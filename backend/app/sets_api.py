"""POST /sets/count: one set's small silent clip -> the measured rep count (HANDOFF.md §5).

SAM 3.1 tracks the equipment; `app.reps` turns the track into a count. The clip goes to Meta
on the Standard tier, is deleted from Meta's file store afterwards, and is never kept here.
"""

from __future__ import annotations

import tempfile
from pathlib import Path
from typing import Annotated

from fastapi import APIRouter, File, Form, UploadFile
from fastapi.concurrency import run_in_threadpool
from pydantic import Field

from app import meta, reps, video
from app.schemas import StrictModel

router = APIRouter()

MAX_CLIP_BYTES = 40 * 1024 * 1024


class CountContext(StrictModel):
    exerciseId: str
    equipment: reps.Equipment
    plannedReps: int | None = None
    phoneReps: int | None = None


class CountResponse(StrictModel):
    reps: int | None = Field(description="Null when the equipment was not tracked on enough frames")
    repTimes: list[float] = Field(description="Seconds from the clip's first frame, one per rep")
    confidence: float = Field(description="0-1; under 0.6 the phone asks the athlete")
    trackFound: bool
    frames: int
    trackedFrames: int
    prompt: str = Field(description="What SAM was asked to track")


class ClipError(ValueError):
    pass


async def count_clip(data: bytes, context: CountContext) -> CountResponse:
    if not data:
        raise ClipError("empty video")
    if len(data) > MAX_CLIP_BYTES:
        raise ClipError(f"clip is {len(data)} bytes; the limit is {MAX_CLIP_BYTES}")
    prompt = reps.SAM_PROMPTS[context.equipment]
    with tempfile.TemporaryDirectory(prefix="setecho-count-") as tmp:
        path = Path(tmp) / "set.mp4"
        path.write_bytes(data)
        try:
            times = await run_in_threadpool(video.frame_times, path)
        except Exception as e:  # ffprobe could not read it: not a video we can count
            raise ClipError(f"could not read the clip: {e}") from e
        if len(times) < 10:
            raise ClipError(f"clip has only {len(times)} frames")
        if len(times) > video.MAX_COUNT_FRAMES:
            raise ClipError(f"clip has {len(times)} frames; the limit is {video.MAX_COUNT_FRAMES}")
        # The upload and the mask decoding take seconds: off the event loop, so /health keeps answering.
        file_id = await run_in_threadpool(meta.upload_video, path)
    try:
        result = await meta.segment_video(file_id, prompt)
    finally:
        await run_in_threadpool(meta.delete_file, file_id)
    track = await run_in_threadpool(reps.centroid_track, result, times)
    counted = reps.count(track)
    return CountResponse(
        reps=counted.reps,
        repTimes=counted.rep_times,
        confidence=counted.confidence,
        trackFound=counted.track_found,
        frames=counted.frames,
        trackedFrames=counted.tracked_frames,
        prompt=prompt,
    )


@router.post("/sets/count", response_model=CountResponse)
async def sets_count(
    video_file: Annotated[UploadFile, File(alias="video")],
    context: Annotated[str, Form()],
) -> CountResponse:
    """`video`: MP4, 720p, 10 fps, no audio, trimmed to the set. `context`: JSON
    {exerciseId, equipment, plannedReps, phoneReps}."""
    ctx = CountContext.model_validate_json(context)
    return await count_clip(await video_file.read(), ctx)
