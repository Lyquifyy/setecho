"""POST /session/turn/text and /session/turn: one thing the athlete said between sets, as a
conversation turn (HANDOFF.md §5, §7 Talk to it like a person).

Two layers, like /voice/command. The fast path is the rule layer for the few lines he says a
hundred times a session (arm phrases, "done" with or without a number, "that was N", "go with it",
"keep it", "undo", "flag that", and yes, no, a number or a choice answering an open ask): an
action with no reply, so the phone speaks its own template within a second. Everything else is a
turn with Muse Spark, which gets the session's facts and its last few exchanges and returns typed
actions (the existing intents), a short reply in a training partner's words, and whether the words
were meant for Setecho at all.

The validator checks every turn: each action's numbers appear in what he said, the facts or the
recent turns; the reply is 20 words or fewer, every number in it is in the facts or his words, and
it neither advises nor judges. Advice asked for gets the coach line and the note offer. A reply that
fails falls back to the rules' reading with the engine's template, else "Sorry, say that again?".
Setecho never coaches, and never changes the plan: actions go to the phone's engine, which applies
each one, confirms it in a template and can undo it.
"""

from __future__ import annotations

import json
import logging
import re
import time
from typing import Annotated, Literal

from fastapi import APIRouter, File, Form, UploadFile
from fastapi.concurrency import run_in_threadpool
from pydantic import Field

from app import audio, meta, voice
from app.schemas import StrictModel, strict_schema

router = APIRouter()
log = logging.getLogger(__name__)

MAX_REPLY_WORDS = 20
MAX_RECENT_TURNS = 8
COACH_LINE = "That's one for your coach. Want me to note it for Thursday?"
SAY_AGAIN = "Sorry, say that again?"

# What a turn may do: the engine's own intents. Questions are answered in the reply; out-of-scope is
# its own flag so the coach line and the note offer are never left to the model's wording.
ACTION_KINDS = tuple(k for k in voice.INTENTS if k not in ("chatter", "unknown", "question"))
ActionKind = Literal[*ACTION_KINDS]  # type: ignore[valid-type]

# The fast path: the rule layer's reading is used as is, with the engine's template as the reply.
FAST_INTENTS = {"starting", "topSet", "endSet", "reps", "acceptSuggestion", "keepLoad", "undo", "flagSet"}
# These only when they answer something the app asked (a bare number is a count either way).
FAST_WHEN_ASKED = {"yes", "no", "choose"}


class TurnError(ValueError):
    """A request this endpoint can't read: 422 with {"error": ...}."""


class Turn(StrictModel):
    heard: str = Field(description="What the athlete said")
    said: str | None = Field(default=None, description="What Setecho said back, if anything")


class SetFact(StrictModel):
    exercise: str
    setNumber: int
    role: str | None = None
    reps: int | None = None
    repSource: str | None = Field(default=None, description="measured, phone, spoken, plan, or counting")
    loadLb: float | None = None
    rpe: float | None = None
    estimatedRIR: float | None = None
    seconds: int | None = Field(default=None, description="A timed set: how long it ran")
    doneAs: str | None = Field(default=None, description="The variant done when the lift was swapped")
    minutesAgo: int | None = None


class ExerciseFact(StrictModel):
    name: str
    setsPlanned: int
    setsDone: int
    target: str | None = Field(default=None, description='"6-8 reps", "60 seconds", "20 total reps"')
    loadLb: float | None = Field(default=None, description="Today's load for its next set, if known")
    lastTime: str | None = Field(default=None, description='"145 for 9", from the log or his logbook')
    sheetNote: str | None = Field(default=None, description="The coach's note on his sheet, verbatim")
    alternates: list[str] = Field(default_factory=list, description="The coach's own options")
    addOn: str | None = Field(default=None, description="The add-on it belongs to, if any")


class SessionFacts(StrictModel):
    """Computed on the phone from the plan and the log. Every number a reply may use is here."""

    day: str | None = None
    state: str = Field(description="ready, recording, rest, leadIn, hold, paused")
    exercise: str | None = Field(default=None, description="The lift up now")
    setNumber: int | None = None
    setCount: int | None = None
    targetLoadLb: float | None = None
    targetReps: str | None = None
    restLeft: str | None = Field(default=None, description='"1:40" while resting')
    openAsk: str | None = Field(default=None, description="The question Setecho asked and is waiting on")
    exercises: list[ExerciseFact] = Field(default_factory=list, description="Today's plan in order")
    sets: list[SetFact] = Field(default_factory=list, description="Every set logged this session")
    rules: list[str] = Field(default_factory=list, description="His confirmed rules, in his coach's words")
    addOns: list[str] = Field(default_factory=list, description="Add-ons he can add or skip today")
    takenOptions: list[str] = Field(default_factory=list, description="Machine taken: his options offered")
    athleteName: str | None = None


class TurnRequest(StrictModel):
    transcript: str
    state: str = Field(description="The engine's state; recording means only set commands count")
    recentTurns: list[Turn] = Field(default_factory=list)
    facts: SessionFacts


class TurnResponse(StrictModel):
    transcript: str
    actions: list[voice.VoiceIntent]
    reply: str | None = Field(default=None, description="Spoken at once; null means the engine's templates")
    expectsAnswer: bool = False
    addressed: bool = True
    classifiedBy: str = Field(description="rules, spark, or fallback")
    unclearReason: str | None = Field(default=None, description="Why the model's turn was not used")
    timings: dict[str, float] = Field(default_factory=dict)


class SparkAction(StrictModel):
    intent: ActionKind = Field(description="One of the engine's actions; never chatter, unknown or question")
    number: float | None = Field(
        default=None,
        description="Pounds for loads, a count for reps, an RPE, a day number, 1 or 2 for choose",
    )
    reps: int | None = Field(
        default=None, description='The count when a load and a count are said together ("145 for 9")'
    )
    setNumber: int | None = Field(default=None, description="A set he named; else null")
    text: str | None = Field(
        default=None, description="The note, the exercise or add-on, or the swap, in his words"
    )


class SparkTurn(StrictModel):
    addressed: bool = Field(
        description="False when the words were not meant for Setecho: talk to someone else, music, half-heard words"
    )
    actions: list[SparkAction] = Field(
        description="Everything to do, in the order he said it; empty for a question or chat"
    )
    reply: str = Field(
        description="What a training partner would say back: 20 words or fewer; empty when not addressed"
    )
    expectsAnswer: bool = Field(description="The reply asks him something")
    outOfScope: bool = Field(
        description="He asked for advice on form, food, programming, pain or what weight to use"
    )


SPARK_SCHEMA = strict_schema(SparkTurn)

SYSTEM = (
    "You are Setecho, the voice in a lifter's ear between sets, like a training partner who keeps his log. "
    "You are not his coach. The user message has today's facts (the plan, where he is, every set logged, "
    "the rest left, the question you are waiting on, last time's numbers, his coach's rules and sheet notes), "
    "your last few exchanges, and what he just said. The phone hears everything, so first decide whether it "
    "was meant for you. Talk to someone else, music, half-heard words, exclamations: addressed false, no "
    "actions, empty reply.\n"
    "Actions are the app's own: starting (he's about to lift), endSet (a set just ended, number = reps if he "
    "said them), reps (a count for a set: setNumber when he names one, else the last set), rpe (only with "
    "'felt like', 'RPE' or 'out of ten'), setLoad (pounds), loadDelta (+/- pounds), acceptSuggestion, "
    "keepLoad, undo, note (a remark for his coach, his words in text), flagSet (the last set's video for his "
    "coach), skipSet, nextExercise, skipExercise (text = the name), addAddOn / skipAddOn (text = the name), "
    "changeDay (number = day), equipmentTaken (text = what's taken, as he said it), swapTo (text = what he's "
    "doing instead), equipmentFree, choose (1 = the first option, 2 = the other, text 'wait'), yes / no "
    "(answering your question), answer (a number answering your question), logbook (last time's top set: "
    "number = load, reps), topSet, warmup, pause, resume, replayCue, endSession (he's finished for the day; "
    "the app asks first). One utterance can carry several actions, in order: 'that was 9, and the incline's "
    "taken' is reps 9 then equipmentTaken. Use the recent exchanges for follow-ups: 'same as last set' takes "
    "the number from the facts, 'actually make it 140' corrects what was just set.\n"
    "Numbers: never invent one. Every number in an action or the reply must be in his words or the facts. "
    "A bare number is a rep count; his coach uses no RPE.\n"
    "The reply: what a friend spotting him would say back, 20 words or fewer, plain and short. Confirm what "
    "you did in plain words ('Nine on set two.', 'Swapped to dumbbells. Noted for Thursday.'). Answer "
    "questions from the facts only ('One forty left.', 'Last time 145 for 9.'). When unsure, ask a real "
    "question ('Was that nine reps, or how hard it felt?') and set expectsAnswer. Never judge a set or his "
    "numbers, never praise or criticise. Never advise on form, food, pain, programming or what weight to use: "
    "set outOfScope and leave the reply empty. Use his first name rarely."
)

_ADVICE = re.compile(
    r"\b(you should|you need to|you'?ll want to|try to|try (going|adding|dropping)|i'?d (recommend|suggest|go)|"
    r"recommend|suggest|make sure|aim for|go heavier|go lighter|add (more )?weight|drop the weight|eat|"
    r"carbs|protein|calories|diet|form|elbows|knees|back straight|brace|slow down|speed up|lock out|"
    r"ice it|stretch|rest it|see a doctor|deload)\b",
    re.IGNORECASE,
)
_JUDGING = re.compile(
    r"\b(great|good|nice|solid|strong|weak|bad|poor|easy|terrible|ugly|sloppy|heavy|light) "
    r"(set|lift|rep|reps|job|work|one|effort|press|pull|squat|session)\b"
    r"|\b(awesome|amazing|impressive|crushed it|killed it|well done|beast|proud of you|disappointing|lazy)\b",
    re.IGNORECASE,
)
_NUMBER = re.compile(r"\d+(?:[.:]\d+)?")
_SPOKEN_SMALL = {
    "zero": 0, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8,
    "nine": 9, "ten": 10, "eleven": 11, "twelve": 12, "thirteen": 13, "fourteen": 14, "fifteen": 15,
    "sixteen": 16, "seventeen": 17, "eighteen": 18, "nineteen": 19, "twenty": 20, "thirty": 30,
    "forty": 40, "fifty": 50, "sixty": 60, "seventy": 70, "eighty": 80, "ninety": 90,
}  # fmt: skip


# ---------------------------------------------------------------------------
# Numbers the turn may use
# ---------------------------------------------------------------------------


def numbers_in(text: str, *, parts: bool = False) -> set[float]:
    """Every number written in `text`: digits ("225", "9.5"), clock times ("1:40" is 1:40, 100
    seconds, or "one forty"), and runs of spoken words read as one number ("two twenty five" is
    225). With `parts`, each number word on its own too: what the facts allow is read generously,
    what a reply says is read as said."""
    found: set[float] = set()
    for m in _NUMBER.finditer(text):
        token = m.group()
        if ":" in token:
            minutes, seconds = (float(x) for x in token.split(":", 1))
            found.update({minutes, seconds, minutes * 60 + seconds, minutes * 100 + seconds})
        else:
            found.add(float(token))
    words = re.findall(r"[a-z]+", text.lower())
    if parts:
        found.update(float(_SPOKEN_SMALL[w]) for w in words if w in _SPOKEN_SMALL)
    run: list[str] = []
    for w in [*words, "."]:
        if w in _SPOKEN_SMALL or (w in ("hundred", "and", "a", "half", "point") and run):
            run.append(w)
            continue
        while run and run[-1] in ("and", "a", "point"):
            run.pop()
        if run and (value := voice.parse_number(" ".join(run))) is not None:
            found.add(float(value))
        run = []
    return found


def known_numbers(facts: SessionFacts, transcript: str, recent: list[Turn]) -> set[float]:
    """What a turn may say: anything in the facts, his words now, or the recent exchanges."""
    text = json.dumps(facts.model_dump(exclude_none=True)) + " " + transcript
    text += " " + " ".join(f"{t.heard} {t.said or ''}" for t in recent)
    known = numbers_in(text, parts=True)
    # Plain speech counts small things ("two more", "the other one", "set three") and every set
    # number up to the plan's; nothing that could pass for a load or a count of reps.
    known.update(float(n) for n in range(6))
    if facts.setCount:
        known.update(float(n) for n in range(1, facts.setCount + 1))
    return known


def _is_known(value: float, known: set[float]) -> bool:
    return any(abs(value - k) < 1e-6 for k in known)


# ---------------------------------------------------------------------------
# Validation
# ---------------------------------------------------------------------------


def check_reply(reply: str, known: set[float]) -> str | None:
    """Why the reply can't be spoken, or None."""
    line = reply.strip()
    if not line:
        return "empty"
    if len(line.split()) > MAX_REPLY_WORDS:
        return "too long"
    if _ADVICE.search(line):
        return "advice"
    if _JUDGING.search(line):
        return "judging"
    for value in numbers_in(line):
        if not _is_known(value, known):
            return f"number {value:g}"
    return None


COUNT_INTENTS = ("reps", "endSet", "answer", "rpe")


def check_action(action: SparkAction, known: set[float], said: set[float]) -> str | None:
    """A count is what he said (now or in the last exchanges), never a number from the plan."""
    for field in ("number", "reps", "setNumber"):
        value = getattr(action, field)
        if value is None:
            continue
        allowed = said if field == "reps" or (field == "number" and action.intent in COUNT_INTENTS) else known
        if not _is_known(float(value), allowed):
            return f"{action.intent} {field} {value:g}"
    if (
        action.intent in ("note", "swapTo", "skipExercise", "addAddOn", "skipAddOn")
        and not (action.text or "").strip()
    ):
        return f"{action.intent} without text"
    return None


def to_intent(action: SparkAction) -> voice.VoiceIntent:
    return voice.intent(
        action.intent,
        action.number,
        confidence=0.9,
        reps=action.reps,
        setNumber=action.setNumber,
        text=action.text,
    )


def out_of_scope_turn(transcript: str, actions: list[voice.VoiceIntent]) -> TurnResponse:
    """Advice he asked for: the coach line, and the engine's note offer so a yes notes it."""
    offer = voice.intent("question", topic="outOfScope", confidence=0.9)
    return TurnResponse(
        transcript=transcript, actions=[*actions, offer], reply=COACH_LINE, expectsAnswer=True,
        addressed=True, classifiedBy="spark",
    )  # fmt: skip


def validated(spark: SparkTurn, req: TurnRequest) -> TurnResponse:
    """The model's turn, checked. Anything that fails falls back to the rules or a plain re-ask."""
    transcript = req.transcript
    if not spark.addressed:
        return TurnResponse(transcript=transcript, actions=[], addressed=False, classifiedBy="spark")
    recent = req.recentTurns[-MAX_RECENT_TURNS:]
    known = known_numbers(req.facts, transcript, recent)
    said = numbers_in(" ".join([transcript, *(t.heard for t in recent)]), parts=True)
    actions: list[voice.VoiceIntent] = []
    for action in spark.actions:
        if action.intent not in ACTION_KINDS:
            continue
        if (why := check_action(action, known, said)) is not None:
            return fallback(req, f"action: {why}")
        actions.append(to_intent(action))
    if spark.outOfScope:
        return out_of_scope_turn(transcript, actions)
    reply = spark.reply.strip()
    if reply and (why := check_reply(reply, known)) is not None:
        if why == "advice":
            return out_of_scope_turn(transcript, actions)
        if actions:
            # The actions stand; the engine's templates confirm them.
            return TurnResponse(
                transcript=transcript, actions=actions, reply=None, addressed=True, classifiedBy="spark",
                unclearReason=f"reply: {why}",
            )  # fmt: skip
        return fallback(req, f"reply: {why}")
    if not actions and not reply:
        return fallback(req, "empty")
    return TurnResponse(
        transcript=transcript, actions=actions, reply=reply or None, expectsAnswer=spark.expectsAnswer and bool(reply),
        addressed=True, classifiedBy="spark",
    )  # fmt: skip


def fallback(req: TurnRequest, why: str) -> TurnResponse:
    """The rule layer's full reading with the engine's template, else a plain re-ask."""
    context = context_for(req)
    ruled = voice.classify_by_rules(req.transcript, context)
    if ruled is not None and ruled.intent not in ("chatter", "unknown"):
        return TurnResponse(
            transcript=req.transcript, actions=[ruled], reply=None, classifiedBy="fallback", unclearReason=why
        )
    return TurnResponse(
        transcript=req.transcript, actions=[], reply=SAY_AGAIN, expectsAnswer=True, classifiedBy="fallback",
        unclearReason=why,
    )  # fmt: skip


# ---------------------------------------------------------------------------
# The turn
# ---------------------------------------------------------------------------


def context_for(req: TurnRequest) -> voice.SessionContext:
    f = req.facts
    return voice.SessionContext(
        state=req.state,
        exerciseName=f.exercise,
        setIndex=f.setNumber,
        setCount=f.setCount,
        plannedLoadLb=f.targetLoadLb,
        pendingAsk=f.openAsk,
        lastSpoken=req.recentTurns[-1].said if req.recentTurns else None,
        exercisesAhead=[e.name for e in f.exercises if e.setsDone < e.setsPlanned],
        addOnNames=f.addOns,
    )


def fast_path(req: TurnRequest) -> voice.VoiceIntent | None:
    """The rule layer's reading when it is one of the instant lines, else None."""
    ruled = voice.classify_by_rules(req.transcript, context_for(req))
    if ruled is None:
        return None
    if ruled.intent in FAST_INTENTS:
        # "Twelve on those, I'm done" reads as a bare "done": a number the rules dropped means Spark reads it.
        dropped = (
            ruled.number is None and ruled.intent not in ("starting", "topSet") and numbers_in(req.transcript)
        )
        return None if dropped else ruled
    if ruled.intent == "answer":  # a bare number: a count, or the answer to what was asked
        return ruled
    if ruled.intent in FAST_WHEN_ASKED and req.facts.openAsk:
        return ruled
    if ruled.intent == "chatter":
        return ruled  # "let's go", "ugh, that was brutal": not for Setecho, nothing said
    if ruled.intent == "question" and ruled.topic == "help":
        return ruled  # "what can I say?": the phone's guide for this moment, a template
    return None


def spark_turn(req: TurnRequest) -> SparkTurn:
    recent = req.recentTurns[-MAX_RECENT_TURNS:]
    lines = [f"He: {t.heard}" + (f"\nYou: {t.said}" if t.said else "") for t in recent]
    user = (
        f"Facts: {json.dumps(req.facts.model_dump(exclude_none=True), separators=(',', ':'))}\n"
        f"Recent exchanges:\n{chr(10).join(lines) or '(none yet)'}\n"
        f"He just said: {req.transcript!r}"
    )
    raw, _ = meta.spark_json(SYSTEM, user, "SessionTurn", SPARK_SCHEMA, effort="low")
    return SparkTurn.model_validate(raw)


def take_turn(req: TurnRequest) -> TurnResponse:
    """One utterance: the fast path, the set-time gate, then a Spark turn with its validator."""
    transcript = req.transcript.strip()
    if not transcript or not re.search(r"[a-z0-9]", transcript.lower()):
        return TurnResponse(transcript=transcript, actions=[], addressed=False, classifiedBy="rules")
    if req.state == "recording":
        # During a set only the rules' set commands count; Spark is never called.
        ruled, _ = voice.route(transcript, context_for(req))
        if ruled.intent in voice.SET_COMMANDS:
            return TurnResponse(transcript=transcript, actions=[ruled], classifiedBy="rules")
        return TurnResponse(transcript=transcript, actions=[], addressed=False, classifiedBy="rules")
    if (fast := fast_path(req)) is not None:
        if fast.intent == "chatter":
            return TurnResponse(transcript=transcript, actions=[], addressed=False, classifiedBy="rules")
        return TurnResponse(transcript=transcript, actions=[fast], classifiedBy="rules")
    t0 = time.monotonic()
    try:
        spark = spark_turn(req)
    except Exception as e:  # noqa: BLE001 - a slow or failed model call falls back to the rules
        log.info("session turn: spark failed: %s", e)
        out = fallback(req, f"model: {type(e).__name__}")
        out.timings["spark"] = round(time.monotonic() - t0, 2)
        return out
    out = validated(spark, req)
    out.timings["spark"] = round(time.monotonic() - t0, 2)
    return out


@router.post("/session/turn/text", response_model=TurnResponse)
async def session_turn_text(req: TurnRequest) -> TurnResponse:
    """The realtime stream's words for one utterance -> actions and a reply (HANDOFF.md §5)."""
    return await run_in_threadpool(take_turn, req)


@router.post("/session/turn", response_model=TurnResponse)
async def session_turn_audio(
    audio_file: Annotated[UploadFile, File(alias="audio")],
    request: Annotated[str, Form()],
) -> TurnResponse:
    """The fallback when the stream had no words: the utterance's WAV, transcribed, then the same turn.
    `request` is the TurnRequest JSON with an empty transcript."""
    req = TurnRequest.model_validate_json(request)
    wav = await audio_file.read()
    try:
        audio.check_transcribe_wav(wav)
    except ValueError as e:
        raise TurnError(str(e)) from e
    t0 = time.monotonic()
    result = await run_in_threadpool(meta.transcribe_wav, wav)
    transcribed = round(time.monotonic() - t0, 2)
    out = await run_in_threadpool(
        take_turn, req.model_copy(update={"transcript": str(result.get("transcript", ""))})
    )
    out.timings["transcribe"] = transcribed
    return out
