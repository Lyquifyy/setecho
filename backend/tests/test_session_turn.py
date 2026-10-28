"""The session conversation (HANDOFF.md §5 /session/turn, §7 Talk to it like a person). Scenarios
A-L in natural speech, each line said several ways, through the real fast path and validator with
Spark's answers canned in the fixtures; multi-action turns, follow-ups, talk not meant for Setecho,
advice asked for, and every number in every reply traced to the facts or his words. No live calls."""

import json
from pathlib import Path

import pytest
from fastapi.testclient import TestClient

from app import meta, session_turn, voice
from app.main import app

FIXTURES = Path(__file__).parent / "fixtures" / "session_turns"
SCENARIOS = sorted(FIXTURES.glob("*.json"))


def _cases():
    for path in SCENARIOS:
        scenario = json.loads(path.read_text())
        for i, turn in enumerate(scenario["turns"]):
            yield pytest.param(scenario, turn, id=f"{scenario['scenario']}[{i}] {turn['say']}")


def _request(scenario: dict, turn: dict) -> session_turn.TurnRequest:
    facts = {**(turn.get("facts") or scenario["facts"]), "state": turn["state"]}
    return session_turn.TurnRequest(
        transcript=turn["say"], state=turn["state"], recentTurns=turn.get("recent", []), facts=facts
    )


def _canned(monkeypatch, raw: dict | None) -> list[str]:
    """Spark answers with the fixture's turn; a fast-path line must never reach it."""
    calls: list[str] = []

    def fake(system, user, name, schema, effort=None):
        calls.append(user)
        if raw is None:
            raise AssertionError("the fast path called Spark")
        return raw, {}

    monkeypatch.setattr(meta, "spark_json", fake)
    return calls


def _actions(response: session_turn.TurnResponse) -> list[dict]:
    return [
        {k: v for k, v in a.model_dump().items() if v is not None and k not in ("confidence", "fieldId")}
        for a in response.actions
    ]


def test_every_scenario_a_to_l_is_here():
    names = {p.stem[0] for p in SCENARIOS}
    assert set("abcdefghijkl") <= names


@pytest.mark.parametrize(("scenario", "turn"), list(_cases()))
def test_scenarios_in_natural_speech(monkeypatch, scenario, turn):
    calls = _canned(monkeypatch, turn["spark"])
    out = session_turn.take_turn(_request(scenario, turn))
    expect = turn["expect"]
    assert out.classifiedBy == expect["via"], out
    assert out.addressed == expect["addressed"]
    assert _actions(out) == expect["actions"]
    if "reply" in expect:
        assert out.reply == expect["reply"]
    if "expectsAnswer" in expect:
        assert out.expectsAnswer == expect["expectsAnswer"]
    assert bool(calls) == (expect["via"] != "rules")


@pytest.mark.parametrize(("scenario", "turn"), list(_cases()))
def test_every_number_in_every_reply_is_in_the_facts_or_his_words(monkeypatch, scenario, turn):
    _canned(monkeypatch, turn["spark"])
    req = _request(scenario, turn)
    out = session_turn.take_turn(req)
    if out.reply in (None, session_turn.COACH_LINE, session_turn.SAY_AGAIN):
        return
    known = session_turn.known_numbers(req.facts, req.transcript, req.recentTurns)
    for n in session_turn.numbers_in(out.reply):
        assert any(abs(n - k) < 1e-6 for k in known), (out.reply, n)


def test_during_a_set_only_set_commands_count_and_spark_is_never_called(monkeypatch):
    _canned(monkeypatch, None)
    facts = {"state": "recording"}
    for said, intent in [
        ("done", "endSet"),
        ("done, 9", "endSet"),
        ("that was 8", "reps"),
        ("top set", "topSet"),
    ]:
        out = session_turn.take_turn(
            session_turn.TurnRequest(transcript=said, state="recording", facts=facts)
        )
        assert [a.intent for a in out.actions] == [intent]
    for said in ["the incline's taken", "what's next", "come on", "go"]:
        out = session_turn.take_turn(
            session_turn.TurnRequest(transcript=said, state="recording", facts=facts)
        )
        assert out.actions == [] and not out.addressed


@pytest.mark.parametrize(
    "said",
    [
        "go",
        "starting",
        "here we go",
        "lifting",
        "back-off",
        "back off set",
        "set two",
        "alright, going",
        "ok go",
    ],
)
def test_arm_phrases_are_the_fast_path(monkeypatch, said):
    _canned(monkeypatch, None)
    out = session_turn.take_turn(
        session_turn.TurnRequest(transcript=said, state="ready", facts={"state": "ready"})
    )
    assert [a.intent for a in out.actions] == ["starting"], said
    assert out.reply is None


def test_back_off_with_a_number_is_still_a_load_change():
    assert voice.classify_by_rules("back off ten").intent == "loadDelta"
    assert voice.classify_by_rules("set two was 7").intent == "reps"


def test_a_model_failure_falls_back_to_the_rules(monkeypatch):
    def boom(*a, **k):
        raise TimeoutError

    monkeypatch.setattr(meta, "spark_json", boom)
    req = session_turn.TurnRequest(
        transcript="how long have I got left", state="rest", facts={"state": "rest"}
    )
    out = session_turn.take_turn(req)
    assert out.classifiedBy == "fallback"
    assert [(a.intent, a.topic) for a in out.actions] == [("question", "restLeft")]
    assert out.unclearReason == "model: TimeoutError"


def test_reply_checks():
    known = {9.0, 205.0, 140.0}
    assert session_turn.check_reply("Nine on set two.", known | {2.0}) is None
    assert session_turn.check_reply("Last time 205 for 9.", known) is None
    assert session_turn.check_reply("You should go 205.", known) == "advice"
    assert session_turn.check_reply("Nice set, nine reps.", known) == "judging"
    assert session_turn.check_reply("Two fifteen next.", known | {2.0}) == "number 215"
    assert session_turn.check_reply(" ".join(["word"] * 21), known) == "too long"


def test_endpoint_returns_the_turn(monkeypatch):
    _canned(monkeypatch, None)
    client = TestClient(app)
    r = client.post(
        "/session/turn/text",
        json={"transcript": "done, 12", "state": "ready", "recentTurns": [], "facts": {"state": "ready"}},
    )
    assert r.status_code == 200, r.text
    body = r.json()
    assert body["actions"][0]["intent"] == "endSet" and body["actions"][0]["number"] == 12
    assert body["addressed"] is True and body["reply"] is None
