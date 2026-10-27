"""Rep counting on synthetic series and on fake SAM records. Never hits the API."""

import json
from pathlib import Path
from types import SimpleNamespace

import numpy as np
import pytest

from app import reps

FIXTURES = Path(__file__).parent / "fixtures" / "reps"
FIXTURE_FILES = sorted(FIXTURES.glob("*.json"))


def _series(path: Path) -> reps.Series:
    return reps.series_from_json(json.loads(path.read_text()))


@pytest.mark.parametrize("path", FIXTURE_FILES, ids=[p.stem for p in FIXTURE_FILES])
def test_shared_fixture_counts_match(path):
    series = _series(path)
    result = reps.count_1d(series)
    assert result.reps == series.expected_reps, f"{series.name}: {series.notes}"
    if series.expected_reps is None:
        assert not result.track_found
    else:
        assert result.track_found
        assert len(result.rep_times) == series.expected_reps
        assert result.rep_times == sorted(result.rep_times)


def test_fixture_set_covers_the_required_cases():
    names = {p.stem for p in FIXTURE_FILES}
    assert {"paused_rep", "half_rep", "short_gap", "mostly_lost", "clean_8"} <= names


def test_paused_rep_is_one_rep_and_confident():
    result = reps.count_1d(_series(FIXTURES / "paused_rep.json"))
    assert result.reps == 5
    assert result.track_found


def test_half_rep_does_not_reach_the_prominence():
    full = _series(FIXTURES / "clean_8.json")
    half = _series(FIXTURES / "half_rep.json")
    assert reps.count_1d(full).reps == 8
    assert reps.count_1d(half).reps == 6


def test_confidence_rewards_even_tempo():
    even = reps.count_1d(_series(FIXTURES / "clean_8.json"))
    uneven = reps.count_1d(_series(FIXTURES / "uneven_tempo.json"))
    assert even.confidence > 0.9
    assert uneven.confidence < even.confidence
    assert reps.confidence_of(1.0, []) == 0.0
    assert reps.confidence_of(0.9, [1.0]) == pytest.approx(0.45)
    assert reps.confidence_of(1.0, [1.0, 2.0, 3.0]) == pytest.approx(1.0)
    assert reps.confidence_of(0.85, [1.0, 2.0, 3.0]) == pytest.approx(0.85)


def test_gap_fill_bridges_short_gaps_and_holds_long_ones():
    t = np.arange(10) / 10
    y = np.array([0, 1, np.nan, np.nan, 4, np.nan, np.nan, np.nan, np.nan, np.nan], float)
    filled = reps.fill_gaps(t, y, max_gap=0.35)
    assert filled[2] == pytest.approx(2) and filled[3] == pytest.approx(3)  # 0.3 s gap: interpolated
    assert (filled[5:] == 4).all()  # untracked tail: held
    y2 = np.array([np.nan, np.nan, 2, np.nan, np.nan, np.nan, np.nan, np.nan, np.nan, 9], float)
    filled2 = reps.fill_gaps(t, y2, max_gap=0.35)
    assert (filled2[:2] == 2).all()  # untracked head: held
    assert (filled2[3:9] == 2).all()  # 0.7 s gap: held, never a ramp that could look like a rep


def test_smooth_is_savitzky_golay_window_5_order_2():
    assert np.allclose(reps.SMOOTH_KERNEL, np.array([-3, 12, 17, 12, -3]) / 35)
    y = np.array([0, 1, 2, 3, 4, 5, 6.0])
    assert np.allclose(reps.smooth(y), y)  # a line is its own quadratic fit
    spike = np.array([0, 0, 0, 1, 0, 0, 0.0])
    s = reps.smooth(spike)
    assert s[3] == pytest.approx(17 / 35)
    assert s[2] == pytest.approx(12 / 35) and s[4] == pytest.approx(12 / 35)
    assert s[1] == 0 and s[5] == 0 and s[0] == 0 and s[6] == 0  # the two edge samples are kept
    assert reps.smooth(np.array([1.0, 2.0])).tolist() == [1.0, 2.0]


def test_jitter_below_the_amplitude_floor_is_zero_reps():
    t = np.arange(120) / 15
    jitter = 0.004 * np.sin(t * 9)
    assert reps.count_1d(reps.Series(t, 0.5 + jitter)).reps == 0
    # In pixels, the floor is a tenth of the object's size: a 100 px plate must move 10 px.
    track = reps.Track(t, np.stack([np.zeros_like(t), 300 + 3 * np.sin(t * 2)], axis=1), object_size=100)
    assert reps.count(track).reps == 0
    moving = reps.Track(t, np.stack([np.zeros_like(t), 300 + 60 * np.sin(t * 2)], axis=1), object_size=100)
    assert reps.count(moving).reps > 0


def test_two_dimensional_track_projects_onto_the_motion_axis():
    series = _series(FIXTURES / "clean_8.json")
    # The plate moves along a diagonal in the frame; the centroid wanders a bit sideways.
    y = series.y
    centroids = np.stack([640 + 300 * y + 2 * np.sin(series.t * 9), 400 - 500 * y], axis=1)
    track = reps.Track(series.t, centroids)
    result = reps.count(track)
    assert result.reps == 8 and result.track_found
    assert result.frames == len(series.t) and result.tracked_frames == len(series.t)
    assert result.rep_times[0] > 1.0 and result.rep_times[-1] < series.t[-1]


def test_untracked_frames_below_80_percent_give_no_count():
    series = _series(FIXTURES / "clean_8.json")
    centroids = np.stack([series.y * 100, series.y * 100], axis=1)
    centroids[: len(centroids) // 3] = np.nan
    result = reps.count(reps.Track(series.t, centroids))
    assert result == reps.RepResult(None, [], 0.0, False, len(series.t), len(series.t) - len(series.t) // 3)
    assert reps.count(reps.Track(np.array([]), np.zeros((0, 2)))).frames == 0


def _mask_record(object_id, frame_index, left, top, right, bottom):
    return SimpleNamespace(
        kind="mask",
        object_id=object_id,
        frame=SimpleNamespace(frame_index=frame_index),
        bounds=SimpleNamespace(left=left, top=top, right=right, bottom=bottom),
        mask=SimpleNamespace(width=right - left, height=bottom - top),
    )


def test_centroid_track_keeps_the_object_seen_on_most_frames_when_none_qualifies():
    times = [0.0, 0.1, 0.2, 0.3]
    records = [
        _mask_record("plate", 0, 10, 10, 30, 30),
        _mask_record("plate", 1, 10, 20, 30, 40),
        _mask_record("plate", 3, 10, 40, 30, 60),
        _mask_record("shadow", 2, 100, 100, 120, 120),
        SimpleNamespace(kind="text", text="plate"),
        _mask_record("plate", 9, 0, 0, 1, 1),  # a frame index the file does not have
    ]
    track = reps.centroid_track(SimpleNamespace(records=records), times)
    assert track.object_size == 20.0 and track.objects == 2
    assert track.centroids[0].tolist() == [20.0, 20.0]
    assert track.centroids[1].tolist() == [20.0, 30.0]
    assert np.isnan(track.centroids[2]).all()
    assert track.centroids[3].tolist() == [20.0, 50.0]
    assert track.share == 0.75


def test_centroid_track_picks_the_plate_that_moves_not_the_rack():
    """A gym has many plates in frame: the one on the bar travels, the racked ones sit still."""
    n = 40
    times = [i / 10 for i in range(n)]
    records = []
    for i in range(n):
        records.append(_mask_record("rack", i, 1200, 80, 1300, 180))  # still, every frame
        y = 300 + int(120 * (1 - np.cos(2 * np.pi * i / 20)) / 2)  # two reps of 120 px
        records.append(_mask_record("bar", i, 100, y, 200, y + 100))
        if i < 36:  # a track that hops to another plate halfway: a 600 px step
            x = 600 if i < 18 else 1200
            records.append(_mask_record("hopper", i, x, 300, x + 100, 400))
    track = reps.centroid_track(SimpleNamespace(records=records), times)
    assert track.objects == 3
    assert abs(track.centroids[0][0] - 150) < 1e-6  # the bar's plate
    assert track.motion_range > 100
    assert reps.count(track).reps == 2


def test_equipment_prompts_and_inference():
    assert reps.SAM_PROMPTS == {
        "barbell": "weight plate",
        "dumbbell": "dumbbell",
        "machine": "weight stack",
        "cable": "weight stack",
        "bodyweight": "person",
    }
    assert reps.infer_equipment("Bench press") == "barbell"
    assert reps.infer_equipment("Incline DB press") == "dumbbell"
    assert reps.infer_equipment("Cable fly") == "cable"
    assert reps.infer_equipment("Leg press") == "machine"
    assert reps.infer_equipment("Weighted pull-up") == "bodyweight"
    assert reps.infer_equipment("Lat pulldown") == "cable"


def test_series_json_round_trip():
    series = reps.Series(
        t=np.array([0.0, 0.1]), y=np.array([1.0, np.nan]), expected_reps=0, name="x", notes="n"
    )
    data = reps.series_to_json(series)
    assert data["y"] == [1.0, None]
    back = reps.series_from_json(data)
    assert back.name == "x" and back.expected_reps == 0 and np.isnan(back.y[1])


SAM_FIXTURES = sorted((Path(__file__).parent / "fixtures" / "sam_reps").glob("*.json"))


@pytest.mark.parametrize("path", SAM_FIXTURES, ids=[p.stem for p in SAM_FIXTURES])
def test_saved_g7_centroid_series_count_correctly(path):
    """Real sets from the G7 probe, replayed offline. Added as the human runs the probe."""
    data = json.loads(path.read_text())
    centroids = np.array(
        [
            [np.nan if x is None else x, np.nan if y is None else y]
            for x, y in zip(data["x"], data["y"], strict=True)
        ]
    )
    result = reps.count(reps.Track(np.asarray(data["t"], float), centroids))
    assert result.reps == data["expectedReps"]


def test_parse_boxes_reads_frames_and_objects_and_skips_masks():
    raw = (
        "<0f>0<|box;x1=10;y1=20;x2=30;y2=40;w=1280;h=720|><|mask;x=0;y=0;data=1,1,!!|>"
        ",1<|box;x1=100;y1=100;x2=120;y2=120;w=1280;h=720|><|mask;x=0;y=0;data=!!|>"
        "<1f>0<|box;x1=10;y1=25;x2=30;y2=45;w=1280;h=720|><|mask;x=0;y=0;data=!!|>"
        "<3f>1<|box;x1=100;y1=100;x2=120;y2=120;w=1280;h=720|><|mask;x=0;y=0;data=!!|>"
    )
    boxes = reps.parse_boxes(raw)
    assert boxes == {
        "0": {0: (10.0, 20.0, 30.0, 40.0), 1: (10.0, 25.0, 30.0, 45.0)},
        "1": {0: (100.0, 100.0, 120.0, 120.0), 3: (100.0, 100.0, 120.0, 120.0)},
    }
    track = reps.track_from_raw(raw, [0.0, 0.1, 0.2, 0.3])
    assert track.objects == 2 and track.centroids[1].tolist() == [20.0, 35.0]
    assert reps.parse_boxes("") == {} and reps.track_from_raw("", [0.0]).share == 0.0


def test_parse_boxes_is_fast_enough_for_a_set():
    import time

    frame = "".join(
        f",{o}<|box;x1={o * 50};y1=100;x2={o * 50 + 40};y2=140;w=1280;h=720|><|mask;x=0;y=0;data="
        + "x" * 150
        + "|>"
        for o in range(15)
    )
    raw = "".join(f"<{i}f>" + frame[1:] for i in range(400))  # a 40 s set with 15 plates in frame
    t0 = time.time()
    boxes = reps.parse_boxes(raw)
    assert len(boxes) == 15 and len(boxes["0"]) == 400
    assert time.time() - t0 < 1.0
