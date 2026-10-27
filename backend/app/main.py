"""Setecho API. Stateless: it holds the key, converts, measures, validates, and returns JSON.

Contract (HANDOFF.md §5): every endpoint answers 422 with {"error": "..."} when the input or the
model output does not validate. It never guesses.
"""

from __future__ import annotations

from typing import Annotated

from fastapi import FastAPI, File, Form, Request, UploadFile
from fastapi.responses import JSONResponse
from pydantic import ValidationError

from app import importing, meta
from app.schemas import CheckInTemplate, Program

app = FastAPI(title="Setecho API", version="0.2.0")


@app.exception_handler(importing.ImportError_)
@app.exception_handler(importing.ImportValidationError)
@app.exception_handler(ValidationError)
async def _unprocessable(_: Request, exc: Exception) -> JSONResponse:
    return JSONResponse(status_code=422, content={"error": str(exc).splitlines()[0]})


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
