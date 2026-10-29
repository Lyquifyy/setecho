"""Write the made-up Garmin strength activity that `test_history.py` reads, with the FIT SDK's encoder.

  uv run python -m scripts.make_history_fixtures

Offline and free. Every set here is invented; none comes from the athlete's files (they stay in
backend/private/history/, gitignored). The activity is built the way a Venu 4 writes one: a set
message per active set and per rest, weight in kg at 1/16 kg, Garmin's exercise category and
subtype, and the workout's name. It covers a superset (raises and pressdowns interleaved), a lift
that comes back after another one finished (leg curls, squats, leg curls), and active sets with
no reps. Re-running it writes the same bytes.
"""

from __future__ import annotations

import io
import zipfile
from datetime import UTC, datetime, timedelta
from pathlib import Path

from garmin_fit_sdk import Encoder, Profile

OUT = Path(__file__).resolve().parents[1] / "tests" / "fixtures" / "history"
ACTIVITY_ID = "10000000001"
START = datetime(2026, 10, 5, 21, 0, tzinfo=UTC)
LB = 0.45359237

MESG = Profile["mesg_num"]

# (category, subtype, lb, reps): reps None is an active set he never entered reps for.
SETS: list[tuple[str, int, float, int | None]] = [
    ("bench_press", 22, 225, 8),  # smith_machine_bench_press
    ("bench_press", 22, 185, 11),
    ("lateral_raise", 34, 20, 15),  # dumbbell_lateral_raise, superset with pressdowns
    ("triceps_extension", 39, 70, 12),  # triceps_pressdown
    ("lateral_raise", 34, 20, 12),
    ("triceps_extension", 39, 60, 10),
    ("lateral_raise", 34, 20, None),
    ("leg_curl", 1, 170, 10),  # weighted_leg_curl
    ("leg_curl", 1, 130, 13),
    ("squat", 6, 315, 5),  # barbell_back_squat
    ("squat", 6, 295, 6),
    ("leg_curl", 1, 150, 18),  # a second leg curl after squats
    ("flye", 3, 27.5, 12),  # incline_dumbbell_flye: a 27.5 lb dumbbell, 12.47 kg on the 1/16 grid
]


def build() -> bytes:
    enc = Encoder()
    enc.write_mesg(
        {
            "mesg_num": MESG["FILE_ID"],
            "type": "activity",
            "manufacturer": "development",
            "product": 0,
            "time_created": START,
            "serial_number": 1234,
        }
    )
    enc.write_mesg(
        {
            "mesg_num": MESG["WORKOUT"],
            "wkt_name": "Day 1 Workout",
            "sport": "training",
            "sub_sport": "strength_training",
        }
    )
    t = START
    index = 0
    for category, subtype, lb, reps in SETS:
        active = {
            "mesg_num": MESG["SET"],
            "timestamp": START,
            "start_time": t,
            "duration": 40.0,
            "set_type": "active",
            "category": [category],
            "category_subtype": [subtype],
            "weight": lb * LB,
            "weight_display_unit": "pound",
            "message_index": index,
        }
        if reps is not None:
            active["repetitions"] = reps
        enc.write_mesg(active)
        t += timedelta(seconds=41)
        enc.write_mesg(
            {
                "mesg_num": MESG["SET"],
                "timestamp": START,
                "start_time": t,
                "duration": 120.0,
                "set_type": "rest",
                "message_index": index + 1,
            }
        )
        t += timedelta(seconds=121)
        index += 2
    enc.write_mesg(
        {
            "mesg_num": MESG["SESSION"],
            "timestamp": t,
            "start_time": START,
            "sport": "training",
            "sub_sport": "strength_training",
            "total_elapsed_time": (t - START).total_seconds(),
            "total_timer_time": (t - START).total_seconds(),
            "message_index": 0,
        }
    )
    return enc.close()


def main() -> None:
    OUT.mkdir(parents=True, exist_ok=True)
    fit = build()
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w", zipfile.ZIP_DEFLATED) as z:
        info = zipfile.ZipInfo(f"{ACTIVITY_ID}_ACTIVITY.fit", date_time=(2026, 10, 5, 21, 0, 0))
        z.writestr(info, fit)
    (OUT / f"{ACTIVITY_ID}.zip").write_bytes(buf.getvalue())
    print(f"wrote {OUT / f'{ACTIVITY_ID}.zip'} ({len(fit)} byte FIT)")


if __name__ == "__main__":
    main()
