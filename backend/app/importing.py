"""Coach material in, structured JSON out: the sheet or form becomes Spark input, and Spark's
output gets its ids from code. Used by scripts/import_probe.py now and by /import/* in M1.

Conversions happen here, never on the model: .xlsx becomes CSV text with openpyxl, images become
base64 data URLs. Raw binary never goes to Spark.
"""

from __future__ import annotations

import csv
import io
import mimetypes
from datetime import UTC, datetime
from pathlib import Path
from typing import Any

from app import meta, prompts
from app.schemas import (
    CheckInTemplate,
    CheckInTemplateOut,
    Program,
    ProgramOut,
    strict_schema,
    to_program,
    to_template,
)

IMAGE_SUFFIXES = {".png", ".jpg", ".jpeg", ".webp", ".gif"}
PROGRAM_SCHEMA = strict_schema(ProgramOut)
TEMPLATE_SCHEMA = strict_schema(CheckInTemplateOut)


def is_image(path: Path) -> bool:
    return path.suffix.lower() in IMAGE_SUFFIXES


def sheet_to_text(path: Path) -> str:
    """A .csv passes through; a .xlsx becomes one CSV block per worksheet; .txt passes through."""
    suffix = path.suffix.lower()
    if suffix in {".csv", ".txt", ".tsv", ".md"}:
        return path.read_text(encoding="utf-8-sig")
    if suffix in {".xlsx", ".xlsm"}:
        return xlsx_to_text(path.read_bytes())
    raise ValueError(f"unsupported sheet type {suffix!r}; use .csv, .xlsx, text or an image")


def xlsx_to_text(data: bytes) -> str:
    import openpyxl

    wb = openpyxl.load_workbook(io.BytesIO(data), data_only=True, read_only=True)
    blocks: list[str] = []
    for ws in wb.worksheets:
        buf = io.StringIO()
        writer = csv.writer(buf, lineterminator="\n")
        rows = 0
        for row in ws.iter_rows(values_only=True):
            cells = ["" if v is None else _cell(v) for v in row]
            if any(cells):
                writer.writerow(cells)
                rows += 1
        if rows:
            blocks.append(f"## Sheet: {ws.title}\n{buf.getvalue().rstrip()}")
    return "\n\n".join(blocks)


def _cell(value: Any) -> str:
    if isinstance(value, float) and value.is_integer():
        return str(int(value))
    if isinstance(value, datetime):
        return value.date().isoformat()
    return str(value)


def image_content(path: Path, instruction: str) -> list[dict[str, Any]]:
    mime = mimetypes.guess_type(path.name)[0] or "image/jpeg"
    return [
        {"type": "text", "text": instruction},
        {"type": "image_url", "image_url": {"url": meta.data_url(path.read_bytes(), mime)}},
    ]


def _user_content(source: Path | None, text: str | None, instruction: str) -> meta.UserContent:
    if source is not None and is_image(source):
        return image_content(source, instruction)
    if source is not None:
        text = sheet_to_text(source)
    if not text or not text.strip():
        raise ValueError("nothing to import: give a file or text")
    return f"{instruction}\n\n{text}"


def import_program(source: Path | None = None, text: str | None = None) -> tuple[Program, dict, Any]:
    """Returns the Program with ids, Spark's raw JSON, and the raw response."""
    user = _user_content(source, text, "Convert this training spreadsheet.")
    raw, resp = meta.spark_json(prompts.IMPORT_PROGRAM, user, "Program", PROGRAM_SCHEMA)
    program = to_program(ProgramOut.model_validate(raw), datetime.now(UTC))
    return program, raw, resp


def import_form(source: Path | None = None, text: str | None = None) -> tuple[CheckInTemplate, dict, Any]:
    """Returns the CheckInTemplate with ids and order, Spark's raw JSON, and the raw response."""
    user = _user_content(source, text, "Convert this weekly check-in form.")
    raw, resp = meta.spark_json(prompts.IMPORT_FORM, user, "CheckInTemplate", TEMPLATE_SCHEMA)
    template = to_template(CheckInTemplateOut.model_validate(raw))
    return template, raw, resp
