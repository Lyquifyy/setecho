"""POST /photos/segment: one check-in still -> person box, mask and the 3:4 crop that aligns it
to the reference week (HANDOFF.md §5, §7). SAM 3.1 finds the person; the math here does the rest.
Photos go to Meta only through this endpoint, Standard tier, and are never stored.
"""

from __future__ import annotations

from typing import Annotated

from fastapi import APIRouter, File, Form, UploadFile

from app import align, meta, photos
from app.schemas import StrictModel

router = APIRouter()


class SegmentResponse(StrictModel):
    """Coordinates are in the uploaded image's own pixels."""

    width: int
    height: int
    box: list[int]
    crop: list[int]
    bodyFraction: float
    clamped: bool
    maskPng: str
    maskWidth: int
    maskHeight: int


class NoPersonError(ValueError):
    pass


async def segment(data: bytes, reference_fraction: float | None, prompt: str = "person") -> SegmentResponse:
    prepared = photos.prepare_image(data)
    result = await meta.segment_image(meta.data_url(prepared.jpeg, "image/jpeg"), prompt)
    best = photos.largest_mask(result)
    if best is None:
        raise NoPersonError("no person found in the photo; step into frame and try again")
    px, py, pw, ph = photos.box_of(best)
    inverse = 1 / prepared.scale
    box = align.scaled(align.Box(px, py, pw, ph), inverse)
    original_w, original_h = round(prepared.width * inverse), round(prepared.height * inverse)
    aligned = align.align(box, original_w, original_h, reference_fraction)
    mask = photos.full_frame_mask(best, prepared.width, prepared.height)
    return SegmentResponse(
        width=original_w,
        height=original_h,
        box=[box.x, box.y, box.w, box.h],
        crop=[aligned.crop.x, aligned.crop.y, aligned.crop.w, aligned.crop.h],
        bodyFraction=round(aligned.body_fraction, 4),
        clamped=aligned.clamped,
        maskPng=photos.mask_png_base64(mask),
        maskWidth=prepared.width,
        maskHeight=prepared.height,
    )


@router.post("/photos/segment", response_model=SegmentResponse)
async def photos_segment(
    image: Annotated[UploadFile, File()],
    referenceFraction: Annotated[float | None, Form()] = None,
) -> SegmentResponse:
    """`image`: a JPEG. `referenceFraction`: the body box height over the crop height from the
    reference week's same pose, so this week is cropped to match. Omit for the first ever set."""
    return await segment(await image.read(), referenceFraction)
