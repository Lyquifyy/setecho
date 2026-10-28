"""POST /checkin/turn: one spoken turn of Check-in morning (HANDOFF.md §5, §7).

Transcribe the utterance, let Muse Spark read it against the field just asked and the fields still
pending, then check every number against the transcript. Spark understands; code decides: the
backend never picks the next question, and a turn that fails any check becomes `unclear`.
"""

from __future__ import annotations

import json
import re
import time
from typing import Annotated, Literal

from fastapi import APIRouter, File, Form, UploadFile
from fastapi.concurrency import run_in_threadpool
from pydantic import Field

from app import audio, checkin, importing, meta, voice
from app.checkin_api import Measurements, _fmt_in
from app.schemas import CheckInTemplate, FieldSpec, StrictModel, strict_schema

router = APIRouter()

TurnIntent = Literal[
    "answer", "correction", "pause", "resume", "skip", "goBack", "repeat", "forCoach", "ready", "chitchat", "unclear"
]  # fmt: skip
INTENTS: tuple[str, ...] = TurnIntent.__args__  # type: ignore[attr-defined]

MAX_REPLY_WORDS = 20
UNCLEAR_REPLY = "Sorry, say that again?"

# The reply must never advise. A short blocklist backs the prompt (HANDOFF.md §5, step 5).
_ADVICE = re.compile(
    r"\b(you should|you need to|try to|i'?d recommend|recommend|my advice|make sure|aim for|"
    r"increase your|decrease your|cut your|bump your|drop your|more protein|more carbs|less carbs|"
    r"eat more|eat less|you could|consider)\b",
    re.IGNORECASE,
)


class TurnContext(StrictModel):
    template: CheckInTemplate
    step: str = Field(description="weight, glucose, photos, questions or review")
    askedFieldId: str | None = Field(default=None, description="The field whose question was just asked")
    pending: list[str] = Field(default_factory=list, description="Field ids still to answer, in his order")
    answered: list[checkin.FieldAnswer] = Field(default_factory=list)
    styleExamples: list[str] = Field(default_factory=list)
    askedOn: str | None = Field(default=None, description="yyyy-mm-dd, for the provenance")


class TurnAnswerOut(StrictModel):
    fieldId: str
    text: str = Field(description="The answer as the athlete would type it; their words, filler removed")
    number: float | None = Field(
        default=None, description="The number they said for a number, scale or weight field"
    )
    measurements: Measurements | None = Field(
        default=None, description="Only when several tape measurements were given"
    )


class TurnOut(StrictModel):
    intent: TurnIntent
    answers: list[TurnAnswerOut] = Field(default_factory=list)
    reply: str = Field(description="One short, friendly, casual sentence; never advice")
    confidence: float


class TurnResponse(StrictModel):
    transcript: str
    intent: TurnIntent
    answers: list[checkin.FieldAnswer]
    reply: str
    confidence: float
    timings: dict[str, float] = Field(
        default_factory=dict, description="Seconds per stage: transcribe, spark, validate"
    )
    fastPath: bool = Field(default=False, description="Code answered a plain number; Spark was not called")


SYSTEM = (
    "You are the voice of a check-in app, talking with an athlete on check-in morning. You are not "
    "their coach: never give advice about training, food, weight, recovery or posing. The user message "
    "gives the question just asked, the fields still to answer, the fields already answered, and what "
    "the athlete said. Return the intent, any answers (the field id plus the number or words they used), "
    "and a reply of one short, friendly, casual sentence. Use only numbers the athlete said. One "
    'utterance can answer several fields ("180.8, and glucose was 91"). A correction names a field '
    'already answered ("wait, it was 180.6"). pause is "give me a couple of minutes"; resume is "I\'m '
    'back"; ready is "ready" or "I\'m off the scale"; repeat is "say that again"; forCoach is a question '
    'meant for the coach ("should I bump my carbs?"): say it\'s one for their coach and offer to add it '
    "to their notes, with their question in `text` for the notes field. If they need a minute, tell them "
    'to take their time. For a scale field write the text as "N/10" plus anything they added; for tape '
    "measurements fill `measurements` in the order asked. Never move to another question yourself, and "
    "never answer a field they did not speak to."
)


def schema_for(field_ids: list[str]) -> dict:
    """The strict schema with `fieldId` as a per-request enum, so the model can't invent a field."""
    schema = strict_schema(TurnOut)
    enum = sorted(set(field_ids)) or ["none"]
    schema["properties"]["answers"]["items"]["properties"]["fieldId"]["enum"] = enum
    return schema


# ---------------------------------------------------------------------------
# The validator
# ---------------------------------------------------------------------------


def spoken_numbers(transcript: str) -> set[float]:
    """Every number the athlete said: digits, and number words in each spoken chunk."""
    found: set[float] = set()
    for m in re.finditer(r"\d+(?:\.\d+)?", transcript):
        found.add(float(m.group()))
    lowered = transcript.lower()
    chunks = [lowered]
    chunks += re.split(r"[,;?!]|\.(?!\d)", lowered)  # punctuation, but not a decimal point
    chunks += re.split(r"[,;?!]|\.(?!\d)|\band\b(?!\s+(?:a\s+)?(?:half|quarter|three))|\bthen\b", lowered)
    for chunk in chunks:
        if not chunk or not chunk.strip():
            continue
        n = voice.parse_number(chunk)
        if n is not None:
            found.add(float(n))
    return found


def _number_is_spoken(value: float, said: set[float]) -> bool:
    return any(abs(value - s) < 0.001 for s in said)


def _text_numbers(text: str) -> list[float]:
    return [float(m.group()) for m in re.finditer(r"\d+(?:\.\d+)?", text.replace("/10", ""))]


def validate_turn(out: TurnOut, transcript: str, context: TurnContext) -> TurnResponse:
    """Every number in the answers and the reply appears in the transcript; every fieldId exists;
    the reply is short and gives no advice. Anything else is `unclear` (HANDOFF.md §5)."""
    said = spoken_numbers(transcript)
    fields = {f.id: f for f in context.template.fields}
    when = f"You said · {checkin._mdy(context.askedOn)}" if context.askedOn else "You said"

    def unclear() -> TurnResponse:
        return TurnResponse(
            transcript=transcript, intent="unclear", answers=[], reply=UNCLEAR_REPLY, confidence=0.0
        )

    if len(out.reply.split()) > MAX_REPLY_WORDS or _ADVICE.search(out.reply):
        return unclear()
    if any(not _number_is_spoken(n, said) for n in _text_numbers(out.reply)):
        return unclear()

    answers: list[checkin.FieldAnswer] = []
    for a in out.answers:
        spec = fields.get(a.fieldId)
        if spec is None:
            return unclear()
        if a.number is not None and not _number_is_spoken(a.number, said):
            return unclear()
        if a.measurements is not None:
            values = [a.measurements.waistIn, a.measurements.bicepIn, a.measurements.thighIn]
            if any(v is not None and not _number_is_spoken(v, said) for v in values):
                return unclear()
        if any(not _number_is_spoken(n, said) for n in _text_numbers(a.text)):
            return unclear()
        answers.append(_answer(spec, a, transcript, when))

    if out.intent in ("answer", "correction") and not answers:
        return unclear()
    state_intent: TurnIntent = out.intent
    return TurnResponse(
        transcript=transcript,
        intent=state_intent,
        answers=answers,
        reply=out.reply.strip(),
        confidence=out.confidence,
    )


def _answer(spec: FieldSpec, a: TurnAnswerOut, transcript: str, when: str) -> checkin.FieldAnswer:
    """The field's text in the athlete's own style, as /checkin/answer writes it."""
    text = a.text.strip()
    tape = (
        spec.kind == "measurement" and "weight" not in spec.label.lower()
    )  # a body weight is never in inches
    if a.measurements is not None and tape:
        value = {
            "waist": a.measurements.waistIn,
            "bicep": a.measurements.bicepIn,
            "thigh": a.measurements.thighIn,
        }
        for part, v in value.items():
            if part in spec.label.lower() and v is not None:
                text = f"{_fmt_in(v)} in"
                break
    elif tape and a.number is not None and "in" not in text:
        text = f"{_fmt_in(a.number)} in"
    elif spec.kind == "scale10" and a.number is not None and "/10" not in text:
        text = f"{checkin._fmt(a.number)}/10" + (f", {text}" if text else "")
    elif a.number is not None and not text:
        text = checkin._fmt(a.number)
    return checkin.FieldAnswer(
        fieldId=spec.id,
        text=text,
        state="filled",
        provenance=[checkin.Provenance(source=when, detail=transcript)],
    )


# ---------------------------------------------------------------------------
# The number fast path (HANDOFF.md §9, block 1): a plain number for the field just asked
# ---------------------------------------------------------------------------

_FILLER = re.compile(
    r"\b(uh|um|it'?s|it was|was|about|like|around|roughly|pounds?|lbs?|lb|out of ten|out of 10|inches|inch|in|and a|"
    r"and|a|an|the|so|yeah|ok|okay|that'?s|i'?m at|i was|weight|glucose|is|at)\b",
    re.IGNORECASE,
)
_NUMBER_WORDS = (
    set(voice._UNITS) | set(voice._TENS) | {"hundred", "point", "half", "quarter", "quarters", "three"}
)


def _only_numbers(text: str) -> bool:
    cleaned = _FILLER.sub(" ", text.lower())
    cleaned = re.sub(r"[^\w.\s]", " ", cleaned)
    words = [w.strip(".,!?") for w in cleaned.split()]
    words = [w for w in words if w]
    return bool(words) and all(re.fullmatch(r"\d+(?:\.\d+)?", w) or w in _NUMBER_WORDS for w in words)


def fast_turn(transcript: str, context: TurnContext) -> TurnResponse | None:
    """A transcript that is only a number (or the three tape measurements) for the field just
    asked: code parses it and replies from a template. Everything else goes to Spark."""
    fields = {f.id: f for f in context.template.fields}
    asked = fields.get(context.askedFieldId or "")
    if asked is None or not _only_numbers(transcript):
        return None
    when = f"You said · {checkin._mdy(context.askedOn)}" if context.askedOn else "You said"
    chunks = [
        c
        for c in re.split(r"[,;]|\band\b(?!\s+(?:a\s+)?(?:half|quarter|three))", transcript.lower())
        if c.strip()
    ]
    numbers = [voice.parse_number(c) for c in chunks]
    numbers = [n for n in numbers if n is not None]
    if asked.kind == "measurement" and "weight" not in asked.label.lower():
        # The three tape measurements as one question: waist, bicep, thigh, in the order asked.
        tape = [asked] + [
            fields[i]
            for i in context.pending
            if i in fields and fields[i].kind == "measurement" and i != asked.id
        ]
        tape = tape[: len(numbers)]
        if not numbers:
            return None
        answers = [
            checkin.FieldAnswer(fieldId=f.id, text=f"{_fmt_in(n)} in", state="filled",
                                provenance=[checkin.Provenance(source=when, detail=transcript)])
            for f, n in zip(tape, numbers, strict=False)
        ]  # fmt: skip
        reply = (
            ", ".join(f"{_short(f.label)} {_fmt_in(n)}" for f, n in zip(tape, numbers, strict=False)) + "."
        )
        return TurnResponse(
            transcript=transcript,
            intent="answer",
            answers=answers,
            reply=reply,
            confidence=0.95,
            fastPath=True,
        )
    if len(numbers) != 1:
        return None
    n = numbers[0]
    if asked.kind == "scale10":
        if not 0 <= n <= 10:
            return None
        text = f"{checkin._fmt(n)}/10"
    else:
        text = checkin._fmt(n)
    answer = checkin.FieldAnswer(fieldId=asked.id, text=text, state="filled",
                                 provenance=[checkin.Provenance(source=when, detail=transcript)])  # fmt: skip
    return TurnResponse(transcript=transcript, intent="answer", answers=[answer], reply=f"{checkin._fmt(n)}, got it.",
                        confidence=0.95, fastPath=True)  # fmt: skip


def _short(label: str) -> str:
    lower = label.lower()
    for part in ("waist", "bicep", "thigh", "calf", "chest", "hips", "arm"):
        if part in lower:
            return part.capitalize()
    return label


# ---------------------------------------------------------------------------
# The call
# ---------------------------------------------------------------------------


def read_turn(transcript: str, context: TurnContext) -> TurnResponse:
    fields = {f.id: f for f in context.template.fields}
    asked = fields.get(context.askedFieldId or "")
    pending = [fields[i] for i in context.pending if i in fields]
    answered = [a for a in context.answered if a.fieldId in fields]
    field_ids = [f.id for f in pending] + [a.fieldId for a in answered] + ([asked.id] if asked else [])
    for extra in ("additional_notes", "notes"):  # the notes field forCoach appends to, by its usual slug
        for fid in fields:
            if extra in fid and fid not in field_ids:
                field_ids.append(fid)

    def line(f: FieldSpec) -> str:
        return f'- {f.id}: "{f.label}{" " + f.prompt if f.prompt else ""}" [{f.kind}]'

    examples = "\n".join(f"- {e}" for e in context.styleExamples) or "- (none)"
    user = (
        f"Step: {context.step}\n"
        f"Question just asked: {line(asked) if asked else '(none)'}\n"
        f"Fields still to answer:\n{chr(10).join(line(f) for f in pending) or '- (none)'}\n"
        f"Already answered:\n{chr(10).join(f'- {a.fieldId}: {a.text}' for a in answered) or '- (none)'}\n"
        f"Examples of how the athlete writes:\n{examples}\n"
        f"The athlete said: {transcript!r}"
    )
    t0 = time.monotonic()
    raw, _ = meta.spark_json(SYSTEM, user, "CheckInTurn", schema_for(field_ids), effort="low")
    spark_s = time.monotonic() - t0
    t1 = time.monotonic()
    out = TurnOut.model_validate(raw)
    response = validate_turn(out, transcript, context)
    response.timings = {"spark": round(spark_s, 3), "validate": round(time.monotonic() - t1, 3)}
    return response


class TextTurnRequest(StrictModel):
    """A turn whose words the realtime stream already produced: no audio, no Transcribe call."""

    transcript: str
    context: TurnContext


@router.post("/checkin/turn/text", response_model=TurnResponse)
async def checkin_turn_text(req: TextTurnRequest) -> TurnResponse:
    transcript = req.transcript.strip()
    if not transcript:
        return TurnResponse(
            transcript="",
            intent="unclear",
            answers=[],
            reply=UNCLEAR_REPLY,
            confidence=0.0,
            timings={"transcribe": 0.0},
        )
    if (fast := fast_turn(transcript, req.context)) is not None:
        fast.timings = {"transcribe": 0.0, "spark": 0.0, "validate": 0.0}
        return fast
    response = await run_in_threadpool(read_turn, transcript, req.context)
    response.timings = {"transcribe": 0.0, **response.timings}
    return response


@router.post("/checkin/turn", response_model=TurnResponse)
async def checkin_turn(
    audio_file: Annotated[UploadFile, File(alias="audio")],
    context: Annotated[str, Form()],
) -> TurnResponse:
    """One utterance (WAV) + the conversation's context -> intent, answers, a reply. The phone
    applies the answers, speaks the reply, and picks the next question itself."""
    ctx = TurnContext.model_validate_json(context)
    data = await audio_file.read()
    try:
        audio.check_transcribe_wav(data)
    except ValueError as e:
        raise importing.ImportError_(str(e)) from e
    t0 = time.monotonic()
    result = await run_in_threadpool(meta.transcribe_wav, data)
    transcribe_s = round(time.monotonic() - t0, 3)
    transcript = (result.get("transcript") or "").strip()
    if not transcript:
        return TurnResponse(transcript="", intent="unclear", answers=[], reply=UNCLEAR_REPLY, confidence=0.0,
                            timings={"transcribe": transcribe_s})  # fmt: skip
    if (fast := fast_turn(transcript, ctx)) is not None:
        fast.timings = {"transcribe": transcribe_s, "spark": 0.0, "validate": 0.0}
        return fast
    response = await run_in_threadpool(read_turn, transcript, ctx)
    response.timings = {"transcribe": transcribe_s, **response.timings}
    return response


def turn_context_json(context: TurnContext) -> str:
    """For the probes: the context as the phone sends it."""
    return json.dumps(context.model_dump(), separators=(",", ":"))
