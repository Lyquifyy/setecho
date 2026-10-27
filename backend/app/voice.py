"""Spoken commands during a session -> VoiceIntent (HANDOFF.md §5, §8).

Two layers. A rule layer handles the short, unambiguous commands the athlete says a hundred times
a session ("undo", "felt like a 9", "drop to 215") with no model round-trip, so the echo comes back
within the transcription's own latency. Anything the rules don't recognise goes to Muse Spark with
the session context. Numbers are never invented: the rules only return a number they parsed from
the words, and the app asks back on anything under 0.7 confidence.
"""

from __future__ import annotations

import re
from typing import Literal

from pydantic import Field

from app import meta
from app.schemas import StrictModel, strict_schema

Intent = Literal[
    "rpe",
    "reps",
    "setLoad",
    "loadDelta",
    "skipSet",
    "nextExercise",
    "note",
    "undo",
    "pause",
    "resume",
    "endSession",
    "starting",
    "endSet",
    "replayCue",
    "yes",
    "no",
    "answer",
    "topSet",
    "warmup",
    "addAddOn",
    "skipAddOn",
    "changeDay",
    "flagSet",
    "unknown",
]
INTENTS: tuple[str, ...] = Intent.__args__  # type: ignore[attr-defined]


class VoiceIntent(StrictModel):
    intent: Intent
    number: float | None = Field(
        default=None, description="Pounds for loads, a count for reps, the RPE value; else null"
    )
    text: str | None = Field(
        default=None, description="The note or answer text in the athlete's own words; else null"
    )
    fieldId: str | None = Field(
        default=None, description="The check-in field a note targets, when the athlete names one"
    )
    confidence: float = Field(description="0 to 1. Under 0.7 the app asks back instead of acting")


class SessionContext(StrictModel):
    state: str = Field(description="ready, recording, rest, listening, paused")
    exerciseName: str | None = None
    setIndex: int | None = Field(default=None, description="1-based set number")
    setCount: int | None = None
    plannedLoadLb: float | None = None
    plannedReps: int | None = None


VOICE_INTENT_SCHEMA = strict_schema(VoiceIntent)

SYSTEM_PROMPT = (
    "Classify one short spoken command from an athlete during a lifting session. The user message "
    "gives the session context, then the transcript. Map it to exactly one intent:\n"
    'rpe: how hard the set felt ("felt like a 9" is rpe 9). reps: a corrected rep count ("that was 7"). '
    'setLoad: a new load in pounds ("drop to 215", "go to 225"). loadDelta: a change in pounds '
    '("add 5" is +5, "take off 10" is -10). skipSet. nextExercise. starting: the set is about to begin. '
    "endSet: the set just finished. undo. pause. resume. endSession. note: something for the weekly check-in, "
    'with the text in `text` verbatim. replayCue: play the coach\'s cue again ("say that again"). yes / no: '
    "a plain answer to a question the app asked. answer: a reply with a number or words to a question the "
    'app asked. topSet: the next set is the top set ("top set", "this is my top set"), or the last set was '
    '("that was my top set"). warmup: the last set was only a warm-up ("that was a warm-up"). addAddOn / '
    'skipAddOn: do or skip today\'s add-on block ("add abs", "skip abs"), with its name in `text`. changeDay: '
    'the athlete is doing another cycle day today ("I\'m doing Day 5 today"), with the day number in `number`. '
    'flagSet: send the last set\'s video to the coach ("flag that", "send that one to coach"). unknown when '
    "unsure.\n"
    "Numbers are pounds for loads and counts for reps. Never invent a number: `number` holds only a value "
    "the athlete said. Keep `text` in the athlete's own words. Set confidence honestly; under 0.7 the app "
    "will ask the athlete to repeat."
)

# ---------------------------------------------------------------------------
# Numbers in words
# ---------------------------------------------------------------------------

_UNITS = {
    "zero": 0, "oh": 0, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7,
    "eight": 8, "nine": 9, "ten": 10, "eleven": 11, "twelve": 12, "thirteen": 13, "fourteen": 14,
    "fifteen": 15, "sixteen": 16, "seventeen": 17, "eighteen": 18, "nineteen": 19,
}  # fmt: skip
_TENS = {
    "twenty": 20,
    "thirty": 30,
    "forty": 40,
    "fifty": 50,
    "sixty": 60,
    "seventy": 70,
    "eighty": 80,
    "ninety": 90,
}
_FRACTIONS = {"half": 0.5, "quarter": 0.25, "quarters": 0.25}


def parse_number(text: str) -> float | None:
    """The first number in `text`, digits or words. "two fifteen" is 215, "two twenty five" is 225,
    "a hundred and eighty five" is 185, "twenty four and three quarters" is 24.75, "9.5" is 9.5."""
    if m := re.search(r"\d+(?:\.\d+)?", text):
        value = float(m.group())
        if re.search(rf"{re.escape(m.group())}\s+and\s+a\s+half", text):
            value += 0.5
        return value
    words = re.findall(r"[a-z]+", text.lower())
    groups: list[int] = []  # spoken chunks like "two", "fifteen", "twenty five"
    current: int | None = None
    fraction = 0.0
    i = 0
    while i < len(words):
        w = words[i]
        if w in _TENS:
            current = (current or 0) + _TENS[w]
            if i + 1 < len(words) and words[i + 1] in _UNITS and _UNITS[words[i + 1]] < 10:
                current += _UNITS[words[i + 1]]
                i += 1
            groups.append(current)
            current = None
        elif w in _UNITS:
            if w == "oh" and not groups:
                i += 1
                continue
            groups.append(_UNITS[w])
        elif w == "hundred":
            base = groups.pop() if groups else 1
            groups.append(base * 100)
            if i + 1 < len(words) and words[i + 1] == "and":
                i += 1
            if i + 1 < len(words) and (words[i + 1] in _UNITS or words[i + 1] in _TENS):
                # "a hundred and eighty five": fold the rest into this hundred
                rest, consumed = _small_number(words[i + 1 :])
                groups[-1] += rest
                i += consumed
        elif (
            w == "and"
            and i + 1 < len(words)
            and (words[i + 1] in ("a", "three") or words[i + 1] in _FRACTIONS)
        ):
            # "and a half", "and three quarters"
            tail = words[i + 1 : i + 4]
            if "half" in tail:
                fraction = 0.5
            elif "quarter" in tail or "quarters" in tail:
                fraction = 0.75 if "three" in tail else 0.25
            break
        elif w == "point" and i + 1 < len(words) and words[i + 1] in _UNITS:
            fraction = _UNITS[words[i + 1]] / 10
            i += 1
        elif groups:
            break
        i += 1
    if not groups:
        return None
    if len(groups) == 1:
        return groups[0] + fraction
    # "two fifteen" -> 215, "two twenty five" -> 225, "one eighty" -> 180
    if groups[0] < 10 and all(0 <= g < 100 for g in groups[1:]):
        value = groups[0] * 100 + groups[1]
        return float(value) + fraction
    return float(sum(groups)) + fraction


def _small_number(words: list[str]) -> tuple[int, int]:
    value, consumed = 0, 0
    for w in words[:2]:
        if w in _TENS:
            value += _TENS[w]
            consumed += 1
        elif w in _UNITS:
            value += _UNITS[w]
            consumed += 1
            break
        else:
            break
    return value, consumed


# ---------------------------------------------------------------------------
# Rules
# ---------------------------------------------------------------------------

_RULES: list[tuple[str, re.Pattern[str]]] = [
    ("undo", re.compile(r"\b(undo|scratch that|never ?mind|take that back)\b")),
    ("replayCue", re.compile(r"\b(say that again|repeat that|play (that|it) again|again please)\b")),
    ("yes", re.compile(r"^(yes|yeah|yep|yup|correct|right|sure|affirmative)( please)?$")),
    ("no", re.compile(r"^(no|nope|nah|negative|wrong)( thanks)?$")),
    ("pause", re.compile(r"\b(pause|hold on|wait)\b")),
    ("resume", re.compile(r"\b(resume|unpause|continue|keep going)\b")),
    (
        "endSession",
        re.compile(r"\b(end|finish|stop|done with)( the| this| my)? (session|workout)\b|\bi'?m done\b"),
    ),
    ("nextExercise", re.compile(r"\b(next|skip)( the| this)? (exercise|movement|lift)\b|\bnext exercise\b")),
    ("skipSet", re.compile(r"\bskip( this| that| the)? set\b|\bskip it\b")),
    (
        "endSet",
        re.compile(
            r"\b(end|done|finished|that'?s|stop)( the| this| that)? (set|rep)s?\b|\bset done\b|\bdone\b$"
        ),
    ),
    (
        "starting",
        re.compile(r"\b(starting|start(ing)? (the |this |my )?set|here we go|going now|next set)\b"),
    ),
    (
        "topSet",
        re.compile(r"\b(top set|this is (the|my) top set|that was (the|my) top set|going for the top set)\b"),
    ),
    (
        "warmup",
        re.compile(r"\b(that was (just |only )?(a |my )?warm[ -]?up|warm[ -]?up set|still warming up)\b"),
    ),
    (
        "flagSet",
        re.compile(
            r"\b(flag (that|it|this)( one)?|send (that|this)( one)? to (the )?coach|flag for (the )?coach)\b"
        ),
    ),
]
_ADD_ON = re.compile(
    r"^(?P<verb>add|do|include|skip|drop|no)\s+(the\s+)?(?P<name>[a-z][a-z ]{1,30}?)(\s+today)?$"
)
_CHANGE_DAY = re.compile(r"\b(doing|do|make it|switch to|change to|it'?s)\s+day\s+(?P<n>[\w]+)(\s+today)?\b")
_RPE = re.compile(
    r"\b(felt like|feels like|that was|that'?s|rpe|rated?)\s+(an?\s+)?(?P<n>[\w .]+?)(\s+(rpe|out of ten))?\s*$"
)
_REPS = re.compile(
    r"\b(that was|i got|got|only|did|just)\s+(?P<n>[\w ]+?)\s*(reps?|repetitions?)?\s*$|^(?P<m>[\w ]+?)\s+reps?$"
)
_SET_LOAD = re.compile(
    r"\b(drop|go|move|change|set( the)? (load|weight))\s+(it\s+)?(to|at)\s+(?P<n>[\w .]+?)(\s*(pounds?|lbs?))?\s*$"
)
_DELTA_UP = re.compile(
    r"\b(add|plus|up|go up|bump( it)? up|increase( by)?)\s+(?P<n>[\w .]+?)(\s*(pounds?|lbs?))?\s*$"
)
_DELTA_DOWN = re.compile(
    r"\b(take off|minus|down|go down|drop|back off|decrease( by)?|lower( by)?)\s+(?P<n>[\w .]+?)(\s*(pounds?|lbs?))?\s*$"
)
_NOTE = re.compile(
    r"^\s*(note|notes?)( for( the)? (check[ -]?in|coach))?\s*[:,]?\s*(?P<text>.+?)\.?\s*$", re.IGNORECASE
)
_FILLER = re.compile(r"\b(uh|um|setecho|hey)\b")


def normalize(transcript: str) -> str:
    t = transcript.lower().strip()
    t = re.sub(r"[^\w\s.'-]", " ", t)
    t = _FILLER.sub(" ", t)
    return re.sub(r"\s+", " ", t).strip(" .")


def classify_by_rules(transcript: str) -> VoiceIntent | None:
    """A VoiceIntent for the plain commands, else None so Spark can read it."""
    if m := _NOTE.match(transcript):
        # The note keeps the athlete's own words and casing.
        return VoiceIntent(
            intent="note", number=None, text=m.group("text").strip(), fieldId=None, confidence=0.9
        )
    t = normalize(transcript)
    if not t:
        return None
    for intent, pattern in _RULES:
        if pattern.search(t):
            return VoiceIntent(intent=intent, number=None, text=None, fieldId=None, confidence=0.95)
    if (m := _CHANGE_DAY.search(t)) and (n := parse_number(m.group("n"))) is not None:
        return VoiceIntent(intent="changeDay", number=n, text=None, fieldId=None, confidence=0.9)
    if (m := _ADD_ON.match(t)) and m.group("name") not in ("it", "that", "this", "set", "weight"):
        intent = "skipAddOn" if m.group("verb") in ("skip", "drop", "no") else "addAddOn"
        return VoiceIntent(
            intent=intent, number=None, text=m.group("name").strip(), fieldId=None, confidence=0.85
        )
    if (m := _SET_LOAD.search(t)) and (n := parse_number(m.group("n"))) is not None:
        return VoiceIntent(intent="setLoad", number=n, text=None, fieldId=None, confidence=0.9)
    if (m := _DELTA_UP.search(t)) and (n := parse_number(m.group("n"))) is not None:
        return VoiceIntent(intent="loadDelta", number=n, text=None, fieldId=None, confidence=0.9)
    if (m := _DELTA_DOWN.search(t)) and (n := parse_number(m.group("n"))) is not None:
        return VoiceIntent(intent="loadDelta", number=-n, text=None, fieldId=None, confidence=0.9)
    if ("rep" in t or re.search(r"\b(got|only|did)\b", t)) and (m := _REPS.search(t)):
        n = parse_number(m.group("n") or m.group("m") or "")
        if n is not None:
            return VoiceIntent(intent="reps", number=n, text=None, fieldId=None, confidence=0.9)
    if (m := _RPE.search(t)) and (n := parse_number(m.group("n"))) is not None and 1 <= n <= 10:
        return VoiceIntent(intent="rpe", number=n, text=None, fieldId=None, confidence=0.85)
    return None


# ---------------------------------------------------------------------------
# Spark fallback
# ---------------------------------------------------------------------------


def classify_with_spark(transcript: str, context: SessionContext) -> VoiceIntent:
    user = (
        f"Context: state {context.state}; exercise {context.exerciseName or 'unknown'}; "
        f"set {context.setIndex or '?'} of {context.setCount or '?'}; planned "
        f"{context.plannedLoadLb or '?'} lb for {context.plannedReps or '?'} reps.\n"
        f"Transcript: {transcript!r}"
    )
    raw, _ = meta.spark_json(SYSTEM_PROMPT, user, "VoiceIntent", VOICE_INTENT_SCHEMA)
    intent = VoiceIntent.model_validate(raw)
    if (
        intent.number is not None
        and str(int(intent.number)) not in transcript
        and parse_number(transcript) is None
    ):
        # The model produced a number the athlete never said: never act on it.
        intent = intent.model_copy(update={"number": None, "confidence": min(intent.confidence, 0.5)})
    return intent


def classify(transcript: str, context: SessionContext) -> VoiceIntent:
    return classify_by_rules(transcript) or classify_with_spark(transcript, context)
