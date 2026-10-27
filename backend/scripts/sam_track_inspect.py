"""Replay a saved raw SAM video output offline and list every tracked object: frames seen, box
size, and how far its centroid moved. Free: no API call.

  uv run python -m scripts.sam_track_inspect private/reps/bench_6s.raw.txt --frames 62
"""

from __future__ import annotations

import argparse
import asyncio
from pathlib import Path

import numpy as np

from app import reps


async def replay_video(raw_output: str):
    from meta_sam_parser import parse_responses_stream, video_segmentation_format

    lane = {"item_id": "replay", "output_index": 0, "content_index": 0}

    async def events():
        yield {"type": "response.output_text.delta", "delta": raw_output, **lane}
        yield {"type": "response.output_text.done", "text": raw_output, **lane}
        yield {"type": "response.completed", "response": {"id": "replay", "status": "completed"}}

    parsed = parse_responses_stream(events(), video_segmentation_format())
    final = parsed.final_result
    return await (final() if callable(final) else final)


def main() -> None:
    p = argparse.ArgumentParser()
    p.add_argument("raw")
    p.add_argument("--frames", type=int, required=True, help="frames in the clip")
    p.add_argument("--fps", type=float, default=10.0)
    args = p.parse_args()
    result = asyncio.run(replay_video(Path(args.raw).read_text()))
    times = [i / args.fps for i in range(args.frames)]
    per_object: dict[str, dict[int, object]] = {}
    for rec in result.records:
        if getattr(rec, "kind", None) == "mask" and rec.frame is not None:
            per_object.setdefault(rec.object_id, {})[rec.frame.frame_index] = rec
    print(f"{len(per_object)} objects, {len(result.records)} records, outcome {result.outcome}")
    for oid, frames in sorted(per_object.items(), key=lambda kv: -len(kv[1])):
        xs, ys, sizes = [], [], []
        for rec in frames.values():
            b = rec.bounds
            xs.append((b.left + b.right) / 2)
            ys.append((b.top + b.bottom) / 2)
            sizes.append(max(b.right - b.left, b.bottom - b.top))
        print(
            f"  {oid}: {len(frames)}/{args.frames} frames, size {np.median(sizes):.0f}px, "
            f"x {min(xs):.0f}-{max(xs):.0f} (range {max(xs) - min(xs):.0f}), "
            f"y {min(ys):.0f}-{max(ys):.0f} (range {max(ys) - min(ys):.0f})"
        )
    track = reps.centroid_track(result, times)
    counted = reps.count(track)
    print(
        f"\ncurrent rule picks: objects {track.objects}, size {track.object_size:.0f}px, motion {track.motion_range:.1f}px, reps {counted.reps}"
    )


if __name__ == "__main__":
    main()
