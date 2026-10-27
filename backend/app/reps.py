"""Rep counting from a SAM 3.1 track (HANDOFF.md §5, `/sets/count`). Pure NumPy and SciPy.

The pipeline, numbered as in the handoff:
1. SAM tracks the equipment ("weight plate", "dumbbell", "weight stack", "person"). Keep the
   object tracked on the most frames; under 80% of frames tracked means no count.
2. One centroid per frame, with the frame's own timestamp from the file (never index / fps).
3. Project onto the main direction of motion (first principal component), bridge gaps up to
   0.5 s, smooth with Savitzky-Golay (window 5, order 2).
4. The rest position is the median of the first and last 0.5 s; d(t) = |projection - rest|.
5. Reps are the peaks of d(t) with prominence of at least 35% of d's 95th percentile, at least
   0.8 s apart. A half rep never reaches the prominence and is not counted.
6. confidence = tracked share x (1 - min(1, CV of the rep intervals)).

Steps 3-5 on a one-dimensional series are `count_series`, which `RepCounter.swift` mirrors on
the phone. Both run on the fixtures in tests/fixtures/reps/ and must agree.
"""

from __future__ import annotations

import itertools
import logging
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

# Tuned constants. Change them here and in RepCounter.swift together.
MIN_TRACK_SHARE = 0.80
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


@dataclass(frozen=True)
class RepResult:
    reps: int | None
    rep_times: list[float]
    confidence: float
    track_found: bool
    frames: int
    tracked_frames: int

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
# Step 1-2: SAM records -> centroid track
# ---------------------------------------------------------------------------


def _mask_centroid(record: Any) -> tuple[float, float]:
    """The centroid of the mask raster in frame pixels; the box centre when the raster is empty."""
    b = record.bounds
    try:
        from meta_sam_parser import InvalidSegmentationMaskError

        from app.photos import mask_raster

        raster = mask_raster(record)
        ys, xs = np.nonzero(raster)
        if len(xs):
            sx = (b.right - b.left) / raster.shape[1] if raster.shape[1] else 1.0
            sy = (b.bottom - b.top) / raster.shape[0] if raster.shape[0] else 1.0
            return float(b.left + (xs.mean() + 0.5) * sx), float(b.top + (ys.mean() + 0.5) * sy)
    except (ValueError, TypeError, AttributeError, InvalidSegmentationMaskError) as e:
        # A malformed raster must not lose the whole set; the box still says where the object is.
        logging.getLogger(__name__).debug("mask raster unreadable, using the box centre: %s", e)
    return float((b.left + b.right) / 2), float((b.top + b.bottom) / 2)


# An object whose centroid jumps more than this many times its own size between two frames is a
# track that hopped to another plate, not a plate that moved.
MAX_STEP_SIZES = 2.0


def _object_track(frames: dict[int, Any], n: int) -> tuple[np.ndarray, float]:
    """Centroids on every frame (NaN where unseen) and the object's median box size."""
    centroids = np.full((n, 2), np.nan)
    sizes = []
    for index, rec in frames.items():
        centroids[index] = _mask_centroid(rec)
        b = rec.bounds
        sizes.append(max(b.right - b.left, b.bottom - b.top))
    return centroids, float(np.median(sizes)) if sizes else 0.0


def _max_step(centroids: np.ndarray) -> float:
    ok = ~np.isnan(centroids[:, 0])
    pts = centroids[ok]
    if len(pts) < 2:
        return 0.0
    return float(np.max(np.linalg.norm(np.diff(pts, axis=0), axis=1)))


def centroid_track(result: Any, frame_times: list[float]) -> Track:
    """The plate that moves. A gym has many plates in frame, so among the objects tracked on at
    least MIN_TRACK_SHARE of the frames, keep the one whose centroid travels furthest along its
    main axis, after dropping tracks that hop between plates (a step over MAX_STEP_SIZES sizes).
    Falls back to the object seen on the most frames when nothing qualifies."""
    per_object: dict[str, dict[int, Any]] = {}
    for rec in result.records:
        if getattr(rec, "kind", None) != "mask" or rec.frame is None:
            continue
        index = rec.frame.frame_index
        if index < 0 or index >= len(frame_times):
            continue
        per_object.setdefault(rec.object_id, {})[index] = rec  # the last revision of a frame wins
    times = np.asarray(frame_times, dtype=float)
    n = len(frame_times)
    if not per_object:
        return Track(times, np.full((n, 2), np.nan))
    best: tuple[float, np.ndarray, float] | None = None
    for frames in per_object.values():
        if len(frames) < MIN_TRACK_SHARE * n:
            continue
        centroids, size = _object_track(frames, n)
        if size > 0 and _max_step(centroids) > MAX_STEP_SIZES * size:
            continue
        motion = Track(times, centroids, size).motion_range
        if best is None or motion > best[0]:
            best = (motion, centroids, size)
    if best is None:
        centroids, size = _object_track(max(per_object.values(), key=len), n)
        return Track(times, centroids, size, len(per_object))
    return Track(times, best[1], best[2], len(per_object))


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


def count(track: Track) -> RepResult:
    """The full pipeline on a centroid track."""
    frames = len(track.times)
    tracked = int(track.tracked.sum())
    share = track.share
    if frames == 0 or share < MIN_TRACK_SHARE:
        return RepResult(None, [], 0.0, False, frames, tracked)
    peaks, _ = count_series(track.times, project(track), MIN_AMPLITUDE_OBJECT_FRACTION * track.object_size)
    rep_times = [round(float(track.times[p] - track.times[0]), 3) for p in peaks]
    return RepResult(len(peaks), rep_times, round(confidence_of(share, rep_times), 3), True, frames, tracked)


def count_1d(series: Series, min_amplitude: float = MIN_AMPLITUDE_NORMALIZED) -> RepResult:
    """The pipeline on an already one-dimensional, normalized series (the shared fixtures, the
    phone's joint)."""
    frames = len(series.t)
    tracked = int((~np.isnan(series.y)).sum())
    share = tracked / frames if frames else 0.0
    if frames == 0 or share < MIN_TRACK_SHARE:
        return RepResult(None, [], 0.0, False, frames, tracked)
    peaks, _ = count_series(series.t, series.y, min_amplitude)
    rep_times = [round(float(series.t[p] - series.t[0]), 3) for p in peaks]
    return RepResult(len(peaks), rep_times, round(confidence_of(share, rep_times), 3), True, frames, tracked)


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
