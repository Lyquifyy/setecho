"""Check-in photo alignment math (HANDOFF.md §7 Photo session). Python, not Swift (AGENTS.md rule 6).

Each pose is cropped to 3:4 so the body box is the same height, as a fraction of the frame, as in
the reference week (the first photo set ever), and centered horizontally on the box. Only a crop
and a scale: pixels are never altered.
"""

from __future__ import annotations

from dataclasses import dataclass

ASPECT_W, ASPECT_H = 3, 4
DEFAULT_BODY_FRACTION = 0.80  # with no reference yet, the body fills 80% of the crop's height


@dataclass(frozen=True)
class Box:
    x: int
    y: int
    w: int
    h: int

    @property
    def cx(self) -> float:
        return self.x + self.w / 2

    @property
    def cy(self) -> float:
        return self.y + self.h / 2


@dataclass(frozen=True)
class Alignment:
    crop: Box
    """The body box height as a fraction of the crop height, after this crop."""
    body_fraction: float
    """True when the crop had to shrink or shift to stay inside the image; framing was off."""
    clamped: bool


def align(box: Box, width: int, height: int, reference_fraction: float | None) -> Alignment:
    """A 3:4 crop, in the same pixel space as `box`, that puts the body at `reference_fraction`
    of the crop height and centers it horizontally. Falls back to DEFAULT_BODY_FRACTION."""
    if width <= 0 or height <= 0 or box.w <= 0 or box.h <= 0:
        raise ValueError("box and image must have positive size")
    fraction = (
        reference_fraction if reference_fraction and 0 < reference_fraction <= 1 else DEFAULT_BODY_FRACTION
    )

    crop_h = box.h / fraction
    crop_w = crop_h * ASPECT_W / ASPECT_H
    clamped = False
    # Never larger than the image: shrink keeping 3:4 (the body then fills more of the crop).
    if crop_w > width or crop_h > height:
        clamped = True
        scale = min(width / crop_w, height / crop_h)
        crop_w *= scale
        crop_h *= scale

    x = box.cx - crop_w / 2
    y = box.cy - crop_h / 2
    # Keep inside the frame.
    if x < 0 or y < 0 or x + crop_w > width or y + crop_h > height:
        clamped = clamped or (
            x < 0 or x + crop_w > width
        )  # vertical shifts are routine; horizontal ones mean off-centre
        x = min(max(x, 0), width - crop_w)
        y = min(max(y, 0), height - crop_h)

    crop = Box(round(x), round(y), round(crop_w), round(crop_h))
    return Alignment(crop=crop, body_fraction=box.h / crop.h if crop.h else 0.0, clamped=clamped)


def scaled(box: Box, factor: float) -> Box:
    """Map a box between pixel spaces (prepared image <-> original image)."""
    return Box(
        round(box.x * factor),
        round(box.y * factor),
        round(box.w * factor),
        round(box.h * factor),
    )
