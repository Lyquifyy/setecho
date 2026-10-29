"""Bring your history: Liftoff's CSV and Garmin's FIT files, read by code, and the names matched by
Spark. Every row and set here is made up (tests/fixtures/history/, the FIT written by
scripts/make_history_fixtures.py); the athlete's own files never leave backend/private/."""

import io
import json
import zipfile
from datetime import datetime
from pathlib import Path
from zoneinfo import ZoneInfo

from fastapi.testclient import TestClient

from app import history, meta
from app.history import HistorySet, assign_roles
from app.main import app

FIXTURES = Path(__file__).parent / "fixtures" / "history"
CSV = (FIXTURES / "liftoff_synthetic.csv").read_text()
ZIP = (FIXTURES / "10000000001.zip").read_bytes()
CHICAGO = ZoneInfo("America/Chicago")


def _sets(out, name):
    return [
        (s.loadLb, s.reps, s.role)
        for e in (x for sess in out.sessions for x in sess.exercises)
        if e.name == name
        for s in e.sets
    ]


def test_liftoff_sessions_by_date_in_local_time():
    out = history.parse_liftoff(CSV, tz=CHICAGO)
    assert [s.id for s in out.sessions] == [
        "liftoff:2026-09-28 16:30:00",
        "liftoff:2026-10-02 17:05:10",
        "liftoff:2026-10-05 16:20:00",
    ]
    first = out.sessions[0]
    assert first.source == "liftoff" and first.name is None
    assert first.startedAt == datetime(2026, 9, 28, 16, 30, tzinfo=CHICAGO)


def test_liftoff_keeps_decimals_and_orders_sets():
    out = history.parse_liftoff(CSV)
    # Set Order, not file order: 32.5 was set 0.
    assert _sets(out, "Cable Fly") == [(32.5, 12, "top"), (27.5, 11, "backOff")]


def test_heaviest_set_is_the_top_set_and_lighter_ones_after_are_back_offs():
    out = history.parse_liftoff(CSV)
    # A lighter set before the top set is neither.
    assert _sets(out, "Close Grip Bench Press") == [(135, 10, None), (205, 8, "top"), (175, 11, "backOff")]
    # Same weight on every set: the first is the top set, the rest are straight sets.
    assert _sets(out, "Lat Pulldown") == [(150, 10, "top"), (150, 12, None)]


def test_holds_and_cardio_stay_history_never_lifting_sets():
    out = history.parse_liftoff(CSV)
    plank = next(e for s in out.sessions for e in s.exercises if e.name == "Plank")
    assert [(s.reps, s.seconds, s.role) for s in plank.sets] == [(None, 45, None)]
    cycling = next(e for s in out.sessions for e in s.exercises if e.name == "Cycling")
    assert [(s.reps, s.seconds, s.distance) for s in cycling.sets] == [(None, 300, 3.2)]
    # Bodyweight reps are a set, but no top set: there's no weight to beat.
    assert _sets(out, "Hanging Leg Raise") == [(0, 15, None)]
    # The plank set with nothing recorded and Liftoff's empty workout are left out, and said so.
    assert [(x.exercise, x.sets, x.reason) for x in out.leftOut] == [("Plank", 1, "empty")]


def test_liftoff_notes_stay_once_per_exercise():
    out = history.parse_liftoff(CSV)
    fly = next(e for s in out.sessions for e in s.exercises if e.name == "Cable Fly")
    assert fly.note == "Squeeze at the top"
    assert (
        next(e for s in out.sessions for e in s.exercises if e.name == "Close Grip Bench Press").note is None
    )


def test_liftoff_in_kilograms_converts_to_pounds():
    out = history.parse_liftoff(CSV, unit="kg")
    assert _sets(out, "Close Grip Bench Press")[1] == (452.0, 8, "top")  # 205 kg = 451.95 lb


def test_not_a_liftoff_export_is_refused():
    try:
        history.parse_liftoff("Date,Exercise,Reps\n2026-10-01,Bench,5\n")
    except history.ImportError_ as e:
        assert "not a Liftoff export" in str(e)
    else:
        raise AssertionError("expected a refusal")


def test_garmin_active_sets_converted_to_pounds():
    out = history.parse_garmin_zip(ZIP, "10000000001.zip")
    (session,) = out.sessions
    assert session.id == "garmin:10000000001" and session.name == "Day 1 Workout"
    assert session.startedAt.isoformat() == "2026-10-05T21:00:00+00:00"
    # kg on the 1/16 grid comes back as the pounds he entered: 225, and a 27.5 lb dumbbell.
    assert _sets(out, "Smith Machine Bench Press") == [(225, 8, "top"), (185, 11, "backOff")]
    assert _sets(out, "Incline Dumbbell Flye") == [(27.5, 12, "top")]


def test_garmin_superset_stays_together_and_a_lift_that_comes_back_is_its_own():
    out = history.parse_garmin_zip(ZIP, "10000000001.zip")
    assert [e.name for e in out.sessions[0].exercises] == [
        "Smith Machine Bench Press",
        "Dumbbell Lateral Raise",
        "Triceps Pressdown",
        "Weighted Leg Curl",
        "Barbell Back Squat",
        "Weighted Leg Curl (second)",
        "Incline Dumbbell Flye",
    ]
    assert _sets(out, "Triceps Pressdown") == [(70, 12, "top"), (60, 10, "backOff")]
    assert _sets(out, "Weighted Leg Curl (second)") == [(150, 18, "top")]


def test_garmin_set_without_reps_is_left_out_and_said():
    out = history.parse_garmin_zip(ZIP, "10000000001.zip")
    assert [(x.exercise, x.sets, x.reason) for x in out.leftOut] == [("Dumbbell Lateral Raise", 1, "noReps")]
    assert _sets(out, "Dumbbell Lateral Raise") == [(20, 15, "top"), (20, 12, None)]


def test_garmin_names_come_from_the_profile():
    assert history.garmin_exercise_name("bench_press", 4) == "Close Grip Barbell Bench Press"
    assert history.garmin_exercise_name("bench_press", None) == "Bench Press"
    assert history.garmin_exercise_name("unknown", None) == "Unknown exercise"


def test_a_zip_with_no_fit_and_a_bad_zip():
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w") as z:
        z.writestr("readme.txt", "hi")
    assert history.parse_garmin_zip(buf.getvalue(), "a.zip").sessions == []
    try:
        history.parse_garmin_zip(b"not a zip", "b.zip")
    except history.ImportError_ as e:
        assert "not a zip" in str(e)
    else:
        raise AssertionError("expected a refusal")


def test_assign_roles_ignores_bodyweight_and_holds():
    sets = [HistorySet(order=0, loadLb=0, reps=12), HistorySet(order=1, loadLb=0, seconds=30)]
    assign_roles(sets)
    assert [s.role for s in sets] == [None, None]


def test_endpoint_reads_both_and_sorts_by_time():
    client = TestClient(app)
    resp = client.post(
        "/import/history",
        files=[
            ("files", ("liftoff_workout_data.csv", CSV.encode(), "text/csv")),
            ("files", ("10000000001.zip", ZIP, "application/zip")),
            ("files", ("10000000001.zip", ZIP, "application/zip")),  # shared twice: one session
        ],
        data={"timeZone": "America/Chicago"},
    )
    assert resp.status_code == 200, resp.text
    body = resp.json()
    assert [s["source"] for s in body["sessions"]] == ["liftoff", "liftoff", "garmin", "liftoff"]
    assert body["sessions"][2]["startedAt"] == "2026-10-05T21:00:00Z"
    assert body["sessions"][3]["startedAt"] == "2026-10-05T16:20:00-05:00"
    assert len(body["leftOut"]) == 2


def test_endpoint_refuses_other_files():
    resp = TestClient(app).post("/import/history", files=[("files", ("notes.txt", b"hi", "text/plain"))])
    assert resp.status_code == 422 and "expected Liftoff" in resp.json()["error"]


# ---------------------------------------------------------------------------
# Matching: Spark sees names only, and can only answer with his plan's ids
# ---------------------------------------------------------------------------

PLAN = [
    {"id": "d1-smith-close-grip", "name": "Smith close-grip bench"},
    {"id": "d1-pressdown", "name": "Rope pressdown"},
    {"id": "d2-lying-curl", "name": "Lying leg curl"},
]


def test_match_sends_names_only_and_validates(monkeypatch):
    seen = {}

    def fake(system, user, name, schema, **kw):
        seen["user"], seen["schema"] = user, schema
        return (
            {
                "matches": [
                    {"name": "Close Grip Bench Press", "exerciseId": "d1-smith-close-grip"},
                    {"name": "Triceps Pressdown", "exerciseId": "d1-pressdown"},
                    {"name": "Triceps Pressdown", "exerciseId": "d2-lying-curl"},  # a second answer: ignored
                    {"name": "Barbell Back Squat", "exerciseId": "none"},
                    {"name": "Made Up", "exerciseId": "d1-pressdown"},  # not his name: dropped
                    {"name": "Weighted Leg Curl", "exerciseId": "invented-id"},  # not his plan: unmatched
                ]
            },
            None,
        )

    monkeypatch.setattr(meta, "spark_json", fake)
    names = [
        "Close Grip Bench Press",
        "Triceps Pressdown",
        "Barbell Back Squat",
        "Weighted Leg Curl",
        "Plank",
    ]
    resp = TestClient(app).post("/import/history/match", json={"names": names, "exercises": PLAN})
    assert resp.status_code == 200, resp.text
    assert resp.json()["matches"] == [
        {"name": "Close Grip Bench Press", "exerciseId": "d1-smith-close-grip"},
        {"name": "Triceps Pressdown", "exerciseId": "d1-pressdown"},
        {"name": "Barbell Back Squat", "exerciseId": None},
        {"name": "Weighted Leg Curl", "exerciseId": None},
        {"name": "Plank", "exerciseId": None},
    ]
    # Names and plan exercises only: no weights, reps, dates or notes.
    assert "Squeeze" not in seen["user"] and "225" not in seen["user"]
    items = seen["schema"]["properties"]["matches"]["items"]["properties"]
    assert items["name"]["enum"] == names
    assert items["exerciseId"]["enum"] == ["d1-smith-close-grip", "d1-pressdown", "d2-lying-curl", "none"]


def test_match_without_names_or_plan_never_calls_spark(monkeypatch):
    monkeypatch.setattr(meta, "spark_json", lambda *a, **k: (_ for _ in ()).throw(AssertionError("called")))
    client = TestClient(app)
    assert client.post("/import/history/match", json={"names": [], "exercises": PLAN}).json() == {
        "matches": []
    }
    assert client.post("/import/history/match", json={"names": ["Plank"], "exercises": []}).json() == {
        "matches": [{"name": "Plank", "exerciseId": None}]
    }


def test_match_schema_is_strict():
    schema = history.match_schema(["A"], ["x"])
    assert json.dumps(schema)  # serializable
    item = schema["properties"]["matches"]["items"]
    assert item["additionalProperties"] is False and set(item["required"]) == {"name", "exerciseId"}
