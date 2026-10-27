"""Read a saved raw SAM video output offline and list every tracked object: frames seen, box
size, and how far its centroid moved. Free: no API call.

  uv run python -m scripts.sam_track_inspect private/reps/bench_6s.raw.txt --frames 62
"""

from __future__ import annotations

import argparse
import time
from pathlib import Path

import numpy as np

from app import reps


def main() -> None:
    p = argparse.ArgumentParser()
    p.add_argument("raw")
    p.add_argument("--frames", type=int, required=True, help="frames in the clip")
    p.add_argument("--fps", type=float, default=10.0)
    args = p.parse_args()
    t0 = time.time()
    boxes = reps.parse_boxes(Path(args.raw).read_text())
    times = [i / args.fps for i in range(args.frames)]
    records = sum(len(f) for f in boxes.values())
    print(f"{len(boxes)} objects, {records} boxes, parsed in {time.time() - t0:.2f}s")
    for oid, frames in sorted(boxes.items(), key=lambda kv: -len(kv[1])):
        xs, ys, sizes = [], [], []
        for x1, y1, x2, y2 in frames.values():
            xs.append((x1 + x2) / 2)
            ys.append((y1 + y2) / 2)
            sizes.append(max(x2 - x1, y2 - y1))
        print(
            f"  {oid}: {len(frames)}/{args.frames} frames, size {np.median(sizes):.0f}px, "
            f"x {min(xs):.0f}-{max(xs):.0f} (range {max(xs) - min(xs):.0f}), "
            f"y {min(ys):.0f}-{max(ys):.0f} (range {max(ys) - min(ys):.0f})"
        )
    track = reps.track_from_boxes(boxes, times)
    counted = reps.count(track)
    print(
        f"\ncurrent rule picks: objects {track.objects}, size {track.object_size:.0f}px, motion {track.motion_range:.1f}px, reps {counted.reps}"
    )


if __name__ == "__main__":
    main()
