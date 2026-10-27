"""Pydantic models mirroring the Swift Codable structs (HANDOFF.md §4), camelCase, identical names.

Two layers:
- `*Out` models are what Muse Spark returns (structured output). They carry no ids or timestamps,
  so the model never invents identifiers. `strict_schema()` turns them into a strict JSON schema.
- The API models add the ids and timestamps that code assigns (`to_program`, `to_template`).

Schema version: bump SCHEMA_VERSION when a model changes shape, so fixtures can be told apart.
"""

from __future__ import annotations

import re
from datetime import datetime
from typing import Any, Literal

from pydantic import BaseModel, ConfigDict, Field

SCHEMA_VERSION = 1


class StrictModel(BaseModel):
    """extra="forbid" emits additionalProperties: false, which strict structured output requires."""

    model_config = ConfigDict(extra="forbid")


# ---------------------------------------------------------------------------
# Coach's program (from the spreadsheet)
# ---------------------------------------------------------------------------


class PlannedSet(StrictModel):
    reps: int | None = Field(
        default=None, description="Exact rep count, or null when the sheet gives a range"
    )
    repsMin: int | None = Field(default=None, description="Low end of a rep range like 6-8, else null")
    repsMax: int | None = Field(default=None, description="High end of a rep range like 6-8, else null")
    loadLb: float | None = Field(default=None, description="Prescribed load in pounds, else null")
    rpe: float | None = Field(default=None, description="Prescribed RPE, else null")
    rir: int | None = Field(default=None, description="Prescribed reps in reserve, else null")


class PlannedExerciseOut(StrictModel):
    name: str = Field(description="Exercise name exactly as written on the sheet")
    sets: list[PlannedSet] = Field(description="One entry per set, in order")
    restSeconds: int | None = Field(
        default=None, description="Rest between sets in seconds if the sheet states it"
    )
    notes: str | None = Field(default=None, description="Any coach note attached to this exercise, verbatim")


class ProgramDayOut(StrictModel):
    name: str = Field(description='The day name as written, e.g. "Upper A"')
    exercises: list[PlannedExerciseOut]


class ProgramWeekOut(StrictModel):
    number: int = Field(description="Week number as the sheet labels it")
    days: list[ProgramDayOut]


class ImportFlag(StrictModel):
    path: str = Field(description='Where the doubt is, e.g. "week 4 / Upper A / Bench / set 2"')
    message: str = Field(description="What is unclear and which reading was kept")


class ProgramOut(StrictModel):
    name: str = Field(description="Program title from the sheet, or the sheet's file name")
    weeks: list[ProgramWeekOut]
    flags: list[ImportFlag] = Field(description="Every ambiguous cell. Empty when nothing was unclear")


class PlannedExercise(PlannedExerciseOut):
    id: str


class ProgramDay(StrictModel):
    id: str
    name: str
    exercises: list[PlannedExercise]


class ProgramWeek(StrictModel):
    number: int
    days: list[ProgramDay]


class Program(StrictModel):
    name: str
    weeks: list[ProgramWeek]
    importedAt: datetime
    flags: list[ImportFlag]


# ---------------------------------------------------------------------------
# Coach's check-in form
# ---------------------------------------------------------------------------

FieldKind = Literal["number", "scale10", "percent", "date", "text", "measurement", "photo"]
SourceType = Literal["data", "drafted", "voice", "photo", "calculated"]
DataKey = Literal[
    "weeksToShow",
    "planAccuracy",
    "nutritionConsistency",
    "trainingConsistency",
    "cardioProtocol",
    "performanceNotes",
    "lastRefeedDate",
    "avgDailySteps",
    "lastCheckInWeight",
    "currentWeight",
    "sleepDuration",
]

# One-line meanings, used verbatim in the form-import prompt.
DATA_KEY_MEANINGS: dict[str, str] = {
    "weeksToShow": "weeks until the show or target date, calculated from settings",
    "planAccuracy": "days on macros and sessions completed against the plan, as counts",
    "nutritionConsistency": "days within the macro targets, from MacroFactor via Apple Health",
    "trainingConsistency": "sessions done against the program, plus PRs from the training log",
    "cardioProtocol": "the assigned cardio protocol plus logged LISS sessions and steps",
    "performanceNotes": "lifts that beat or matched the logbook, drafted from the training log",
    "lastRefeedDate": "the latest day calories ran well over target, drafted for confirmation",
    "avgDailySteps": "seven-day mean of daily steps, from Garmin via Apple Health",
    "lastCheckInWeight": "the body weight reported in the previous check-in",
    "currentWeight": "the check-in morning weigh-in, from Withings via Apple Health",
    "sleepDuration": "average hours asleep per night from Garmin; the quality note is spoken",
}


class FieldSource(StrictModel):
    type: SourceType = Field(
        description=(
            "data: filled entirely from a data key. drafted: built from a data key but shown for "
            "confirmation. calculated: weeksToShow. voice: the athlete answers out loud. photo: the photos"
        )
    )
    key: DataKey | None = Field(
        default=None, description="The data key for data, drafted and calculated; null for voice and photo"
    )


class CarriedBlockOut(StrictModel):
    title: str | None = Field(
        default=None,
        description='The block heading line as written, e.g. "Macro targets"; null when the block has none',
    )
    text: str = Field(description="The block body copied verbatim, line breaks kept")


class CarriedBlock(StrictModel):
    title: str
    text: str


class FieldSpecOut(StrictModel):
    label: str = Field(description="The coach's exact wording, without any numbering")
    prompt: str | None = Field(
        default=None, description='Hint text in parentheses, e.g. "(scale 1-10)", else null'
    )
    kind: FieldKind
    source: FieldSource


class CheckInTemplateOut(StrictModel):
    fields: list[FieldSpecOut] = Field(description="Every question, in the coach's order")
    carriedBlocks: list[CarriedBlockOut] = Field(description="Instruction blocks that are not questions")


class FieldSpec(FieldSpecOut):
    id: str
    order: int


class CheckInTemplate(StrictModel):
    fields: list[FieldSpec]
    carriedBlocks: list[CarriedBlock]


# ---------------------------------------------------------------------------
# Strict JSON schema for Muse Spark
# ---------------------------------------------------------------------------


def strict_schema(model: type[BaseModel]) -> dict[str, Any]:
    """A JSON schema that satisfies Meta's strict structured-output subset.

    - every object has additionalProperties: false and lists all properties in required
    - `X | None` becomes {"type": ["X", "null"]} where X is a plain type
    - $defs are inlined, so the server sees one self-contained tree (a live run showed a
      required key inside a $ref'd object being dropped)
    - titles are dropped so the schema stays small and byte-stable
    - no oneOf / allOf anywhere (anyOf is allowed below the root)
    """
    raw = model.model_json_schema()
    defs = raw.pop("$defs", {})
    return _strictify(_inline(raw, defs))


def _inline(node: Any, defs: dict[str, Any]) -> Any:
    if isinstance(node, list):
        return [_inline(n, defs) for n in node]
    if not isinstance(node, dict):
        return node
    if "$ref" in node:
        name = node["$ref"].rsplit("/", 1)[-1]
        target = dict(defs[name])
        target.update({k: v for k, v in node.items() if k != "$ref"})
        return _inline(target, defs)
    return {k: _inline(v, defs) for k, v in node.items()}


def _strictify(node: Any) -> Any:
    if isinstance(node, list):
        return [_strictify(n) for n in node]
    if not isinstance(node, dict):
        return node
    out: dict[str, Any] = {}
    for key, value in node.items():
        if key == "title":
            continue  # a schema annotation, dropped for size and byte-stability
        if key == "properties" and isinstance(value, dict):
            # property names are data, never annotations: a field called "title" must survive
            out[key] = {name: _strictify(sub) for name, sub in value.items()}
            continue
        out[key] = _strictify(value)
    if out.get("type") == "object" and "properties" in out:
        out["additionalProperties"] = False
        out["required"] = list(out["properties"].keys())
    any_of = out.get("anyOf")
    if isinstance(any_of, list) and len(any_of) == 2:
        null = [b for b in any_of if b == {"type": "null"}]
        other = [b for b in any_of if b != {"type": "null"}]
        if (
            null
            and other
            and isinstance(other[0].get("type"), str)
            and set(other[0]) <= {"type", "description"}
        ):
            merged = {k: v for k, v in out.items() if k != "anyOf"}
            merged["type"] = [other[0]["type"], "null"]
            out = merged
    for forbidden in ("oneOf", "allOf"):
        if forbidden in out:
            raise ValueError(f"{forbidden} is not allowed in a strict schema")
    return out


# ---------------------------------------------------------------------------
# Ids assigned by code, never by the model
# ---------------------------------------------------------------------------


def slug(text: str) -> str:
    s = re.sub(r"[^a-z0-9]+", "_", text.lower()).strip("_")
    return s or "item"


def _unique(base: str, taken: set[str]) -> str:
    candidate, n = base, 2
    while candidate in taken:
        candidate = f"{base}_{n}"
        n += 1
    taken.add(candidate)
    return candidate


def to_program(out: ProgramOut, imported_at: datetime) -> Program:
    day_ids: set[str] = set()
    weeks: list[ProgramWeek] = []
    for week in out.weeks:
        days: list[ProgramDay] = []
        for day in week.days:
            day_id = _unique(f"w{week.number}_{slug(day.name)}", day_ids)
            ex_ids: set[str] = set()
            exercises = [
                PlannedExercise(id=_unique(f"{day_id}_{slug(ex.name)}", ex_ids), **ex.model_dump())
                for ex in day.exercises
            ]
            days.append(ProgramDay(id=day_id, name=day.name, exercises=exercises))
        weeks.append(ProgramWeek(number=week.number, days=days))
    return Program(name=out.name, weeks=weeks, importedAt=imported_at, flags=out.flags)


def block_title(block: CarriedBlockOut) -> str:
    """The heading as given, else the block's first line without its trailing colon. Never invented."""
    if block.title and block.title.strip():
        return block.title.strip()
    lines = [line.strip() for line in block.text.splitlines() if line.strip()]
    return lines[0].rstrip(":").strip() if lines else "Notes"


def to_template(out: CheckInTemplateOut) -> CheckInTemplate:
    taken: set[str] = set()
    fields = [
        FieldSpec(id=_unique(slug(f.label), taken), order=i, **f.model_dump())
        for i, f in enumerate(out.fields)
    ]
    blocks = [CarriedBlock(title=block_title(b), text=b.text) for b in out.carriedBlocks]
    return CheckInTemplate(fields=fields, carriedBlocks=blocks)
