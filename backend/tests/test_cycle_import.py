"""The athlete's sheet shape (HANDOFF.md §7, Training cycle): an add-on tab first, rest tabs with a
cardio line, timed holds, top/back-down and rest-pause sets, a day-level rest period, "or" options
and slash names. Driven by the hand-written Spark output for the hand-made sheet; never live."""

import json
from datetime import UTC, datetime
from pathlib import Path

from fastapi.testclient import TestClient

from app import meta
from app.main import app
from app.schemas import ProgramOut, strict_schema, to_program

FIXTURES = Path(__file__).parent / "fixtures"
RAW = json.loads((FIXTURES / "spark" / "program_synthetic_cycle.json").read_text())["raw"]
SHEET = (FIXTURES / "import" / "synthetic_cycle_sheet.txt").read_text()


def _program():
    return to_program(ProgramOut.model_validate(RAW), datetime(2026, 10, 28, tzinfo=UTC))


def test_the_sheet_has_the_athletes_shape():
    assert SHEET.startswith("## Sheet: Ab Training")  # the add-on tab comes first, as on his sheet
    assert SHEET.count("## Sheet:") == 8 and "## Sheet: Rest 2" in SHEET


def test_cycle_days_and_add_ons_are_kept_apart():
    program = _program()
    days = program.weeks[0].days
    assert [d.name for d in days] == ["Day 1", "Day 2", "Day 3", "Rest", "Day 5", "Day 6", "Rest 2"]
    assert [d.kind for d in days] == ["training"] * 3 + ["rest"] + ["training"] * 2 + ["rest"]
    assert sum(d.kind == "training" for d in days) == 5 and sum(d.kind == "rest" for d in days) == 2
    assert days[3].exercises == [] and days[3].cardio == "25 minutes of fasted LISS"
    assert days[0].cardio is None
    assert [a.name for a in program.addOns] == ["Stomach Vacuums", "Abs"]
    assert [a.id for a in program.addOns] == ["addon_stomach_vacuums", "addon_abs"]
    assert program.addOns[0].timing == "onWaking" and program.addOns[0].perWeek == 4
    assert program.addOns[0].quote == "Complete these 4x per week upon waking:"
    assert program.addOns[1].timing == "withSession" and program.addOns[1].perWeek == 2
    assert program.flags == []


def test_timed_sets_set_seconds_and_keep_reps_null():
    program = _program()
    bike = program.weeks[0].days[0].exercises[0]
    assert bike.name == "Stationary Bike" and bike.sets[0].seconds == 300 and bike.sets[0].reps is None
    vacuums = program.addOns[0].exercises[0]
    assert len(vacuums.sets) == 4 and all(s.seconds == 20 and s.reps is None for s in vacuums.sets)
    plank = program.addOns[1].exercises[2]
    assert all(s.seconds == 60 for s in plank.sets)


def test_set_roles_and_rest_pause_totals():
    day1 = _program().weeks[0].days[0]
    incline = day1.exercises[1]
    assert [s.role for s in incline.sets] == ["top", "backOff"]
    assert incline.sets[0].repsMin == 6 and incline.sets[0].repsMax == 8
    flat = day1.exercises[2]
    assert [s.role for s in flat.sets] == ["top", "restPause"] and flat.sets[1].totalReps == 20
    pec = day1.exercises[3]
    assert len(pec.sets) == 1 and pec.sets[0].role == "restPause" and pec.sets[0].totalReps == 20
    curl = _program().weeks[0].days[2].exercises[3]
    assert [s.role for s in curl.sets] == ["top", "backOff"]  # "work down set"


def test_day_level_rest_period_applies_to_every_exercise_that_day():
    day1 = _program().weeks[0].days[0]
    assert all(ex.restSeconds == 180 and ex.restMinSeconds == 90 for ex in day1.exercises)


def test_or_options_and_slash_names_become_alternates():
    program = _program()
    hack = program.weeks[0].days[1].exercises[0]
    assert hack.name == "Hack Squat"
    assert [(a.name, a.quote, a.source) for a in hack.alternates] == [
        ("Leg Press", "Hack Squat or Leg Press", "Sheet")
    ]
    raises = program.addOns[1].exercises[0]
    assert raises.name == "Hanging/Lying Leg Raises"
    assert [(a.name, a.quote) for a in raises.alternates] == [
        ("Lying Leg Raises", "Hanging/Lying Leg Raises")
    ]
    assert program.weeks[0].days[0].exercises[4].alternates == []


def test_ids_are_assigned_by_code():
    program = _program()
    assert program.weeks[0].days[3].id == "w1_rest" and program.weeks[0].days[6].id == "w1_rest_2"
    assert program.addOns[1].exercises[0].id == "addon_abs_hanging_lying_leg_raises"


def test_old_fixture_without_the_new_fields_still_imports():
    old = json.loads((FIXTURES / "spark" / "program_synthetic_program.json").read_text())["raw"]
    program = to_program(ProgramOut.model_validate(old), datetime(2026, 10, 28, tzinfo=UTC))
    assert program.addOns == [] and all(d.kind == "training" for d in program.weeks[0].days)
    assert program.weeks[0].days[0].exercises[0].alternates == []


def test_program_schema_lists_the_new_fields_and_stays_strict():
    schema = strict_schema(ProgramOut)
    assert "addOns" in schema["properties"] and "addOns" in schema["required"]
    day = schema["properties"]["weeks"]["items"]["properties"]["days"]["items"]
    assert set(day["properties"]) == {"name", "kind", "cardio", "restSeconds", "restMinSeconds", "exercises"}
    planned_set = day["properties"]["exercises"]["items"]["properties"]["sets"]["items"]
    assert {"seconds", "totalReps", "role"} <= set(planned_set["properties"])
    assert planned_set["properties"]["role"]["anyOf"][0]["enum"] == ["top", "backOff", "restPause"]


def test_import_program_endpoint_returns_the_cycle(monkeypatch):
    monkeypatch.setattr(meta, "spark_json", lambda *a, **k: (RAW, None))
    r = TestClient(app).post("/import/program", data={"text": SHEET})
    assert r.status_code == 200, r.text
    body = r.json()
    assert len(body["weeks"][0]["days"]) == 7 and len(body["addOns"]) == 2
    assert body["weeks"][0]["days"][3]["kind"] == "rest"
    assert body["weeks"][0]["days"][0]["exercises"][1]["sets"][1]["role"] == "backOff"
    assert body["addOns"][0]["exercises"][0]["sets"][0]["seconds"] == 20
