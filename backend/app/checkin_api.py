"""The check-in endpoints: /checkin/draft, /checkin/answer, /checkin/render (HANDOFF.md §5)."""

from __future__ import annotations

import json
from typing import Annotated

from fastapi import APIRouter, File, Form, UploadFile
from pydantic import Field

from app import audio, checkin, importing, meta
from app.schemas import FieldSpec, StrictModel, strict_schema

router = APIRouter()


@router.post("/checkin/draft", response_model=checkin.CheckInDraft)
def checkin_draft(req: checkin.DraftRequest) -> checkin.CheckInDraft:
    """Every data field from code with its sources; the text fields drafted by Muse Spark through
    tool calls, every number checked against the facts."""
    return checkin.build_draft(req)


class RenderResponse(StrictModel):
    text: str
    messages: list[str] = Field(
        default_factory=list,
        description="The plan message (carried blocks), then the questionnaire, in his order",
    )


@router.post("/checkin/render", response_model=RenderResponse)
def checkin_render(req: checkin.RenderRequest) -> RenderResponse:
    messages = checkin.render_messages(req.template, req.draft, req.adjustments, req.deviations)
    return RenderResponse(text="\n\n".join(messages), messages=messages)


# ---------------------------------------------------------------------------
# Wrap-up answers
# ---------------------------------------------------------------------------


class Measurements(StrictModel):
    waistIn: float | None = None
    bicepIn: float | None = None
    thighIn: float | None = None


class SpokenAnswer(StrictModel):
    text: str = Field(
        description="The answer as the athlete would type it: their words, filler and false starts removed"
    )
    number: float | None = Field(
        default=None, description="The number for a scale, number or single measurement field; else null"
    )
    measurements: Measurements | None = Field(
        default=None, description="Only when several tape measurements were given at once"
    )
    confidence: float


ANSWER_SCHEMA = strict_schema(SpokenAnswer)

ANSWER_SYSTEM = (
    "Turn the athlete's spoken answer to a check-in question into the text they'd type. Keep their "
    "words and tone; fix only filler and false starts. Extract the number for scale or measurement "
    'fields. "Twenty-four and three quarters" is 24.75. For a scale field, write the text as "N/10" '
    "followed by anything they added. When the question covers several tape measurements, fill "
    "`measurements` in the order asked. Never add facts the athlete did not say."
)


class AnswerResponse(StrictModel):
    transcript: str
    answers: list[checkin.FieldAnswer]


@router.post("/checkin/answer", response_model=AnswerResponse)
async def checkin_answer(
    audio_file: Annotated[UploadFile, File(alias="audio")],
    fields: Annotated[
        str, Form(description="JSON list of FieldSpec, 1 to 3 (the tape measurements are one question)")
    ],
    styleExamples: Annotated[str | None, Form()] = None,
    askedOn: Annotated[str | None, Form(description="yyyy-mm-dd, for the provenance")] = None,
) -> AnswerResponse:
    specs = [FieldSpec.model_validate(f) for f in json.loads(fields)]
    if not specs:
        raise importing.ImportError_("no fields given")
    data = await audio_file.read()
    try:
        audio.check_transcribe_wav(data)
    except ValueError as e:
        raise importing.ImportError_(str(e)) from e
    transcript = (meta.transcribe_wav(data).get("transcript") or "").strip()
    if not transcript:
        return AnswerResponse(transcript="", answers=[
            checkin.FieldAnswer(fieldId=f.id, text="", state="missing", provenance=[]) for f in specs
        ])  # fmt: skip

    labels = "; ".join(f"{f.label}{' ' + f.prompt if f.prompt else ''} [{f.kind}]" for f in specs)
    examples = "\n".join(f"- {e}" for e in json.loads(styleExamples or "[]")) or "- (none)"
    user = f"Question(s): {labels}\nExamples of how the athlete writes:\n{examples}\nSpoken answer: {transcript!r}"
    raw, _ = meta.spark_json(ANSWER_SYSTEM, user, "SpokenAnswer", ANSWER_SCHEMA)
    spoken = SpokenAnswer.model_validate(raw)
    when = f"You said · {checkin._mdy(askedOn)}" if askedOn else "You said"
    state = "filled" if spoken.confidence >= 0.7 else "drafted"

    answers: list[checkin.FieldAnswer] = []
    if len(specs) > 1 and spoken.measurements is not None:
        values = [spoken.measurements.waistIn, spoken.measurements.bicepIn, spoken.measurements.thighIn]
        for spec, value in zip(specs, values, strict=False):
            text = f"{_fmt_in(value)} in" if value is not None else ""
            answers.append(checkin.FieldAnswer(
                fieldId=spec.id, text=text, state=state if value is not None else "missing",
                provenance=[checkin.Provenance(source=when, detail=transcript)]))  # fmt: skip
        return AnswerResponse(transcript=transcript, answers=answers)

    spec = specs[0]
    text = spoken.text.strip()
    if spec.kind == "measurement" and spoken.number is not None and "in" not in text:
        text = f"{_fmt_in(spoken.number)} in"
    elif spec.kind == "scale10" and spoken.number is not None and "/10" not in text:
        text = f"{checkin._fmt(spoken.number)}/10" + (f", {text}" if text else "")
    answers.append(checkin.FieldAnswer(
        fieldId=spec.id, text=text, state=state, provenance=[checkin.Provenance(source=when, detail=transcript)]))  # fmt: skip
    for extra in specs[1:]:
        answers.append(checkin.FieldAnswer(fieldId=extra.id, text="", state="missing", provenance=[]))
    return AnswerResponse(transcript=transcript, answers=answers)


def _fmt_in(value: float) -> str:
    """24.75 -> "24 3/4", 31 -> "31", 16.5 -> "16 1/2": the athlete's own tape style."""
    whole = int(value)
    frac = round(value - whole, 2)
    names = {0.25: "1/4", 0.5: "1/2", 0.75: "3/4"}
    if frac in names:
        return f"{whole} {names[frac]}"
    return checkin._fmt(value)
