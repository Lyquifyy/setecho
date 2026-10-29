"""Bring your history: the sets he logged before Setecho, from Liftoff's CSV export and Garmin's FIT
files, so Today's "Last time" line is his real last time from the first session. No model reads a set.

- `POST /import/history`: multipart `files` (Liftoff's `.csv`, Garmin's `<activityId>.zip` or `.fit`),
  `liftoffUnit` ("lb" default, or "kg"), `timeZone` (IANA; Liftoff's times are local and carry none).
  Returns every session with its exercises and sets, each set's role, and what was left out.
- `POST /import/history/match`: `{names, exercises}` -> `{matches}`. Muse Spark sees the exercise
  names and nothing else, and every match is the athlete's to confirm on the phone.

Stateless: nothing is kept. Numbers come from the files, by code (rule 5).
- Liftoff weights keep their decimals; the phone rounds them for display to his load steps.
- Garmin stores weight in kg at 1/16 kg. Converted to lb and rounded to 0.5 lb, which is the number he
  entered on the watch in pounds (the FIT grid is 0.14 lb), so "245" stays 245.
- Neither source marks top sets: in each session the heaviest set of an exercise is its top set
  (the first at that weight), and the lighter sets after it are back-offs.
- Imported sets carry no effort (Liftoff's RPE column is empty, Garmin has none), so none is ever
  "measured". Liftoff's Notes stay with the exercise and never go to Spark.
"""

from __future__ import annotations

import csv
import io
import zipfile
from datetime import UTC, datetime
from typing import Annotated, Literal
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

from fastapi import APIRouter, File, Form, UploadFile
from fastapi.concurrency import run_in_threadpool
from garmin_fit_sdk import Decoder, Profile, Stream

from app import meta, prompts
from app.importing import ImportError_
from app.schemas import StrictModel

router = APIRouter()

KG_TO_LB = 1 / 0.45359237
MAX_FIT_BYTES = 20 * 1024 * 1024  # a strength activity is ~100 KB; anything this big isn't one
LIFTOFF_COLUMNS = ["Date", "Exercise Name", "Set Order", "Weight", "Reps", "Distance", "Seconds", "Notes"]

Source = Literal["liftoff", "garmin"]
Role = Literal["top", "backOff"]


class HistorySet(StrictModel):
    order: int
    loadLb: float
    reps: int | None = None
    seconds: float | None = None
    distance: float | None = None
    role: Role | None = None


class HistoryExercise(StrictModel):
    name: str
    note: str | None = None
    sets: list[HistorySet]


class HistorySession(StrictModel):
    id: str
    source: Source
    startedAt: datetime
    name: str | None = None
    exercises: list[HistoryExercise]


class LeftOut(StrictModel):
    """Sets that aren't kept: nothing recorded (no reps, no time), or a Garmin set with no reps."""

    source: Source
    startedAt: datetime
    exercise: str
    sets: int
    reason: Literal["noReps", "empty"]


class HistoryImport(StrictModel):
    sessions: list[HistorySession]
    leftOut: list[LeftOut]


# ---------------------------------------------------------------------------
# Roles
# ---------------------------------------------------------------------------


def assign_roles(sets: list[HistorySet]) -> None:
    """The first set at the session's heaviest weight is the top set; lighter sets after it are back-offs.
    Sets without reps (holds, cardio) and loads of 0 (bodyweight) get no role."""
    lifting = [s for s in sets if s.reps and s.loadLb > 0]
    if not lifting:
        return
    heaviest = max(s.loadLb for s in lifting)
    top = next(s for s in lifting if s.loadLb == heaviest)
    top.role = "top"
    for s in lifting:
        if s.order > top.order and s.loadLb < heaviest:
            s.role = "backOff"


# ---------------------------------------------------------------------------
# Liftoff
# ---------------------------------------------------------------------------


def _number(value: str | None) -> float:
    try:
        return float((value or "").strip() or 0)
    except ValueError:
        return 0.0


def parse_liftoff(text: str, unit: Literal["lb", "kg"] = "lb", tz: ZoneInfo | None = None) -> HistoryImport:
    """Liftoff's own export: one row per set. A workout is every row sharing a Date."""
    reader = csv.DictReader(io.StringIO(text.lstrip("﻿")))
    missing = [c for c in LIFTOFF_COLUMNS if c not in (reader.fieldnames or [])]
    if missing:
        raise ImportError_(f"not a Liftoff export: no {', '.join(missing)} column")
    zone = tz or UTC
    # date -> exercise name -> rows, in the file's order
    workouts: dict[str, dict[str, list[dict]]] = {}
    for row in reader:
        name = (row.get("Exercise Name") or "").strip()
        when = (row.get("Date") or "").strip()
        if not name or not when:
            continue  # an empty workout: Liftoff writes one row with no exercise
        workouts.setdefault(when, {}).setdefault(name, []).append(row)

    sessions: list[HistorySession] = []
    left_out: list[LeftOut] = []
    for when, exercises in workouts.items():
        try:
            started = datetime.strptime(when, "%Y-%m-%d %H:%M:%S").replace(tzinfo=zone)
        except ValueError as e:
            raise ImportError_(f"Liftoff date not readable: {when}") from e
        kept: list[HistoryExercise] = []
        for name, rows in exercises.items():
            rows.sort(key=lambda r: _number(r.get("Set Order")))
            sets: list[HistorySet] = []
            empty = 0
            for i, row in enumerate(rows):
                weight = _number(row.get("Weight"))
                load = round(weight * KG_TO_LB * 2) / 2 if unit == "kg" else weight
                reps = int(_number(row.get("Reps")))
                seconds = _number(row.get("Seconds"))
                distance = _number(row.get("Distance"))
                if reps > 0:
                    sets.append(HistorySet(order=i, loadLb=load, reps=reps))
                elif seconds > 0 or distance > 0:
                    # Cardio or a hold: history, never a lifting set.
                    sets.append(
                        HistorySet(order=i, loadLb=load, seconds=seconds or None, distance=distance or None)
                    )
                else:
                    empty += 1
            if empty:
                left_out.append(
                    LeftOut(source="liftoff", startedAt=started, exercise=name, sets=empty, reason="empty")
                )
            if not sets:
                continue
            assign_roles(sets)
            note = next((n for r in rows if (n := (r.get("Notes") or "").strip())), None)
            kept.append(HistoryExercise(name=name, note=note, sets=sets))
        if kept:
            sessions.append(
                HistorySession(id=f"liftoff:{when}", source="liftoff", startedAt=started, exercises=kept)
            )
    sessions.sort(key=lambda s: s.startedAt)
    return HistoryImport(sessions=sessions, leftOut=left_out)


# ---------------------------------------------------------------------------
# Garmin
# ---------------------------------------------------------------------------


def garmin_exercise_name(category: object, subtype: object) -> str:
    """Garmin's own name for the exercise: the category's subtype ("smith_machine_bench_press"), else
    the category ("bench_press"), as words: "Smith Machine Bench Press"."""
    raw = None
    if isinstance(category, str) and isinstance(subtype, int):
        raw = Profile["types"].get(f"{category}_exercise_name", {}).get(subtype)
    if raw is None:
        raw = category if isinstance(category, str) and category != "unknown" else "Unknown exercise"
    return " ".join(w.capitalize() for w in str(raw).split("_"))


def group_garmin_sets(named: list[tuple[str, dict]]) -> dict[str, list[dict]]:
    """Sets in time order -> exercises. Supersets interleave (raise, pressdown, raise) and stay one
    exercise each. A name that comes back after another exercise finished in between (leg curls, squats,
    leg curls) is a second exercise: "Weighted Leg Curl (second)", so he can match it on its own."""
    runs: list[tuple[str, list[dict]]] = []
    for name, m in named:
        if runs and runs[-1][0] == name:
            runs[-1][1].append(m)
        else:
            runs.append((name, [m]))
    positions: dict[str, list[int]] = {}
    for i, (name, _) in enumerate(runs):
        positions.setdefault(name, []).append(i)
    groups: dict[str, list[dict]] = {}
    current: dict[str, str] = {}  # garmin name -> the group its latest run went to
    last_run: dict[str, int] = {}
    for i, (name, sets) in enumerate(runs):
        key = current.get(name)
        if key is not None:
            prev = last_run[name]
            between = {n for n, _ in runs[prev + 1 : i]}
            finished = [n for n in between if all(prev < p < i for p in positions[n])]
            if finished:  # an exercise started and finished in between: this is a new one
                count = sum(1 for k in groups if k == name or k.startswith(f"{name} ("))
                key = name if count == 0 else f"{name} ({ORDINALS.get(count + 1, str(count + 1))})"
        else:
            key = name
        groups.setdefault(key, []).extend(sets)
        current[name] = key
        last_run[name] = i
    return groups


ORDINALS = {2: "second", 3: "third", 4: "fourth"}


def _first(value: object) -> object:
    return value[0] if isinstance(value, list) and value else value


def parse_fit(data: bytes, activity_id: str) -> HistoryImport:
    """One strength activity: its active sets, as he corrected them on the watch."""
    stream = Stream.from_byte_array(bytearray(data))
    decoder = Decoder(stream)
    if not decoder.is_fit():
        raise ImportError_(f"{activity_id}: not a FIT file")
    messages, errors = decoder.read()
    if errors and not messages.get("set_mesgs"):
        raise ImportError_(f"{activity_id}: the FIT file could not be read")
    sets_raw = [m for m in messages.get("set_mesgs", []) if m.get("set_type") == "active"]
    if not sets_raw:
        return HistoryImport(sessions=[], leftOut=[])  # a run or a walk: no sets to bring in
    session = (messages.get("session_mesgs") or [{}])[0]
    started = session.get("start_time") or sets_raw[0].get("start_time")
    if not isinstance(started, datetime):
        raise ImportError_(f"{activity_id}: no start time")
    workout = (messages.get("workout_mesgs") or [{}])[0].get("wkt_name")

    ordered = sorted(sets_raw, key=lambda m: m.get("start_time") or started)
    named = [
        (garmin_exercise_name(_first(m.get("category")), _first(m.get("category_subtype"))), m)
        for m in ordered
    ]
    by_name = group_garmin_sets(named)

    exercises: list[HistoryExercise] = []
    left_out: list[LeftOut] = []
    for name, raw in by_name.items():
        sets: list[HistorySet] = []
        no_reps = 0
        for m in raw:
            reps = m.get("repetitions")
            if not isinstance(reps, int) or reps <= 0:
                no_reps += 1
                continue
            kg = m.get("weight")
            load = round(float(kg) * KG_TO_LB * 2) / 2 if isinstance(kg, (int, float)) else 0.0
            sets.append(HistorySet(order=len(sets), loadLb=load, reps=reps))
        if no_reps:
            left_out.append(
                LeftOut(source="garmin", startedAt=started, exercise=name, sets=no_reps, reason="noReps")
            )
        if sets:
            assign_roles(sets)
            exercises.append(HistoryExercise(name=name, sets=sets))
    sessions = (
        [
            HistorySession(
                id=f"garmin:{activity_id}",
                source="garmin",
                startedAt=started,
                name=workout,
                exercises=exercises,
            )
        ]
        if exercises
        else []
    )
    return HistoryImport(sessions=sessions, leftOut=left_out)


def parse_garmin_zip(data: bytes, filename: str) -> HistoryImport:
    """Garmin Connect's export: `<activityId>.zip` holding `<activityId>_ACTIVITY.fit`."""
    try:
        archive = zipfile.ZipFile(io.BytesIO(data))
    except zipfile.BadZipFile as e:
        raise ImportError_(f"{filename}: not a zip file") from e
    out = HistoryImport(sessions=[], leftOut=[])
    with archive:
        for info in archive.infolist():
            if info.is_dir() or not info.filename.lower().endswith(".fit"):
                continue
            if info.file_size > MAX_FIT_BYTES:
                raise ImportError_(f"{filename}: {info.filename} is too large for a strength activity")
            stem = info.filename.rsplit("/", 1)[-1].rsplit(".", 1)[0]
            part = parse_fit(archive.read(info), stem.removesuffix("_ACTIVITY"))
            out.sessions += part.sessions
            out.leftOut += part.leftOut
    return out


# ---------------------------------------------------------------------------
# The upload
# ---------------------------------------------------------------------------


def import_files(
    files: list[tuple[str, bytes]], liftoff_unit: Literal["lb", "kg"] = "lb", time_zone: str | None = None
) -> HistoryImport:
    try:
        tz = ZoneInfo(time_zone) if time_zone else None
    except (ZoneInfoNotFoundError, ValueError):
        tz = None
    out = HistoryImport(sessions=[], leftOut=[])
    for filename, data in files:
        lower = filename.lower()
        if lower.endswith(".csv"):
            part = parse_liftoff(data.decode("utf-8-sig", errors="replace"), liftoff_unit, tz)
        elif lower.endswith(".zip"):
            part = parse_garmin_zip(data, filename)
        elif lower.endswith(".fit"):
            part = parse_fit(data, filename.rsplit("/", 1)[-1].rsplit(".", 1)[0].removesuffix("_ACTIVITY"))
        else:
            raise ImportError_(f"{filename}: expected Liftoff's .csv or a Garmin .zip or .fit")
        out.sessions += part.sessions
        out.leftOut += part.leftOut
    # The same file shared twice is one session.
    seen: dict[str, HistorySession] = {s.id: s for s in out.sessions}
    out.sessions = sorted(seen.values(), key=lambda s: s.startedAt)
    out.leftOut = list({(x.source, x.startedAt, x.exercise, x.reason): x for x in out.leftOut}.values())
    return out


@router.post("/import/history", response_model=HistoryImport)
async def import_history(
    files: Annotated[list[UploadFile], File()],
    liftoffUnit: Annotated[Literal["lb", "kg"], Form()] = "lb",
    timeZone: Annotated[str | None, Form()] = None,
) -> HistoryImport:
    read = [(f.filename or "file", await f.read()) for f in files if f.filename]
    if not read:
        raise ImportError_("nothing to import: share Liftoff's CSV or Garmin's activity zips")
    return await run_in_threadpool(import_files, read, liftoffUnit, timeZone)


# ---------------------------------------------------------------------------
# Matching names to his plan (Muse Spark, names only)
# ---------------------------------------------------------------------------


class PlanExercise(StrictModel):
    id: str
    name: str


class MatchRequest(StrictModel):
    names: list[str]
    exercises: list[PlanExercise]


class Match(StrictModel):
    name: str
    exerciseId: str | None


class MatchResponse(StrictModel):
    matches: list[Match]


NONE = "none"


def match_schema(names: list[str], ids: list[str]) -> dict:
    """Per request, so the model can only answer with his names and his plan's ids (or none)."""
    return {
        "type": "object",
        "additionalProperties": False,
        "required": ["matches"],
        "properties": {
            "matches": {
                "type": "array",
                "items": {
                    "type": "object",
                    "additionalProperties": False,
                    "required": ["name", "exerciseId"],
                    "properties": {
                        "name": {"type": "string", "enum": names},
                        "exerciseId": {"type": "string", "enum": [*ids, NONE]},
                    },
                },
            }
        },
    }


def validate_matches(raw: dict, names: list[str], ids: set[str]) -> MatchResponse:
    """Every name once, in his order; a name the model skipped or matched to nothing real is unmatched."""
    picked: dict[str, str | None] = {}
    for m in raw.get("matches", []) if isinstance(raw, dict) else []:
        if not isinstance(m, dict):
            continue
        name, ex = m.get("name"), m.get("exerciseId")
        if name in names and name not in picked:
            picked[name] = ex if ex in ids else None
    return MatchResponse(matches=[Match(name=n, exerciseId=picked.get(n)) for n in names])


def match_names(req: MatchRequest) -> MatchResponse:
    names = list(dict.fromkeys(n.strip() for n in req.names if n.strip()))
    exercises = list({e.id: e for e in req.exercises}.values())
    if not names:
        return MatchResponse(matches=[])
    if not exercises:
        return MatchResponse(matches=[Match(name=n, exerciseId=None) for n in names])
    plan = "\n".join(f"- {e.id}: {e.name}" for e in exercises)
    log = "\n".join(f"- {n}" for n in names)
    user = f"Plan exercises (id: name):\n{plan}\n\nNames from his workout log:\n{log}"
    raw, _ = meta.spark_json(
        prompts.HISTORY_MATCH, user, "HistoryMatch", match_schema(names, [e.id for e in exercises])
    )
    return validate_matches(raw, names, {e.id for e in exercises})


@router.post("/import/history/match", response_model=MatchResponse)
async def import_history_match(req: MatchRequest) -> MatchResponse:
    return await run_in_threadpool(match_names, req)
