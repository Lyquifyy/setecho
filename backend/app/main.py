"""Setecho API. Stateless: it holds the key, converts, measures, validates, and returns JSON.

Contract (HANDOFF.md §5): every endpoint answers 422 with {"error": "..."} when the input or the
model output does not validate. It never guesses.
"""

from __future__ import annotations

from typing import Annotated

from fastapi import FastAPI, File, Form, Request, UploadFile
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse
from pydantic import ValidationError

from app import audio, checkin_api, importing, meta, photos_api, sets_api, voice
from app.schemas import CheckInTemplate, Program, StrictModel

app = FastAPI(title="Setecho API", version="0.3.0")
app.include_router(photos_api.router)
app.include_router(sets_api.router)
app.include_router(checkin_api.router)


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
    transcript = (result.get("transcript") or "").strip()
    if not transcript:
        intent = voice.VoiceIntent(intent="unknown", number=None, text=None, fieldId=None, confidence=0.0)
    else:
        intent = voice.classify(transcript, ctx)
    return VoiceCommandResponse(transcript=transcript, intent=intent, sessionId=result.get("sessionId"))


@app.post("/import/form", response_model=CheckInTemplate)
async def import_form(
    request: Request,
    file: Annotated[UploadFile | None, File()] = None,
    text: Annotated[str | None, Form()] = None,
) -> CheckInTemplate:
    """The coach's check-in form: multipart (file or text), or JSON {"text": "..."}."""
    upload = await _upload(file)
    if upload is None and text is None and "application/json" in request.headers.get("content-type", ""):
        body = await request.json()
        text = body.get("text") if isinstance(body, dict) else None
    template, _, _ = importing.import_form(upload=upload, text=text)
    return template
