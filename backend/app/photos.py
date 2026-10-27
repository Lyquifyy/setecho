"""Check-in photo measurement math: downscale for SAM, pick the person mask, box, overlay.

All math is NumPy / OpenCV here, never in Swift (AGENTS.md rule 6). The SAM call itself lives
in app.meta; this module turns its result into a box and a full-frame mask, and can replay a
saved raw output offline so tests and demo retakes never hit the API.
"""

from __future__ import annotations

import base64
from dataclasses import dataclass
from typing import Any

import cv2
import numpy as np

MAX_LONG_SIDE = 1280
JPEG_QUALITY = 90


@dataclass(frozen=True)
class Prepared:
    jpeg: bytes
    width: int
    height: int
    scale: float  # prepared px / original px


def prepare_image(data: bytes, max_long_side: int = MAX_LONG_SIDE) -> Prepared:
    """Decode (EXIF orientation applied), downscale to `max_long_side`, re-encode as JPEG."""
    img = cv2.imdecode(np.frombuffer(data, np.uint8), cv2.IMREAD_COLOR)
    if img is None:
        raise ValueError("could not decode image")
    h, w = img.shape[:2]
    scale = min(1.0, max_long_side / max(h, w))
    if scale < 1.0:
        img = cv2.resize(img, (round(w * scale), round(h * scale)), interpolation=cv2.INTER_AREA)
    ok, buf = cv2.imencode(".jpg", img, [cv2.IMWRITE_JPEG_QUALITY, JPEG_QUALITY])
    if not ok:
        raise ValueError("could not encode JPEG")
    return Prepared(buf.tobytes(), img.shape[1], img.shape[0], scale)


def decode_bgr(jpeg: bytes) -> np.ndarray:
    return cv2.imdecode(np.frombuffer(jpeg, np.uint8), cv2.IMREAD_COLOR)


# ---------------------------------------------------------------------------
# SAM result -> box and mask
# ---------------------------------------------------------------------------


def mask_records(result: Any) -> list[Any]:
    return [r for r in result.records if getattr(r, "kind", None) == "mask"]


def box_of(record: Any) -> tuple[int, int, int, int]:
    """(x, y, w, h) in source pixels from the record's half-open bounds."""
    b = record.bounds
    x, y = round(b.left), round(b.top)
    return x, y, round(b.right) - x, round(b.bottom) - y


def largest_mask(result: Any) -> Any | None:
    """The mask with the largest box area, or None when SAM found nothing (a normal outcome)."""
    records = mask_records(result)
    if not records:
        return None
    return max(records, key=lambda r: box_of(r)[2] * box_of(r)[3])


def mask_raster(record: Any) -> np.ndarray:
    """The record's own raster as an H x W uint8 array of 0/1."""
    from meta_sam_parser import decode_mask_to_raster

    raw = decode_mask_to_raster(record.mask)
    return np.frombuffer(raw, dtype=np.uint8).reshape(record.mask.height, record.mask.width)


def full_frame_mask(record: Any, width: int, height: int) -> np.ndarray:
    """Place the box-local raster into a full-frame H x W uint8 mask (0/1)."""
    x, y, w, h = box_of(record)
    raster = mask_raster(record)
    if raster.shape != (h, w) and w > 0 and h > 0:
        raster = cv2.resize(raster, (w, h), interpolation=cv2.INTER_NEAREST)
    full = np.zeros((height, width), dtype=np.uint8)
    x0, y0 = max(x, 0), max(y, 0)
    x1, y1 = min(x + w, width), min(y + h, height)
    if x1 > x0 and y1 > y0:
        full[y0:y1, x0:x1] = raster[y0 - y : y1 - y, x0 - x : x1 - x]
    return full


def overlay(bgr: np.ndarray, mask: np.ndarray, box: tuple[int, int, int, int]) -> np.ndarray:
    """Tint the mask cobalt and draw the box, for a human to judge the mask by eye."""
    out = bgr.copy()
    tint = np.zeros_like(out)
    tint[:] = (216, 65, 37)  # cobalt #2541D8 in BGR
    sel = mask.astype(bool)
    out[sel] = (0.55 * out[sel] + 0.45 * tint[sel]).astype(np.uint8)
    x, y, w, h = box
    cv2.rectangle(out, (x, y), (x + w, y + h), (80, 205, 240), 3)  # yellow #F0CD50 in BGR
    return out


def mask_png_base64(mask: np.ndarray) -> str:
    ok, buf = cv2.imencode(".png", (mask * 255).astype(np.uint8))
    if not ok:
        raise ValueError("could not encode mask PNG")
    return base64.b64encode(buf.tobytes()).decode("ascii")


# ---------------------------------------------------------------------------
# Offline replay of a saved raw SAM output
# ---------------------------------------------------------------------------


async def replay_raw(raw_output: str):
    """Rebuild an ImageSegmentationResult from `result.raw_output` saved by the probe."""
    from meta_sam_parser import image_segmentation_format, parse_responses_stream

    lane = {"item_id": "replay", "output_index": 0, "content_index": 0}

    async def events():
        yield {"type": "response.output_text.delta", "delta": raw_output, **lane}
        yield {"type": "response.output_text.done", "text": raw_output, **lane}
        yield {"type": "response.completed", "response": {"id": "replay", "status": "completed"}}

    parsed = parse_responses_stream(events(), image_segmentation_format())
    final = parsed.final_result
    return await (final() if callable(final) else final)
