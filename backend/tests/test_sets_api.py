"""POST /sets/count with SAM and ffprobe replaced: the request shape, the response, the errors."""

import json
from pathlib import Path
from types import SimpleNamespace

import numpy as np
import pytest
from fastapi.testclient import TestClient

from app import meta, reps, sets_api, video
from app.main import app

FIXTURES = Path(__file__).parent / "fixtures" / "reps"


@pytest.fixture
def client():
    return TestClient(app)


@pytest.fixture
def fake_sam(monkeypatch):
    """Replace upload, segmentation, deletion and ffprobe with the clean_8 series as a plate track."""
    series = reps.series_from_json(json.loads((FIXTURES / "clean_8_10fps.json").read_text()))
    calls = {"uploaded": [], "deleted": [], "prompts": []}
    monkeypatch.setattr(video, "frame_times", lambda path: [float(v) for v in series.t])
    monkeypatch.setattr(meta, "upload_video", lambda path: calls["uploaded"].append(path.name) or "file_1")
    monkeypatch.setattr(meta, "delete_file", lambda fid: calls["deleted"].append(fid))
    monkeypatch.setattr("app.photos.mask_raster", lambda r: np.ones((r.mask.height, r.mask.width), np.uint8))

    async def segment(file_id, prompt):
        calls["prompts"].append(prompt)
        records = []
        for i, y in enumerate(series.y):
            top = 400 - 500 * float(y)
            records.append(
                SimpleNamespace(
                    kind="mask",
                    object_id="plate",
                    frame=SimpleNamespace(frame_index=i),
                    bounds=SimpleNamespace(left=600, top=top, right=680, bottom=top + 80),
                    mask=SimpleNamespace(width=80, height=80),
                )
            )
        return SimpleNamespace(records=records)

    monkeypatch.setattr(meta, "segment_video", segment)
    return calls


def _post(client, data=b"\x00" * 4096, context=None):
    ctx = {"exerciseId": "w1_upper_a_bench_press", "equipment": "barbell", "plannedReps": 8, "phoneReps": 8}
    if context is not None:
        ctx = context
    return client.post(
        "/sets/count",
        files={"video": ("set.mp4", data, "video/mp4")},
        data={"context": json.dumps(ctx)},
    )


def test_counts_a_barbell_set(client, fake_sam):
    r = _post(client)
    assert r.status_code == 200, r.text
    body = r.json()
    assert body["reps"] == 8 and body["trackFound"] and body["frames"] == body["trackedFrames"]
    assert len(body["repTimes"]) == 8 and body["confidence"] > 0.9
    assert body["prompt"] == "weight plate"
    assert fake_sam["uploaded"] == ["set.mp4"] and fake_sam["deleted"] == ["file_1"]


def test_equipment_picks_the_prompt(client, fake_sam):
    r = _post(client, context={"exerciseId": "x", "equipment": "dumbbell"})
    assert r.status_code == 200 and r.json()["prompt"] == "dumbbell"
    assert fake_sam["prompts"] == ["dumbbell"]


def test_bad_equipment_is_422(client, fake_sam):
    r = _post(client, context={"exerciseId": "x", "equipment": "sled"})
    assert r.status_code == 422 and "error" in r.json()


def test_unreadable_clip_streams_an_error_line(client, fake_sam, monkeypatch):
    """Once the stream has started the status is 200; the error travels as the final JSON line."""

    def boom(path):
        raise RuntimeError("ffprobe: invalid data")

    monkeypatch.setattr(video, "frame_times", boom)
    r = _post(client)
    assert r.status_code == 200
    assert "could not read the clip" in r.json()["error"]
    assert fake_sam["uploaded"] == []  # nothing goes to Meta when the clip is unreadable


def test_empty_clip_streams_an_error_line(client, fake_sam):
    r = _post(client, data=b"")
    assert r.status_code == 200 and "empty" in r.json()["error"]


def test_file_is_deleted_even_when_sam_fails(client, fake_sam, monkeypatch):
    async def boom(file_id, prompt):
        raise RuntimeError("sam down")

    monkeypatch.setattr(meta, "segment_video", boom)
    r = _post(client)
    assert r.status_code == 200 and r.json()["error"] == "count failed: RuntimeError"
    assert fake_sam["deleted"] == ["file_1"]


def test_slow_count_sends_heartbeats_before_the_json(client, fake_sam, monkeypatch):
    import asyncio

    monkeypatch.setattr(sets_api, "HEARTBEAT_SECONDS", 0.05)
    original = meta.segment_video

    async def slow(file_id, prompt):
        await asyncio.sleep(0.2)
        return await original(file_id, prompt)

    monkeypatch.setattr(meta, "segment_video", slow)
    r = _post(client)
    assert r.status_code == 200
    assert r.text.startswith("\n") and r.text.count("\n") >= 2
    assert r.json()["reps"] == 8


def test_no_track_gives_no_count(client, fake_sam, monkeypatch):
    async def nothing(file_id, prompt):
        return SimpleNamespace(records=[])

    monkeypatch.setattr(meta, "segment_video", nothing)
    r = _post(client)
    assert r.status_code == 200
    body = r.json()
    assert body["reps"] is None and body["trackFound"] is False and body["repTimes"] == []


def test_context_model_defaults():
    ctx = sets_api.CountContext.model_validate_json('{"exerciseId":"e","equipment":"cable"}')
    assert ctx.plannedReps is None and ctx.phoneReps is None
