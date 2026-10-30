"""POST /sets/count with SAM and ffprobe replaced: the request shape, the response, the errors."""

import json
from pathlib import Path

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

    async def segment(file_id, prompt):
        calls["prompts"].append(prompt)
        frames = []
        for i, y in enumerate(series.y):
            top = int(400 - 500 * float(y))
            frames.append(
                f"<{i}f>0<|box;x1=600;y1={top};x2=680;y2={top + 80};w=1280;h=720|><|mask;x=0;y=0;data=!!|>"
            )
        return "".join(frames)

    monkeypatch.setattr(meta, "segment_video_raw", segment)
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
    assert len(body["repSpeeds"]) == 8 and all(v > 0 for v in body["repSpeeds"])
    assert body["velocityLossPct"] == 0.0  # an even set
    assert fake_sam["uploaded"] == ["set.mp4"] and fake_sam["deleted"] == ["file_1"]


def test_rest_pause_set_gets_no_velocity_loss(client, fake_sam):
    r = _post(client, context={"exerciseId": "x", "equipment": "barbell", "setRole": "restPause"})
    assert r.status_code == 200, r.text
    body = r.json()
    assert body["reps"] == 8 and body["velocityLossPct"] is None and len(body["repSpeeds"]) == 8
    r = _post(client, context={"exerciseId": "x", "equipment": "barbell", "setRole": "warmup"})
    assert r.json()["velocityLossPct"] == 0.0
    r = _post(client, context={"exerciseId": "x", "equipment": "barbell", "setRole": "amrap"})
    assert r.status_code == 422


def test_equipment_picks_the_prompt(client, fake_sam):
    r = _post(client, context={"exerciseId": "x", "equipment": "dumbbell"})
    assert r.status_code == 200 and r.json()["prompt"] == "dumbbell"
    assert sorted(fake_sam["prompts"]) == ["dumbbell", "hand"]  # the hands looked at alongside


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

    monkeypatch.setattr(meta, "segment_video_raw", boom)
    r = _post(client)
    assert r.status_code == 200 and r.json()["error"] == "count failed: RuntimeError"
    assert fake_sam["deleted"] == ["file_1"]


def test_slow_count_sends_heartbeats_before_the_json(client, fake_sam, monkeypatch):
    import asyncio

    monkeypatch.setattr(sets_api, "HEARTBEAT_SECONDS", 0.05)
    original = meta.segment_video_raw

    async def slow(file_id, prompt):
        await asyncio.sleep(0.2)
        return await original(file_id, prompt)

    monkeypatch.setattr(meta, "segment_video_raw", slow)
    r = _post(client)
    assert r.status_code == 200
    assert r.text.startswith("\n") and r.text.count("\n") >= 2
    assert r.json()["reps"] == 8


def test_no_track_gives_no_count(client, fake_sam, monkeypatch):
    async def nothing(file_id, prompt):
        return ""

    monkeypatch.setattr(meta, "segment_video_raw", nothing)
    r = _post(client)
    assert r.status_code == 200
    body = r.json()
    assert body["reps"] is None and body["trackFound"] is False and body["repTimes"] == []
    assert body["repSpeeds"] == [] and body["velocityLossPct"] is None
    assert fake_sam["deleted"] == ["file_1"]


def test_nothing_moving_under_the_equipment_looks_at_his_hands(client, fake_sam, monkeypatch):
    """Oct 30: the dumbbell prompt found only racked ones. The hands carry the count, and its speeds."""
    original = meta.segment_video_raw

    async def only_hands(file_id, prompt):
        fake_sam["prompts"].append(prompt)
        return await original(file_id, prompt) if prompt == "hand" else ""

    monkeypatch.setattr(meta, "segment_video_raw", only_hands)
    r = _post(client, context={"exerciseId": "x", "equipment": "dumbbell"})
    body = r.json()
    assert [p for p in fake_sam["prompts"] if p in ("dumbbell", "hand")][:2] == ["dumbbell", "hand"]
    assert body["reps"] == 8 and body["prompt"] == "hand" and body["velocityLossPct"] == 0.0
    assert "segment2" in body["timings"] and fake_sam["deleted"] == ["file_1"]


def test_a_count_under_the_equipment_needs_no_second_look(client, fake_sam):
    r = _post(client, context={"exerciseId": "x", "equipment": "barbell"})
    assert r.json()["reps"] == 8 and fake_sam["prompts"] == ["weight plate"]


def test_dumbbells_and_cables_look_at_the_hands_at_the_same_time(client, fake_sam):
    """Both looks run together; the equipment's count wins when it has one."""
    r = _post(client, context={"exerciseId": "x", "equipment": "cable"})
    body = r.json()
    assert sorted(fake_sam["prompts"]) == ["hand", "weight stack"]
    assert body["reps"] == 8 and body["prompt"] == "weight stack" and fake_sam["deleted"] == ["file_1"]


def test_context_model_defaults():
    ctx = sets_api.CountContext.model_validate_json('{"exerciseId":"e","equipment":"cable"}')
    assert ctx.plannedReps is None and ctx.phoneReps is None and ctx.setRole is None


def test_clips_are_720p_at_15_fps():
    assert video.COUNT_FPS == 15 and video.COUNT_HEIGHT == 720
    assert video.MAX_COUNT_FRAMES == 4 * 60 * 15


# His station only (HANDOFF.md §7, Sets start on his word): the phone sends his box, SAM sees the crop.


def test_a_crop_box_cuts_the_clip_before_sam(client, fake_sam, monkeypatch):
    cropped = []

    def fake_crop(src, dst, box, front=False):
        cropped.append(box)
        dst.write_bytes(src.read_bytes())
        return dst

    monkeypatch.setattr(video, "crop", fake_crop)
    ctx = {"exerciseId": "e", "equipment": "barbell", "cropBox": [0.2, 0.1, 0.5, 0.6]}
    r = _post(client, context=ctx)
    assert r.status_code == 200, r.text
    assert cropped == [[0.2, 0.1, 0.5, 0.6]]
    assert fake_sam["uploaded"] == ["station.mp4"]
    assert "crop" in r.json()["timings"]


def test_a_crop_that_fails_counts_the_whole_frame(client, fake_sam, monkeypatch):
    def broken(src, dst, box, front=False):
        raise ValueError("crop box too small")

    monkeypatch.setattr(video, "crop", broken)
    r = _post(
        client, context={"exerciseId": "e", "equipment": "barbell", "cropBox": [0.5, 0.5, 0.001, 0.001]}
    )
    assert r.status_code == 200 and r.json()["reps"] == 8
    assert fake_sam["uploaded"] == ["set.mp4"]


def test_crop_box_in_the_upright_frame_and_the_sensors():
    # Portrait as decoded (the file carries its rotation): the box as the phone saw it.
    assert video.crop_box_pixels([0.25, 0.1, 0.5, 0.5], (720, 1280)) == (360, 640, 180, 128)
    # Landscape, the sensor's own orientation: the upright frame is this one turned 90° clockwise,
    # so the upright top-left quarter is the sensor frame's bottom-left quarter.
    assert video.crop_box_pixels([0.0, 0.0, 0.5, 0.5], (1280, 720)) == (640, 360, 0, 360)
    assert video.crop_box_pixels([0.5, 0.0, 0.5, 0.5], (1280, 720)) == (640, 360, 0, 0)
    # The front camera turns the other way: the upright top-left quarter is its top-right quarter.
    assert video.crop_box_pixels([0.0, 0.0, 0.5, 0.5], (1280, 720), front=True) == (640, 360, 640, 0)
    assert video.crop_box_pixels([0.0, 0.0, 0.5, 0.5], (720, 1280), front=True) == (360, 640, 0, 0)


@pytest.mark.skipif(not video.has_ffmpeg(), reason="ffmpeg not installed")
def test_crop_keeps_every_frame_and_its_time(tmp_path):
    import subprocess

    src = tmp_path / "src.mp4"
    subprocess.run(
        ["ffmpeg", "-y", "-loglevel", "error", "-f", "lavfi", "-i", "testsrc=size=720x1280:rate=15:duration=2",
         "-pix_fmt", "yuv420p", str(src)],
        check=True,
    )  # fmt: skip
    out = video.crop(src, tmp_path / "out.mp4", [0.25, 0.25, 0.5, 0.5])
    assert video.display_size(out) == (360, 640)
    assert video.frame_times(out) == pytest.approx(video.frame_times(src))
