"""The weekly check-in (HANDOFF.md §5, §7, §8): the week's numbers arrive from the phone as plain
values, code fills every data field and cites its source, Muse Spark drafts only the text fields
through tool calls, and a validator checks every number in the model's text against its source.
Rendering reproduces the coach's form: his labels, his order, his carried blocks.
"""

from __future__ import annotations

import json
import re
from datetime import date
from typing import Any

from pydantic import Field

from app import meta
from app.schemas import CheckInTemplate, FieldSpec, Macros, MacroTargets, StrictModel, strict_schema

# ---------------------------------------------------------------------------
# Models mirroring the Swift structs
# ---------------------------------------------------------------------------


class LissSession(StrictModel):
    type: str
    minutes: int


class DayFacts(StrictModel):
    date: str
    isTrainingDay: bool
    kcal: float | None = None
    proteinG: float | None = None
    carbsG: float | None = None
    fatG: float | None = None
    steps: float | None = None
    sleepHours: float | None = None
    weighInLb: float | None = None
    liss: list[LissSession]


class WeekFacts(StrictModel):
    weekStart: str
    weekEnd: str
    daily: list[DayFacts]
    targets: MacroTargets
    showDate: str | None = None
    lastCheckInWeightLb: float | None = None
    sources: dict[str, str]
    cardioProtocol: str | None = None


class PersonalRecord(StrictModel):
    exercise: str
    loadLb: float
    reps: int


class TrainingSummary(StrictModel):
    sessionsDone: int
    sessionsScheduled: int
    setsLogged: int
    prs: list[PersonalRecord]
    exercises: list[str] = Field(default_factory=list, description="Exercises trained this week")


class VoiceNote(StrictModel):
    id: str
    at: str
    transcript: str
    targetFieldId: str | None = None


class Provenance(StrictModel):
    source: str
    detail: str


class FieldAnswer(StrictModel):
    fieldId: str
    text: str
    state: str  # filled | drafted | missing | confirmed
    provenance: list[Provenance]


class CheckInDraft(StrictModel):
    id: str
    weekStart: str
    weekEnd: str
    answers: list[FieldAnswer]
    photoSetId: str | None = None
    sentAt: str | None = None


class DraftRequest(StrictModel):
    template: CheckInTemplate
    facts: WeekFacts
    notes: list[VoiceNote]
    training: TrainingSummary
    lastCheckIn: CheckInDraft | None = None
    styleExamples: list[str]
    draftId: str | None = None


class RenderRequest(StrictModel):
    template: CheckInTemplate
    draft: CheckInDraft
    adjustments: list[str] = Field(
        default_factory=list,
        description='The accepted suggestions as lines computed on the phone: "Incline press set 3, 225 → 215 (RPE 9.5 vs 8)"',
    )
    deviations: list[str] = Field(default_factory=list, description="Gym changes (stretch), one line each")


# ---------------------------------------------------------------------------
# Deterministic fields (numbers from code, never from the model)
# ---------------------------------------------------------------------------

KCAL_TOLERANCE = 0.05
GRAMS_TOLERANCE = 10.0
# A training day logged this far under target is the day of the untracked free meal.
UNTRACKED_MEAL_UNDER = 0.25
_FREE_MEAL = re.compile(r"\b(free meal|cheat meal|cheat day|refeed|re-feed)\b", re.IGNORECASE)


def _fmt(n: float) -> str:
    return str(int(n)) if float(n).is_integer() else f"{n:.1f}"


def _mdy(iso: str) -> str:
    """2026-10-17 -> 10/17/26, the athlete's own date style."""
    try:
        d = date.fromisoformat(iso)
    except ValueError:
        return iso
    return f"{d.month}/{d.day}/{d.year % 100:02d}"


def _target(facts: WeekFacts, day: DayFacts) -> Macros:
    return facts.targets.training if day.isTrainingDay else facts.targets.rest


def on_plan(facts: WeekFacts, day: DayFacts) -> bool | None:
    if None in (day.kcal, day.proteinG, day.carbsG, day.fatG):
        return None
    t = _target(facts, day)
    return (
        abs(day.kcal - t.kcal) <= t.kcal * KCAL_TOLERANCE
        and abs(day.proteinG - t.proteinG) <= GRAMS_TOLERANCE
        and abs(day.carbsG - t.carbsG) <= GRAMS_TOLERANCE
        and abs(day.fatG - t.fatG) <= GRAMS_TOLERANCE
    )


def _source(facts: WeekFacts, key: str, default: str) -> str:
    app = facts.sources.get(key)
    return f"{app} via Apple Health" if app else default


def _range(facts: WeekFacts) -> str:
    return f"{_mdy(facts.weekStart)}–{_mdy(facts.weekEnd)}"


def fill_data_field(
    field: FieldSpec,
    facts: WeekFacts,
    training: TrainingSummary,
    last: CheckInDraft | None = None,
    notes: list[VoiceNote] | None = None,
) -> FieldAnswer | None:
    """The answer for a data / drafted / calculated field, or None when it isn't one."""
    key = field.source.key
    if field.source.type not in ("data", "drafted", "calculated") or key is None:
        return None
    state = "drafted" if field.source.type == "drafted" else "filled"
    verdicts = [(d, on_plan(facts, d)) for d in facts.daily]
    logged = [v for _, v in verdicts if v is not None]
    on = sum(1 for v in logged if v)

    if key == "weeksToShow":
        if not facts.showDate:
            return FieldAnswer(fieldId=field.id, text="N/A", state="filled",
                               provenance=[Provenance(source="Settings", detail="No show date set")])  # fmt: skip
        try:
            weeks = max(0, (date.fromisoformat(facts.showDate) - date.fromisoformat(facts.weekEnd)).days // 7)
        except ValueError:
            weeks = 0
        return FieldAnswer(fieldId=field.id, text=str(weeks), state="filled",
                           provenance=[Provenance(source="Settings", detail=f"Show date {_mdy(facts.showDate)}")])  # fmt: skip

    if key == "planAccuracy":
        pct = round(100 * (on + training.sessionsDone) / max(1, len(logged) + training.sessionsScheduled))
        text = f"{pct}% ({on} of {len(logged)} days on macros, {training.sessionsDone} of {training.sessionsScheduled} sessions)"
        return FieldAnswer(fieldId=field.id, text=text, state=state, provenance=[
            Provenance(source=_source(facts, "calories", "MacroFactor via Apple Health"), detail=f"{_range(facts)}: {on} of {len(logged)} days within targets"),
            Provenance(source="Training log", detail=f"{training.sessionsDone} of {training.sessionsScheduled} sessions"),
        ])  # fmt: skip

    if key == "nutritionConsistency":
        pct = round(100 * on / max(1, len(logged)))
        off = [d.date for d, v in verdicts if v is False]
        text = f"{pct}%, {on} of {len(logged)} days within targets" + (
            f" (off on {', '.join(_mdy(x) for x in off)})" if off else ""
        )
        detail = "; ".join(
            f"{_mdy(d.date)}: {_fmt(d.kcal or 0)} kcal, {_fmt(d.proteinG or 0)}P/{_fmt(d.carbsG or 0)}C/{_fmt(d.fatG or 0)}F"
            for d in facts.daily
            if d.kcal is not None
        )
        return FieldAnswer(fieldId=field.id, text=text, state=state, provenance=[
            Provenance(source=_source(facts, "calories", "MacroFactor via Apple Health"), detail=detail or "No nutrition logged")])  # fmt: skip

    if key == "trainingConsistency":
        pct = round(100 * training.sessionsDone / max(1, training.sessionsScheduled))
        prs = ", ".join(f"{p.exercise} {_fmt(p.loadLb)}×{p.reps}" for p in training.prs)
        text = f"{pct}%, {training.sessionsDone} of {training.sessionsScheduled} sessions" + (
            f". PRs: {prs}" if prs else ""
        )
        return FieldAnswer(fieldId=field.id, text=text, state=state, provenance=[
            Provenance(source="Training log", detail=f"{training.setsLogged} sets logged; PRs: {prs or 'none'}")])  # fmt: skip

    if key == "cardioProtocol":
        liss = [s for d in facts.daily for s in d.liss]
        minutes = sum(s.minutes for s in liss)
        steps = [d.steps for d in facts.daily if d.steps is not None]
        avg = round(sum(steps) / len(steps) / 100) * 100 if steps else None
        parts = [facts.cardioProtocol] if facts.cardioProtocol else []
        parts.append(f"logged: {len(liss)} sessions, {minutes} min")
        if avg is not None:
            parts.append(f"Steps: avg {avg / 1000:.1f}k")
        text = ". ".join(parts) if facts.cardioProtocol else " ".join(parts)
        return FieldAnswer(fieldId=field.id, text=text, state=state, provenance=[
            Provenance(source="Settings", detail=facts.cardioProtocol or "No protocol set"),
            Provenance(source=_source(facts, "workouts", "Garmin via Apple Health"), detail=f"{len(liss)} LISS sessions, {minutes} min"),
        ])  # fmt: skip

    if key == "performanceNotes":
        if training.prs:
            prs = ", ".join(f"{p.exercise} {_fmt(p.loadLb)} for {p.reps}" for p in training.prs)
            text = f"Beat the logbook on {prs}"
        elif training.setsLogged:
            text = "Matched the logbook this week, no PRs logged"
        else:
            text = "No sessions logged in Setecho this week"
        return FieldAnswer(fieldId=field.id, text=text, state="drafted", provenance=[
            Provenance(source="Training log", detail=f"{training.setsLogged} sets; PRs: {', '.join(p.exercise for p in training.prs) or 'none'}")])  # fmt: skip

    if key == "lastRefeedDate":
        # His free meal is untracked, so a high-calorie day won't show it. A spoken note ("free meal
        # today") wins; else the latest training day logged well under target is the untracked meal;
        # else it is asked. Always drafted, never confirmed by code.
        spoken = [n for n in (notes or []) if _FREE_MEAL.search(n.transcript)]
        if spoken:
            note = max(spoken, key=lambda n: n.at)
            return FieldAnswer(fieldId=field.id, text=_mdy(note.at[:10]), state="drafted", provenance=[
                Provenance(source=f"You said · {_mdy(note.at[:10])}", detail=note.transcript)])  # fmt: skip
        under = [
            d.date
            for d in facts.daily
            if d.isTrainingDay
            and d.kcal is not None
            and d.kcal < _target(facts, d).kcal * (1 - UNTRACKED_MEAL_UNDER)
        ]
        if under:
            latest = max(under)
            return FieldAnswer(fieldId=field.id, text=_mdy(latest), state="drafted", provenance=[
                Provenance(source=_source(facts, "calories", "MacroFactor via Apple Health"),
                           detail=f"Training days logged more than 25% under target (the untracked meal): "
                                  f"{', '.join(_mdy(x) for x in under)}")])  # fmt: skip
        return FieldAnswer(fieldId=field.id, text="", state="missing", provenance=[
            Provenance(source=_source(facts, "calories", "MacroFactor via Apple Health"),
                       detail="No note and no training day logged well under target: asked on check-in morning")])  # fmt: skip

    if key == "avgDailySteps":
        steps = [d.steps for d in facts.daily if d.steps is not None]
        if not steps:
            return FieldAnswer(
                fieldId=field.id,
                text="",
                state="missing",
                provenance=[Provenance(source="Apple Health", detail="No steps this week")],
            )
        avg = round(sum(steps) / len(steps) / 100) * 100
        return FieldAnswer(fieldId=field.id, text=f"{avg / 1000:.1f}k", state=state, provenance=[
            Provenance(source=_source(facts, "steps", "Garmin via Apple Health"),
                       detail=f"{_range(facts)}: " + ", ".join(_fmt(s) for s in steps))])  # fmt: skip

    if key == "lastCheckInWeight":
        if facts.lastCheckInWeightLb is None:
            return FieldAnswer(
                fieldId=field.id,
                text="",
                state="missing",
                provenance=[Provenance(source="Last check-in", detail="No previous check-in in Setecho")],
            )
        return FieldAnswer(fieldId=field.id, text=_fmt(facts.lastCheckInWeightLb), state=state, provenance=[
            Provenance(source="Last check-in", detail=f"Sent weight {_fmt(facts.lastCheckInWeightLb)}")])  # fmt: skip

    if key == "currentWeight":
        weights = [(d.date, d.weighInLb) for d in facts.daily if d.weighInLb is not None]
        if not weights:
            return FieldAnswer(
                fieldId=field.id,
                text="",
                state="missing",
                provenance=[Provenance(source="Apple Health", detail="No weigh-in this week")],
            )
        last_date, last_weight = weights[-1]
        return FieldAnswer(fieldId=field.id, text=_fmt(last_weight), state=state, provenance=[
            Provenance(source=_source(facts, "weight", "Withings via Apple Health"),
                       detail=f"Weigh-in {_mdy(last_date)}; week: " + ", ".join(_fmt(w) for _, w in weights))])  # fmt: skip

    if key == "sleepDuration":
        hours = [d.sleepHours for d in facts.daily if d.sleepHours is not None]
        if not hours:
            return FieldAnswer(
                fieldId=field.id,
                text="",
                state="missing",
                provenance=[Provenance(source="Apple Health", detail="No sleep this week")],
            )
        avg = round(sum(hours) / len(hours), 1)
        return FieldAnswer(fieldId=field.id, text=f"Avg {avg} h/night", state="drafted", provenance=[
            Provenance(source=_source(facts, "sleep", "Garmin via Apple Health"),
                       detail=f"{_range(facts)}: " + ", ".join(f"{h:.1f}" for h in hours) + " h")])  # fmt: skip

    return None


# ---------------------------------------------------------------------------
# Validator: every number the model writes must come from the facts
# ---------------------------------------------------------------------------

_NUMBER = re.compile(r"\d+(?:[.,]\d+)?")


def known_numbers(facts: WeekFacts, training: TrainingSummary, last: CheckInDraft | None) -> set[str]:
    values: set[str] = set()

    def add(n: float | None) -> None:
        if n is None:
            return
        values.add(_fmt(n))
        values.add(str(round(n)))
        values.add(f"{n:.1f}")
        if n >= 1000:
            values.add(f"{n / 1000:.1f}k")
            values.add(f"{round(n / 1000)}k")

    for d in facts.daily:
        for n in (d.kcal, d.proteinG, d.carbsG, d.fatG, d.steps, d.sleepHours, d.weighInLb):
            add(n)
        for s in d.liss:
            add(s.minutes)
    for m in (facts.targets.training, facts.targets.rest):
        for n in (m.kcal, m.proteinG, m.carbsG, m.fatG):
            add(n)
    add(facts.lastCheckInWeightLb)
    for p in training.prs:
        add(p.loadLb)
        add(p.reps)
    for n in (training.sessionsDone, training.sessionsScheduled, training.setsLogged, len(facts.daily)):
        add(n)
    # The derived values the data fields render: averages, counts and percentages.
    steps = [d.steps for d in facts.daily if d.steps is not None]
    if steps:
        add(round(sum(steps) / len(steps) / 100) * 100)
    hours = [d.sleepHours for d in facts.daily if d.sleepHours is not None]
    if hours:
        add(round(sum(hours) / len(hours), 1))
    verdicts = [on_plan(facts, d) for d in facts.daily]
    logged = [v for v in verdicts if v is not None]
    on = sum(1 for v in logged if v)
    for n in (on, len(logged), len(logged) - on, sum(s.minutes for d in facts.daily for s in d.liss)):
        add(n)
    for pct in (
        round(100 * on / max(1, len(logged))),
        round(100 * training.sessionsDone / max(1, training.sessionsScheduled)),
        round(100 * (on + training.sessionsDone) / max(1, len(logged) + training.sessionsScheduled)),
    ):
        add(pct)
    for n in (1, 2, 3, 4, 5, 6, 7, 10, 100):  # counts and percentages that are always fair game
        add(n)
    return values


def validate(text: str, known: set[str]) -> list[str]:
    """Numbers in `text` that do not come from the facts. Empty means every number is accounted for."""
    found = []
    for m in _NUMBER.finditer(text):
        token = m.group().replace(",", "")
        token = token.removesuffix(".")
        suffix = text[m.end() : m.end() + 1]
        candidates = {token, f"{token}k" if suffix == "k" else token}
        if not candidates & known and _fmt(float(token)) not in known:
            found.append(m.group())
    return found


# ---------------------------------------------------------------------------
# The agent: Muse Spark writes only the text fields, through tool calls
# ---------------------------------------------------------------------------

AGENT_SYSTEM = (
    "You fill in an athlete's weekly check-in for their coach, in the athlete's own voice. "
    "Use only facts returned by your tools. Do not give advice, judge form or suggest changes; the "
    "coach does that. Keep answers short and casual, like the examples. Write only the fields you are "
    "asked for. Never invent a number: every number you write must appear in a tool result."
)


class AgentAnswer(StrictModel):
    fieldId: str
    text: str


class AgentOutput(StrictModel):
    answers: list[AgentAnswer]


AGENT_SCHEMA = strict_schema(AgentOutput)

TOOLS = [
    {"type": "function", "name": "get_week_facts", "description": "The week's nutrition, steps, sleep and weigh-ins, day by day, with the macro targets.", "parameters": {"type": "object", "properties": {}, "additionalProperties": False}},
    {"type": "function", "name": "get_training_summary", "description": "Sessions done and scheduled, sets logged, and this week's PRs.", "parameters": {"type": "object", "properties": {}, "additionalProperties": False}},
    {"type": "function", "name": "get_notes", "description": "Things the athlete said mid-week for the check-in, with the field each targets when known.", "parameters": {"type": "object", "properties": {}, "additionalProperties": False}},
    {"type": "function", "name": "get_last_checkin", "description": "The previous check-in as sent, for continuity.", "parameters": {"type": "object", "properties": {}, "additionalProperties": False}},
]  # fmt: skip


def agent_fields(template: CheckInTemplate, notes: list[VoiceNote]) -> list[FieldSpec]:
    """The fields the model drafts: performance notes, biggest win, and any voice field a mid-week note targets."""
    targeted = {n.targetFieldId for n in notes if n.targetFieldId}
    out = []
    for f in template.fields:
        if (
            f.source.key == "performanceNotes"
            or f.source.type == "voice"
            and ("win" in f.label.lower() or f.id in targeted)
        ):
            out.append(f)
    return out


def run_agent(req: DraftRequest, fields: list[FieldSpec]) -> dict[str, str]:
    """Responses API tool loop. Returns fieldId -> text. Raises on API failure; the caller falls back."""
    client = meta.client()
    results = {
        "get_week_facts": req.facts.model_dump(),
        "get_training_summary": req.training.model_dump(),
        "get_notes": [n.model_dump() for n in req.notes],
        "get_last_checkin": req.lastCheckIn.model_dump() if req.lastCheckIn else None,
    }
    examples = "\n".join(f"- {e}" for e in req.styleExamples) or "- (none)"
    wanted = "\n".join(f'- {f.id}: "{f.label}"' for f in fields)
    user = (
        f"Examples of how the athlete writes:\n{examples}\n\n"
        f"Draft these fields, one or two sentences each, first person:\n{wanted}\n\n"
        "Call the tools you need first. Put each answer in `answers` with its fieldId."
    )
    text_format = {
        "format": {"type": "json_schema", "name": "AgentOutput", "schema": AGENT_SCHEMA, "strict": True}
    }
    resp = client.responses.create(
        model=meta.SPARK_MODEL,
        instructions=AGENT_SYSTEM,
        input=user,
        tools=TOOLS,
        tool_choice="auto",
        text=text_format,
    )
    for _ in range(6):
        calls = [item for item in resp.output if getattr(item, "type", "") == "function_call"]
        if not calls:
            break
        outputs = [
            {"type": "function_call_output", "call_id": c.call_id, "output": json.dumps(results.get(c.name))}
            for c in calls
        ]
        resp = client.responses.create(
            model=meta.SPARK_MODEL,
            previous_response_id=resp.id,
            input=outputs,
            tools=TOOLS,
            tool_choice="auto",
            text=text_format,
        )
    data = AgentOutput.model_validate_json(resp.output_text or '{"answers": []}')
    return {a.fieldId: a.text for a in data.answers}


# ---------------------------------------------------------------------------
# Draft and render
# ---------------------------------------------------------------------------


def build_draft(req: DraftRequest, agent: Any = None) -> CheckInDraft:
    known = known_numbers(req.facts, req.training, req.lastCheckIn)
    wanted = agent_fields(req.template, req.notes)
    try:
        drafted = (agent or run_agent)(req, wanted) if wanted else {}
    except Exception as e:  # noqa: BLE001  the agent is optional: data fields never depend on it
        drafted = {"__error__": str(e)}
    notes_by_field: dict[str, list[VoiceNote]] = {}
    for n in req.notes:
        if n.targetFieldId:
            notes_by_field.setdefault(n.targetFieldId, []).append(n)

    answers: list[FieldAnswer] = []
    for field in req.template.fields:
        if (
            answer := fill_data_field(field, req.facts, req.training, req.lastCheckIn, req.notes)
        ) is not None:
            if field.source.key == "performanceNotes" and field.id in drafted:
                text = drafted[field.id]
                bad = validate(text, known)
                prov = answer.provenance + [
                    Provenance(source="Drafted by Muse Spark", detail="From the training log")
                ]
                if bad:
                    prov.append(
                        Provenance(source="Check this", detail=f"Numbers not in the log: {', '.join(bad)}")
                    )
                answer = FieldAnswer(fieldId=field.id, text=text, state="drafted", provenance=prov)
            answers.append(answer)
            continue
        if field.source.type == "photo":
            answers.append(
                FieldAnswer(
                    fieldId=field.id,
                    text="",
                    state="missing",
                    provenance=[Provenance(source="Photo session", detail="Attached as the collage")],
                )
            )
            continue
        if field.id in drafted:
            text = drafted[field.id]
            bad = validate(text, known)
            prov = [Provenance(source="Drafted by Muse Spark", detail="From your notes and the week's data")]
            for n in notes_by_field.get(field.id, []):
                prov.append(Provenance(source=f"You said · {_mdy(n.at[:10])}", detail=n.transcript))
            if bad:
                prov.append(
                    Provenance(source="Check this", detail=f"Numbers not in the data: {', '.join(bad)}")
                )
            answers.append(FieldAnswer(fieldId=field.id, text=text, state="drafted", provenance=prov))
            continue
        if notes := notes_by_field.get(field.id):
            text = " ".join(n.transcript for n in notes)
            answers.append(FieldAnswer(fieldId=field.id, text=text, state="drafted",
                                       provenance=[Provenance(source=f"You said · {_mdy(n.at[:10])}", detail=n.transcript) for n in notes]))  # fmt: skip
            continue
        answers.append(FieldAnswer(fieldId=field.id, text="", state="missing", provenance=[]))

    return CheckInDraft(
        id=req.draftId or "draft",
        weekStart=req.facts.weekStart,
        weekEnd=req.facts.weekEnd,
        answers=answers,
        photoSetId=None,
        sentAt=None,
    )


def _trim(lines: list[str]) -> str:
    while lines and lines[-1] == "":
        lines.pop()
    return "\n".join(lines)


def render_messages(
    template: CheckInTemplate, draft: CheckInDraft, adjustments: list[str] = (), deviations: list[str] = ()
) -> list[str]:
    """The check-in as the coach asked for it (HANDOFF.md §7, Check-in, step 6): two messages in his
    order. First the plan message, the carried blocks verbatim (macros, cardio, supplements); then
    the questionnaire, every field in his order as "Label (prompt): answer". Missing answers render
    as an empty value, never a guess. With no carried blocks there is only the questionnaire."""
    by_id = {a.fieldId: a for a in draft.answers}
    plan: list[str] = []
    for block in template.carriedBlocks:
        title = block.title.strip()
        text = block.text.strip()
        if text.startswith(title):
            plan.append(text)
        else:
            plan.append(f"{title}\n\n{text}" if title else text)
        plan.append("")
    form: list[str] = []
    for field in sorted(template.fields, key=lambda f: f.order):
        if field.source.type == "photo":
            continue
        label = field.label.strip()
        if field.prompt:
            label = f"{label} {field.prompt.strip()}"
        answer = by_id.get(field.id)
        value = answer.text.strip() if answer and answer.state != "missing" else ""
        form.append(f"{label}: {value}".rstrip())
        form.append("")
    # After his last field: the week's accepted suggestions, his rule applied, and any gym changes
    # (HANDOFF.md §7, Measured effort; Machine taken). Only what the athlete accepted or kept in.
    if adjustments:
        form.append("Adjustments (your rule): " + "; ".join(a.strip() for a in adjustments if a.strip()))
        form.append("")
    if deviations:
        form.append("Gym changes: " + " ".join(d.strip().rstrip(".") + "." for d in deviations if d.strip()))
        form.append("")
    messages = [_trim(plan), _trim(form)]
    return [m for m in messages if m]


def render(template: CheckInTemplate, draft: CheckInDraft) -> str:
    """Both messages as one text, for the screen and the clipboard fallback."""
    return "\n\n".join(render_messages(template, draft))
