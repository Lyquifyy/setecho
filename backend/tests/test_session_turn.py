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


def test_during_a_set_set_commands_and_plain_questions_need_no_spark(monkeypatch):
    _canned(monkeypatch, None)
    facts = {"state": "recording"}
    for said, intent in [
        ("done", "endSet"),
        ("done, 9", "endSet"),
        ("that was 8", "reps"),
        ("top set", "topSet"),
        ("what's next", "question"),
        ("what do I got for the rest of this lift?", "question"),
        ("what weight is my next set", "question"),
    ]:
        out = session_turn.take_turn(
            session_turn.TurnRequest(transcript=said, state="recording", facts=facts)
        )
        assert [a.intent for a in out.actions] == [intent], said
        assert out.classifiedBy == "rules"
    # Grunts, counting aloud, someone else, and commands that wait for the rest: silence, and no Spark.
    for said in ["the incline's taken", "come on", "go", "one more", "push it baby", "ugh"]:
        out = session_turn.take_turn(
            session_turn.TurnRequest(transcript=said, state="recording", facts=facts)
        )
        assert out.actions == [] and not out.addressed, said


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


# ---------------------------------------------------------------------------
# Oct 30, Day 5 in the gym
# ---------------------------------------------------------------------------

LATERALS = {
    "state": "rest",
    "exercise": "Seated DB Lateral Raises",
    "setNumber": 1,
    "setCount": 3,
    "targetLoadLb": 25,
    "targetReps": "10-15",
    "exercises": [
        {
            "name": "Seated DB Lateral Raises",
            "setsPlanned": 3,
            "setsDone": 0,
            "target": "10-15 reps",
            "loadLb": 25,
        },
        {"name": "Machine Shoulder Press", "setsPlanned": 1, "setsDone": 0, "target": "25 total reps"},
    ],
}


def _rest(said: str, recent: list[dict] | None = None) -> session_turn.TurnRequest:
    return session_turn.TurnRequest(transcript=said, state="rest", recentTurns=recent or [], facts=LATERALS)


@pytest.mark.parametrize("said", ["What weight should I do?", "What weight?", "What weight for my next set?"])
def test_the_plans_weight_is_never_the_coach_line(monkeypatch, said):
    """Spark marked these out of scope with the weight on his screen: the phone's template answers."""
    _canned(
        monkeypatch,
        {"addressed": True, "actions": [], "reply": "", "expectsAnswer": False, "outOfScope": True},
    )
    out = session_turn.take_turn(_rest(said))
    assert out.reply is None
    assert _actions(out) == [{"intent": "question", "topic": "load"}]


def test_real_advice_still_gets_the_coach_line(monkeypatch):
    _canned(
        monkeypatch,
        {"addressed": True, "actions": [], "reply": "", "expectsAnswer": False, "outOfScope": True},
    )
    out = session_turn.take_turn(_rest("should I go heavier next week?"))
    assert out.reply == session_turn.COACH_LINE


def test_the_prompt_calls_the_plans_weight_a_fact():
    assert "is a fact" in session_turn.SYSTEM
    assert "what weight to use" not in session_turn.SYSTEM
    assert "rest of this lift" in session_turn.SYSTEM


def test_a_load_and_a_count_go_to_spark_with_the_turns_before(monkeypatch):
    """ "12.5 for 13 reps" after "Change that third set to what?": the rules took 12.5 as the count."""
    calls = _canned(
        monkeypatch,
        {
            "addressed": True,
            "actions": [{"intent": "reps", "number": 13, "reps": None, "setNumber": 3, "text": None}],
            "reply": "Third set, 13 reps.",
            "expectsAnswer": False,
            "outOfScope": False,
        },
    )
    recent = [
        {"heard": "Change the cable lateral raises third set to", "said": "Change that third set to what?"}
    ]
    out = session_turn.take_turn(_rest("12.5 for 13 reps.", recent))
    assert calls and out.classifiedBy == "spark"
    assert _actions(out)[0]["number"] == 13


def test_never_mind_is_not_addressed_and_changes_nothing(monkeypatch):
    _canned(monkeypatch, None)
    out = session_turn.take_turn(_rest("Hey, never mind."))
    assert (out.actions, out.addressed) == ([], False)


@pytest.mark.parametrize("said", ["then got 11.", "Dann.", "Set Dan.", "Done. 35.", "Set done. 35 reps."])
def test_done_mid_set_as_heard_on_oct_30(monkeypatch, said):
    _canned(monkeypatch, None)
    out = session_turn.take_turn(
        session_turn.TurnRequest(transcript=said, state="recording", facts={**LATERALS, "state": "recording"})
    )
    assert [a.intent for a in out.actions] == ["endSet"]


# ---------------------------------------------------------------------------
# Oct 30: "I need to be able to say anything to it during the set"
# ---------------------------------------------------------------------------

LATERALS_FACTS = {
    "state": "recording",
    "exercise": "Single Arm Triceps Pushdowns",
    "setNumber": 1,
    "setCount": 4,
    "targetLoadLb": 27.5,
    "targetReps": "10-12",
    "exercises": [
        {
            "name": "Seated DB Lateral Raises",
            "setsPlanned": 3,
            "setsDone": 3,
            "target": "10-15 reps",
            "loadLb": 20,
        },
        {
            "name": "Cable Lateral Raises",
            "setsPlanned": 2,
            "setsDone": 2,
            "target": "12-15 reps",
            "loadLb": 12.5,
        },
        {
            "name": "Single Arm Triceps Pushdowns",
            "setsPlanned": 4,
            "setsDone": 0,
            "target": "10-12 reps",
            "loadLb": 27.5,
        },
    ],
}


def test_mid_set_talk_meant_for_setecho_goes_to_spark_with_its_actions_held_to_the_bar(monkeypatch):
    calls = _canned(
        monkeypatch,
        {
            "addressed": True,
            "actions": [
                {"intent": "setLoad", "number": 25, "reps": None, "setNumber": None, "text": None},
                {
                    "intent": "skipExercise",
                    "number": None,
                    "reps": None,
                    "setNumber": None,
                    "text": "pushdowns",
                },
            ],
            "reply": "Got it, 25 on this one.",
            "expectsAnswer": True,
            "outOfScope": False,
        },
    )
    out = session_turn.take_turn(
        session_turn.TurnRequest(
            transcript="hey this one's actually 25 pounds", state="recording", facts=LATERALS_FACTS
        )
    )
    assert calls and out.classifiedBy == "spark" and out.addressed
    assert [(a.intent, a.number) for a in out.actions] == [("setLoad", 25)]
    assert out.reply == "Got it, 25 on this one." and not out.expectsAnswer


def test_mid_set_a_failed_or_unsure_read_is_silence_never_say_that_again(monkeypatch):
    def boom(*a, **k):
        raise TimeoutError

    monkeypatch.setattr(meta, "spark_json", boom)
    req = session_turn.TurnRequest(
        transcript="what are you doing later", state="recording", facts=LATERALS_FACTS
    )
    out = session_turn.take_turn(req)
    assert out.actions == [] and not out.addressed and out.reply is None
    _canned(
        monkeypatch,
        {
            "addressed": True,
            "actions": [],
            "reply": "You should go lighter.",
            "expectsAnswer": False,
            "outOfScope": False,
        },
    )
    out = session_turn.take_turn(req)
    assert out.reply != "You should go lighter." and out.reply != session_turn.SAY_AGAIN


def test_mid_set_advice_gets_the_coach_line_without_an_ask(monkeypatch):
    _canned(
        monkeypatch,
        {"addressed": True, "actions": [], "reply": "", "expectsAnswer": False, "outOfScope": True},
    )
    out = session_turn.take_turn(
        session_turn.TurnRequest(
            transcript="how's my form looking on these", state="recording", facts=LATERALS_FACTS
        )
    )
    assert out.actions == [] and out.reply == "That's one for your coach." and not out.expectsAnswer


@pytest.mark.parametrize(
    ("said", "state"),
    [
        ("that was another set of laterals", "rest"),
        ("that last one was cable laterals", "rest"),
        ("no, that was an extra set of laterals", "rest"),
        ("this is an extra set of cable laterals", "recording"),
    ],
)
def test_a_set_on_the_wrong_lift_moves_back_by_name(monkeypatch, said, state):
    _canned(monkeypatch, None)
    out = session_turn.take_turn(
        session_turn.TurnRequest(transcript=said, state=state, facts={**LATERALS_FACTS, "state": state})
    )
    assert [a.intent for a in out.actions] == ["addSet"], said
    assert voice.name_matches(out.actions[0].text, "Cable Lateral Raises")


def test_that_was_with_no_lift_named_is_not_an_extra_set():
    ctx = voice.SessionContext(
        state="rest", exercisesToday=["Cable Lateral Raises", "Single Arm Triceps Pushdowns"]
    )
    for said in ["that was heavy", "that was 12", "that was the last one", "that was set two"]:
        ruled = voice.classify_by_rules(said, ctx)
        assert ruled is None or ruled.intent != "addSet", said


def test_the_rest_of_this_lift_is_sets_left():
    for said in [
        "what do I got for the rest of this lift",
        "what's left",
        "what have I got left",
        "what do I have left on this exercise",
    ]:
        ruled = voice.classify_by_rules(said)
        assert ruled is not None and (ruled.intent, ruled.topic) == ("question", "setsLeft"), said
    for said in ["what weight do I need to do for my next set", "how much should I be lifting"]:
        ruled = voice.classify_by_rules(said)
        assert ruled is not None and (ruled.intent, ruled.topic) == ("question", "load"), said
