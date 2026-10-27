"""Alignment math and the /photos/segment endpoint, offline. SAM is replayed from the saved fixture."""

import base64
from pathlib import Path

import cv2
import numpy as np
import pytest
from fastapi.testclient import TestClient

from app import align, meta, photos
from app.main import app

FIXTURES = Path(__file__).parent / "fixtures"
Box = align.Box


def test_first_set_uses_the_default_fraction():
    a = align.align(Box(400, 200, 300, 900), width=1200, height=1600, reference_fraction=None)
    # Body 900 px tall at 80% -> crop 1125 tall, 844 wide, centred on the box (cx 550, cy 650).
    assert a.crop == Box(128, 88, 844, 1125)
    assert abs(a.body_fraction - 0.8) < 0.001
    assert not a.clamped


def test_later_weeks_match_the_reference_fraction():
    a = align.align(Box(400, 200, 300, 900), width=1200, height=1600, reference_fraction=0.6)
    assert a.crop.h == 1500 and a.crop.w == 1125
    assert abs(a.body_fraction - 0.6) < 0.001


def test_crop_shrinks_and_shifts_to_stay_inside_the_image():
    # Standing too close: the wanted crop is taller than the photo.
    a = align.align(Box(300, 50, 600, 1500), width=1200, height=1600, reference_fraction=0.5)
    assert a.clamped
    assert a.crop.h <= 1600 and a.crop.w <= 1200
    assert a.crop.x >= 0 and a.crop.y >= 0
    assert abs(a.crop.w / a.crop.h - 0.75) < 0.01
    # Standing at the left edge: the crop shifts right of its ideal centre.
    b = align.align(Box(0, 300, 200, 800), width=1200, height=1600, reference_fraction=0.8)
    assert b.crop.x == 0 and b.clamped


def test_scaled_maps_between_pixel_spaces():
    assert align.scaled(Box(10, 20, 30, 40), 2.5) == Box(25, 50, 75, 100)


def test_bad_sizes_raise():
    with pytest.raises(ValueError):
        align.align(Box(0, 0, 0, 10), width=100, height=100, reference_fraction=None)


@pytest.fixture
def sam_replay(monkeypatch):
    raw = (FIXTURES / "sam" / "photos" / "shape.raw.txt").read_text()

    async def fake(data_url, prompt="person"):
        return await photos.replay_raw(raw)

    monkeypatch.setattr(meta, "segment_image", fake)


def _jpeg(width: int, height: int) -> bytes:
    ok, buf = cv2.imencode(".jpg", np.full((height, width, 3), 255, np.uint8))
    assert ok
    return buf.tobytes()


def test_segment_endpoint_returns_box_crop_and_mask(sam_replay):
    client = TestClient(app)
    # A 2400 x 1800 upload is prepared at 1280 x 960 (scale 0.5333); the fixture box is in prepared px.
    r = client.post("/photos/segment", files={"image": ("front.jpg", _jpeg(2400, 1800), "image/jpeg")})
    assert r.status_code == 200, r.text
    body = r.json()
    assert (body["width"], body["height"]) == (2400, 1800)
    # Fixture box [482, 232, 437, 437] in 1200 x 900 prepared px... the fixture was made at 1200 x 900,
    # so here it lands scaled by 2400 / 1280.
    assert body["box"] == [904, 435, 819, 819]
    assert len(body["crop"]) == 4 and abs(body["crop"][2] / body["crop"][3] - 0.75) < 0.01
    assert abs(body["bodyFraction"] - 0.8) < 0.01 or body["clamped"]
    png = base64.b64decode(body["maskPng"])
    assert png[:4] == b"\x89PNG"
    assert (body["maskWidth"], body["maskHeight"]) == (1280, 960)


def test_segment_endpoint_with_reference_fraction(sam_replay):
    client = TestClient(app)
    r = client.post(
        "/photos/segment",
        files={"image": ("front.jpg", _jpeg(1200, 900), "image/jpeg")},
        data={"referenceFraction": "0.5"},
    )
    assert r.status_code == 200, r.text
    body = r.json()
    assert body["box"] == [482, 232, 437, 437]
    assert body["crop"][3] == 874 and body["crop"][2] == 656  # 437 / 0.5 tall, 3:4 wide
    assert abs(body["bodyFraction"] - 0.5) < 0.01


def test_segment_endpoint_no_person_is_422(monkeypatch):
    async def nothing(data_url, prompt="person"):
        return await photos.replay_raw("")

    monkeypatch.setattr(meta, "segment_image", nothing)
    client = TestClient(app)
    r = client.post("/photos/segment", files={"image": ("front.jpg", _jpeg(600, 800), "image/jpeg")})
    assert r.status_code == 422
    assert "no person" in r.json()["error"]


def test_segment_endpoint_rejects_garbage():
    client = TestClient(app)
    r = client.post("/photos/segment", files={"image": ("front.jpg", b"not an image", "image/jpeg")})
    assert r.status_code == 422
