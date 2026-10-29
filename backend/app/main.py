"""Setecho API. Stateless: it holds the key, converts, measures, validates, and returns JSON.

Contract (HANDOFF.md §5): every endpoint answers 422 with {"error": "..."} when the input or the
model output does not validate. It never guesses.
"""

from __future__ import annotations

from datetime import date
from typing import Annotated, Literal

from fastapi import FastAPI, File, Form, Request, UploadFile
from fastapi.concurrency import run_in_threadpool
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse
from pydantic import ValidationError

from app import (
    audio,
    checkin_api,
    checkin_turn,
    coach,
    history,
    importing,
    meta,
    photos_api,
    realtime,
    session_turn,
    sets_api,
    spotter,
    voice,
    withings,
)
from app.schemas import FormImport, Program, RulesImport, StrictModel

app = FastAPI(title="Setecho API", version="0.4.0")
app.include_router(photos_api.router)
app.include_router(sets_api.router)
app.include_router(checkin_api.router)
app.include_router(checkin_turn.router)
app.include_router(spotter.router)
app.include_router(realtime.router)
app.include_router(session_turn.router)
app.include_router(withings.router)
app.include_router(history.router)


@app.exception_handler(importing.ImportError_)
@app.exception_handler(photos_api.NoPersonError)
@app.exception_handler(sets_api.ClipError)
@app.exception_handler(ValueError)
@app.exception_handler(importing.ImportValidationError)
@app.exception_handler(ValidationError)
async def _unprocessable(_: Request, exc: Exception) -> JSONResponse:
    return JSONResponse(status_code=422, content={"error": str(exc).splitlines()[0]})


@app.exception_handler(RequestValidationError)
async def _bad_request(_: Request, exc: RequestValidationError) -> JSONResponse:
    """The contract is 422 {"error"}: name the first bad field so the app can show it."""
    first = exc.errors()[0] if exc.errors() else {}
    where = ".".join(str(x) for x in first.get("loc", []) if x != "body")
    return JSONResponse(status_code=422, content={"error": f"{where}: {first.get('msg', 'invalid request')}"})


@app.get("/health")
def health() -> dict:
    return {
        "ok": True,
        "models": {"spark": meta.SPARK_MODEL, "transcribe": meta.TRANSCRIBE_MODEL, "sam": meta.SAM_MODEL},
    }


async def _upload(file: UploadFile | None) -> importing.Upload | None:
    if file is None or not file.filename:
        return None
    return importing.Upload(file.filename, await file.read())


@app.post("/import/program", response_model=Program)
async def import_program(
    file: Annotated[UploadFile | None, File()] = None,
    text: Annotated[str | None, Form()] = None,
    url: Annotated[str | None, Form()] = None,
) -> Program:
    """The coach's spreadsheet: a .csv/.xlsx/image file, pasted text, or a Google Sheets link."""
    program, _, _ = importing.import_program(upload=await _upload(file), text=text, url=url)
    return program


class VoiceCommandResponse(StrictModel):
    transcript: str
    intent: voice.VoiceIntent
    sessionId: str | None
    classifiedBy: Literal["rules", "spark", "none"] = "none"


class VoiceTextRequest(StrictModel):
    transcript: str
    context: voice.SessionContext


@app.exception_handler(meta.TranscribeError)
async def _transcribe_failed(_: Request, exc: meta.TranscribeError) -> JSONResponse:
    status = exc.status if exc.status in (400, 429, 500) else 502
    return JSONResponse(status_code=status, content={"error": str(exc)})


@app.post("/voice/command", response_model=VoiceCommandResponse)
async def voice_command(
    audio_file: Annotated[UploadFile, File(alias="audio")],
    context: Annotated[str, Form()],
) -> VoiceCommandResponse:
    """One spoken utterance (WAV) + session context -> transcript and VoiceIntent.

    Transcription is Muse Voice Transcribe in PUSH_TO_TALK. Classification is the rule layer for
    plain commands, else Muse Spark. An empty transcript is `unknown`, never acted on.
    """
    ctx = voice.SessionContext.model_validate_json(context)
    data = await audio_file.read()
    try:
        audio.check_transcribe_wav(data)
    except ValueError as e:
        raise importing.ImportError_(str(e)) from e
    result = meta.transcribe_wav(data)
    response = await _classify((result.get("transcript") or "").strip(), ctx)
    response.sessionId = result.get("sessionId")
    return response


@app.post("/voice/command/text", response_model=VoiceCommandResponse)
async def voice_command_text(req: VoiceTextRequest) -> VoiceCommandResponse:
    """An utterance the realtime stream already transcribed + session context -> VoiceIntent. The
    same rules then Spark as /voice/command, with no audio and no Transcribe call."""
    return await _classify(req.transcript.strip(), req.context)


async def _classify(transcript: str, ctx: voice.SessionContext) -> VoiceCommandResponse:
    """An empty transcript is `unknown`, never acted on."""
    if not transcript:
        unknown = voice.intent("unknown", confidence=0.0)
        return VoiceCommandResponse(transcript="", intent=unknown, sessionId=None, classifiedBy="none")
    intent, by = await run_in_threadpool(voice.route, transcript, ctx)
    return VoiceCommandResponse(transcript=transcript, intent=intent, sessionId=None, classifiedBy=by)


@app.post("/import/form", response_model=FormImport)
async def import_form(
    request: Request,
    file: Annotated[UploadFile | None, File()] = None,
    text: Annotated[str | None, Form()] = None,
) -> FormImport:
    """The coach's check-in form: multipart (file or text), or JSON {"text": "..."}. Returns the
    template plus the macro targets and cardio protocol read from its blocks (the first PlanState)."""
    upload = await _upload(file)
    if upload is None and text is None and "application/json" in request.headers.get("content-type", ""):
        body = await request.json()
        text = body.get("text") if isinstance(body, dict) else None
    result, _, _ = importing.import_form(upload=upload, text=text)
    return result


class RulesRequest(StrictModel):
    text: str


@app.post("/import/rules", response_model=RulesImport)
async def import_rules(req: RulesRequest) -> RulesImport:
    """The coach's written instructions (his onboarding email), pasted once. Returns the rules he states
    with his quotes, each unconfirmed, and nothing personal (HANDOFF.md §5)."""
    result, _, _ = await run_in_threadpool(importing.import_rules, req.text)
    return result


def _today(value: str | None) -> date | None:
    try:
        return date.fromisoformat(value) if value else None
    except ValueError:
        return None


@app.post("/coach/reply", response_model=coach.ReplyResponse)
async def coach_reply(
    request: Request,
    audio_file: Annotated[UploadFile | None, File(alias="audio")] = None,
    plan: Annotated[str | None, Form()] = None,
    cuesEnabled: Annotated[bool | None, Form()] = None,
    today: Annotated[str | None, Form()] = None,
) -> coach.ReplyResponse:
    """The coach's reply as JSON {text, plan, cuesEnabled, today} or multipart `audio` (a WhatsApp
    voice note) + `plan` JSON. Returns the proposed changes with his quotes, the unclear sentences,
    and the voice cues. Nothing is applied here."""
    if audio_file is not None and audio_file.filename:
        if not plan:
            raise importing.ImportError_("plan is required")
        state = coach.PlanState.model_validate_json(plan)
        data = await audio_file.read()
        return await run_in_threadpool(
            coach.read_audio_reply, data, audio_file.filename, state, cuesEnabled is not False, _today(today)
        )
    body = await request.json() if "application/json" in request.headers.get("content-type", "") else {}
    req = coach.ReplyRequest.model_validate(body)
    if not req.text:
        raise importing.ImportError_("give the reply as text, or an audio file")
    return await run_in_threadpool(
        coach.read_text_reply, req.text, req.plan, req.cuesEnabled, _today(req.today)
    )
