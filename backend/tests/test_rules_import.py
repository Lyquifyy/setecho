"""/import/rules: his rules with his quotes, the validator, and nothing personal. Driven by the
hand-written Spark output for the hand-written email; never live."""

import json
from pathlib import Path

import pytest
from fastapi.testclient import TestClient

from app import importing, meta
from app.main import app
from app.schemas import RulesOut, strict_schema

FIXTURES = Path(__file__).parent / "fixtures"
RAW = json.loads((FIXTURES / "spark" / "rules_synthetic_email.json").read_text())["raw"]
EMAIL = (FIXTURES / "import" / "synthetic_rules_email.txt").read_text()


def _import():
    return importing.validate_rules(RulesOut.model_validate(RAW), EMAIL)


def test_rules_schema_is_strict():
    from tests.test_schemas import assert_strict

    assert_strict(strict_schema(RulesOut))


def test_every_rule_comes_with_his_quote_and_nothing_confirmed():
    out = _import()
    assert [r.when for r in out.rules] == ["afterTopSet", "restPauseOverGoal"]
    back_off = out.rules[0]
    assert back_off.adjust == "backOff" and (back_off.minPct, back_off.maxPct) == (20, 25)
    assert back_off.quote == "Back down sets are 20-25% lighter than your top set."
    assert back_off.id == "rule_1" and back_off.source == "Coach's instructions" and not back_off.confirmed
    assert (
        out.rules[1].adjust == "loadSteps"
        and out.rules[1].amount == 1
        and out.rules[1].scope == "nextSession"
    )
    assert [(t.role, t.rir) for t in out.roleTargets] == [("top", 0), ("backOff", 0)]
    assert all(not t.confirmed for t in out.roleTargets)
    assert out.restRules[0].after == "top" and (out.restRules[0].minSeconds, out.restRules[0].maxSeconds) == (
        180,
        240,
    )
    assert out.warmups is not None and (out.warmups.minSets, out.warmups.maxSets, out.warmups.maxReps) == (
        1,
        3,
        8,
    )
    assert out.checkInSchedule is not None
    assert (out.checkInSchedule.everyWeeks, out.checkInSchedule.weekday, out.checkInSchedule.dueBy) == (
        2,
        5,
        "09:00",
    )
    assert out.checkInSchedule.timeZone == "America/Chicago" and not out.checkInSchedule.confirmed
    assert out.quietDays == [1]
    assert out.flags == []


def test_output_carries_no_names_numbers_or_links():
    text = _import().model_dump_json()
    for personal in ("Dan", "555-123-4567", "example-supps", "COACH20", "2400", "creatine"):
        assert personal not in text


def test_quote_missing_from_the_text_moves_the_rule_to_flags():
    raw = json.loads(json.dumps(RAW))
    raw["rules"][0]["quote"] = "Back off sets are 20-25% lighter."  # not his words
    out = importing.validate_rules(RulesOut.model_validate(raw), EMAIL)
    assert [r.when for r in out.rules] == ["restPauseOverGoal"]
    assert len(out.flags) == 1 and out.flags[0].path == "rules[0]" and "not found" in out.flags[0].message


def test_number_missing_from_the_quote_moves_the_rule_to_flags():
    raw = json.loads(json.dumps(RAW))
    raw["rules"][0]["maxPct"] = 30  # the quote says 20-25%
    out = importing.validate_rules(RulesOut.model_validate(raw), EMAIL)
    assert [r.when for r in out.rules] == ["restPauseOverGoal"]
    assert out.flags[0].path == "rules[0]" and "not in his words" in out.flags[0].message
    raw = json.loads(json.dumps(RAW))
    raw["restRules"][0]["maxSeconds"] = 300  # "3-4 minutes"
    out = importing.validate_rules(RulesOut.model_validate(raw), EMAIL)
    assert out.restRules == [] and out.flags[0].path == "restRules[0]"
    raw = json.loads(json.dumps(RAW))
    raw["checkInSchedule"]["weekday"] = 3  # "Thursday"
    out = importing.validate_rules(RulesOut.model_validate(raw), EMAIL)
    assert out.checkInSchedule is None and out.flags[0].path == "checkInSchedule"


def test_a_quote_with_a_link_or_phone_number_is_dropped_without_being_repeated():
    raw = json.loads(json.dumps(RAW))
    raw["rules"].append({
        "appliesTo": None, "when": "aboveTarget", "byRPE": 1, "adjust": "percent", "amount": -20, "minPct": None,
        "maxPct": None, "scope": "nextSet",
        "quote": "Use code COACH20 at www.example-supps.com for 20% off. You can reach me on 555-123-4567.",
    })  # fmt: skip
    out = importing.validate_rules(RulesOut.model_validate(raw), EMAIL)
    assert len(out.rules) == 2 and out.flags[0].path == "rules[2]"
    assert "example-supps" not in out.model_dump_json() and "555" not in out.model_dump_json()


def test_failure_counts_as_zero_reps_in_reserve_and_add_weight_as_one_step():
    out = _import()
    assert out.roleTargets[0].rir == 0 and "fail" in out.roleTargets[0].quote
    assert out.rules[1].amount == 1
    raw = json.loads(json.dumps(RAW))
    raw["roleTargets"][0]["rir"] = 1  # "one left" is not in the quote
    out = importing.validate_rules(RulesOut.model_validate(raw), EMAIL)
    assert [t.role for t in out.roleTargets] == ["backOff"]


def test_numbers_in_text():
    assert importing.numbers_in("Rest 3-4 minutes") == {3, 4}
    assert importing.numbers_in("20-25% lighter") == {20, 25}
    assert importing.numbers_in("every other week by 9am") == {2, 9}
    assert importing.numbers_in("twice a week") == {2}
    assert importing.quote_in_text("rest 3-4  MINUTES after", "Please rest 3-4 minutes after a top set")
    assert not importing.quote_in_text("rest 5 minutes", "Please rest 3-4 minutes after a top set")


def test_instructions_with_targets_but_no_rule_return_no_rule():
    """The validator never adds a rule the model did not return; an empty answer stays empty."""
    out = importing.validate_rules(RulesOut.model_validate({}), "Train hard. Eat well.")
    assert out.rules == [] and out.roleTargets == [] and out.warmups is None and out.flags == []


def test_import_rules_endpoint(monkeypatch):
    calls = []

    def fake(system, user, schema_name, schema):
        calls.append((schema_name, user))
        return RAW, None

    monkeypatch.setattr(meta, "spark_json", fake)
    client = TestClient(app)
    r = client.post("/import/rules", json={"text": EMAIL})
    assert r.status_code == 200, r.text
    body = r.json()
    assert calls[0][0] == "Rules" and "welcome aboard" in calls[0][1]
    assert len(body["rules"]) == 2 and body["quietDays"] == [1] and body["warmups"]["maxReps"] == 8
    assert body["checkInSchedule"]["confirmed"] is False
    assert "Dan" not in r.text and "555" not in r.text
    r = client.post("/import/rules", json={"text": "  "})
    assert r.status_code == 422 and "nothing to import" in r.json()["error"]


@pytest.mark.parametrize("quote,ok", [("by 9am Central", True), ("by 21:00", False), ("at noon", False)])
def test_hour_in_quote(quote, ok):
    assert importing._hour_in("09:00", quote) is ok
