"""What Setecho measurably changed, from real data only (HANDOFF.md §9, P5 and P9).

  uv run python -m scripts.evidence                     # Liftoff + every export in private/sessions/
  uv run python -m scripts.evidence --out private/evidence.md

Reads the Liftoff export (`private/history/liftoff_workout_data.csv`) and every Setecho session
export (Settings → Developer → Session data → Share, saved to `private/sessions/`). Prints a
markdown report of aggregates only — minutes, set counts, agreement rates, latencies — never a
load, a note or a transcript, so its tables can go into the public README as they are.

1. **Time back.** Each Setecho session against the same program day before Setecho. The cycle
   follows the weekday (Day 1 is Monday, HANDOFF.md §7, Today), so the baseline is the Liftoff
   sessions on the same weekday in the weeks before, full sessions only (6+ exercises). Minutes
   per working set is the fair comparison when the set counts differ.
2. **Rep counts.** On camera sets, SAM's count against the number he said or corrected to. A set
   SAM counted and he never touched is reported apart: accepted, not verified.
3. **Effort.** Where a set has both SAM's slowdown and a spoken RPE, the estimated reps in
   reserve against 10 − RPE (P5's bar: within one rep most of the time).
4. **Speed.** Seconds from a set's end to SAM's count, and the voice turn's latency.

Stdlib only, so it runs anywhere the export lands.
"""

from __future__ import annotations

import argparse
import csv
import json
import re
import statistics
from dataclasses import dataclass, field
from datetime import UTC, datetime, timedelta
from itertools import pairwise
from pathlib import Path
from zoneinfo import ZoneInfo

ROOT = Path(__file__).resolve().parents[1]
LIFTOFF = ROOT / "private" / "history" / "liftoff_workout_data.csv"
SESSIONS = ROOT / "private" / "sessions"
# His first gym session with Setecho. From that day Liftoff ran beside it as a check, so later
# Liftoff logs are not "before".
FIRST_SETECHO_DAY = "2026-10-28"
WEEKDAYS = ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"]


# ---------- Liftoff ----------


@dataclass
class Workout:
    started: datetime  # local time
    minutes: float
    sets: int
    exercises: int
    source: str = "Liftoff"


def _duration_minutes(text: str) -> float:
    def part(unit: str) -> int:
        m = re.search(rf"(\d+)\s*{unit}", text)
        return int(m.group(1)) if m else 0

    return part("hour") * 60 + part("minute") + part("second") / 60


def read_liftoff(path: Path, tz: ZoneInfo) -> list[Workout]:
    """One Workout per Liftoff session (rows share the session's start time and duration)."""
    by_start: dict[str, dict] = {}
    with path.open(newline="") as f:
        for row in csv.DictReader(f):
            s = by_start.setdefault(row["Date"], {"duration": row["Duration"], "sets": 0, "ex": set()})
            s["sets"] += 1
            s["ex"].add(row["Exercise Name"].strip().lower())
    out = []
    for start, s in by_start.items():
        started = datetime.strptime(start, "%Y-%m-%d %H:%M:%S").replace(tzinfo=tz)
        out.append(Workout(started, _duration_minutes(s["duration"]), s["sets"], len(s["ex"])))
    return sorted(out, key=lambda w: w.started)


def is_full(w: Workout) -> bool:
    """A training day, not an abs-only add-on or a timer left running for hours."""
    return w.exercises >= 6 and 20 <= w.minutes <= 180


# ---------- Setecho exports ----------


def parse_date(value: str | None, tz: ZoneInfo) -> datetime | None:
    if not value:
        return None
    text = value.strip().replace("Z", "+00:00")
    try:
        dt = datetime.fromisoformat(text)
    except ValueError:
        return None
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=UTC)
    return dt.astimezone(tz)


@dataclass
class SetechoSet:
    role: str | None
    reps: int
    rpe: float | None
    source: str
    measured: int | None
    phone: int | None
    velocity_loss: float | None
    est_rir: float | None
    corrected: bool
    seconds: int | None
    started: datetime | None = None
    ended: datetime | None = None
    exercise: str | None = None
    confidence: float | None = None


@dataclass
class SetechoSession:
    started: datetime
    ended: datetime
    program_day: str | None
    sets: list[SetechoSet]
    count_latencies: list[float] = field(default_factory=list)
    voice_latencies: list[float] = field(default_factory=list)
    utterances: int = 0
    understood: int = 0

    @property
    def minutes(self) -> float:
        return (self.ended - self.started).total_seconds() / 60

    @property
    def working_sets(self) -> list[SetechoSet]:
        return [s for s in self.sets if s.role != "warmup"]


def read_session(path: Path, tz: ZoneInfo) -> SetechoSession | None:
    data = json.loads(path.read_text())
    session = data.get("session") or {}
    started = parse_date(session.get("startedAt"), tz)
    raw_sets = session.get("sets") or []
    if started is None or not raw_sets:
        return None
    sets = []
    last_end = started
    for s in raw_sets:
        rc = s.get("repCount") or {}
        end = parse_date(s.get("endedAt"), tz)
        if end and end > last_end:
            last_end = end
        sets.append(
            SetechoSet(
                role=s.get("role"),
                reps=int(s.get("reps") or 0),
                rpe=s.get("rpe"),
                source=rc.get("source", "plan"),
                measured=rc.get("measured"),
                phone=rc.get("phone"),
                velocity_loss=rc.get("velocityLossPct"),
                est_rir=rc.get("estimatedRIR"),
                corrected=any(
                    (e.get("field") or "").startswith("rep") and (e.get("transcript") or "") != "measured"
                    for e in s.get("edits") or []
                ),
                started=parse_date(s.get("startedAt"), tz),
                ended=end,
                exercise=s.get("exerciseId"),
                seconds=s.get("seconds"),
                confidence=rc.get("confidence"),
            )
        )
    ended = parse_date(session.get("endedAt"), tz) or last_end
    out = SetechoSession(started, ended, session.get("programDayId"), sets)
    for c in data.get("counts") or []:
        if c.get("response") is not None and c.get("secondsAfterSetEnd") is not None:
            out.count_latencies.append(float(c["secondsAfterSetEnd"]))
    for u in data.get("utterances") or []:
        if (u.get("kind") or "utterance") != "utterance":
            continue
        if not (u.get("transcript") or "").strip():
            continue  # silence, noise and too-short clips are not things he said
        out.utterances += 1
        if u.get("intent") and u.get("intent") not in ("none", "unclear") and not u.get("error"):
            out.understood += 1
        if u.get("toIntent") is not None:
            out.voice_latencies.append(float(u["toIntent"]))
    return out


def read_sessions(directory: Path, tz: ZoneInfo) -> list[SetechoSession]:
    out = []
    for path in sorted(directory.glob("*.json")):
        try:
            s = read_session(path, tz)
        except (json.JSONDecodeError, KeyError, TypeError, ValueError):
            continue
        if s is not None and s.program_day and len(s.working_sets) >= 3:
            out.append(s)
    return sorted(out, key=lambda s: s.started)


# ---------- the comparisons ----------


def before_setecho(workouts: list[Workout], first_day: str = FIRST_SETECHO_DAY) -> list[Workout]:
    """Full Liftoff sessions from before Setecho's first gym session."""
    cutoff = datetime.strptime(first_day, "%Y-%m-%d").date()
    return [w for w in workouts if is_full(w) and w.started.date() < cutoff]


def baseline_for(session: SetechoSession, workouts: list[Workout], weeks: int = 4) -> list[Workout]:
    """The same weekday's full Liftoff sessions from before Setecho, in the `weeks` before this one."""
    day = session.started.date()
    since = day - timedelta(weeks=weeks)
    return [
        w
        for w in before_setecho(workouts)
        if w.started.weekday() == session.started.weekday() and since <= w.started.date() < day
    ]


@dataclass
class CountAgreement:
    verified: int = 0
    exact: int = 0
    within_one: int = 0
    accepted_unverified: int = 0
    disagreed_unverified: int = 0
    phone_verified: int = 0
    phone_exact: int = 0


def count_agreement(sessions: list[SetechoSession]) -> CountAgreement:
    """His number is the truth when he said it or corrected to it; SAM's count is checked against it."""
    a = CountAgreement()
    for session in sessions:
        for s in session.working_sets:
            if s.seconds:  # holds and timed sets have no rep count
                continue
            truth_known = s.source == "spoken" or s.corrected
            if s.measured is not None:
                if truth_known:
                    a.verified += 1
                    a.exact += s.measured == s.reps
                    a.within_one += abs(s.measured - s.reps) <= 1
                elif s.source == "measured":
                    a.accepted_unverified += 1
                elif s.phone is not None and s.measured != s.phone:
                    a.disagreed_unverified += 1
            if s.phone is not None and truth_known:
                a.phone_verified += 1
                a.phone_exact += s.phone == s.reps
    return a


ROLE_NAMES = {"top": "top", "backOff": "back-off", "restPause": "rest-pause"}


def lift_name(exercise_id: str | None) -> str:
    """`w1_day_6_chest_supported_machine_rows` → "Chest supported machine rows"."""
    name = re.sub(r"^w\d+_day_\d+_", "", exercise_id or "").replace("_", " ").strip()
    name = " ".join("DB" if w == "db" else w for w in name.split())
    return name[:1].upper() + name[1:] if name else "—"


def camera_sets(sessions: list[SetechoSession]) -> list[dict]:
    """Every working set SAM counted, with what was logged and how SAM's count fared against it.
    Lift names and rep counts only: no load, note or transcript."""
    rows = []
    for session in sessions:
        for s in session.working_sets:
            if s.measured is None or s.seconds:
                continue
            conf = f" ({s.confidence:.2f})" if s.confidence is not None else ""
            if s.source == "spoken" or s.corrected:
                result = "matched his count" if s.measured == s.reps else f"missed: he said {s.reps}"
            elif s.source == "measured":
                result = "accepted, not verified"
            elif s.source == "phone" and s.phone is not None and s.measured != s.phone:
                result = "under the confidence bar: the phone's count stood, not verified"
            else:
                result = "—"
            rows.append(
                {
                    "date": f"{s.started or session.started:%a %b %-d}",
                    "lift": lift_name(s.exercise),
                    "role": ROLE_NAMES.get(s.role or "", "working"),
                    "sam": f"{s.measured}{conf}",
                    "phone": "—" if s.phone is None else str(s.phone),
                    "logged": str(s.reps),
                    "result": result,
                }
            )
    return rows


def effort_pairs(sessions: list[SetechoSession]) -> list[tuple[float, float]]:
    """(estimated reps in reserve, 10 − his RPE) wherever both exist."""
    return [
        (s.est_rir, 10 - s.rpe)
        for session in sessions
        for s in session.working_sets
        if s.est_rir is not None and s.rpe is not None
    ]


def pacing(session: SetechoSession, away_factor: float = 2.5) -> dict:
    """Gaps between consecutive sets: rest (same exercise), transition (new exercise) and away
    (longer than `away_factor` × the session's median rest, or over 5 min)."""
    timed = [s for s in session.sets if s.started and s.ended]
    rest, trans, away = [], [], []
    for a, b in pairwise(timed):
        gap = (b.started - a.ended).total_seconds()
        (rest if a.exercise == b.exercise else trans).append(gap)
    if rest:
        med = statistics.median(rest)
        limit = max(away_factor * med, 300)
        away = [g for g in rest + trans if g > limit]
    work = sum((s.ended - s.started).total_seconds() for s in timed)
    total = (session.ended - session.started).total_seconds()
    return {
        "rest": rest,
        "transitions": trans,
        "away": away,
        "work_pct": 100 * work / total if total else 0,
        "away_minutes": sum(away) / 60,
    }


def _pct(n: int, d: int) -> str:
    return f"{round(100 * n / d)}%" if d else "—"


def _med(xs: list[float]) -> str:
    return f"{statistics.median(xs):.0f}" if xs else "—"


def report(workouts: list[Workout], sessions: list[SetechoSession]) -> str:
    lines = ["# Setecho evidence", ""]
    full = before_setecho(workouts)
    if full:
        mins = [w.minutes for w in full]
        per_set = [w.minutes / w.sets for w in full]
        lines += [
            "## Before Setecho (Liftoff, logged by hand)",
            "",
            (
                f"{len(full)} full training sessions, {full[0].started:%b %-d} to {full[-1].started:%b %-d}: "
                f"median {_med(mins)} min ({min(mins):.0f}–{max(mins):.0f}), "
                f"{statistics.median(per_set):.1f} min per set."
            ),
            "",
            "| Day | Sessions | Median minutes | Range | Minutes per set |",
            "|---|---|---|---|---|",
        ]
        for wd in range(7):
            day = [w for w in full if w.started.weekday() == wd]
            if not day:
                continue
            m = [w.minutes for w in day]
            ps = [w.minutes / w.sets for w in day]
            spread = f"{min(m):.0f}–{max(m):.0f}"
            per_set = statistics.median(ps)
            lines.append(f"| {WEEKDAYS[wd]} | {len(day)} | {_med(m)} | {spread} | {per_set:.1f} |")
        lines.append("")

    lines += ["## With Setecho", ""]
    if not sessions:
        lines += [
            (
                "No session exports yet. On the phone: Settings → Developer → Session data → Share, "
                "saved to `backend/private/sessions/`."
            ),
            "",
        ]
        return "\n".join(lines)

    lines += [
        (
            "| Date | Working sets | Minutes | Minutes per set | Same day before (Liftoff, 4 wks) "
            "| Per set before | Change |"
        ),
        "|---|---|---|---|---|---|---|",
    ]
    for s in sessions:
        base = baseline_for(s, workouts)
        n = len(s.working_sets)
        per = s.minutes / n
        if base:
            bm = [w.minutes for w in base]
            bp = statistics.median([w.minutes / w.sets for w in base])
            change = f"{round(100 * (per - bp) / bp):+d}% per set"
            before = f"{_med(bm)} min ({min(bm):.0f}–{max(bm):.0f}, n={len(base)})"
            before_per = f"{bp:.1f}"
        else:
            before, before_per, change = "—", "—", "—"
        lines.append(
            f"| {s.started:%a %b %-d} | {n} | {s.minutes:.0f} | {per:.1f} | {before} "
            f"| {before_per} | {change} |"
        )
    lines.append("")

    a = count_agreement(sessions)
    lines += [
        "## Rep counts on camera sets",
        "",
        (
            f"- SAM 3.1 against the count he said or corrected to: {a.exact} of {a.verified} exact "
            f"({_pct(a.exact, a.verified)}), {_pct(a.within_one, a.verified)} within one rep."
        ),
        (
            f"- The phone's pose count on the same sets: {a.phone_exact} of {a.phone_verified} exact "
            f"({_pct(a.phone_exact, a.phone_verified)})."
        ),
        (
            f"- SAM counts he accepted without saying a number: {a.accepted_unverified} "
            "(not verified, not counted above)."
        ),
        (
            f"- Sets where SAM and the phone disagreed and he said nothing: {a.disagreed_unverified} "
            "(the phone's count stands, unverified)."
        ),
        "",
    ]
    rows = camera_sets(sessions)
    if rows:
        lines += [
            "Every camera set, misses included (SAM's confidence in brackets; under 0.6 is not used):",
            "",
            "| Date | Lift | Set | SAM 3.1 | Phone | Logged | Result |",
            "|---|---|---|---|---|---|---|",
        ]
        lines += [
            f"| {r['date']} | {r['lift']} | {r['role']} | {r['sam']} | {r['phone']} | {r['logged']} | {r['result']} |"
            for r in rows
        ]
        lines.append("")

    pairs = effort_pairs(sessions)
    if pairs:
        within = sum(abs(est - said) <= 1 for est, said in pairs)
        lines += [
            "## Effort",
            "",
            (
                f"- Estimated reps in reserve from the slowdown against his spoken RPE: {within} of {len(pairs)} "
                f"within one rep ({_pct(within, len(pairs))})."
            ),
            "",
        ]

    lines += [
        "## Pacing",
        "",
        "| Date | Rest between sets (median) | Between exercises (median) | Away (gaps over 2.5× rest) | Under load |",
        "|---|---|---|---|---|",
    ]
    for s in sessions:
        pc = pacing(s)
        away = (
            f"{len(pc['away'])} gaps, {pc['away_minutes']:.0f} min" if pc["away"] else "none"
        )
        lines.append(
            f"| {s.started:%a %b %-d} | {_med(pc['rest'])} s | {_med(pc['transitions'])} s | {away} "
            f"| {pc['work_pct']:.0f}% |"
        )
    lines.append("")

    counts = [x for s in sessions for x in s.count_latencies]
    voice = [x for s in sessions for x in s.voice_latencies]
    heard = sum(s.utterances for s in sessions)
    understood = sum(s.understood for s in sessions)
    lines += ["## Speed and hearing", ""]
    if counts:
        lines.append(
            f"- Set end to SAM's count: median {_med(counts)} s, slowest {max(counts):.0f} s, "
            f"over {len(counts)} sets."
        )
    if voice:
        lines.append(f"- End of speech to understood: median {statistics.median(voice):.1f} s.")
    if heard:
        lines.append(
            f"- Utterances with words that became an action: {understood} of {heard} ({_pct(understood, heard)}); "
            "the rest were questions, chat or bystanders."
        )
    lines.append("")
    return "\n".join(lines)


def main() -> None:
    p = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    p.add_argument("--liftoff", type=Path, default=LIFTOFF)
    p.add_argument("--sessions", type=Path, default=SESSIONS)
    p.add_argument("--tz", default="America/Chicago")
    p.add_argument("--out", type=Path, help="also write the report here (keep it under private/)")
    args = p.parse_args()
    tz = ZoneInfo(args.tz)
    workouts = read_liftoff(args.liftoff, tz) if args.liftoff.exists() else []
    sessions = read_sessions(args.sessions, tz) if args.sessions.exists() else []
    text = report(workouts, sessions)
    print(text)
    if args.out:
        args.out.write_text(text)


if __name__ == "__main__":
    main()
