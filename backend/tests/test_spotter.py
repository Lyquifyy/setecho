"""/spotter/line: the validator rejects a number not in the facts, advice, a suggestion the facts
don't carry, and an opening it used recently. Spark is replaced."""

from fastapi.testclient import TestClient

from app import meta, spotter
from app.main import app
from app.schemas import ProgramOut, strict_schema


def facts(**over):
    base = {
        "exercise": "Incline DB press", "setNumber": 3, "setCount": 4, "reps": 8, "repSource": "measured",
        "loadLb": 70, "velocityLossPct": 38.0, "estimatedRIR": 1, "target": "failure", "role": "top",
    }  # fmt: skip
    base.update(over)
    return spotter.SpotterFacts(**base)


def test_a_line_with_only_the_facts_numbers_passes():
    f = facts(isPR=True, suggestionLb=165, suggestionRule="20 to 25% lighter")
    assert spotter.validate("Big set. Eight, and that last one was a grind.", f, []) is None
    assert spotter.validate("Set 3 of 4 done, 8 reps at 70. Back-off at 165, his rule.", f, []) is None
    assert spotter.validate("Slowed 38 percent, about 1 left by the measure.", f, []) is None


def test_a_number_not_in_the_facts_fails():
    assert spotter.validate("Nine reps, nice.", facts(), []) == "number 9"
    assert spotter.validate("Try 215 next.", facts(), []) is not None
    assert spotter.validate("Set 3 of 4, 8 at 70.5.", facts(), []) == "number 70.5"


def test_advice_and_length_fail():
    assert spotter.validate("You should keep your elbows in.", facts(), []) == "advice"
    assert spotter.validate("Go heavier next set.", facts(), []) == "advice"
    assert spotter.validate(" ".join(["word"] * 31), facts(), []) == "too long"
    assert spotter.validate("", facts(), []) == "empty"


def test_a_suggestion_the_facts_do_not_carry_fails():
    assert spotter.validate("Next set at 70.", facts(), []) == "suggestion the facts don't carry"
    assert (
        spotter.validate(
            "Next set at 165, his rule.", facts(suggestionLb=165, suggestionRule="20-25% lighter"), []
        )
        is None
    )


def test_an_opening_used_recently_fails():
    recent = ["Big set. Eight and done.", "Nice work, 8 clean."]
    assert spotter.validate("Big set, that's 8.", facts(), recent) == "repeats an opening"
    assert spotter.validate("Eight on the nose.", facts(), recent) is None


def test_endpoint_falls_back_when_the_line_fails(monkeypatch):
    client = TestClient(app)
    body = {
        "moment": "restAfterSet",
        "facts": facts().model_dump(),
        "recent": [],
        "styleHints": ["first name: Zander"],
    }
    monkeypatch.setattr(
        meta, "spark_json", lambda *a, **k: ({"text": "Eight, and that last one was a grind."}, None)
    )
    r = client.post("/spotter/line", json=body)
    assert r.status_code == 200 and r.json() == {"text": "Eight, and that last one was a grind.", "ok": True}
    monkeypatch.setattr(meta, "spark_json", lambda *a, **k: ({"text": "Nine reps, go heavier."}, None))
    r = client.post("/spotter/line", json=body)
    assert r.status_code == 200 and r.json() == {"text": "", "ok": False}
    assert (
        client.post("/spotter/line", json={"moment": "nap", "facts": facts().model_dump()}).status_code == 422
    )


def test_schemas_are_strict():
    from tests.test_schemas import assert_strict

    assert_strict(spotter.LINE_SCHEMA)
    assert_strict(strict_schema(ProgramOut))
    assert "rules" in strict_schema(ProgramOut)["properties"]


def test_quick_calls_ask_spark_for_low_effort(monkeypatch):
    seen = {}

    def fake(system, user, schema_name, schema, **kw):
        seen[schema_name] = kw
        return {"text": "Eight, and done."}, None

    monkeypatch.setattr(meta, "spark_json", fake)
    spotter.write_line(spotter.LineRequest(moment="restAfterSet", facts=facts()))
    assert seen["SpotterLine"] == {"effort": "low"}  # never a token cap: reasoning tokens count against it


def test_a_reaction_is_asked_for_the_human_part_and_checked_the_same_way(monkeypatch):
    seen = {}

    def fake(system, user, name, schema, **kw):
        seen["user"] = user
        return {"text": "One more than last time at 70. That one was a grind."}, None

    monkeypatch.setattr(meta, "spark_json", fake)
    body = {
        "moment": "reaction",
        "facts": facts(lastTimeLoadLb=70, lastTimeReps=7).model_dump(),
        "recent": ["8 reps, measured."],
    }
    resp = TestClient(app).post("/spotter/line", json=body)
    assert resp.json() == {"text": "One more than last time at 70. That one was a grind.", "ok": True}
    assert "Add one short reaction" in seen["user"] and "don't ask a question" in seen["user"]
    # A reaction with a number the facts don't hold is dropped, like any line.
    monkeypatch.setattr(
        meta, "spark_json", lambda *a, **k: ({"text": "Two more than the 65 last week."}, None)
    )
    assert TestClient(app).post("/spotter/line", json=body).json() == {"text": "", "ok": False}
