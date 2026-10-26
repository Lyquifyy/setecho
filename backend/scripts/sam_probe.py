"""Monday gate: does SAM 3.1 track the plate on a real clip, and do point prompts work?

  uv run python -m scripts.sam_probe clips/bench_set1.mov                    # text prompt
  uv run python -m scripts.sam_probe clips/bench_set1.mov --point 812,455    # tap on frame 0 (720p coords)

Prepares a 720p, silent, faststart H.264 copy, uploads it, runs SAM, prints latency and
track summary, and saves the raw output to tests/fixtures/sam/ so later work runs offline.
"""

import argparse
import asyncio
import json
import subprocess
import time
from collections import defaultdict
from pathlib import Path

from app import meta

FIXTURES = Path(__file__).resolve().parents[1] / "tests" / "fixtures" / "sam"


def prep(src: Path) -> Path:
    out = src.with_name(src.stem + "_720p.mp4")
    subprocess.run(
        [
            "ffmpeg",
            "-y",
            "-loglevel",
            "error",
            "-i",
            str(src),
            "-vf",
            "scale=-2:720",
            "-an",
            "-c:v",
            "libx264",
            "-preset",
            "veryfast",
            "-crf",
            "20",
            "-movflags",
            "+faststart",
            str(out),
        ],
        check=True,
    )
    return out


def size_of(path: Path) -> tuple[int, int]:
    w, h = (
        subprocess.run(
            [
                "ffprobe",
                "-v",
                "error",
                "-select_streams",
                "v:0",
                "-show_entries",
                "stream=width,height",
                "-of",
                "csv=p=0",
                str(path),
            ],
            capture_output=True,
            text=True,
            check=True,
        )
        .stdout.strip()
        .split(",")
    )
    return int(w), int(h)


async def run(args: argparse.Namespace) -> None:
    clip = prep(Path(args.clip))
    if args.point:
        from meta_sam_parser import FramePrompt, PromptObject, PromptPoint, build_object_prompt

        x, y = (int(v) for v in args.point.split(","))
        prompt = build_object_prompt(
            size=size_of(clip),
            objects=[PromptObject(id=1, prompts=[FramePrompt(frame=0, points=[PromptPoint(x, y)])])],
        )
    else:
        prompt = args.concept
    t0 = time.time()
    file_id = meta.upload_video(clip)
    t1 = time.time()
    result = await meta.segment_video(file_id, prompt)
    t2 = time.time()

    frames = defaultdict(set)
    for rec in result.records:
        if rec.kind == "mask" and rec.frame is not None:
            frames[rec.object_id].add(rec.frame.frame_index)
    print(f"prompt: {prompt!r}")
    print(f"upload {t1 - t0:.1f}s, segment {t2 - t1:.1f}s, outcome {result.outcome}")
    for oid, fs in sorted(frames.items()):
        print(f"  track {oid}: {len(fs)} frames ({min(fs)}-{max(fs)})")
    print(f"diagnostics: {len(result.diagnostics)}")

    FIXTURES.mkdir(parents=True, exist_ok=True)
    tag = "point" if args.point else "text"
    (FIXTURES / f"{clip.stem}_{tag}.txt").write_text(result.raw_output)
    (FIXTURES / f"{clip.stem}_{tag}.json").write_text(
        json.dumps(
            {"prompt": prompt, "file_id": file_id, "upload_s": t1 - t0, "segment_s": t2 - t1}, indent=2
        )
    )


if __name__ == "__main__":
    p = argparse.ArgumentParser()
    p.add_argument("clip")
    p.add_argument("--concept", default="weight plate")
    p.add_argument("--point", help="x,y of the plate on frame 0, in 720p pixel coordinates")
    asyncio.run(run(p.parse_args()))
