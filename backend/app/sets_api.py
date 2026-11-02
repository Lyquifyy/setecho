"""POST /sets/count: one set's small silent clip -> the measured rep count (HANDOFF.md §5).

SAM 3.1 tracks the equipment, and his hands when the equipment shows nothing moving; `app.reps`
turns the track into a count. The clip goes to Meta
on the Standard tier, is deleted from Meta's file store afterwards, and is never kept here.
"""

from __future__ import annotations

import asyncio
import json
import logging
import tempfile
import time
from pathlib import Path
from typing import Annotated, Literal

from fastapi import APIRouter, File, Form, UploadFile
from fastapi.concurrency import run_in_threadpool
from fastapi.responses import StreamingResponse
from pydantic import Field

from app import budget, meta, reps, video
from app.schemas import StrictModel

router = APIRouter()
log = logging.getLogger(__name__)

MAX_CLIP_BYTES = 40 * 1024 * 1024


class CountContext(StrictModel):
    exerciseId: str
    equipment: reps.Equipment
    plannedReps: int | None = None
    phoneReps: int | None = None
    setRole: reps.SetRole | None = Field(default=None, description="A rest-pause set gets no velocity loss")
    camera: Literal["front", "back"] | None = Field(
        default=None, description="Which camera filmed it: the front camera's frames turn the other way"
    )
    cropBox: list[float] | None = Field(
        default=None,
        description="[x, y, w, h], normalized, top-left, upright portrait: his station. The clip is cut to "
        "it before SAM, so other people's bars and plates aren't tracked",
    )


class CountResponse(StrictModel):
    reps: int | None = Field(description="Null when the equipment was not tracked on enough frames")
    repTimes: list[float] = Field(description="Seconds from the clip's first frame, one per rep")
    repSpeeds: list[float] = Field(
        default_factory=list, description="Mean lifting speed per rep, px/s at 720p (HANDOFF.md §5, step 8)"
    )
    velocityLossPct: float | None = Field(
        default=None,
        description="How much the last two reps slowed against the first two, 0-100; null under 3 reps "
        "or on a rest-pause set (step 9)",
    )
    confidence: float = Field(description="0-1; under 0.6 the phone asks the athlete")
    trackFound: bool
    frames: int
    trackedFrames: int
    prompt: str = Field(description="What SAM was asked to track")
    objects: int = Field(default=0, description="Objects SAM tracked; the one on most frames was kept")
    objectSizePx: float = Field(default=0.0, description="The tracked object's box size, px, at 720p")
    motionRangePx: float = Field(default=0.0, description="Peak-to-peak of the tracked motion, px")
    timings: dict[str, float] = Field(
        default_factory=dict, description="Seconds per phase: probe, upload, segment, track"
    )


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
        timings: dict[str, float] = {}
        t0 = time.monotonic()
        if context.cropBox is not None and len(context.cropBox) == 4:
            try:
                path = await run_in_threadpool(
                    video.crop,
                    path,
                    Path(tmp) / "station.mp4",
                    context.cropBox,
                    front=context.camera == "front",
                )
            except Exception as e:  # noqa: BLE001 - an odd box or clip: count the whole frame instead
                log.info("crop failed, counting the whole frame: %s", e)
            timings["crop"] = round(time.monotonic() - t0, 2)
            t0 = time.monotonic()
        try:
            times = await run_in_threadpool(video.frame_times, path)
        except Exception as e:  # ffprobe could not read it: not a video we can count
            raise ClipError(f"could not read the clip: {e}") from e
        timings["probe"] = round(time.monotonic() - t0, 2)
        if len(times) < 10:
            raise ClipError(f"clip has only {len(times)} frames")
        if len(times) > video.MAX_COUNT_FRAMES:
            raise ClipError(f"clip has {len(times)} frames; the limit is {video.MAX_COUNT_FRAMES}")
        # The spend guard: SAM bills per frame, and the hands look costs the frames a second time.
        budget.budget.charge_sam_frames(len(times) * (2 if context.equipment in reps.HANDS_ALONGSIDE else 1))
        # The upload and the mask decoding take seconds: off the event loop, so /health keeps answering.
        t1 = time.monotonic()
        file_id = await run_in_threadpool(meta.upload_video, path)
        timings["upload"] = round(time.monotonic() - t1, 2)
    try:
        if context.equipment in reps.HANDS_ALONGSIDE:
            # Dumbbells and cables, where the equipment's look most often finds nothing moving: both looks
            # at once, so the hands cost no extra wait. The equipment's count wins when it has one.
            first, hands = await asyncio.gather(
                _segment_and_count(file_id, prompt, times, context, timings, ""),
                _segment_and_count(file_id, reps.SAM_FALLBACK_PROMPT, times, context, timings, "2"),
            )
        else:
            first = await _segment_and_count(file_id, prompt, times, context, timings, "")
            hands = None
            if not first[1].reps:
                # Nothing moving under the equipment's prompt: one more look, at his hands.
                hands = await _segment_and_count(
                    file_id, reps.SAM_FALLBACK_PROMPT, times, context, timings, "2"
                )
        track, counted = first
        if not counted.reps and hands is not None and hands[1].reps:
            prompt = reps.SAM_FALLBACK_PROMPT
            track, counted = hands
    finally:
        await run_in_threadpool(meta.delete_file, file_id)
    return CountResponse(
        reps=counted.reps,
        repTimes=counted.rep_times,
        repSpeeds=counted.rep_speeds,
        velocityLossPct=counted.velocity_loss_pct,
        confidence=counted.confidence,
        trackFound=counted.track_found,
        frames=counted.frames,
        trackedFrames=counted.tracked_frames,
        prompt=prompt,
        objects=track.objects,
        objectSizePx=round(track.object_size, 1),
        motionRangePx=round(track.motion_range, 1),
        timings=timings,
    )


async def _segment_and_count(
    file_id: str,
    prompt: str,
    times: list[float],
    context: CountContext,
    timings: dict[str, float],
    suffix: str,
) -> tuple[reps.Track, reps.RepResult]:
    t0 = time.monotonic()
    raw = await meta.segment_video_raw(file_id, prompt)
    timings[f"segment{suffix}"] = round(time.monotonic() - t0, 2)
    t1 = time.monotonic()
    track = await run_in_threadpool(reps.track_from_raw, raw, times)
    counted = reps.count(track, context.setRole)
    timings[f"track{suffix}"] = round(time.monotonic() - t1, 2)
    return track, counted


HEARTBEAT_SECONDS = 5.0


@router.post("/sets/count", response_model=CountResponse)
async def sets_count(
    video_file: Annotated[UploadFile, File(alias="video")],
    context: Annotated[str, Form()],
) -> StreamingResponse:
    """`video`: MP4, 720p, 15 fps, no audio, trimmed to the set. `context`: JSON
    {exerciseId, equipment, plannedReps, phoneReps, setRole}.

    SAM takes a minute or more and says nothing meanwhile, so the response streams a newline
    every few seconds until the JSON is ready: proxies and the phone's connection stay open.
    A failure comes as a final JSON {"error": ...} line, with the 200 already sent."""
    ctx = CountContext.model_validate_json(context)
    data = await video_file.read()

    async def body():
        task = asyncio.create_task(count_clip(data, ctx))
        while True:
            done, _ = await asyncio.wait({task}, timeout=HEARTBEAT_SECONDS)
            if done:
                break
            yield "\n"
        try:
            result = task.result()
        except ClipError as e:
            yield json.dumps({"error": str(e)})
            return
        except budget.BudgetExceeded as e:
            yield json.dumps(e.body())
            return
        except Exception as e:  # the stream has started: the error must reach the phone as JSON
            logging.getLogger(__name__).exception("count failed")
            yield json.dumps({"error": f"count failed: {type(e).__name__}"})
            return
        yield result.model_dump_json()

    return StreamingResponse(body(), media_type="application/json")
