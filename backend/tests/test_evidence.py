"""scripts/evidence.py on made-up data: a Liftoff export and one Setecho session export."""

import json
from datetime import UTC, datetime, timedelta
from zoneinfo import ZoneInfo

from scripts import evidence

TZ = ZoneInfo("America/Chicago")


def _liftoff(tmp_path):
    rows = ["Date,Duration,Workout Name,Exercise Name,Set Order,Weight,Reps,Distance,Seconds,RPE,Notes"]
    # Four Fridays before, 64 min each with 16 sets over 8 lifts; one Friday after Setecho started.
    fridays = [
        ("2026-10-02", 64),
        ("2026-10-09", 60),
        ("2026-10-16", 68),
        ("2026-10-23", 64),
        ("2026-10-30", 70),
    ]
    for date, dur in fridays:
        for i in range(16):
            duration = f"01 hours {dur - 60:02d} minutes 00 seconds"
            rows.append(f"{date} 16:20:00,{duration},,Lift {i % 8},{i % 2},137.5,10,0,0,,")
    # An abs-only add-on: not a full session.
    for i in range(4):
        rows.append(f"2026-10-09 18:00:00,00 hours 20 minutes 00 seconds,,Abs {i},0,0,15,0,0,,")
    path = tmp_path / "liftoff.csv"
    path.write_text("\n".join(rows))
    return path


def _set(
    start, *, role=None, reps=10, rpe=None, source="measured", measured=None, phone=None, rir=None, edits=()
):
    return {
        "id": "x",
        "exerciseId": "e",
        "setIndex": 0,
        "loadLb": 137.5,
        "reps": reps,
        "rpe": rpe,
        "role": role,
        "flaggedForCoach": False,
        "startedAt": start.isoformat().replace("+00:00", "Z"),
        "endedAt": (start + timedelta(seconds=45)).isoformat().replace("+00:00", "Z"),
        "repCount": {
            "source": source,
            "measured": measured,
            "phone": phone,
            "estimatedRIR": rir,
            "repTimes": [],
            "status": "done",
        },
        "edits": [
            {
                "at": "2026-10-30T21:00:00Z",
                "field": "reps",
                "from": "9",
                "to": "10",
                "transcript": "that was 10",
            }
            for _ in edits
        ],
    }


def _session(tmp_path):
    t0 = datetime(2026, 10, 30, 21, 0, tzinfo=UTC)  # 4:00 PM Central, a Friday
    sets = [_set(t0, role="warmup", source="phone", phone=8)]
    m = lambda n: t0 + timedelta(minutes=n)
    sets.append(_set(m(3), role="top", reps=9, rpe=10, source="spoken", measured=9, phone=8, rir=0.5))
    sets.append(_set(m(8), role="backOff", reps=11, rpe=9, source="spoken", measured=10, phone=11, rir=1.0))
    sets.append(_set(m(11), reps=10, source="measured", measured=10, phone=10, edits=[1]))
    sets.append(_set(m(14), reps=12, source="measured", measured=12))  # accepted, unverified
    written_back = _set(m(15), reps=7, source="measured", measured=7, edits=[1])
    written_back["edits"][0].update({"from": "8", "to": "7", "transcript": "measured"})
    sets.append(written_back)  # SAM's own write-back, also accepted, not his word
    sets.append(_set(m(16), reps=6, source="phone", measured=13, phone=6))  # SAM and phone disagree, he said nothing
    sets += [_set(t0 + timedelta(minutes=18 + 2 * i), reps=12, source="spoken") for i in range(10)]
    data = {
        "session": {
            "id": "s",
            "programDayId": "day5",
            "startedAt": t0.isoformat().replace("+00:00", "Z"),
            "endedAt": (t0 + timedelta(minutes=40)).isoformat().replace("+00:00", "Z"),
            "sets": sets,
        },
        "counts": [
            {"setId": "x", "attempt": 1, "at": "", "secondsAfterSetEnd": s, "response": {}}
            for s in (40, 60, 111)
        ],
        "utterances": [
            {"at": "", "seconds": 1, "state": "", "intent": "logSet", "toIntent": 0.6, "transcript": "ten"},
            {"at": "", "seconds": 1, "state": "", "intent": None, "toIntent": 2.1, "transcript": "how long"},
            {"at": "", "seconds": 1, "state": "", "intent": None, "error": "too short"},  # no words
            {"at": "", "seconds": 1, "state": "", "kind": "nearMiss", "transcript": "hm"},
        ],
    }
    folder = tmp_path / "sessions"
    folder.mkdir()
    (folder / "setecho-session-2026-10-30-abcd.json").write_text(json.dumps(data))
    return folder


def test_liftoff_sessions_and_full_days(tmp_path):
    workouts = evidence.read_liftoff(_liftoff(tmp_path), TZ)
    assert len(workouts) == 6
    assert len([w for w in workouts if evidence.is_full(w)]) == 5
    assert workouts[0].minutes == 64 and workouts[0].sets == 16


def test_before_setecho_leaves_out_liftoff_run_beside_it(tmp_path):
    workouts = evidence.read_liftoff(_liftoff(tmp_path), TZ)
    before = evidence.before_setecho(workouts)
    assert [w.started.day for w in before] == [2, 9, 16, 23]


def test_session_against_the_same_weekday(tmp_path):
    workouts = evidence.read_liftoff(_liftoff(tmp_path), TZ)
    [session] = evidence.read_sessions(_session(tmp_path), TZ)
    assert round(session.minutes) == 40
    assert len(session.working_sets) == 16  # the warm-up is left out
    base = evidence.baseline_for(session, workouts)
    assert sorted(w.minutes for w in base) == [60, 64, 64, 68]


def test_counts_are_checked_only_against_his_number(tmp_path):
    a = evidence.count_agreement(evidence.read_sessions(_session(tmp_path), TZ))
    # Verified: the top set (9 = 9), the back-off (10 vs 11), the corrected set (10 = 10).
    assert (a.verified, a.exact, a.within_one) == (3, 2, 3)
    assert a.accepted_unverified == 2  # the plain accept and SAM's own write-back
    assert a.disagreed_unverified == 1
    assert (a.phone_verified, a.phone_exact) == (3, 2)


def test_every_camera_set_is_listed_with_its_result(tmp_path):
    rows = evidence.camera_sets(evidence.read_sessions(_session(tmp_path), TZ))
    assert [r["result"] for r in rows] == [
        "matched his count",  # top set, 9 said, SAM 9
        "missed: he said 11",  # back-off, SAM 10
        "matched his count",  # corrected to 10, SAM 10
        "accepted, not verified",
        "accepted, not verified",  # SAM's own write-back is not his word
        "under the confidence bar: the phone's count stood, not verified",
    ]
    assert rows[0]["role"] == "top" and rows[1]["role"] == "back-off" and rows[2]["role"] == "working"
    assert rows[-1]["sam"] == "13" and rows[-1]["phone"] == "6" and rows[-1]["logged"] == "6"


def test_lift_names_drop_the_plan_prefix():
    assert evidence.lift_name("w1_day_6_chest_supported_machine_rows_plate_loaded") == (
        "Chest supported machine rows plate loaded"
    )
    assert evidence.lift_name("w1_day_5_db_seated_shoulder_press") == "DB seated shoulder press"
    assert evidence.lift_name(None) == "—"


def test_effort_pairs_and_report(tmp_path):
    workouts = evidence.read_liftoff(_liftoff(tmp_path), TZ)
    sessions = evidence.read_sessions(_session(tmp_path), TZ)
    assert evidence.effort_pairs(sessions) == [(0.5, 0), (1.0, 1)]
    text = evidence.report(workouts, sessions)
    assert "| Fri Oct 30 | 16 | 40 | 2.5 | 64 min (60–68, n=4) | 4.0 | -38% per set |" in text
    assert "2 of 3 exact" in text
    assert "median 60 s, slowest 111 s" in text
    assert "1 of 2" in text  # the near miss and the wordless clip aren't utterances
    assert "## Pacing" in text
    assert "| Fri Oct 30 | E | top | 9 | 8 | 9 | matched his count |" in text

    for private in ("137.5", "Lift 0", "that was"):
        assert private not in text.split("## With Setecho")[1]


def test_pacing_rest_transitions_and_away(tmp_path):
    [session] = evidence.read_sessions(_session(tmp_path), TZ)
    pc = evidence.pacing(session)
    assert len(pc["rest"]) + len(pc["transitions"]) == len(session.sets) - 1
    assert pc["away"] == []  # 2-min gaps, no outlier
    assert 0 < pc["work_pct"] < 100
