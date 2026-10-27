"""The coach's reply -> proposed plan changes and voice cues (HANDOFF.md §5 `/coach/reply`, §8).

Nothing here changes a plan. The backend lists what the coach changed, each with his exact
words, and the phone applies only what the athlete approves (AGENTS.md rule 12).

- The plan's addressable items (macro targets, cardio, every exercise and its sets/reps/load/rest,
  every supplement line) are built from `PlanState` with a path, a label and the current value.
- Muse Spark picks changes with `path` as a per-request enum, so it cannot invent an item.
- The validator checks every change: the quote is in the transcript, the amount is in the quote,
  a new item's name is in the quote, the op fits the kind. Anything that fails goes to `unclear`.
- `before` and `after` are computed here from the plan, the op and the amount. Never by the model.
- Voice cues: the reply is cut at pauses, each segment transcribed, and Spark labels which
  segments are the coach's instructions about one exercise. Those become cues with their times.
"""

from __future__ import annotations

import re
import subprocess
import tempfile
import uuid
from dataclasses import dataclass
from datetime import date
from pathlib import Path
from typing import Any, Literal

from pydantic import Field

from app import audio, meta, prompts
from app.checkin import MacroTargets
from app.schemas import CarriedBlock, PlannedExercise, Program, StrictModel, slug, strict_schema
from app.voice import parse_number

ChangeKind = Literal[
    "macroTarget", "cardio", "exerciseSwap", "exerciseAdd", "exerciseRemove",
    "sets", "reps", "load", "rest", "supplement", "other",
]  # fmt: skip
ChangeOp = Literal["set", "increase", "decrease", "replace", "add", "remove"]

# Which ops make sense for which kind. Anything else is unclear.
OPS_FOR_KIND: dict[str, set[str]] = {
    "macroTarget": {"set", "increase", "decrease"},
    "cardio": {"set", "replace", "increase", "decrease"},
    "exerciseSwap": {"replace"},
    "exerciseAdd": {"add"},
    "exerciseRemove": {"remove"},
    "sets": {"set", "increase", "decrease"},
    "reps": {"set", "increase", "decrease"},
    "load": {"set", "increase", "decrease"},
    "rest": {"set", "increase", "decrease"},
    "supplement": {"set", "add", "remove", "replace"},
}
NUMERIC_KINDS = {"macroTarget", "sets", "reps", "load", "rest"}


# ---------------------------------------------------------------------------
# Wire models (mirroring the Swift structs)
# ---------------------------------------------------------------------------


class PlanState(StrictModel):
    version: int
    program: Program
    targets: MacroTargets
    cardioProtocol: str
    carriedBlocks: list[CarriedBlock]
    replyId: str | None = None


class PlanChange(StrictModel):
    id: str
    kind: ChangeKind
    path: str
    label: str
    op: ChangeOp
    amount: float | None = None
    before: str | None = None
    after: str | None = None
    quote: str
    appliesFrom: str | None = None
    approved: bool = True


class CueOut(StrictModel):
    id: str
    exerciseId: str
    text: str
    startSec: float | None = None
    endSec: float | None = None


class ReplyRequest(StrictModel):
    text: str | None = None
    plan: PlanState
    cuesEnabled: bool = True
    today: str | None = None


class ReplyResponse(StrictModel):
    transcript: str
    changes: list[PlanChange]
    unclear: list[str]
    cues: list[CueOut]


# ---------------------------------------------------------------------------
# Spark's output shapes
# ---------------------------------------------------------------------------


class ChangeOut(StrictModel):
    kind: ChangeKind
    path: str = Field(description="The item's path, from the list given")
    op: ChangeOp
    amount: float | None = Field(
        default=None, description="The number he said, as he said it: 25 for 'drop carbs by 25'. Null if none"
    )
    newItem: str | None = Field(
        default=None,
        description="For a swap, an addition, or a rep range: the new exercise, supplement or range in his words",
    )
    quote: str = Field(description="His exact words for this change, verbatim from the transcript")
    appliesFrom: str | None = Field(
        default=None, description="yyyy-mm-dd when he names a start day ('from Monday'); null otherwise"
    )


class ChangesOut(StrictModel):
    changes: list[ChangeOut]
    unclear: list[str] = Field(description="His sentences that change something not in the list")


class SegmentLabel(StrictModel):
    index: int
    exerciseId: str
    isCue: bool


class SegmentLabelsOut(StrictModel):
    segments: list[SegmentLabel]


# ---------------------------------------------------------------------------
# Addressable items
# ---------------------------------------------------------------------------


@dataclass(frozen=True)
class Item:
    path: str
    label: str
    value: str
    kind: str
    # For program items: the day name and exercise name they address (matched across weeks).
    day: str | None = None
    exercise: str | None = None
    # For supplements: the exact block line.
    line: str | None = None


def _fmt_num(n: float) -> str:
    return str(int(n)) if float(n).is_integer() else f"{n:g}"


def sets_text(ex: PlannedExercise) -> str:
    return str(len(ex.sets))


def reps_text(ex: PlannedExercise) -> str:
    first = ex.sets[0] if ex.sets else None
    if first is None:
        return "?"
    if first.reps is not None:
        return str(first.reps)
    if first.repsMin is not None and first.repsMax is not None:
        return f"{first.repsMin}–{first.repsMax}"
    return "?"


def load_text(ex: PlannedExercise) -> str | None:
    first = ex.sets[0] if ex.sets else None
    return f"{_fmt_num(first.loadLb)} lb" if first and first.loadLb is not None else None


def rest_text(ex: PlannedExercise) -> str | None:
    return f"{ex.restSeconds} s" if ex.restSeconds is not None else None


def exercise_summary(ex: PlannedExercise) -> str:
    parts = [f"{sets_text(ex)} × {reps_text(ex)}"]
    if load := load_text(ex):
        parts.append(load)
    if rest := rest_text(ex):
        parts.append(f"rest {rest}")
    return " · ".join(parts)


def is_supplement_block(block: CarriedBlock) -> bool:
    return "supplement" in block.title.lower()


def supplement_lines(plan: PlanState) -> list[str]:
    lines: list[str] = []
    for block in plan.carriedBlocks:
        if not is_supplement_block(block):
            continue
        for raw in block.text.splitlines():
            line = raw.strip().lstrip("-•*").strip()
            if line:
                lines.append(line)
    return lines


def items_for(plan: PlanState) -> list[Item]:
    """Every path the model may address, with a plain label and the current value."""
    items: list[Item] = []
    for day_key, day_label in (("training", "Training-day"), ("rest", "Rest-day")):
        macros = getattr(plan.targets, day_key)
        for field, label, unit in (
            ("kcal", "calories", "kcal"),
            ("proteinG", "protein", "g"),
            ("carbsG", "carbs", "g"),
            ("fatG", "fat", "g"),
        ):
            items.append(
                Item(f"targets.{day_key}.{field}", f"{day_label} {label}", f"{_fmt_num(getattr(macros, field))} {unit}", "macroTarget")
            )  # fmt: skip
    items.append(Item("cardioProtocol", "Cardio protocol", plan.cardioProtocol or "(none)", "cardio"))

    seen_days: dict[str, str] = {}
    seen_ex: set[str] = set()
    for week in plan.program.weeks:
        for day in week.days:
            dslug = slug(day.name)
            if dslug not in seen_days:
                seen_days[dslug] = day.name
                items.append(
                    Item(
                        f"program.{dslug}",
                        f"{day.name} (the day)",
                        f"{len(day.exercises)} exercises",
                        "exerciseAdd",
                        day=day.name,
                    )
                )
            for ex in day.exercises:
                base = f"program.{dslug}.{slug(ex.name)}"
                if base in seen_ex:
                    continue
                seen_ex.add(base)
                who = f"{day.name} · {ex.name}"
                items.append(
                    Item(base, who, exercise_summary(ex), "exerciseSwap", day=day.name, exercise=ex.name)
                )
                items.append(
                    Item(f"{base}.sets", f"{who} sets", sets_text(ex), "sets", day=day.name, exercise=ex.name)
                )
                items.append(
                    Item(f"{base}.reps", f"{who} reps", reps_text(ex), "reps", day=day.name, exercise=ex.name)
                )
                items.append(
                    Item(
                        f"{base}.load",
                        f"{who} load",
                        load_text(ex) or "(none)",
                        "load",
                        day=day.name,
                        exercise=ex.name,
                    )
                )
                items.append(
                    Item(
                        f"{base}.rest",
                        f"{who} rest",
                        rest_text(ex) or "(none)",
                        "rest",
                        day=day.name,
                        exercise=ex.name,
                    )
                )
    for line in supplement_lines(plan):
        items.append(
            Item(f"supplement.{slug(line)[:40]}", f"Supplement: {line}", line, "supplement", line=line)
        )
    items.append(
        Item("supplements", "Supplements (the list)", f"{len(supplement_lines(plan))} items", "supplement")
    )
    return items


def items_text(items: list[Item]) -> str:
    return "\n".join(f"- {i.path} | {i.label} | {i.value}" for i in items)


def changes_schema(items: list[Item]) -> dict[str, Any]:
    """The strict schema with `path` as an enum of this plan's paths."""
    schema = strict_schema(ChangesOut)
    schema["properties"]["changes"]["items"]["properties"]["path"] = {
        "type": "string",
        "enum": [i.path for i in items],
        "description": "The item's path, from the list given",
    }
    return schema


def labels_schema(exercise_ids: list[str]) -> dict[str, Any]:
    schema = strict_schema(SegmentLabelsOut)
    schema["properties"]["segments"]["items"]["properties"]["exerciseId"] = {
        "type": "string",
        "enum": [*exercise_ids, "none"],
    }
    return schema


# ---------------------------------------------------------------------------
# Validator and before/after
# ---------------------------------------------------------------------------


def _squash(text: str) -> str:
    t = text.lower().replace("’", "'").replace("‘", "'").replace("“", '"').replace("”", '"')
    return re.sub(r"[\s\.,;:!?\"'\-–—]+", "", t)


def quote_in(quote: str, transcript: str) -> bool:
    q = _squash(quote)
    return bool(q) and q in _squash(transcript)


def numbers_in(text: str) -> set[float]:
    """Every number in `text`, as digits or words ("twenty five", "two fifty")."""
    found: set[float] = set()
    for m in re.finditer(r"\d+(?:\.\d+)?", text):
        found.add(float(m.group()))
    words = re.findall(r"[a-z]+", text.lower())
    for size in (1, 2, 3, 4):
        for i in range(len(words) - size + 1):
            if (n := parse_number(" ".join(words[i : i + size]))) is not None:
                found.add(float(n))
    return found


def amount_in(amount: float, quote: str) -> bool:
    return any(abs(n - amount) < 1e-6 for n in numbers_in(quote))


def _range_from(text: str | None) -> tuple[int, int] | None:
    if not text:
        return None
    m = re.search(r"(\d+)\s*(?:-|–|to)\s*(\d+)", text)
    return (int(m.group(1)), int(m.group(2))) if m else None


def _parse_value(value: str) -> float | None:
    m = re.search(r"-?\d+(?:\.\d+)?", value.replace(",", ""))
    return float(m.group()) if m else None


def compute_after(item: Item, op: str, amount: float | None, new_item: str | None) -> str | None:
    """`after` from the current value, the op and the amount. Units follow the current value."""
    before = item.value
    if item.kind in NUMERIC_KINDS:
        if item.kind == "reps" and (rng := _range_from(new_item)) and op == "set":
            return f"{rng[0]}–{rng[1]}"
        current = _parse_value(before) if before != "(none)" else None
        unit = re.sub(r"^[\s\d.,–\-]+", "", before).strip() if before != "(none)" else ""
        if op == "set":
            if amount is None:
                return None
            value = amount
        elif op in ("increase", "decrease"):
            if amount is None or current is None:
                return None
            value = current + amount if op == "increase" else current - amount
        else:
            return None
        if item.kind == "reps" and (rng := _range_from(before)) and op in ("increase", "decrease"):
            delta = amount if op == "increase" else -amount  # type: ignore[operator]
            return f"{int(rng[0] + delta)}–{int(rng[1] + delta)}"
        text = _fmt_num(value)
        return f"{text} {unit}".strip() if unit else text
    if item.kind in ("exerciseSwap", "exerciseAdd", "supplement") and op in ("replace", "add"):
        return new_item
    if op == "remove":
        return "(removed)"
    if item.kind == "cardio":
        return new_item
    return new_item


@dataclass
class Validated:
    changes: list[PlanChange]
    unclear: list[str]


def validate(out: ChangesOut, transcript: str, items: list[Item], today: date | None = None) -> Validated:
    """Every change passes every check or moves to `unclear` with its quote. Never dropped silently."""
    by_path = {i.path: i for i in items}
    changes: list[PlanChange] = []
    unclear: list[str] = list(out.unclear)

    def reject(ch: ChangeOut) -> None:
        if ch.quote and ch.quote not in unclear:
            unclear.append(ch.quote)

    for ch in out.changes:
        item = by_path.get(ch.path)
        if item is None or ch.kind == "other" or not quote_in(ch.quote, transcript):
            reject(ch)
            continue
        if ch.op not in OPS_FOR_KIND.get(ch.kind, set()):
            reject(ch)
            continue
        # The path addresses one kind of thing; "sets" on a ".reps" path is a mismatch. A removal
        # addresses the exercise path, which is listed as a swap target.
        kind_ok = item.kind == ch.kind or (ch.kind == "exerciseRemove" and item.kind == "exerciseSwap")
        if not kind_ok:
            reject(ch)
            continue
        if ch.amount is not None and not amount_in(ch.amount, ch.quote):
            reject(ch)
            continue
        if (
            ch.kind in NUMERIC_KINDS
            and ch.amount is None
            and not (ch.kind == "reps" and _range_from(ch.newItem))
        ):
            reject(ch)
            continue
        if (
            ch.op in ("replace", "add")
            and ch.kind != "cardio"
            and not (ch.newItem and quote_in(ch.newItem, ch.quote))
        ):
            reject(ch)
            continue
        if ch.kind == "cardio" and ch.op in ("set", "replace") and not ch.newItem:
            reject(ch)
            continue
        after = compute_after(item, ch.op, ch.amount, ch.newItem)
        if after is None:
            reject(ch)
            continue
        applies = ch.appliesFrom
        if applies:
            try:
                parsed = date.fromisoformat(applies)
                if today is not None and parsed < today:
                    applies = None  # already past: applies from the next session
            except ValueError:
                applies = None
        changes.append(
            PlanChange(
                id=f"c{len(changes) + 1}",
                kind=ch.kind,
                path=ch.path,
                label=item.label,
                op=ch.op,
                amount=ch.amount,
                before=None if item.value == "(none)" else item.value,
                after=after,
                quote=ch.quote,
                appliesFrom=applies,
                approved=True,
            )
        )
    return Validated(changes, unclear)


# ---------------------------------------------------------------------------
# Spark calls
# ---------------------------------------------------------------------------


def read_changes(transcript: str, plan: PlanState, today: date | None = None) -> Validated:
    items = items_for(plan)
    raw, _ = meta.spark_json(
        prompts.COACH_REPLY,
        f"Plan items (path | label | current value):\n{items_text(items)}\n\nHis reply:\n{transcript}",
        "CoachChanges",
        changes_schema(items),
    )
    return validate(ChangesOut.model_validate(raw), transcript, items, today)


def exercise_ids(plan: PlanState) -> list[tuple[str, str]]:
    """(id, name) for every exercise, first occurrence of each name."""
    seen: dict[str, str] = {}
    for week in plan.program.weeks:
        for day in week.days:
            for ex in day.exercises:
                seen.setdefault(ex.id, f"{day.name} · {ex.name}")
    return list(seen.items())


def label_segments(segments: list[str], plan: PlanState) -> list[SegmentLabel]:
    ids = exercise_ids(plan)
    if not segments or not ids:
        return []
    listing = "\n".join(f"- {i}: {name}" for i, name in ids)
    numbered = "\n".join(f"{n}. {s}" for n, s in enumerate(segments))
    raw, _ = meta.spark_json(
        prompts.CUE_LABELS,
        f"Exercises:\n{listing}\n\nSegments:\n{numbered}",
        "CueLabels",
        labels_schema([i for i, _ in ids]),
    )
    known = {i for i, _ in ids}
    labels = SegmentLabelsOut.model_validate(raw).segments
    return [s for s in labels if s.exerciseId in known and 0 <= s.index < len(segments)]


# ---------------------------------------------------------------------------
# Segmentation
# ---------------------------------------------------------------------------

SILENCE_DB = -35
PAUSE_SECONDS = 0.4
SHORT_SEGMENT = 1.5
LONG_SEGMENT = 15.0
CANDIDATE_PAUSE = 0.2
CHUNK_SECONDS = 9 * 60


@dataclass(frozen=True)
class Segment:
    start: float
    end: float

    @property
    def length(self) -> float:
        return self.end - self.start


def detect_silences(
    wav_path: Path, noise_db: int = SILENCE_DB, min_pause: float = CANDIDATE_PAUSE
) -> list[Segment]:
    """Silences of at least `min_pause` seconds, from ffmpeg's silencedetect."""
    cmd = [
        "ffmpeg", "-nostats", "-i", str(wav_path),
        "-af", f"silencedetect=noise={noise_db}dB:d={min_pause}", "-f", "null", "-",
    ]  # fmt: skip
    out = subprocess.run(cmd, capture_output=True, text=True, check=False).stderr
    return parse_silences(out)


def parse_silences(log: str) -> list[Segment]:
    starts = [float(m.group(1)) for m in re.finditer(r"silence_start:\s*(-?[\d.]+)", log)]
    ends = [float(m.group(1)) for m in re.finditer(r"silence_end:\s*(-?[\d.]+)", log)]
    silences = [Segment(max(0.0, s), e) for s, e in zip(starts, ends, strict=False) if e > s]
    if len(starts) > len(ends):  # the file ends in silence
        silences.append(Segment(max(0.0, starts[-1]), float("inf")))
    return silences


def segments_from_silences(duration: float, silences: list[Segment]) -> list[Segment]:
    """Speech between pauses of at least PAUSE_SECONDS. Segments under SHORT_SEGMENT merge into a
    neighbour; segments over LONG_SEGMENT split at their longest internal pause (else the middle)."""
    boundaries = [s for s in silences if s.length >= PAUSE_SECONDS]
    speech: list[Segment] = []
    cursor = 0.0
    for s in sorted(boundaries, key=lambda x: x.start):
        if s.start > cursor:
            speech.append(Segment(cursor, min(s.start, duration)))
        cursor = max(cursor, min(s.end, duration))
    if cursor < duration:
        speech.append(Segment(cursor, duration))
    speech = [s for s in speech if s.length > 0.05]
    if not speech:
        return [Segment(0.0, duration)] if duration > 0 else []

    # Merge the short ones into the nearer neighbour.
    merged: list[Segment] = []
    for s in speech:
        if s.length < SHORT_SEGMENT and merged:
            merged[-1] = Segment(merged[-1].start, s.end)
        else:
            merged.append(s)
    if len(merged) > 1 and merged[0].length < SHORT_SEGMENT:
        merged[1] = Segment(merged[0].start, merged[1].end)
        merged.pop(0)

    # Split the long ones.
    pauses = sorted(silences, key=lambda x: -x.length)
    out: list[Segment] = []
    stack = list(reversed(merged))
    while stack:
        s = stack.pop()
        if s.length <= LONG_SEGMENT:
            out.append(s)
            continue
        inner = [p for p in pauses if s.start + 1.0 < p.start and p.end < s.end - 1.0]
        cut = (inner[0].start + min(inner[0].end, s.end)) / 2 if inner else s.start + s.length / 2
        stack.append(Segment(cut, s.end))
        stack.append(Segment(s.start, cut))
    return out


def split_sentences(text: str) -> list[str]:
    parts = re.split(r"(?<=[.!?])\s+|\n+", text.strip())
    return [p.strip() for p in parts if p.strip()]


# ---------------------------------------------------------------------------
# Audio
# ---------------------------------------------------------------------------


def wav_slice(wav: bytes, start: float, end: float) -> bytes:
    """A WAV of `wav`[start:end] seconds (mono 16-bit), re-headered."""
    info = audio.wav_info(wav)
    header_end = len(wav) - info.frames * info.channels * info.sample_width
    pcm = wav[header_end:]
    frame = info.channels * info.sample_width
    a = max(0, int(start * info.sample_rate)) * frame
    b = min(info.frames, int(end * info.sample_rate)) * frame
    return audio.write_wav(pcm[a:b], info.sample_rate)


def transcribe(wav: bytes, segments: list[Segment] | None = None) -> tuple[str, list[str]]:
    """Transcribe the whole note (in chunks under nine minutes) or each segment. Returns the
    joined transcript and the per-segment texts."""
    info = audio.wav_info(wav)
    duration = info.duration_s
    if segments is None:
        pieces = [Segment(s, min(s + CHUNK_SECONDS, duration)) for s in _frange(0.0, duration, CHUNK_SECONDS)]
    else:
        pieces = segments
    texts: list[str] = []
    for seg in pieces:
        piece = wav_slice(wav, seg.start, seg.end) if (seg.start > 0 or seg.end < duration) else wav
        result = meta.transcribe_wav(piece)
        texts.append((result.get("transcript") or "").strip())
    return " ".join(t for t in texts if t), texts


def _frange(start: float, stop: float, step: float) -> list[float]:
    out: list[float] = []
    x = start
    while x < stop:
        out.append(x)
        x += step
    return out or [0.0]


# ---------------------------------------------------------------------------
# The whole reply
# ---------------------------------------------------------------------------


def read_text_reply(
    text: str, plan: PlanState, cues_enabled: bool, today: date | None = None
) -> ReplyResponse:
    text = text.strip()
    if not text:
        raise ValueError("the reply is empty")
    validated = read_changes(text, plan, today)
    cues: list[CueOut] = []
    if cues_enabled:
        sentences = split_sentences(text)
        for label in label_segments(sentences, plan):
            if label.isCue:
                cues.append(
                    CueOut(id=f"cue{len(cues) + 1}", exerciseId=label.exerciseId, text=sentences[label.index])
                )
    return ReplyResponse(transcript=text, changes=validated.changes, unclear=validated.unclear, cues=cues)


def read_audio_reply(
    data: bytes, filename: str, plan: PlanState, cues_enabled: bool, today: date | None = None
) -> ReplyResponse:
    with tempfile.TemporaryDirectory(prefix="setecho-reply-") as tmp:
        src = Path(tmp) / (Path(filename).name or "reply.bin")
        src.write_bytes(data)
        try:
            wav = audio.convert_to_transcribe_wav(src)
        except subprocess.CalledProcessError as e:
            raise ValueError(f"could not read the audio: {e.stderr.decode(errors='replace')[:200]}") from e
        wav_path = Path(tmp) / "reply.wav"
        wav_path.write_bytes(wav)
        duration = audio.wav_info(wav).duration_s
        if duration < 0.3:
            raise ValueError("the audio is empty")
        segments = segments_from_silences(duration, detect_silences(wav_path)) if cues_enabled else None
    transcript, texts = transcribe(wav, segments)
    if not transcript:
        raise ValueError("nothing was heard in the audio")
    validated = read_changes(transcript, plan, today)
    cues: list[CueOut] = []
    if cues_enabled and segments:
        spoken = [(seg, t) for seg, t in zip(segments, texts, strict=True) if t]
        for label in label_segments([t for _, t in spoken], plan):
            if label.isCue:
                seg, t = spoken[label.index]
                cues.append(
                    CueOut(id=f"cue{len(cues) + 1}", exerciseId=label.exerciseId, text=t,
                           startSec=round(seg.start, 2), endSec=round(seg.end, 2))
                )  # fmt: skip
    return ReplyResponse(
        transcript=transcript, changes=validated.changes, unclear=validated.unclear, cues=cues
    )


def new_id() -> str:
    return str(uuid.uuid4())
