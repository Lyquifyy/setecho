"""M0 gate G4: does SAM 3.1 return one clean person mask per check-in photo, arms included?

  uv run python -m scripts.sam_photo_probe front.jpg right.jpg back.jpg left.jpg
  uv run python -m scripts.sam_photo_probe photo.jpg --prompt "person"
  uv run python -m scripts.sam_photo_probe shape.png --prompt "red circle" --fixture   # synthetic only

For each image: downscale to 1280 px on the long side, call SAM with a noun phrase, take the
largest mask, and write to backend/private/probes/sam/ (gitignored):
  <stem>_overlay.png   the photo with the mask tinted and the box drawn: judge this by eye
  <stem>_mask.png      the full-frame mask
  <stem>.raw.txt       SAM's raw output, replayable offline with app.photos.replay_raw
  <stem>.json          box, sizes, mask count, latency
--fixture also copies the .raw.txt and .json into tests/fixtures/sam/photos/. Use it only on
synthetic images; the athlete's photos never go in the repo.
"""

from __future__ import annotations

import argparse
import asyncio
import json
import shutil
import time
from pathlib import Path

import cv2

from app import meta, photos

ROOT = Path(__file__).resolve().parents[1]
PRIVATE = ROOT / "private" / "probes" / "sam"
FIXTURES = ROOT / "tests" / "fixtures" / "sam" / "photos"


async def probe(path: Path, prompt: str, fixture: bool) -> dict:
    prepared = photos.prepare_image(path.read_bytes())
    t0 = time.time()
    result = await meta.segment_image(meta.data_url(prepared.jpeg, "image/jpeg"), prompt)
    latency = time.time() - t0

    records = photos.mask_records(result)
    best = photos.largest_mask(result)
    summary = {
        "image": path.name,
        "prompt": prompt,
        "prepared": {"width": prepared.width, "height": prepared.height, "scale": prepared.scale},
        "outcome": getattr(result.outcome, "status", str(result.outcome)),
        "masks": len(records),
        "diagnostics": [d.message for d in result.diagnostics],
        "latency_s": round(latency, 2),
        "box": list(photos.box_of(best)) if best else None,
        "confidence": getattr(best, "confidence", None) if best else None,
    }
    PRIVATE.mkdir(parents=True, exist_ok=True)
    (PRIVATE / f"{path.stem}.raw.txt").write_text(result.raw_output)
    (PRIVATE / f"{path.stem}.json").write_text(json.dumps(summary, indent=2))
    if best is not None:
        mask = photos.full_frame_mask(best, prepared.width, prepared.height)
        bgr = photos.decode_bgr(prepared.jpeg)
        cv2.imwrite(str(PRIVATE / f"{path.stem}_overlay.png"), photos.overlay(bgr, mask, photos.box_of(best)))
        cv2.imwrite(str(PRIVATE / f"{path.stem}_mask.png"), mask * 255)
        x, y, w, h = summary["box"]
        coverage = mask.mean()
        print(
            f"{path.name}: {len(records)} mask(s), box x={x} y={y} w={w} h={h} "
            f"({h / prepared.height:.0%} of frame height), mask covers {coverage:.1%}, {latency:.1f}s"
        )
    else:
        print(f"{path.name}: no mask for {prompt!r} ({summary['outcome']}), {latency:.1f}s")
    if fixture:
        FIXTURES.mkdir(parents=True, exist_ok=True)
        for name in (f"{path.stem}.raw.txt", f"{path.stem}.json"):
            shutil.copy(PRIVATE / name, FIXTURES / name)
        print(f"fixture {FIXTURES.relative_to(ROOT)}/{path.stem}.*")
    return summary


async def run(args: argparse.Namespace) -> None:
    for image in args.images:
        await probe(Path(image), args.prompt, args.fixture)
    print(f"outputs in {PRIVATE.relative_to(ROOT)}/")


if __name__ == "__main__":
    p = argparse.ArgumentParser()
    p.add_argument("images", nargs="+")
    p.add_argument("--prompt", default="person", help="a noun phrase; keep it short")
    p.add_argument(
        "--fixture", action="store_true", help="also copy raw output into tests/fixtures/sam/photos/"
    )
    asyncio.run(run(p.parse_args()))
