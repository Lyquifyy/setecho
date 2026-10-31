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
    assert {"paused_rep", "half_rep", "short_gap", "mostly_lost", "clean_8", "slowing_8"} <= names


# --- Steps 8-9: rep speed and velocity loss (HANDOFF.md §5) ---


def test_slowing_set_reports_its_velocity_loss():
    """The last two reps take 3.6 s against 2.0 s for the first two: a 44% drop in lifting speed."""
    series = _series(FIXTURES / "slowing_8.json")
    result = reps.count_1d(series)
    assert result.reps == 8 and len(result.rep_speeds) == 8
    assert result.rep_speeds == sorted(result.rep_speeds, reverse=True)
    assert result.velocity_loss_pct == pytest.approx(series.extra["expectedVelocityLossPct"], abs=3)


def test_even_set_has_no_velocity_loss_and_a_pause_at_the_bottom_is_not_lifting():
    assert reps.count_1d(_series(FIXTURES / "clean_8.json")).velocity_loss_pct == 0.0
    paused = reps.count_1d(_series(FIXTURES / "paused_rep.json"))
    assert paused.velocity_loss_pct == 0.0  # the 2 s hold at the bottom of rep 3 is not a slow lift
    assert max(paused.rep_speeds) - min(paused.rep_speeds) < 0.01


def test_velocity_loss_needs_three_reps_and_never_applies_to_a_rest_pause_set():
    assert reps.count_1d(_series(FIXTURES / "single_rep.json")).velocity_loss_pct is None
    assert reps.velocity_loss([1.0, 0.5]) is None
    assert reps.velocity_loss([1.0, 0.9, 0.5, 0.5]) == pytest.approx(50.0)
    assert reps.velocity_loss([1.0, 0.9, 0.5, 0.5], "restPause") is None
    assert reps.velocity_loss([1.0, 0.9, 1.2, 1.3]) == 0.0  # faster at the end: floored at 0
    assert reps.velocity_loss([0.0, 0.0, 0.5]) is None
    assert reps.count_1d(_series(FIXTURES / "slowing_8.json"), set_role="restPause").velocity_loss_pct is None
    assert reps.count_1d(_series(FIXTURES / "slowing_8.json"), set_role="top").velocity_loss_pct is not None


def _with_track_jump(series: reps.Series, rep: int, jump: float = 1.5) -> reps.Series:
    """The series with a swapped mask for two frames in one rep's lifting phase: the centroid sits on
    another object 1.5 of the motion range away, then comes back."""
    peaks, _ = reps.count_series(series.t, series.y)
    y = series.y.copy()
    y[peaks[rep] + 3 : peaks[rep] + 5] += jump
    return reps.Series(series.t, y)


def test_a_track_jump_in_an_early_rep_does_not_fake_a_slowdown():
    """SAM swaps masks for two frames during rep 2: that rep's speed comes out 30x the median. The
    count keeps the rep; the slowdown is the one the other seven reps imply, not 98%."""
    series = _series(FIXTURES / "slowing_8.json")
    clean = reps.count_1d(series)
    jumped = reps.count_1d(_with_track_jump(series, rep=1))
    assert jumped.reps == 8 and len(jumped.rep_times) == 8 and len(jumped.rep_speeds) == 8
    assert jumped.rep_times == pytest.approx(clean.rep_times, abs=0.3)  # the spike nudges rep 2's peak
    median = float(np.median(jumped.rep_speeds))
    assert jumped.rep_speeds[1] > 5 * median
    assert reps.speed_outliers(jumped.rep_speeds) == [1]
    assert jumped.velocity_loss_pct == pytest.approx(clean.velocity_loss_pct, abs=1)
    assert reps.velocity_loss(jumped.rep_speeds, "restPause") is None


def test_a_track_jump_in_the_last_rep_does_not_hide_the_slowdown():
    """The same artifact on rep 8 would read as a sprint at the end and floor the loss at 0."""
    series = _series(FIXTURES / "slowing_8.json")
    jumped = reps.count_1d(_with_track_jump(series, rep=7))
    assert jumped.reps == 8
    assert reps.speed_outliers(jumped.rep_speeds) == [7]
    # Reps 6 and 7 against the fastest of 1 and 2: 100 x (1 - (0.148 + 0.114) / 2 / 0.208).
    assert jumped.velocity_loss_pct == pytest.approx(37.0, abs=3)
    assert jumped.velocity_loss_pct > 25


def test_speed_outliers_are_over_twice_the_median_and_rarely_leave_enough_reps():
    speeds = [1.0, 1.0, 1.0, 1.0, 5.0, 1.0, 0.6, 0.6]
    assert reps.speed_outliers(speeds) == [4]
    assert reps.velocity_loss(speeds) == pytest.approx(40.0)
    assert reps.speed_outliers([1.0, 1.0, 2.0]) == []  # exactly twice the median is a fast rep, kept
    assert reps.speed_outliers([]) == [] and reps.speed_outliers([0.0, 0.0, 3.0]) == []
    assert reps.velocity_loss([1.0, 1.0, 9.0]) is None  # one artifact leaves two: no loss
    assert reps.velocity_loss([1.0, 1.0, 9.0, 0.5]) == pytest.approx(25.0)  # (1.0 + 0.5) / 2 against 1.0


def test_no_shared_fixture_carries_a_speed_outlier():
    """The rule changes nothing on the synthetic sets: every speed sits within twice the median."""
    for path in FIXTURE_FILES:
        result = reps.count_1d(_series(path))
        assert reps.speed_outliers(result.rep_speeds) == [], path.stem


def test_rep_speed_uses_real_timestamps():
    """The same motion sampled at half the frame rate must give the same speed."""
    series = _series(FIXTURES / "slowing_8.json")
    full = reps.count_1d(series)
    half = reps.count_1d(reps.Series(series.t[::2], series.y[::2]))
    assert half.reps == 8
    assert half.velocity_loss_pct == pytest.approx(full.velocity_loss_pct, abs=4)


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


def test_a_sam_track_on_under_half_the_frames_gives_no_count():
    series = _series(FIXTURES / "clean_8.json")
    centroids = np.stack([series.y * 100, series.y * 100], axis=1)
    hidden = len(centroids) * 3 // 5
    centroids[:hidden] = np.nan
    result = reps.count(reps.Track(series.t, centroids))
    assert result == reps.RepResult(None, [], 0.0, False, len(series.t), len(series.t) - hidden)
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
    track = reps.Track(np.asarray(data["t"], float), centroids, data.get("objectSizePx", 0.0))
    result = reps.count(track)
    assert result.reps == data["expectedReps"]
    # Step 8-9 on a real set: every rep has a speed, and the set slowed (it was taken near failure).
    assert len(result.rep_speeds) == result.reps and all(v > 0 for v in result.rep_speeds)
    assert result.velocity_loss_pct is not None and 30 <= result.velocity_loss_pct <= 70
    assert reps.count(track, "restPause").velocity_loss_pct is None
    # Rep 4 of the real set is slow (a grind, about 0.4 of the median), never over twice it: no
    # speed is set aside, and the loss is the one the plain formula gives.
    assert reps.speed_outliers(result.rep_speeds) == []


def test_the_two_g7_passes_agree_on_the_velocity_loss():
    """SAM runs are not deterministic, but the two passes over the same set land within a point."""
    results = []
    for path in SAM_FIXTURES:
        data = json.loads(path.read_text())
        centroids = np.array(
            [
                [np.nan if x is None else x, np.nan if y is None else y]
                for x, y in zip(data["x"], data["y"], strict=True)
            ]
        )
        results.append(reps.count(reps.Track(np.asarray(data["t"], float), centroids)))
    assert len(results) >= 2
    losses = [r.velocity_loss_pct for r in results]
    assert max(losses) - min(losses) < 1.0


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


def test_the_phones_joints_still_need_80_percent():
    series = _series(FIXTURES / "clean_8.json")
    y = series.y.copy()
    y[: len(y) // 3] = np.nan
    assert reps.count_1d(reps.Series(series.t, y)).reps is None


def test_the_dumbbell_in_his_hand_beats_the_racked_ones():
    """Oct 30, seated DB shoulder press: SAM kept a dumbbell seen on all 490 frames that never moved
    and counted 0. The pressing one is hidden by his hands on part of each rep."""
    n = 12 + 8 * 15 + 12  # a second at his shoulders, 8 presses, a second at his shoulders
    times = [i / 12 for i in range(n)]
    records = []
    for i in range(n):
        records.append(_mask_record("rack", i, 900, 600, 960, 640))  # still, every frame
        k = i - 12
        y = 350 - int(150 * (1 - np.cos(2 * np.pi * k / 15)) / 2) if 0 <= k < 120 else 350  # 150 px up
        if not (0 <= k < 120 and k % 15 in (6, 7, 8, 9)):  # hidden at the top of each rep: 78% of frames
            records.append(_mask_record("pressing", i, 300, y, 360, y + 40))
    track = reps.centroid_track(SimpleNamespace(records=records), times)
    assert track.motion_range > 100
    result = reps.count(track)
    assert result.reps == 8 and result.track_found
    assert result.confidence <= round(track.share, 3)  # the hidden frames lower it


def test_a_still_object_on_most_frames_is_kept_only_when_nothing_moves():
    n = 40
    times = [i / 10 for i in range(n)]
    records = [_mask_record("rack", i, 900, 600, 960, 640) for i in range(n)]
    records += [_mask_record("blip", i, 100, 100, 160, 140) for i in range(n // 2 + 2)]  # still, 55%
    track = reps.centroid_track(SimpleNamespace(records=records), times)
    assert track.share == 1.0 and reps.count(track).reps == 0
