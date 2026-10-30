"""Rep counting from a SAM 3.1 track (HANDOFF.md §5, `/sets/count`). Pure NumPy and SciPy.

The pipeline, numbered as in the handoff:
1. SAM tracks the equipment ("weight plate", "dumbbell", "weight stack", "person"). Keep the
   object that moves furthest among those tracked on at least half the frames; a dumbbell in his
   hand is hidden by it, while the racked ones sit in plain view on every frame. Under half of the
   frames tracked means no count, and the share lowers the confidence (step 6).
2. One centroid per frame, with the frame's own timestamp from the file (never index / fps).
3. Project onto the main direction of motion (first principal component), bridge gaps up to
   0.5 s, smooth with Savitzky-Golay (window 5, order 2).
4. The rest position is the median of the first and last 0.5 s; d(t) = |projection - rest|.
5. Reps are the peaks of d(t) with prominence of at least 35% of d's 95th percentile, at least
   0.8 s apart. A half rep never reaches the prominence and is not counted.
6. confidence = tracked share x (1 - min(1, CV of the rep intervals)).
7. (Tuned constants below.)
8. Rep speed: each rep's lifting phase runs from its deepest point (the peak of d) back toward
   the rest position, until d falls to 20% of that peak. rep_speeds = the mean |d'(t)| over that
   phase, with real timestamps. Pixels per second; the next step is a ratio, so no scale is needed.
9. Velocity loss: 100 x (1 - mean of the last two speeds / fastest of the first two), floored at 0.
   Sets under 3 reps and rest-pause sets return none: the pauses make the slowdown meaningless.

Steps 3-5 on a one-dimensional series are `count_series`, which `RepCounter.swift` mirrors on
the phone. Both run on the fixtures in tests/fixtures/reps/ and must agree.
"""

from __future__ import annotations

import itertools
import re
from dataclasses import dataclass, field
from typing import Any, Literal

import numpy as np
from scipy.signal import find_peaks, savgol_coeffs

Equipment = Literal["barbell", "dumbbell", "machine", "cable", "bodyweight"]
EQUIPMENT: tuple[str, ...] = Equipment.__args__  # type: ignore[attr-defined]

# What SAM is asked to track, per equipment (HANDOFF.md §5 step 1).
SAM_PROMPTS: dict[str, str] = {
    "barbell": "weight plate",
    "dumbbell": "dumbbell",
    "machine": "weight stack",
    "cable": "weight stack",
    "bodyweight": "person",
}

# When the equipment's prompt finds nothing that moves (no track, or a count of 0): his hands, which
# carry the weight on almost every lift. The racked dumbbell, a home cable with no stack in view, a
# machine filmed from the side (Oct 30: "I need to track any lift on video").
SAM_FALLBACK_PROMPT = "hand"
# Where the hands are looked at alongside the equipment, not after it: the equipment's look fails most
# often here, and doing both at once keeps the count near 30 s. Plates and bodies track well (G7).
HANDS_ALONGSIDE = ("dumbbell", "cable", "machine")

# Tuned constants. Change them here and in RepCounter.swift together.
MIN_TRACK_SHARE = 0.80
# A SAM object needs only this share to count, if it moves: the dumbbell in his hand is behind his
# hand and head for part of every rep (Oct 30: SAM kept a still dumbbell seen on all 490 frames and
# counted 0 on his seated press). The phone's joints keep MIN_TRACK_SHARE, as RepCounter.swift does.
MIN_MOVING_TRACK_SHARE = 0.50
# Motion smaller than this is jitter, never a rep: 0.05 of the frame for the phone's normalized
# joints (and the shared fixtures), a tenth of the tracked object's own size for SAM pixels.
MIN_AMPLITUDE_NORMALIZED = 0.05
MIN_AMPLITUDE_OBJECT_FRACTION = 0.10
GAP_FILL_SECONDS = 0.5
SMOOTH_WINDOW = 5
SMOOTH_ORDER = 2
REST_WINDOW_SECONDS = 0.5
PROMINENCE_FRACTION = 0.35
MIN_REP_INTERVAL_SECONDS = 0.8
LOW_CONFIDENCE = 0.6
# Step 8: the lifting phase starts when the bar leaves the deepest point (the last sample still
# within this fraction of the rep's peak, since a pause at the chest is a plateau, not a lift) and
# ends when d(t) has fallen to LIFT_PHASE_END_FRACTION of that peak.
LIFT_PHASE_START_FRACTION = 0.90
LIFT_PHASE_END_FRACTION = 0.20
# Step 9: velocity loss compares the last two reps with the first two, so it needs three.
MIN_REPS_FOR_VELOCITY = 3

SetRole = Literal["warmup", "top", "backOff", "restPause"]


@dataclass(frozen=True)
class RepResult:
    reps: int | None
    rep_times: list[float]
    confidence: float
    track_found: bool
    frames: int
    tracked_frames: int
    rep_speeds: list[float] = field(default_factory=list)  # step 8, one per rep, px/s (or units/s)
    velocity_loss_pct: float | None = None  # step 9; None under 3 reps or on a rest-pause set

    @property
    def is_confident(self) -> bool:
        return self.track_found and self.confidence >= LOW_CONFIDENCE


@dataclass(frozen=True)
class Track:
    """One centroid per frame in pixels; NaN where the object was not tracked."""

    times: np.ndarray  # (n,) seconds from the file
    centroids: np.ndarray  # (n, 2) x, y
    object_size: float = 0.0  # median of the tracked object's box, max(w, h), in pixels
    objects: int = 0  # how many objects SAM tracked at all; the one seen on most frames is kept

    @property
    def motion_range(self) -> float:
        """Peak-to-peak of the projected motion, in pixels; 0 when nothing was tracked."""
        if self.tracked.sum() < 2:
            return 0.0
        p = project(self)
        p = p[~np.isnan(p)]
        return float(p.max() - p.min())

    @property
    def tracked(self) -> np.ndarray:
        return ~np.isnan(self.centroids[:, 0])

    @property
    def share(self) -> float:
        return float(self.tracked.mean()) if len(self.times) else 0.0


@dataclass
class Series:
    """A one-dimensional motion series, the shared format of tests/fixtures/reps/*.json."""

    t: np.ndarray
    y: np.ndarray  # NaN where untracked
    expected_reps: int | None = None
    name: str = ""
    notes: str = ""
    extra: dict[str, Any] = field(default_factory=dict)


# ---------------------------------------------------------------------------
# Equipment
# ---------------------------------------------------------------------------

_EQUIPMENT_HINTS: tuple[tuple[str, tuple[str, ...]], ...] = (
    ("dumbbell", ("dumbbell", "db ", "db-", "dbs", "kettlebell", "kb ")),
    ("cable", ("cable", "pushdown", "pulldown", "lat pull", "face pull", "rope", "pressdown")),
    ("machine", ("machine", "smith", "leg press", "hack squat", "pec deck", "leg curl", "leg extension",
                 "hip thrust machine", "chest press machine", "row machine", "seated row", "calf raise")),
    ("bodyweight", ("pull-up", "pull up", "pullup", "chin-up", "chin up", "chinup", "push-up", "push up",
                    "pushup", "dip", "plank", "bodyweight", "hanging", "nordic", "back extension", "crunch")),
)  # fmt: skip


def infer_equipment(name: str) -> str:
    """A deterministic fallback for exercises imported before `equipment` existed, or when the
    model left it null. Barbell when nothing in the name says otherwise."""
    lowered = f" {name.lower()} "
    for equipment, hints in _EQUIPMENT_HINTS:
        if any(h in lowered for h in hints):
            return equipment
    return "barbell"


# ---------------------------------------------------------------------------
# Step 1-2: SAM's video output -> centroid track
# ---------------------------------------------------------------------------

# SAM's raw video text: "<12f>" starts frame 12, then comma-separated "<id><|box;x1=..;y1=..;x2=..;
# y2=..;w=..;h=..|><|mask;...|>" records. Only the boxes are read: a box centre is the centroid we
# need, and skipping the masks makes parsing a 20 s set take milliseconds instead of minutes.
# A record follows the frame marker's ">" or the previous record's ",".
_RAW_TOKEN = re.compile(
    r"<(\d+)f>|(?:^|(?<=[,>]))(\d+)<\|box;x1=(\d+);y1=(\d+);x2=(\d+);y2=(\d+);w=\d+;h=\d+\|>"
)

Boxes = dict[str, dict[int, tuple[float, float, float, float]]]  # object id -> frame -> x1, y1, x2, y2


def parse_boxes(raw: str) -> Boxes:
    boxes: Boxes = {}
    frame = -1
    for m in _RAW_TOKEN.finditer(raw):
        if m.group(1) is not None:
            frame = int(m.group(1))
            continue
        if frame < 0:
            continue
        boxes.setdefault(m.group(2), {})[frame] = (
            float(m.group(3)),
            float(m.group(4)),
            float(m.group(5)),
            float(m.group(6)),
        )  # the last record of a frame wins
    return boxes


def boxes_from_records(result: Any) -> Boxes:
    """The same shape from a parsed VideoSegmentationResult (tests, the offline inspector)."""
    boxes: Boxes = {}
    for rec in result.records:
        if getattr(rec, "kind", None) != "mask" or rec.frame is None:
            continue
        b = rec.bounds
        boxes.setdefault(rec.object_id, {})[rec.frame.frame_index] = (b.left, b.top, b.right, b.bottom)
    return boxes


# An object whose centroid jumps more than this many times its own size between two frames is a
# track that hopped to another plate, not a plate that moved.
MAX_STEP_SIZES = 2.0


def _object_track(frames: dict[int, tuple[float, float, float, float]], n: int) -> tuple[np.ndarray, float]:
    """Box centres on every frame (NaN where unseen) and the object's median box size."""
    centroids = np.full((n, 2), np.nan)
    sizes = []
    for index, (x1, y1, x2, y2) in frames.items():
        if 0 <= index < n:
            centroids[index] = ((x1 + x2) / 2, (y1 + y2) / 2)
            sizes.append(max(x2 - x1, y2 - y1))
    return centroids, float(np.median(sizes)) if sizes else 0.0


def _max_step(centroids: np.ndarray) -> float:
    ok = ~np.isnan(centroids[:, 0])
    pts = centroids[ok]
    if len(pts) < 2:
        return 0.0
    return float(np.max(np.linalg.norm(np.diff(pts, axis=0), axis=1)))


def track_from_boxes(boxes: Boxes, frame_times: list[float]) -> Track:
    """The plate or dumbbell that moves. A gym has many in frame, so among the objects tracked on
    at least MIN_MOVING_TRACK_SHARE of the frames, keep the one whose centroid travels furthest
    along its main axis, after dropping tracks that hop between objects (a step over MAX_STEP_SIZES
    sizes). One that never moves past the jitter floor is only kept when nothing moves, and then
    only if it was tracked on MIN_TRACK_SHARE of the frames. Falls back to the object seen on the
    most frames when nothing qualifies."""
    times = np.asarray(frame_times, dtype=float)
    n = len(frame_times)
    if not boxes:
        return Track(times, np.full((n, 2), np.nan))
    best: tuple[bool, float, np.ndarray, float] | None = None
    for frames in boxes.values():
        if len(frames) < MIN_MOVING_TRACK_SHARE * n:
            continue
        centroids, size = _object_track(frames, n)
        if size > 0 and _max_step(centroids) > MAX_STEP_SIZES * size:
            continue
        motion = Track(times, centroids, size).motion_range
        moves = motion >= MIN_AMPLITUDE_OBJECT_FRACTION * size
        if not moves and len(frames) < MIN_TRACK_SHARE * n:
            continue
        if best is None or (moves, motion) > (best[0], best[1]):
            best = (moves, motion, centroids, size)
    if best is None:
        centroids, size = _object_track(max(boxes.values(), key=len), n)
        return Track(times, centroids, size, len(boxes))
    return Track(times, best[2], best[3], len(boxes))


def track_from_raw(raw: str, frame_times: list[float]) -> Track:
    return track_from_boxes(parse_boxes(raw), frame_times)


def centroid_track(result: Any, frame_times: list[float]) -> Track:
    return track_from_boxes(boxes_from_records(result), frame_times)


# ---------------------------------------------------------------------------
# Step 3: 2-D track -> 1-D series
# ---------------------------------------------------------------------------


def project(track: Track) -> np.ndarray:
    """Project the centroids onto their first principal component. NaN stays NaN."""
    ok = track.tracked
    if ok.sum() < 2:
        return np.full(len(track.times), np.nan)
    pts = track.centroids[ok]
    mean = pts.mean(axis=0)
    _, _, vt = np.linalg.svd(pts - mean, full_matrices=False)
    axis = vt[0]
    # Point the axis so "up on screen" (smaller y) is positive; a cosmetic choice that keeps
    # rep_times and the debug plots readable. The count is sign-agnostic.
    if axis[1] > 0:
        axis = -axis
    out = np.full(len(track.times), np.nan)
    out[ok] = (pts - mean) @ axis
    return out


# ---------------------------------------------------------------------------
# Steps 3-5 on a 1-D series (mirrored by RepCounter.swift)
# ---------------------------------------------------------------------------


def fill_gaps(t: np.ndarray, y: np.ndarray, max_gap: float = GAP_FILL_SECONDS) -> np.ndarray:
    """Linear interpolation across untracked runs that last at most `max_gap` seconds. Longer
    runs, and untracked edges, are filled with the nearest tracked value, so a dropout never
    becomes a peak."""
    y = y.astype(float).copy()
    ok = ~np.isnan(y)
    if ok.sum() == 0:
        return y
    idx = np.flatnonzero(ok)
    # Edges: hold the first / last tracked value.
    y[: idx[0]] = y[idx[0]]
    y[idx[-1] + 1 :] = y[idx[-1]]
    for a, b in itertools.pairwise(idx):
        if b - a <= 1:
            continue
        gap = t[b] - t[a]
        if gap <= max_gap:
            frac = (t[a + 1 : b] - t[a]) / gap
            y[a + 1 : b] = y[a] + frac * (y[b] - y[a])
        else:
            y[a + 1 : b] = y[a]
    return y


SMOOTH_KERNEL = savgol_coeffs(SMOOTH_WINDOW, SMOOTH_ORDER)  # [-3, 12, 17, 12, -3] / 35


def smooth(y: np.ndarray, window: int = SMOOTH_WINDOW) -> np.ndarray:
    """Savitzky-Golay (window 5, order 2) on the interior; the two samples at each edge are kept
    as they are. RepCounter.swift applies the same fixed kernel the same way."""
    out = y.astype(float).copy()
    if len(y) < window:
        return out
    half = window // 2
    out[half:-half] = np.convolve(y, SMOOTH_KERNEL, mode="valid")
    return out


def rest_position(t: np.ndarray, y: np.ndarray, window: float = REST_WINDOW_SECONDS) -> float:
    head = y[t <= t[0] + window]
    tail = y[t >= t[-1] - window]
    return float(np.median(np.concatenate([head, tail])))


def count_series(t: np.ndarray, y: np.ndarray, min_amplitude: float = 0.0) -> tuple[list[int], np.ndarray]:
    """Steps 3-5 on one series. Returns the peak indices and d(t). `min_amplitude` is the floor
    under which the whole series is jitter: a 95th percentile of d below it means zero reps."""
    t = np.asarray(t, dtype=float)
    y = np.asarray(y, dtype=float)
    if len(t) < 3 or np.isnan(y).all():
        return [], np.zeros(len(t))
    filled = fill_gaps(t, y)
    smoothed = smooth(filled)
    rest = rest_position(t, smoothed)
    d = np.abs(smoothed - rest)
    scale = float(np.percentile(d, 95))
    if scale <= 0 or scale < min_amplitude:
        return [], d
    dt = float(np.median(np.diff(t))) if len(t) > 1 else 1.0
    distance = max(1, round(MIN_REP_INTERVAL_SECONDS / dt)) if dt > 0 else 1
    peaks, _ = find_peaks(d, distance=distance, prominence=PROMINENCE_FRACTION * scale)
    # `distance` is in samples; with a variable frame rate, enforce the 0.8 s in real time too.
    kept: list[int] = []
    for p in sorted(peaks, key=lambda i: -d[i]):
        if all(abs(t[p] - t[k]) >= MIN_REP_INTERVAL_SECONDS for k in kept):
            kept.append(int(p))
    return sorted(kept), d


def rep_speeds(t: np.ndarray, d: np.ndarray, peaks: list[int]) -> list[float]:
    """Step 8. For each rep, the mean |d'(t)| over its lifting phase: from the moment the bar leaves
    the deepest point (the last sample still within 90% of the peak, so a pause at the chest is
    not counted as lifting) until d falls to 20% of that peak. When the bar never gets that close
    to rest before the next rep (touch-and-go), the phase ends at the lowest point between the
    two peaks. Unrounded; the caller rounds for output."""
    t = np.asarray(t, dtype=float)
    d = np.asarray(d, dtype=float)
    speeds: list[float] = []
    for k, p in enumerate(peaks):
        peak = float(d[p])
        stop = peaks[k + 1] if k + 1 < len(peaks) else len(d) - 1
        if peak <= 0 or stop <= p:
            speeds.append(0.0)
            continue
        segment = d[p : stop + 1]
        below = np.flatnonzero(segment <= LIFT_PHASE_END_FRACTION * peak)
        end = int(below[0]) if len(below) else int(np.argmin(segment))
        high = np.flatnonzero(segment[:end] >= LIFT_PHASE_START_FRACTION * peak)
        start = int(high[-1]) if len(high) else 0
        duration = float(t[p + end] - t[p + start])
        if end <= start or duration <= 0:
            speeds.append(0.0)
            continue
        travelled = float(np.abs(np.diff(segment[start : end + 1])).sum())
        speeds.append(travelled / duration)
    return speeds


def velocity_loss(speeds: list[float], set_role: str | None = None) -> float | None:
    """Step 9. None under three reps, on a rest-pause set, or when the first reps did not move."""
    if set_role == "restPause" or len(speeds) < MIN_REPS_FOR_VELOCITY:
        return None
    fastest = max(speeds[:2])
    if fastest <= 0:
        return None
    loss = 100.0 * (1.0 - (speeds[-2] + speeds[-1]) / 2.0 / fastest)
    return round(max(0.0, loss), 1)


def confidence_of(track_share: float, rep_times: list[float]) -> float:
    """Step 6. No reps: 0. One rep has no intervals; its spread is unknown, so it scores halfway."""
    if not rep_times:
        return 0.0
    if len(rep_times) < 2:
        cv = 0.5
    else:
        intervals = np.diff(np.asarray(rep_times))
        mean = float(intervals.mean())
        cv = float(intervals.std() / mean) if mean > 0 else 1.0
    return float(np.clip(track_share * (1 - min(1.0, cv)), 0.0, 1.0))


def _result(
    t: np.ndarray,
    peaks: list[int],
    d: np.ndarray,
    share: float,
    frames: int,
    tracked: int,
    set_role: str | None,
) -> RepResult:
    rep_times = [round(float(t[p] - t[0]), 3) for p in peaks]
    speeds = rep_speeds(t, d, peaks)
    return RepResult(
        len(peaks), rep_times, round(confidence_of(share, rep_times), 3), True, frames, tracked,
        [round(v, 3) for v in speeds], velocity_loss(speeds, set_role),
    )  # fmt: skip


def count(track: Track, set_role: str | None = None) -> RepResult:
    """The full pipeline on a SAM centroid track."""
    frames = len(track.times)
    tracked = int(track.tracked.sum())
    share = track.share
    if frames == 0 or share < MIN_MOVING_TRACK_SHARE:
        return RepResult(None, [], 0.0, False, frames, tracked)
    peaks, d = count_series(track.times, project(track), MIN_AMPLITUDE_OBJECT_FRACTION * track.object_size)
    return _result(track.times, peaks, d, share, frames, tracked, set_role)


def count_1d(
    series: Series, min_amplitude: float = MIN_AMPLITUDE_NORMALIZED, set_role: str | None = None
) -> RepResult:
    """The pipeline on an already one-dimensional, normalized series (the shared fixtures, the
    phone's joint)."""
    frames = len(series.t)
    tracked = int((~np.isnan(series.y)).sum())
    share = tracked / frames if frames else 0.0
    if frames == 0 or share < MIN_TRACK_SHARE:
        return RepResult(None, [], 0.0, False, frames, tracked)
    peaks, d = count_series(series.t, series.y, min_amplitude)
    return _result(np.asarray(series.t, dtype=float), peaks, d, share, frames, tracked, set_role)


# ---------------------------------------------------------------------------
# Fixture format (shared with the iOS tests)
# ---------------------------------------------------------------------------


def series_to_json(series: Series) -> dict[str, Any]:
    return {
        "name": series.name,
        "notes": series.notes,
        "t": [round(float(v), 4) for v in series.t],
        "y": [None if np.isnan(v) else round(float(v), 5) for v in series.y],
        "expectedReps": series.expected_reps,
        **series.extra,
    }


def series_from_json(data: dict[str, Any]) -> Series:
    y = np.asarray([np.nan if v is None else float(v) for v in data["y"]], dtype=float)
    extra = {k: v for k, v in data.items() if k not in {"name", "notes", "t", "y", "expectedReps"}}
    return Series(
        t=np.asarray(data["t"], dtype=float),
        y=y,
        expected_reps=data.get("expectedReps"),
        name=data.get("name", ""),
        notes=data.get("notes", ""),
        extra=extra,
    )
