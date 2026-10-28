"""Spoken commands during a session -> VoiceIntent (HANDOFF.md §5, §8).

Two layers. A rule layer handles the short, unambiguous commands the athlete says a hundred times
a session ("undo", "that was 8", "drop to 215") with no model round-trip, so the echo comes back
within the transcription's own latency. Anything the rules don't recognise goes to Muse Spark with
the session context, except during a set: then only the rules' set commands count and the rest is
chatter. Numbers are never invented: the rules only return a number they parsed from the words,
and Spark's numbers are checked against the transcript.

His coach uses no RPE, so a bare number is a rep count. RPE needs "felt like", "RPE", "a/an N" or
"out of ten".
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
    "acceptSuggestion",
    "keepLoad",
    # Between sets (HANDOFF.md §7, The between-set conversation)
    "chatter",
    "question",
    "choose",
    "skipExercise",
    "logbook",
    "equipmentTaken",
    "equipmentFree",
    "swapTo",
    "unknown",
]
INTENTS: tuple[str, ...] = Intent.__args__  # type: ignore[attr-defined]

Topic = Literal[
    "next", "restLeft", "lastSet", "lastTime", "load", "setsLeft", "effort", "coachNotes", "outOfScope"
]  # fmt: skip
TOPICS: tuple[str, ...] = Topic.__args__  # type: ignore[attr-defined]

# During a set only these, and only from the rules: grunts and gym noise never become commands.
SET_COMMANDS = ("endSet", "reps", "topSet")


class VoiceIntent(StrictModel):
    intent: Intent
    number: float | None = Field(
        default=None,
        description="Pounds for loads, a count for reps, the RPE value, the option for choose (1 or 2); else null",
    )
    reps: int | None = Field(
        default=None,
        description='The count when a load and a count are said together ("145 for 9"); else null',
    )
    setNumber: int | None = Field(
        default=None, description='A set the athlete names ("set 3 of incline was 7" is 3); else null'
    )
    text: str | None = Field(
        default=None,
        description="The note, the exercise or add-on named, or the swap, in the athlete's own words; else null",
    )
    topic: Topic | None = Field(default=None, description="For question: what he asked about; else null")
    fieldId: str | None = Field(
        default=None, description="The check-in field a note targets, when the athlete names one"
    )
    confidence: float = Field(description="0 to 1. Under 0.7 the app asks back instead of acting")


class SessionContext(StrictModel):
    state: str = Field(description="ready, recording, rest, hold, paused")
    exerciseName: str | None = None
    setIndex: int | None = Field(default=None, description="1-based set number")
    setCount: int | None = None
    plannedLoadLb: float | None = None
    plannedReps: int | None = None
    pendingAsk: str | None = Field(default=None, description="The question the app asked and is waiting on")
    lastSpoken: str | None = Field(default=None, description="The app's last line")
    exercisesAhead: list[str] = Field(default_factory=list, description="Today's exercises still to do")
    addOnNames: list[str] = Field(default_factory=list, description="Add-ons the athlete can add or skip")


def intent(kind: str, number: float | None = None, confidence: float = 0.95, **fields) -> VoiceIntent:
    return VoiceIntent(
        intent=kind,  # type: ignore[arg-type]
        number=number,
        reps=fields.get("reps"),
        setNumber=fields.get("setNumber"),
        text=fields.get("text"),
        topic=fields.get("topic"),
        fieldId=None,
        confidence=confidence,
    )


VOICE_INTENT_SCHEMA = strict_schema(VoiceIntent)

SYSTEM_PROMPT = (
    "Classify one short utterance heard by the phone during a lifting session, between sets. The "
    "user message gives the session context (what the app last said and what it is waiting on), then "
    "the transcript. The phone hears everything: the athlete, other people, music. Map it to exactly "
    "one intent:\n"
    'reps: a rep count for a set ("that was 8", "got 12"). His coach uses no RPE, so a bare number is '
    'reps. rpe: only with "felt like", "RPE", "a/an N" or "out of ten" ("felt like a 9" is rpe 9). '
    'setLoad: a new load in pounds ("drop to 215"). loadDelta: a change in pounds ("add 5" is +5, '
    '"take off 10" is -10). skipSet. nextExercise. starting: the set is about to begin. endSet: the set '
    'just finished ("done", "done, 12" has number 12). undo. pause. resume. endSession: he is finished '
    "for the day. note: a remark for his coach about how something felt or went, with the words in "
    '`text` verbatim ("left shoulder pinched on the last rep", "slept terribly", "the Smith felt heavy '
    'today"). chatter: anything not for the app: exclamations ("let\'s go", "ugh, that was brutal", '
    '"come on"), other people talking, music, small talk. replayCue: play the coach\'s cue again. yes / '
    "no: a plain answer to what the app asked. answer: a number or words answering what the app asked. "
    'choose: picking an option the app offered: number 1 for "go with it" or "the first one", 2 for '
    '"the other one", text "wait" for "I\'ll wait". question: he asks the app something, with '
    "`topic`: next (what's next), restLeft (rest time left), lastSet (what the last set counted), "
    "lastTime (last time's numbers), load (what weight), setsLeft, effort (was that failure), "
    "coachNotes (what the coach wrote, the tempo), outOfScope (advice the app never gives: heavier or "
    "lighter next week, form, food, pain). topSet: the next set is the top set, or the last one was. "
    "warmup: the last set was only a warm-up. addAddOn / skipAddOn: add or skip one of today's add-ons "
    "(names in the context), name in `text`. skipExercise: skip a named exercise still ahead today, "
    "name in `text`. changeDay: another cycle day today, day number in `number`. flagSet: send the last "
    'set\'s video to the coach. acceptSuggestion: take the load the app suggested ("go with it"). '
    'keepLoad: keep the current load ("keep it"). logbook: last time\'s top set from his paper logbook '
    '("last time I did 145 for 9": number 145, reps 9). equipmentTaken: a machine or bench is taken or '
    "he wants another one (exercise in `text` when named). equipmentFree: it's free again. swapTo: he "
    'is doing something else instead ("doing dumbbells instead", what he said in `text`). unknown when '
    "unsure.\n"
    "Numbers are pounds for loads and counts for reps. Never invent a number: `number` and `reps` hold "
    "only values the athlete said; `setNumber` only a set he named. Keep `text` in the athlete's own "
    "words. Set confidence honestly; under 0.7 the app asks before acting."
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

_NUMBER_WORDS = set(_UNITS) | set(_TENS) | {"hundred", "and", "a", "half", "point", "quarter", "quarters"}
_NEGATION = re.compile(r"\b(can'?t|cannot|don'?t|do not|not|no|never|won'?t|nah)\b")
_LEAD = r"^(?:(?:wait|actually|no|oh|sorry|hold on|hang on|um|so)\s+)*"

_UNDO = re.compile(r"\b(undo|scratch that|never ?mind|take that back)\b")
_REPLAY = re.compile(r"\b(say that again|repeat that|play (that|it) again|again please)\b")
_YES = re.compile(
    r"^(yes|yeah|yep|yup|correct|right|sure|affirmative|ok|okay|alright|all right)"
    r"( please| do it| that'?s right| go ahead)?$"
)
_NO = re.compile(
    r"^(no|nope|nah|negative|wrong|not now|no thanks)( thanks| thank you| carry on| keep going)?$"
)
_CHOOSE_FIRST = re.compile(
    r"^(?:(?:i'?ll )?(?:take|do|go with) )?the first( one| option)?$|^first( one| option)?$"
)
_CHOOSE_OTHER = re.compile(
    r"^(?:(?:i'?ll )?(?:take|do|go with) )?the (other|second)( one| option)?$|^(other|second)( one| option)$"
)
_CHOOSE_WAIT = re.compile(
    r"^(?:i'?ll|i will|let'?s|i'?m gonna|i'?m going to) (just )?wait( for it)?$|^wait for it$"
)

_QUESTIONS: list[tuple[str, re.Pattern[str]]] = [
    ("setsLeft", re.compile(r"\bhow many (more )?sets\b|\bsets (left|to go)\b")),
    (
        "restLeft",
        re.compile(
            r"\bhow (long|much time|much rest)( do i have| have i got| is)?( left)?$|\bhow much rest\b|\b(time|rest) left\b"
        ),
    ),
    (
        "lastTime",
        re.compile(
            r"\bwhat did i (do|get|lift|have) last (time|week)\b|\blast (time|week)'?s numbers\b|\bwhat was (it )?last (time|week)\b"
        ),
    ),
    (
        "lastSet",
        re.compile(
            r"\bwhat did i get\b|\bhow many (was|were) (that|those|it)\b|\bhow many did i (get|do)\b|\bhow many reps (was|did)\b"
        ),
    ),
    (
        "next",
        re.compile(
            r"\bwhat'?s (next|after this|after that|coming up)\b|\bwhat'?s my next\b|\bwhat (do i do|am i doing|is) next\b"
            r"|\bwhat'?s the next (set|exercise|lift)\b"
        ),
    ),
    (
        "load",
        re.compile(
            r"\bwhat (weight|load)\b|\bwhat'?s the (weight|load|back-?off|back down)\b|\bhow (heavy|much weight)\b|\bwhat am i lifting\b"
        ),
    ),
    (
        "effort",
        re.compile(
            r"\bwas that (to |at )?failure\b|\bhow close (to failure )?was (that|i)\b|\bhow many (left )?in the tank\b|\bdid i (hit|reach) failure\b"
        ),
    ),
    (
        "coachNotes",
        re.compile(
            r"\bwhat did (he|my coach|coach|the coach) (say|write)\b|\bwhat'?s the tempo\b|\b(any|his|coach'?s) notes?\b"
        ),
    ),
    (
        "outOfScope",
        re.compile(
            r"\bshould i\b|\bhow'?s my form\b|\bis my form\b|\bhow was my form\b|\bwhat should i eat\b|\bwhat do you think\b"
        ),
    ),
]
_LOGBOOK = re.compile(
    r"\blast (?:time|week) (?:i )?(?:did|got|had|hit|went|was)\s+(?P<load>[\w .]+?) for (?P<reps>[\w ]+?)( reps)?$"
)
_TAKEN = re.compile(
    r"^(?:(?:the|my|this) )?(?P<name>[a-z][a-z' -]{0,30}?)(?: is|'s| are) (?:taken|occupied|being used|in use|busy)\b"
    r"|\bsomeone'?s (?:on|using) (?:the |my )?(?P<name2>[a-z][a-z' -]{0,30}?)$|\bsomeone is (?:on|using)\b"
    r"|\banother (?:machine|bench|rack|station|cable)\b|\bcan i swap\b|\bswap (?:this|that|it)\b"
)
_FREE = re.compile(
    r"^(?:it'?s|it is|(?:the )?[a-z ]{1,25}?(?: is|'s)) (?:free|open|available)(?: now| again)?$|^(?:free|open) now$"
)
_SWAP = re.compile(
    r"^(?:i'?m |i am |i'?ll |i will |let'?s )?(?:doing|do|use|using|go with|going with|switch(?:ing)? to) (?P<what>.+?) instead$"
    r"|^(?P<what2>[a-z][a-z ]{1,30}?) instead$"
)
_END_SESSION = re.compile(
    r"\b(end|finish|stop|done with)( the| this| my| today'?s)? (session|workout)\b|\bthat'?s it for (today|the day)\b"
    r"|\bdone for (the day|today)\b|\bcall it a day\b"
)
_IM_DONE = re.compile(r"^(?:ok |okay |alright )?i'?m (?:all )?done$")
_NAMED_SET = re.compile(
    _LEAD
    + r"set (?P<set>\w+)(?: of (?:the )?(?P<name>[a-z][a-z ]*?))? (?:was|got|is|had) (?:only )?(?P<n>[\w .]+?)(?: reps?)?$"
)
_END_SET_N = re.compile(
    r"^(?:i'?m |ok |okay )?(?:done|finished|set done)(?: at| with| for)?\s+(?P<n>[\w .]+?)(?:\s+reps?)?$"
)
_END_SET = re.compile(
    r"\b(end|done|finished|that'?s|stop)( the| this| that| with this| with the| with that)? (set|rep)s?\b|\bset done\b"
    r"|^(i'?m )?(done|finished)$|\bdone$"
)
_RPE = re.compile(
    r"\b(?:felt like|feels like|felt|rpe|rated?)\s+(?:an?\s+)?(?P<n>[\w .]+?)(?:\s+(?:rpe|out of ten))?$"
    r"|\b(?:that was|that'?s|it was)\s+an?\s+(?P<m>[\w .]+?)(?:\s+(?:rpe|out of ten))?$"
    r"|^(?P<o>[\w .]+?)\s+out of ten$"
)
_REPS = re.compile(
    _LEAD
    + r"(?:that was|that'?s|that is|it was|(?:i )?(?:only )?(?:got|did)|only|just)\s+(?:only\s+)?(?P<n>[\w .]+?)"
    r"(?:\s+(?:reps?|repetitions?))?$|^(?P<m>[\w .]+?)\s+(?:reps?|repetitions?)$"
)
_PAUSE = re.compile(
    r"\b(pause|hold on|hang on|give me a (sec|second|minute)|wait a (sec|second|minute)|one (sec|second))\b"
)
_RESUME = re.compile(r"\b(resume|unpause|continue|keep going|i'?m back|back now)\b")
_NEXT_EXERCISE = re.compile(r"\b(next|skip)( the| this)? (exercise|movement|lift)\b|\bnext exercise\b")
_SKIP_SET = re.compile(r"\bskip( this| that| the)? set\b|\bskip it\b")
_STARTING = re.compile(
    r"\b(starting|start(ing)? (the |this |my )?set|here we go|going now)\b|^(go|ready|start|i'?m ready)( now)?$"
)
_TOP_SET = re.compile(
    r"\b(top set|this is (the|my) top set|that was (the|my) top set|going for the top set)\b"
)
_WARMUP = re.compile(r"\b(that was (just |only )?(a |my )?warm[ -]?up|warm[ -]?up set|still warming up)\b")
_FLAG = re.compile(
    r"\b(flag (that|it|this)( one)?|send (that|this)( one)? to (the )?coach|flag for (the )?coach)\b"
)
_ACCEPT = re.compile(r"\b(go with it|go with that|let'?s do (that|it)|sounds good)\b")
_KEEP = re.compile(r"\b(keep it|keep the weight|keep this|stay (here|at this|the same)|leave it)\b")
_ADD_ON = re.compile(
    r"^(?P<verb>add|do|include|skip|drop|no)\s+(the\s+)?(?P<name>[a-z][a-z ]{1,30}?)(\s+today)?$"
)
_CHANGE_DAY = re.compile(r"\b(doing|do|make it|switch to|change to|it'?s)\s+day\s+(?P<n>[\w]+)(\s+today)?\b")
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
_EXCLAIM = (
    r"(?:let'?s go|lets go|come on|c'?mon|ugh+|oof|ooh|ah+|argh|wow|whoa|man|oh man|damn|yeah|god|jeez)"
)
_CHATTER = re.compile(
    rf"^(?:{_EXCLAIM}[ ,]*)*(?:{_EXCLAIM}|nice( one)?|yeah buddy|light weight( baby)?|no problem|no worries|thanks|thank you|"
    r"cheers|cool|great|good stuff|that was (?:brutal|tough|hard|rough|nasty|a grind|easy|nice|good|great|horrible|sick|insane|"
    r"heavy|awful)|that (?:hurt|sucked|burned))(?: baby| man| bro| dude)?$"
)
_FILLER = re.compile(r"\b(uh|um|setecho|hey)\b")
_NAME_STOPWORDS = {
    "it",
    "that",
    "this",
    "set",
    "weight",
    "problem",
    "one",
    "thing",
    "everything",
    "machine",
    "bench",
}


def normalize(transcript: str) -> str:
    t = transcript.lower().strip()
    t = re.sub(r"[^\w\s.'-]", " ", t)
    t = _FILLER.sub(" ", t)
    return re.sub(r"\s+", " ", t).strip(" .")


def _words(name: str) -> list[str]:
    return [w for w in re.findall(r"[a-z]+", name.lower()) if w not in ("the", "a", "my", "of", "on", "with")]


def name_matches(said: str, name: str) -> bool:
    """ "flyes" matches "Cable incline flyes", "smith" matches "Smith close-grip press": every word he
    said is the start of a word in the name (four letters is enough, so "flies" finds "flyes")."""
    said_words = _words(said)
    name_words = _words(name)
    if not said_words or not name_words:
        return False
    return all(any(n.startswith(w[:4]) or w.startswith(n[:4]) for n in name_words) for w in said_words)


def _named(said: str, names: list[str]) -> str | None:
    return next((n for n in names if name_matches(said, n)), None)


def _is_bare_number(t: str) -> bool:
    tokens = t.replace("-", " ").split()
    return bool(tokens) and all(re.fullmatch(r"\d+(\.\d+)?", w) or w in _NUMBER_WORDS for w in tokens)


def _short_and_positive(t: str) -> bool:
    return len(t.split()) <= 5 and not _NEGATION.search(t)


def _number(m: re.Match[str], *groups: str) -> float | None:
    for g in groups:
        if (value := m.group(g)) and (n := parse_number(value)) is not None:
            return n
    return None


def classify_by_rules(transcript: str, context: SessionContext | None = None) -> VoiceIntent | None:
    """A VoiceIntent for the plain commands, else None so Spark can read it."""
    if m := _NOTE.match(transcript):
        # The note keeps the athlete's own words and casing.
        return intent("note", text=m.group("text").strip(), confidence=0.9)
    t = normalize(transcript)
    if not t:
        return None
    recording = context is not None and context.state == "recording"
    add_ons = context.addOnNames if context else []
    ahead = context.exercisesAhead if context else []

    if _UNDO.search(t):
        return intent("undo")
    if _REPLAY.search(t):
        return intent("replayCue")
    if _YES.match(t):
        return intent("yes")
    if _NO.match(t):
        return intent("no")
    if _CHOOSE_FIRST.match(t):
        return intent("choose", 1)
    if _CHOOSE_OTHER.match(t):
        return intent("choose", 2)
    if _CHOOSE_WAIT.match(t):
        return intent("choose", text="wait")
    for topic, pattern in _QUESTIONS:
        if pattern.search(t):
            return intent("question", topic=topic, confidence=0.9)
    if (
        (m := _LOGBOOK.search(t))
        and (load := parse_number(m.group("load")))
        and (reps := parse_number(m.group("reps")))
    ):
        return intent("logbook", load, reps=int(reps), confidence=0.9)
    if _FREE.match(t):
        return intent("equipmentFree", confidence=0.9)
    if m := _TAKEN.search(t):
        name = (m.group("name") or m.group("name2") or "").strip()
        return intent(
            "equipmentTaken", text=None if name in _NAME_STOPWORDS or not name else name, confidence=0.9
        )
    if m := _SWAP.match(t):
        return intent("swapTo", text=(m.group("what") or m.group("what2")).strip(), confidence=0.9)
    if _END_SESSION.search(t):
        return intent("endSession")
    if _IM_DONE.match(t):
        return intent("endSet" if recording else "endSession")
    if (
        (m := _NAMED_SET.match(t))
        and (n := _number(m, "n")) is not None
        and (s := parse_number(m.group("set")))
    ):
        return intent("reps", n, setNumber=int(s), text=m.group("name"), confidence=0.9)
    if (m := _END_SET_N.match(t)) and (n := _number(m, "n")) is not None:
        return intent("endSet", n)
    if (m := _RPE.search(t)) and (n := _number(m, "n", "m", "o")) is not None and 1 <= n <= 10:
        return intent("rpe", n, confidence=0.85)
    if (m := _REPS.match(t)) and (n := _number(m, "n", "m")) is not None:
        return intent("reps", n, confidence=0.9)
    if _PAUSE.search(t):
        return intent("pause")
    if _RESUME.search(t):
        return intent("resume")
    if _NEXT_EXERCISE.search(t):
        return intent("nextExercise")
    if _SKIP_SET.search(t):
        return intent("skipSet")
    if _END_SET.search(t):
        return intent("endSet")
    if _STARTING.search(t):
        return intent("starting")
    if _TOP_SET.search(t):
        return intent("topSet")
    if _WARMUP.search(t):
        return intent("warmup")
    if _FLAG.search(t):
        return intent("flagSet")
    if _ACCEPT.search(t) and _short_and_positive(t):
        return intent("acceptSuggestion")
    if _KEEP.search(t) and _short_and_positive(t):
        return intent("keepLoad")
    if (m := _CHANGE_DAY.search(t)) and (n := parse_number(m.group("n"))) is not None:
        return intent("changeDay", n, confidence=0.9)
    if (m := _ADD_ON.match(t)) and m.group("name") not in _NAME_STOPWORDS:
        said = m.group("name").strip()
        skip = m.group("verb") in ("skip", "drop", "no")
        if add_on := _named(said, add_ons):
            return intent("skipAddOn" if skip else "addAddOn", text=add_on, confidence=0.85)
        if skip and (exercise := _named(said, ahead)):
            return intent("skipExercise", text=exercise, confidence=0.85)
    if (m := _SET_LOAD.search(t)) and (n := parse_number(m.group("n"))) is not None:
        return intent("setLoad", n, confidence=0.9)
    if (m := _DELTA_UP.search(t)) and (n := parse_number(m.group("n"))) is not None:
        return intent("loadDelta", n, confidence=0.9)
    if (m := _DELTA_DOWN.search(t)) and (n := parse_number(m.group("n"))) is not None:
        return intent("loadDelta", -n, confidence=0.9)
    if _is_bare_number(t) and (n := parse_number(t)) is not None:
        # A count by default; the app reads it as the answer to whatever it asked (a weight, "How many?").
        return intent("answer", n, confidence=0.9)
    if _CHATTER.match(t):
        return intent("chatter", confidence=0.9)
    return None


# ---------------------------------------------------------------------------
# Spark fallback
# ---------------------------------------------------------------------------


def _said(value: float, transcript: str) -> bool:
    return str(int(value)) in transcript or parse_number(transcript) is not None


def classify_with_spark(transcript: str, context: SessionContext) -> VoiceIntent:
    user = (
        f"Context: state {context.state}; exercise {context.exerciseName or 'unknown'}; "
        f"set {context.setIndex or '?'} of {context.setCount or '?'}; planned "
        f"{context.plannedLoadLb or '?'} lb for {context.plannedReps or '?'} reps.\n"
        f"The app last said: {context.lastSpoken or 'nothing yet'!r}. Waiting on: {context.pendingAsk or 'nothing'!r}.\n"
        f"Exercises ahead: {', '.join(context.exercisesAhead) or 'none'}. Add-ons: {', '.join(context.addOnNames) or 'none'}.\n"
        f"Transcript: {transcript!r}"
    )
    raw, _ = meta.spark_json(SYSTEM_PROMPT, user, "VoiceIntent", VOICE_INTENT_SCHEMA, effort="low")
    result = VoiceIntent.model_validate(raw)
    update: dict = {}
    # A number the athlete never said is never acted on.
    for field in ("number", "reps", "setNumber"):
        value = getattr(result, field)
        if value is not None and not _said(value, transcript):
            update[field] = None
            update["confidence"] = min(result.confidence, 0.5)
    if result.intent != "question" and result.topic is not None:
        update["topic"] = None
    return result.model_copy(update=update) if update else result


def route(transcript: str, context: SessionContext) -> tuple[VoiceIntent, str]:
    """The intent and who read it ("rules" or "spark"). During a set only the rules' set commands
    count; everything else is chatter and Spark is never called."""
    ruled = classify_by_rules(transcript, context)
    if context.state == "recording":
        if ruled is not None and ruled.intent in SET_COMMANDS:
            return ruled, "rules"
        return intent("chatter", confidence=0.9), "rules"
    if ruled is not None:
        return ruled, "rules"
    return classify_with_spark(transcript, context), "spark"


def classify(transcript: str, context: SessionContext) -> VoiceIntent:
    return route(transcript, context)[0]
