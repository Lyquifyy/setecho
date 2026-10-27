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

from app.reps import infer_equipment

SCHEMA_VERSION = 2  # 2: the training cycle, rest days, add-ons, timed and role sets, alternates, rules


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
    seconds: int | None = Field(
        default=None,
        description='A timed set: "20 seconds" is 20, "60 sec each" is 60, "5 minutes" is 300. Reps stay null',
    )
    totalReps: int | None = Field(
        default=None,
        description='A rest-pause set\'s total-rep goal: "rest pause (20)" or "20 total reps" is 20',
    )
    role: SetRole | None = Field(
        default=None,
        description='top for "1 top set", backOff for "back down set" or "work down set", restPause for a '
        "rest-pause set; null for a straight set",
    )


Equipment = Literal["barbell", "dumbbell", "machine", "cable", "bodyweight"]
SetRole = Literal["top", "backOff", "restPause"]
DayKind = Literal["training", "rest"]
AddOnTiming = Literal["withSession", "onWaking"]


class AlternateOut(StrictModel):
    name: str = Field(description='The alternate exercise exactly as the coach wrote it ("Leg Press")')
    quote: str = Field(description='His words that offer it, verbatim ("Hack Squat or Leg Press")')


class PlannedExerciseOut(StrictModel):
    name: str = Field(description="Exercise name exactly as written on the sheet")
    sets: list[PlannedSet] = Field(description="One entry per set, in order")
    equipment: Equipment | None = Field(
        default=None,
        description="What the athlete moves: barbell, dumbbell, machine, cable or bodyweight. Decides what "
        "the camera tracks. Pick the likeliest from the name and add a flag when unsure",
    )
    restSeconds: int | None = Field(
        default=None, description="Rest between sets in seconds if the sheet states it"
    )
    notes: str | None = Field(default=None, description="Any coach note attached to this exercise, verbatim")
    alternates: list[AlternateOut] = Field(
        default_factory=list,
        description='The coach\'s own "or" options for this exercise, with his words. Empty when he gave none. '
        "Never add one he did not write",
    )


class ProgramDayOut(StrictModel):
    name: str = Field(description='The day name as written, e.g. "Day 1" or "Rest"')
    kind: DayKind = Field(
        default="training", description="rest for a rest day (no lifts; only its cardio line), else training"
    )
    cardio: str | None = Field(
        default=None,
        description='A rest day\'s cardio line, verbatim ("25 minutes of fasted LISS"), else null',
    )
    restSeconds: int | None = Field(
        default=None,
        description='A day-level rest period\'s top, in seconds: "Rest Period: 90-180 seconds" is 180. Null when '
        "the day states none",
    )
    restMinSeconds: int | None = Field(
        default=None, description='The bottom of a day-level rest range: 90 for "90-180 seconds", else null'
    )
    exercises: list[PlannedExerciseOut]


class AddOnOut(StrictModel):
    name: str = Field(
        description='The block\'s name, from its heading or its exercises ("Abs", "Stomach vacuums")'
    )
    exercises: list[PlannedExerciseOut]
    perWeek: int = Field(description='"2x per week" is 2')
    timing: AddOnTiming = Field(description='onWaking for "upon waking"; otherwise withSession')
    quote: str = Field(description="The coach's sentence that sets the frequency, verbatim")


class ProgramWeekOut(StrictModel):
    number: int = Field(description="Week number as the sheet labels it")
    days: list[ProgramDayOut]


class ImportFlag(StrictModel):
    path: str = Field(description='Where the doubt is, e.g. "week 4 / Upper A / Bench / set 2"')
    message: str = Field(description="What is unclear and which reading was kept")


class ProgramOut(StrictModel):
    name: str = Field(description="Program title from the sheet, or the sheet's file name")
    weeks: list[ProgramWeekOut] = Field(
        description="The training cycle: the training and rest days in the sheet's order. Never an add-on block"
    )
    addOns: list[AddOnOut] = Field(
        default_factory=list,
        description='Blocks the coach adds on top of days with a frequency ("4x per week"), wherever their '
        "tab sits. Empty when the sheet has none",
    )
    rules: list[RuleOut] = Field(
        default_factory=list,
        description='Only the load-adjustment rules the coach actually wrote in this sheet ("if RPE is over 9, '
        'drop 5%", "when you hit 8 reps on every set, add 5 lb next week"), with his words in `quote`. If the '
        "sheet has targets but no rule, return none. Never invent a rule",
    )
    flags: list[ImportFlag] = Field(description="Every ambiguous cell. Empty when nothing was unclear")


class Alternate(AlternateOut):
    source: str = Field(description='"Sheet" · "Coach\'s reply, Oct 29"')


class PlannedExercise(PlannedExerciseOut):
    id: str
    equipment: Equipment  # type: ignore[assignment]  # always set: from the model, else inferred from the name
    restMinSeconds: int | None = None  # the bottom of a day-level rest range: a quiet cue there
    alternates: list[Alternate]  # type: ignore[assignment]


class ProgramDay(StrictModel):
    id: str
    name: str
    exercises: list[PlannedExercise]
    kind: DayKind = "training"
    cardio: str | None = None


class ProgramWeek(StrictModel):
    number: int
    days: list[ProgramDay]


class AddOn(StrictModel):
    id: str
    name: str
    exercises: list[PlannedExercise]
    perWeek: int
    timing: AddOnTiming
    quote: str


class Program(StrictModel):
    name: str
    weeks: list[ProgramWeek]
    addOns: list[AddOn] = []
    rules: list[ProgressionRule] = []  # drafted from the sheet's notes; nothing applies until confirmed
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


class MacrosOut(StrictModel):
    kcal: float | None = Field(default=None, description="Calories for this day type, else null")
    proteinG: float | None = Field(default=None, description="Protein in grams, else null")
    carbsG: float | None = Field(default=None, description="Carbohydrate in grams, else null")
    fatG: float | None = Field(default=None, description="Fat in grams, else null")


class MacroTargetsOut(StrictModel):
    training: MacrosOut = Field(description="Training-day targets, copied from the form's nutrition block")
    rest: MacrosOut = Field(description="Rest-day (non-training) targets")


class CheckInTemplateOut(StrictModel):
    fields: list[FieldSpecOut] = Field(description="Every question, in the coach's order")
    carriedBlocks: list[CarriedBlockOut] = Field(description="Instruction blocks that are not questions")
    targets: MacroTargetsOut | None = Field(
        default=None, description="The macro targets written in the form's blocks; null when there are none"
    )
    cardioProtocol: str | None = Field(
        default=None, description="The assigned cardio protocol as written in the form, else null"
    )


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


def _alternates(ex: PlannedExerciseOut) -> list[Alternate]:
    """The coach's "or" options as the model read them, plus a slash name's second option
    ("Hanging/Lying Leg Raises" keeps its name; "Lying Leg Raises" becomes an alternate)."""
    out = [Alternate(name=a.name, quote=a.quote, source="Sheet") for a in ex.alternates if a.name.strip()]
    if "/" in ex.name:
        second = ex.name.split("/", 1)[1].strip()
        if second and all(second.lower() != a.name.lower() for a in out):
            out.append(Alternate(name=second, quote=ex.name, source="Sheet"))
    return out


def _exercise(
    ex: PlannedExerciseOut, exercise_id: str, day_rest: int | None, day_rest_min: int | None
) -> PlannedExercise:
    own_rest = ex.restSeconds is not None
    data = ex.model_dump(exclude={"alternates"})
    data.update(
        equipment=ex.equipment or infer_equipment(ex.name),
        restSeconds=ex.restSeconds if own_rest else day_rest,
        restMinSeconds=None if own_rest else day_rest_min,
        alternates=_alternates(ex),
    )
    return PlannedExercise(id=exercise_id, **data)


def to_program(out: ProgramOut, imported_at: datetime) -> Program:
    day_ids: set[str] = set()
    weeks: list[ProgramWeek] = []
    for week in out.weeks:
        days: list[ProgramDay] = []
        for day in week.days:
            day_id = _unique(f"w{week.number}_{slug(day.name)}", day_ids)
            ex_ids: set[str] = set()
            exercises = [
                _exercise(
                    ex, _unique(f"{day_id}_{slug(ex.name)}", ex_ids), day.restSeconds, day.restMinSeconds
                )
                for ex in day.exercises
            ]
            kind = "rest" if day.kind == "rest" and not exercises else day.kind
            days.append(
                ProgramDay(id=day_id, name=day.name, exercises=exercises, kind=kind, cardio=day.cardio)
            )
        weeks.append(ProgramWeek(number=week.number, days=days))
    addon_ids: set[str] = set()
    add_ons: list[AddOn] = []
    for block in out.addOns:
        addon_id = _unique(f"addon_{slug(block.name)}", addon_ids)
        ex_ids = set()
        exercises = [
            _exercise(ex, _unique(f"{addon_id}_{slug(ex.name)}", ex_ids), None, None)
            for ex in block.exercises
        ]
        add_ons.append(
            AddOn(
                id=addon_id,
                name=block.name,
                exercises=exercises,
                perWeek=max(1, block.perWeek),
                timing=block.timing,
                quote=block.quote,
            )
        )
    rules = [
        ProgressionRule(id=f"sheet_rule_{i + 1}", source="Sheet note", **r.model_dump())
        for i, r in enumerate(out.rules)
    ]
    return Program(
        name=out.name, weeks=weeks, addOns=add_ons, rules=rules, importedAt=imported_at, flags=out.flags
    )


def block_title(block: CarriedBlockOut) -> str:
    """The heading as given, else the block's first line without its trailing colon. Never invented."""
    if block.title and block.title.strip():
        return block.title.strip()
    lines = [line.strip() for line in block.text.splitlines() if line.strip()]
    return lines[0].rstrip(":").strip() if lines else "Notes"


class Macros(StrictModel):
    kcal: float
    proteinG: float
    carbsG: float
    fatG: float


class MacroTargets(StrictModel):
    training: Macros
    rest: Macros


class FormImport(StrictModel):
    """What /import/form returns: the template plus the plan values read from the carried blocks."""

    template: CheckInTemplate
    targets: MacroTargets | None = None
    cardioProtocol: str | None = None


def form_targets(out: CheckInTemplateOut) -> MacroTargets | None:
    """Targets only when every number is there; a half-read block is worse than none."""
    t = out.targets
    if t is None:
        return None
    values = [t.training.kcal, t.training.proteinG, t.training.carbsG, t.training.fatG,
              t.rest.kcal, t.rest.proteinG, t.rest.carbsG, t.rest.fatG]  # fmt: skip
    if any(v is None for v in values):
        return None
    return MacroTargets(
        training=Macros(
            kcal=t.training.kcal, proteinG=t.training.proteinG, carbsG=t.training.carbsG, fatG=t.training.fatG
        ),  # type: ignore[arg-type]
        rest=Macros(kcal=t.rest.kcal, proteinG=t.rest.proteinG, carbsG=t.rest.carbsG, fatG=t.rest.fatG),  # type: ignore[arg-type]
    )


def to_template(out: CheckInTemplateOut) -> CheckInTemplate:
    taken: set[str] = set()
    fields = [
        FieldSpec(id=_unique(slug(f.label), taken), order=i, **f.model_dump())
        for i, f in enumerate(out.fields)
    ]
    blocks = [CarriedBlock(title=block_title(b), text=b.text) for b in out.carriedBlocks]
    return CheckInTemplate(fields=fields, carriedBlocks=blocks)


# ---------------------------------------------------------------------------
# The coach's rules, from his written instructions (/import/rules, HANDOFF.md §4-§5)
# ---------------------------------------------------------------------------

RuleTrigger = Literal[
    "aboveTarget", "belowTarget", "repsBelowMin", "allSetsAtTopOfRange", "afterTopSet", "restPauseOverGoal",
    "topSetPastRange",
]  # fmt: skip
RuleAdjust = Literal["percent", "pounds", "reps", "backOff", "loadSteps"]
RuleScope = Literal["nextSet", "nextSession"]
RoleName = Literal["top", "backOff", "restPause", "straight"]


class RuleOut(StrictModel):
    appliesTo: str | None = Field(
        default=None,
        description="The exercise it is about, as he wrote it, or null when it applies to every lift",
    )
    when: RuleTrigger = Field(
        description="aboveTarget / belowTarget: the set's effort was over or under his target by byRPE; "
        "repsBelowMin: fewer reps than the range's bottom; allSetsAtTopOfRange: every set hit the top of the "
        "range; afterTopSet: how the back-off set's load follows the top set; restPauseOverGoal: a rest-pause set "
        "beat its total-rep goal; topSetPastRange: a top set went past the top of its range"
    )
    byRPE: float | None = Field(
        default=None, description="For aboveTarget / belowTarget: the RPE margin, else null"
    )
    adjust: RuleAdjust = Field(
        description="percent or pounds: change the load by `amount` (signed); reps: keep the load and change the reps "
        "by `amount`; backOff: the back-off set is minPct-maxPct lighter than the top set; loadSteps: `amount` "
        'load steps up ("add weight" is 1)'
    )
    amount: float | None = Field(default=None, description="The signed number he said; null for backOff")
    minPct: float | None = Field(default=None, description='backOff only: "20-25% lighter" is 20')
    maxPct: float | None = Field(default=None, description='backOff only: "20-25% lighter" is 25')
    scope: RuleScope = Field(description="nextSet within the session, or nextSession (next week)")
    quote: str = Field(description="His exact words, verbatim from the text")


class RoleTargetOut(StrictModel):
    role: RoleName = Field(
        description="Which kind of set: top, backOff, restPause, or straight for plain sets"
    )
    rir: float = Field(description="Reps in reserve he wants left: 0 for failure, 1 for one rep left")
    quote: str


class RestRuleOut(StrictModel):
    after: RoleName = Field(description="The set kind the rest follows")
    minSeconds: int = Field(description='"3-4 minutes" is 180')
    maxSeconds: int = Field(description='"3-4 minutes" is 240')
    quote: str


class WarmupRuleOut(StrictModel):
    minSets: int = Field(description='"1-3 warm-up sets" is 1')
    maxSets: int = Field(description='"1-3 warm-up sets" is 3')
    maxReps: int = Field(description='"no more than 6-8 reps" is 8')
    quote: str


class CheckInScheduleOut(StrictModel):
    everyWeeks: int = Field(description='1 for weekly, 2 for "every other week"')
    weekday: int = Field(description="1 = Sunday, 2 = Monday … 5 = Thursday … 7 = Saturday")
    dueBy: str = Field(description='24-hour "HH:MM", e.g. "09:00" for 9am')
    timeZone: str = Field(description='An IANA zone from his words: "Central" is America/Chicago')
    quote: str


class QuietDayOut(StrictModel):
    weekday: int = Field(description="1 = Sunday … 7 = Saturday")
    quote: str


class RulesOut(StrictModel):
    rules: list[RuleOut] = Field(
        default_factory=list, description="Load-adjustment rules he states. Empty when he states none"
    )
    roleTargets: list[RoleTargetOut] = Field(
        default_factory=list, description="How hard each kind of set should go. Empty when unstated"
    )
    restRules: list[RestRuleOut] = Field(
        default_factory=list, description="Rest after a kind of set. Empty when unstated"
    )
    warmups: WarmupRuleOut | None = Field(default=None, description="Warm-up sets he expects, else null")
    checkInSchedule: CheckInScheduleOut | None = Field(
        default=None, description="When check-ins are due, else null"
    )
    quietDays: list[QuietDayOut] = Field(
        default_factory=list, description="Days he asked not to be messaged. Empty when unstated"
    )
    flags: list[ImportFlag] = Field(
        default_factory=list, description="Anything that reads like a rule but is unclear. Empty when none"
    )


class ProgressionRule(RuleOut):
    id: str
    source: str
    confirmed: bool = False


class RoleTarget(RoleTargetOut):
    source: str
    confirmed: bool = False


class RestRule(RestRuleOut):
    confirmed: bool = False


class WarmupRule(WarmupRuleOut):
    confirmed: bool = False


class CheckInSchedule(CheckInScheduleOut):
    confirmed: bool = False


class RulesImport(StrictModel):
    """What /import/rules returns: his rules with his quotes, nothing confirmed, nothing personal."""

    rules: list[ProgressionRule]
    roleTargets: list[RoleTarget]
    restRules: list[RestRule]
    warmups: WarmupRule | None = None
    checkInSchedule: CheckInSchedule | None = None
    quietDays: list[int]
    flags: list[ImportFlag]


ProgramOut.model_rebuild()
Program.model_rebuild()
