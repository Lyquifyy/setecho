from types import SimpleNamespace

import cv2
import numpy as np

from app import photos


def _jpeg(width: int, height: int) -> bytes:
    img = np.zeros((height, width, 3), np.uint8)
    ok, buf = cv2.imencode(".jpg", img)
    assert ok
    return buf.tobytes()


def _record(left, top, right, bottom):
    return SimpleNamespace(
        kind="mask",
        bounds=SimpleNamespace(left=left, top=top, right=right, bottom=bottom),
        mask=SimpleNamespace(width=right - left, height=bottom - top),
    )


def test_prepare_image_downscales_long_side_to_1280():
    p = photos.prepare_image(_jpeg(3024, 4032))
    assert (p.width, p.height) == (960, 1280)
    assert abs(p.scale - 1280 / 4032) < 1e-9
    assert photos.decode_bgr(p.jpeg).shape == (1280, 960, 3)


def test_prepare_image_leaves_small_images_alone():
    p = photos.prepare_image(_jpeg(640, 480))
    assert (p.width, p.height, p.scale) == (640, 480, 1.0)


def test_largest_mask_picks_biggest_box_and_handles_none():
    small = _record(10, 10, 30, 30)
    big = _record(100, 50, 400, 650)
    result = SimpleNamespace(records=[SimpleNamespace(kind="box"), small, big])
    assert photos.largest_mask(result) is big
    assert photos.box_of(big) == (100, 50, 300, 600)
    assert photos.largest_mask(SimpleNamespace(records=[])) is None


def test_full_frame_mask_places_box_local_raster(monkeypatch):
    record = _record(5, 2, 9, 6)  # 4 x 4 box
    raster = np.array([[1, 1, 0, 0], [1, 1, 0, 0], [0, 0, 1, 1], [0, 0, 1, 1]], np.uint8)
    monkeypatch.setattr(photos, "mask_raster", lambda r: raster)
    full = photos.full_frame_mask(record, width=12, height=8)
    assert full.shape == (8, 12)
    assert full.sum() == 8
    assert full[2, 5] == 1 and full[3, 6] == 1 and full[5, 8] == 1
    assert full[2, 7] == 0 and full[0, 0] == 0


def test_full_frame_mask_clips_at_frame_edges(monkeypatch):
    record = _record(10, 6, 14, 10)  # runs past a 12 x 8 frame
    monkeypatch.setattr(photos, "mask_raster", lambda r: np.ones((4, 4), np.uint8))
    full = photos.full_frame_mask(record, width=12, height=8)
    assert full.sum() == 2 * 2
    assert full[6:8, 10:12].all()


def test_overlay_and_mask_png():
    bgr = np.full((8, 12, 3), 200, np.uint8)
    mask = np.zeros((8, 12), np.uint8)
    mask[2:6, 3:9] = 1
    out = photos.overlay(bgr, mask, (3, 2, 6, 4))
    assert out.shape == bgr.shape
    assert not np.array_equal(out[4, 5], bgr[4, 5])  # tinted inside the mask
    assert np.array_equal(out[0, 0], bgr[0, 0])  # untouched outside
    png = photos.mask_png_base64(mask)
    assert png.startswith("iVBOR")  # PNG magic, base64-encoded
