"""G7: does SAM 3.1 + reps.py count a real set? (HANDOFF.md §9, Gates still open)

  uv run python -m scripts.sam_reps_probe <set.mov> --equipment barbell [--expected 8] [--fixture]

Downscales the clip to 720p at 10 fps with no audio, uploads it, runs SAM with the equipment's
prompt, counts, and prints the count, the rep times and the seconds from upload to count.
Raw output goes to backend/private/reps/ (gitignored). `--fixture` saves only the per-frame
centroid series (no masks, no video) to tests/fixtures/sam_reps/<name>.json, so the count can
be re-run offline forever. Costs about $0.08 per 40 s set.
"""

from __future__ import annotations

import argparse
import asyncio
import json
import time
from pathlib import Path

import numpy as np

from app import meta, reps, video

ROOT = Path(__file__).resolve().parents[1]
PRIVATE = ROOT / "private" / "reps"
FIXTURES = ROOT / "tests" / "fixtures" / "sam_reps"


async def run(args: argparse.Namespace) -> None:
    src = Path(args.clip)
    name = args.name or src.stem
    PRIVATE.mkdir(parents=True, exist_ok=True)
    small = video.prepare_for_count(src, PRIVATE / f"{name}_720p10.mp4")
    times = video.frame_times(small)
    prompt = reps.SAM_PROMPTS[args.equipment]
    print(f"{small.name}: {len(times)} frames, {times[-1] - times[0]:.1f} s, prompt {prompt!r}")

    t0 = time.time()
    file_id = meta.upload_video(small)
    t1 = time.time()
    try:
        result = await meta.segment_video(file_id, prompt)
    finally:
        meta.delete_file(file_id)
    t2 = time.time()

    track = reps.centroid_track(result, times)
    counted = reps.count(track)
    print(f"upload {t1 - t0:.1f}s, segment {t2 - t1:.1f}s, total {t2 - t0:.1f}s, outcome {result.outcome}")
    print(f"tracked {counted.tracked_frames}/{counted.frames} frames ({track.share:.0%})")
    print(f"reps: {counted.reps}  confidence: {counted.confidence}  trackFound: {counted.track_found}")
    print(f"rep times: {counted.rep_times}")
    if args.expected is not None:
        verdict = "PASS" if counted.reps == args.expected else "FAIL"
        print(f"{verdict}: expected {args.expected}, counted {counted.reps}")
    if counted.track_found:
        projected = reps.project(track)
        _, d = reps.count_series(times, projected)
        print("d(t) 95th percentile:", round(float(np.percentile(d, 95)), 1), "px")

    (PRIVATE / f"{name}.raw.txt").write_text(result.raw_output)
    (PRIVATE / f"{name}.json").write_text(
        json.dumps(
            {
                "prompt": prompt,
                "upload_s": t1 - t0,
                "segment_s": t2 - t1,
                "frames": counted.frames,
                "tracked": counted.tracked_frames,
                "reps": counted.reps,
                "confidence": counted.confidence,
                "rep_times": counted.rep_times,
                "expected": args.expected,
            },
            indent=2,
        )
    )
    if args.fixture:
        FIXTURES.mkdir(parents=True, exist_ok=True)
        fixture = {
            "name": name,
            "equipment": args.equipment,
            "prompt": prompt,
            "expectedReps": args.expected,
            "t": [round(float(v), 4) for v in times],
            "x": [None if np.isnan(v) else round(float(v), 2) for v in track.centroids[:, 0]],
            "y": [None if np.isnan(v) else round(float(v), 2) for v in track.centroids[:, 1]],
        }
        path = FIXTURES / f"{name}.json"
        path.write_text(json.dumps(fixture, separators=(",", ":")) + "\n")
        print(f"fixture {path.relative_to(ROOT)} (centroids only)")


if __name__ == "__main__":
    p = argparse.ArgumentParser()
    p.add_argument("clip")
    p.add_argument("--equipment", choices=reps.EQUIPMENT, default="barbell")
    p.add_argument("--expected", type=int, help="the human's count of the set")
    p.add_argument("--name", help="fixture / output name (default: the clip's stem)")
    p.add_argument(
        "--fixture", action="store_true", help="save the centroid series to tests/fixtures/sam_reps/"
    )
    asyncio.run(run(p.parse_args()))
