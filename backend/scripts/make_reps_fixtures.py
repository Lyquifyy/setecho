"""Write the synthetic motion series that `reps.py` and `RepCounter.swift` are both tested on.

  uv run python -m scripts.make_reps_fixtures

Offline and free. Each fixture is one set as a one-dimensional series: `t` in seconds, `y` the
position along the direction of motion (null where tracking dropped), and the rep count a
human would give it. The generator is deterministic, so re-running it changes nothing.
"""

from __future__ import annotations

import json
from pathlib import Path

import numpy as np

from app import reps

OUT = Path(__file__).resolve().parents[1] / "tests" / "fixtures" / "reps"


def rep_shape(t: np.ndarray, period: float, amplitude: float) -> np.ndarray:
    """One rep: leave the rest position and come back, as 1 - cos."""
    return -amplitude * (1 - np.cos(2 * np.pi * t / period)) / 2


def build(
    name: str,
    reps_spec: list[tuple[float, float]],
    *,
    fps: float = 15.0,
    lead: float = 1.0,
    tail: float = 1.5,
    pauses: dict[int, float] | None = None,
    noise: float = 0.0,
    gaps: list[tuple[float, float]] | None = None,
    jitter: float = 0.0,
    rest: float = 0.55,
    expected: int | None,
    notes: str,
    extra: dict | None = None,
) -> dict:
    rng = np.random.default_rng(7)
    pauses = pauses or {}
    segments: list[np.ndarray] = [np.full(int(lead * fps), 0.0)]
    for i, (period, amplitude) in enumerate(reps_spec):
        n = int(period * fps)
        local = np.arange(n) / fps
        rep = rep_shape(local, period, amplitude)
        if i in pauses:
            hold = int(pauses[i] * fps)
            top = n // 2
            rep = np.concatenate([rep[:top], np.full(hold, rep[top]), rep[top:]])
        segments.append(rep)
    segments.append(np.full(int(tail * fps), 0.0))
    y = rest + np.concatenate(segments)
    n = len(y)
    t = np.arange(n) / fps
    if jitter:
        t = t + rng.uniform(-jitter, jitter, size=n)
        t[0] = 0.0
        t = np.maximum.accumulate(t)
    if noise:
        y = y + rng.normal(0, noise, size=n)
    for start, end in gaps or []:
        y[(t >= start) & (t < end)] = np.nan
    series = reps.Series(
        t=t, y=y, expected_reps=expected, name=name, notes=notes, extra={"fps": fps, **(extra or {})}
    )
    return reps.series_to_json(series)


def main() -> None:
    fixtures = [
        build("clean_8", [(2.5, 0.15)] * 8, expected=8, notes="Eight even bench reps at 15 fps."),
        build("clean_8_10fps", [(2.5, 0.15)] * 8, fps=10, expected=8, notes="The same set as SAM sees it, 10 fps."),
        build("paused_rep", [(2.5, 0.15)] * 5, pauses={2: 2.0}, expected=5,
              notes="Five reps; the third is held at the bottom for 2 s. Still one rep."),
        build("half_rep", [(2.5, 0.15)] * 6 + [(2.5, 0.04)], expected=6,
              notes="Six full reps then a quarter-depth attempt that is not a rep."),
        build("short_gap", [(2.5, 0.15)] * 8, gaps=[(8.2, 8.6)], expected=8,
              notes="Tracking drops for 0.4 s mid-rep; the gap is bridged."),
        build("noisy_slow", [(4.0, 0.12)] * 10, noise=0.012, expected=10,
              notes="Ten slow reps with pose jitter."),
        build("uneven_tempo", [(2.0, 0.15), (2.4, 0.14), (3.1, 0.16), (2.2, 0.15), (3.6, 0.13), (2.8, 0.15)],
              expected=6, notes="Six reps, each a different speed; the grinder at the end is slowest."),
        build("variable_frame_rate", [(2.5, 0.15)] * 8, jitter=0.012, expected=8,
              notes="Eight reps with the frame times jittered, as iPhone video is."),
        build("single_rep", [(3.0, 0.15)], expected=1, notes="A heavy single."),
        build("slowing_8", [(2.0, 0.15)] * 2 + [(2.4, 0.15)] * 2 + [(2.8, 0.15)] * 2 + [(3.6, 0.15)] * 2,
              expected=8, notes="Eight reps that slow down: the last two take 3.6 s against 2.0 s for the "
              "first two, so the lifting speed drops by 44%.",
              extra={"expectedVelocityLossPct": 44.4}),
        build("mostly_lost", [(2.5, 0.15)] * 6, gaps=[(2.0, 12.0)], expected=None,
              notes="Tracking lost for most of the set: no count, trackFound false."),
        build("no_motion", [], lead=4.0, tail=4.0, noise=0.004, expected=0,
              notes="Nothing moved: zero reps, no false positives from jitter."),
    ]  # fmt: skip
    OUT.mkdir(parents=True, exist_ok=True)
    for f in fixtures:
        (OUT / f"{f['name']}.json").write_text(json.dumps(f, separators=(",", ":")) + "\n")
        counted = reps.count_1d(reps.series_from_json(f))
        print(
            f"{f['name']:>22}: expected {f['expectedReps']}, counted {counted.reps}, conf {counted.confidence}"
        )


if __name__ == "__main__":
    main()
