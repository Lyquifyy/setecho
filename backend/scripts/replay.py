"""A recorded sample run with no key and no network: SAM 3.1's saved tracks of real sets, counted.

  make replay
  uv run python -m scripts.replay [fixture.json ...]

Each file in tests/fixtures/sam_reps/ is one real set: the per-frame centroid of the object SAM 3.1
tracked (`scripts/sam_reps_probe.py --fixture` saves it from the live run, boxes only, no video)
with the frame timestamps read from the clip, the prompt SAM was asked, and the lifter's own count.
This script runs each one through `app/reps.py` exactly as `/sets/count` does (`app/sets_api.py`:
`reps.track_from_raw`, then `reps.count`), and prints the hand count, SAM's count, each rep's time
and speed from the real timestamps, the velocity loss and the confidence. New fixtures in the folder
are picked up automatically. The same numbers go into the README's "For judges" section.
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

import numpy as np

from app import reps

ROOT = Path(__file__).resolve().parents[1]
FIXTURES = ROOT / "tests" / "fixtures" / "sam_reps"


def track_from_fixture(data: dict) -> reps.Track:
    """The Track `/sets/count` builds from SAM's raw output, rebuilt from the saved centroids."""
    centroids = np.array(
        [
            [np.nan if x is None else x, np.nan if y is None else y]
            for x, y in zip(data["x"], data["y"], strict=True)
        ],
        dtype=float,
    )
    return reps.Track(np.asarray(data["t"], dtype=float), centroids, float(data.get("objectSizePx", 0.0)))


def replay(path: Path) -> dict:
    """One set: the fixture's facts and the count, as `/sets/count` would return it."""
    data = json.loads(path.read_text())
    track = track_from_fixture(data)
    counted = reps.count(track, data.get("setRole"))
    return {
        "name": data.get("name", path.stem),
        "equipment": data.get("equipment", ""),
        "prompt": data.get("prompt", ""),
        "notes": data.get("notes", ""),
        "handCount": data.get("expectedReps"),
        "reps": counted.reps,
        "repTimes": counted.rep_times,
        "repSpeeds": counted.rep_speeds,
        "velocityLossPct": counted.velocity_loss_pct,
        "confidence": counted.confidence,
        "trackFound": counted.track_found,
        "frames": counted.frames,
        "trackedFrames": counted.tracked_frames,
        "durationSeconds": round(float(track.times[-1] - track.times[0]), 1) if len(track.times) else 0.0,
    }


def render(result: dict) -> str:
    lines = [
        f"{result['name']}  ({result['equipment']}, SAM prompt {result['prompt']!r})",
    ]
    if result["notes"]:
        lines.append(f"  {result['notes']}")
    lines.append(
        f"  {result['frames']} frames over {result['durationSeconds']} s, "
        f"{result['trackedFrames']} tracked ({result['trackedFrames'] / max(result['frames'], 1):.0%})"
    )
    hand = result["handCount"]
    sam = result["reps"]
    verdict = "" if hand is None else ("  matched" if sam == hand else "  MISSED")
    lines.append(
        f"  hand count {hand}   SAM 3.1 count {sam}   confidence {result['confidence']:.2f}{verdict}"
    )
    if result["repTimes"]:
        lines.append("  rep   time (s)   speed (px/s)")
        for i, (t, v) in enumerate(zip(result["repTimes"], result["repSpeeds"], strict=False), start=1):
            lines.append(f"  {i:>3}   {t:>8.2f}   {v:>12.1f}")
    loss = result["velocityLossPct"]
    lines.append(
        "  velocity loss: none (under 3 reps or a rest-pause set)"
        if loss is None
        else f"  velocity loss: {loss:.1f}% (last two reps against the fastest of the first two)"
    )
    return "\n".join(lines)


def main(argv: list[str] | None = None) -> list[dict]:
    args = sys.argv[1:] if argv is None else argv
    paths = [Path(a) for a in args] if args else sorted(FIXTURES.glob("*.json"))
    if not paths:
        print(f"no fixtures in {FIXTURES.relative_to(ROOT)}")
        return []
    results = []
    print(
        f"{len(paths)} saved SAM 3.1 set(s) from {FIXTURES.relative_to(ROOT)}, counted offline by app/reps.py\n"
    )
    for path in paths:
        result = replay(path)
        results.append(result)
        print(render(result))
        print()
    return results


if __name__ == "__main__":
    main()
