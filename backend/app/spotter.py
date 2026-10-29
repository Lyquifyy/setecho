"""POST /spotter/line: one spoken line for a moment when speed doesn't matter, mainly the rest after
a set (HANDOFF.md §5, §7 The spotter voice). Muse Spark puts computed facts into words; a validator
checks every line: every number comes from the facts, nothing beyond the suggestion it was given,
no advice, no opening shared with a recent line. A line that fails falls back to the phone's template.
"""

from __future__ import annotations

import re
from typing import Literal

from fastapi import APIRouter
from fastapi.concurrency import run_in_threadpool
from pydantic import Field

from app import meta
from app.schemas import StrictModel, strict_schema

router = APIRouter()

Moment = Literal["restAfterSet", "exerciseStart", "sessionEnd", "reaction"]
MAX_WORDS = 30

_ADVICE = re.compile(
    r"\b(you should|you need to|try to|i'?d recommend|recommend|make sure|aim for|next time (go|try|add|drop)|"
    r"go heavier|go lighter|add (more )?weight|drop (the )?weight|eat|carbs|protein|form|elbows|knees|back straight|"
    r"tempo|slow down|speed up|lock out)\b",
    re.IGNORECASE,
)
_NUMBER = re.compile(r"\d+(?:[.,]\d+)?")
_WORDS = {
    "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8, "nine": 9, "ten": 10,
    "eleven": 11, "twelve": 12, "thirteen": 13, "fourteen": 14, "fifteen": 15, "sixteen": 16, "seventeen": 17,
    "eighteen": 18, "nineteen": 19, "twenty": 20, "thirty": 30, "forty": 40, "fifty": 50, "sixty": 60,
    "seventy": 70, "eighty": 80, "ninety": 90, "hundred": 100,
}  # fmt: skip


class SpotterFacts(StrictModel):
    """Computed on the phone, never by the model. Every number the line may use is here."""

    exercise: str
    setNumber: int
    setCount: int
    reps: int | None = None
    repSource: str | None = Field(default=None, description="measured, phone, spoken or plan")
    loadLb: float | None = None
    velocityLossPct: float | None = None
    estimatedRIR: float | None = Field(
        default=None, description="Reps left by the measure; always 'estimated'"
    )
    target: str | None = Field(
        default=None, description='His target in words: "failure", "RPE 8", "6-8 reps"'
    )
    suggestionLb: float | None = Field(default=None, description="The next load his rule suggests, if any")
    suggestionRule: str | None = Field(default=None, description="His rule in a few words")
    isPR: bool = False
    streak: int | None = Field(default=None, description="Sets in a row at the top of the range")
    lastTimeLoadLb: float | None = None
    lastTimeReps: int | None = None
    sessionSets: int | None = None
    role: str | None = Field(default=None, description="top, backOff, restPause, warmup or null")


class LineRequest(StrictModel):
    moment: Moment
    facts: SpotterFacts
    recent: list[str] = Field(default_factory=list, description="The last lines spoken this session")
    styleHints: list[str] = Field(default_factory=list, description='e.g. "first name: Zander", "casual"')


class LineOut(StrictModel):
    text: str = Field(description="One or two short sentences, at most 30 words, like a training partner")


class LineResponse(StrictModel):
    text: str
    ok: bool = Field(
        default=True, description="False when the model's line failed the validator and text is empty"
    )


LINE_SCHEMA = strict_schema(LineOut)

SYSTEM = (
    "You're the voice of a training partner spotting an athlete between sets. You are not his coach: "
    "never give advice about form, food or programming, and never suggest a weight other than the one "
    "in the facts. Say one or two short, natural sentences, at most 30 words, the way a friend at the gym "
    "would. Use only the numbers in the facts, and only the facts given; say nothing about a suggestion "
    "unless the facts carry one, and then only its load and his rule. Don't start the way any recent line "
    "started. Use his first name sparingly."
)


def known_numbers(facts: SpotterFacts) -> set[str]:
    values: set[str] = set()

    def add(n: float | None) -> None:
        if n is None:
            return
        f = float(n)
        values.add(str(int(f)) if f.is_integer() else f"{f:.1f}")
        values.add(str(round(f)))
        values.add(f"{f:.1f}")
        values.add(f"{f:.2f}")
        values.add(str(int(f)))

    for n in (
        facts.setNumber, facts.setCount, facts.reps, facts.loadLb, facts.velocityLossPct, facts.estimatedRIR,
        facts.suggestionLb, facts.streak, facts.lastTimeLoadLb, facts.lastTimeReps, facts.sessionSets,
    ):  # fmt: skip
        add(n)
    if facts.target:
        for m in _NUMBER.finditer(facts.target):
            add(float(m.group().replace(",", ".")))
    if facts.suggestionRule:
        for m in _NUMBER.finditer(facts.suggestionRule):
            add(float(m.group().replace(",", ".")))
    for n in (1, 2, 3, 4, 5, 10):  # small counts in plain speech ("two more", "last 3")
        add(n)
    return values


def opening(text: str, words: int = 2) -> str:
    return " ".join(re.findall(r"[a-z']+", text.lower())[:words])


def validate(text: str, facts: SpotterFacts, recent: list[str]) -> str | None:
    """Why the line fails, or None when it passes."""
    line = text.strip()
    if not line:
        return "empty"
    if len(line.split()) > MAX_WORDS:
        return "too long"
    if _ADVICE.search(line):
        return "advice"
    known = known_numbers(facts)
    for m in _NUMBER.finditer(line):
        token = m.group().replace(",", ".")
        try:
            value = float(token)
        except ValueError:
            return f"number {token}"
        if not {token, str(int(value)) if value.is_integer() else token, f"{value:.1f}"} & known:
            return f"number {token}"
    for word in re.findall(r"[a-z]+", line.lower()):
        if (value := _WORDS.get(word)) is not None and str(value) not in known:
            return f"number {value}"
    if facts.suggestionLb is None and re.search(r"\b(next (set|time)) (at|try|go)\b", line, re.IGNORECASE):
        return "suggestion the facts don't carry"
    if (start := opening(line)) and any(opening(r) == start for r in recent if r.strip()):
        return "repeats an opening"
    return None


# Talkative spotter (Oct 29): the facts were just said by the app; Spark adds the human part.
REACTION = (
    "The app has just said this set's count, load and what's next out loud. Add one short reaction, at "
    "most 20 words, the way a friend spotting him would: how it compares with last time (more or fewer reps, "
    "the same weight or heavier), a PR, a streak, or how hard it looked by the measure. Don't repeat the "
    "count unless you compare it, don't say what's next, and don't ask a question."
)


def write_line(req: LineRequest) -> LineResponse:
    facts = req.facts.model_dump(exclude_none=True)
    moment = f"{req.moment}. {REACTION}" if req.moment == "reaction" else req.moment
    user = (
        f"Moment: {moment}\n"
        f"Facts: {facts}\n"
        f"Lines you said recently: {req.recent[-5:] or '(none)'}\n"
        f"Style: {', '.join(req.styleHints) or 'casual'}"
    )
    raw, _ = meta.spark_json(SYSTEM, user, "SpotterLine", LINE_SCHEMA, effort="low")
    text = str(raw.get("text", "")).strip()
    if validate(text, req.facts, req.recent[-5:]) is not None:
        return LineResponse(text="", ok=False)
    return LineResponse(text=text, ok=True)


@router.post("/spotter/line", response_model=LineResponse)
async def spotter_line(req: LineRequest) -> LineResponse:
    """One rest-time line from the facts. `ok` false means the phone speaks its template instead."""
    return await run_in_threadpool(write_line, req)
