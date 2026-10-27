"""Coach material in, structured JSON out: the sheet or form becomes Spark input, and Spark's
output gets its ids from code. Used by /import/* and by scripts/import_probe.py.

Conversions happen here, never on the model: .xlsx becomes CSV text with openpyxl, images become
base64 data URLs, a Google Sheets link is fetched as an .xlsx export. Raw binary never goes to Spark.
"""

from __future__ import annotations

import csv
import io
import mimetypes
import re
from dataclasses import dataclass
from datetime import UTC, datetime
from pathlib import Path
from typing import Any

import httpx
from pydantic import BaseModel, ValidationError

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
TEXT_SUFFIXES = {".csv", ".txt", ".tsv", ".md"}
SHEET_SUFFIXES = {".xlsx", ".xlsm"}
PROGRAM_SCHEMA = strict_schema(ProgramOut)
TEMPLATE_SCHEMA = strict_schema(CheckInTemplateOut)
MAX_UPLOAD_BYTES = 20 * 1024 * 1024

_SHEETS_ID = re.compile(r"docs\.google\.com/spreadsheets/d/([A-Za-z0-9_-]+)")


class ImportError_(ValueError):
    """Bad input (nothing to import, unsupported file, private sheet). Maps to HTTP 422."""


class ImportValidationError(ValueError):
    """Spark answered, but the JSON does not fit the schema. Carries the raw output for inspection."""

    def __init__(self, raw: dict, error: ValidationError):
        super().__init__(f"model output failed validation: {error}")
        self.raw = raw
        self.error = error


@dataclass(frozen=True)
class Upload:
    filename: str
    data: bytes

    @property
    def suffix(self) -> str:
        return Path(self.filename).suffix.lower()

    @classmethod
    def from_path(cls, path: Path) -> Upload:
        return cls(path.name, path.read_bytes())


def is_image(name: str | Path) -> bool:
    return Path(name).suffix.lower() in IMAGE_SUFFIXES


# ---------------------------------------------------------------------------
# Input conversion
# ---------------------------------------------------------------------------


def upload_to_text(upload: Upload) -> str:
    """A .csv/.txt passes through; a .xlsx becomes one CSV block per worksheet."""
    if len(upload.data) > MAX_UPLOAD_BYTES:
        raise ImportError_(f"file is larger than {MAX_UPLOAD_BYTES // (1024 * 1024)} MB")
    if upload.suffix in TEXT_SUFFIXES:
        return upload.data.decode("utf-8-sig", errors="replace")
    if upload.suffix in SHEET_SUFFIXES:
        return xlsx_to_text(upload.data)
    raise ImportError_(f"unsupported file type {upload.suffix!r}; use .csv, .xlsx, text or an image")


def sheet_to_text(path: Path) -> str:
    return upload_to_text(Upload.from_path(path))


def xlsx_to_text(data: bytes) -> str:
    import openpyxl

    try:
        wb = openpyxl.load_workbook(io.BytesIO(data), data_only=True, read_only=True)
    except Exception as e:  # openpyxl raises several unrelated types for a bad file
        raise ImportError_(f"could not read the spreadsheet: {e}") from e
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
    if not blocks:
        raise ImportError_("the spreadsheet has no filled cells")
    return "\n\n".join(blocks)


def _cell(value: Any) -> str:
    if isinstance(value, float) and value.is_integer():
        return str(int(value))
    if isinstance(value, datetime):
        return value.date().isoformat()
    return str(value)


def image_content(upload: Upload, instruction: str) -> list[dict[str, Any]]:
    mime = mimetypes.guess_type(upload.filename)[0] or "image/jpeg"
    return [
        {"type": "text", "text": instruction},
        {"type": "image_url", "image_url": {"url": meta.data_url(upload.data, mime)}},
    ]


# ---------------------------------------------------------------------------
# Google Sheets link
# ---------------------------------------------------------------------------


def sheets_export_url(link: str) -> str:
    """The whole-workbook .xlsx export for a Google Sheets link. Every tab comes along."""
    m = _SHEETS_ID.search(link)
    if not m:
        raise ImportError_("that is not a Google Sheets link")
    return f"https://docs.google.com/spreadsheets/d/{m.group(1)}/export?format=xlsx"


def fetch_sheet(link: str, timeout: float = 30.0) -> Upload:
    """Download a Google Sheet shared as "anyone with the link". A sign-in page means it is private."""
    url = sheets_export_url(link)
    try:
        r = httpx.get(url, follow_redirects=True, timeout=timeout)
    except httpx.HTTPError as e:
        raise ImportError_(f"could not reach Google Sheets: {e}") from e
    content_type = r.headers.get("content-type", "")
    if r.status_code != 200 or "text/html" in content_type:
        raise ImportError_(
            'the sheet is not shared. In Google Sheets choose Share, then "Anyone with the link".'
        )
    return Upload("sheet.xlsx", r.content)


# ---------------------------------------------------------------------------
# Spark calls
# ---------------------------------------------------------------------------


def _user_content(
    upload: Upload | None, text: str | None, url: str | None, instruction: str
) -> meta.UserContent:
    if url:
        upload = fetch_sheet(url)
    if upload is not None and is_image(upload.filename):
        return image_content(upload, instruction)
    if upload is not None:
        text = upload_to_text(upload)
    if not text or not text.strip():
        raise ImportError_("nothing to import: give a file, a link or text")
    return f"{instruction}\n\n{text}"


def _validate[T: BaseModel](model: type[T], raw: dict) -> T:
    try:
        return model.model_validate(raw)
    except ValidationError as e:
        raise ImportValidationError(raw, e) from e


def import_program(
    *, upload: Upload | None = None, text: str | None = None, url: str | None = None
) -> tuple[Program, dict, Any]:
    """Returns the Program with ids, Spark's raw JSON, and the raw response."""
    user = _user_content(upload, text, url, "Convert this training spreadsheet.")
    raw, resp = meta.spark_json(prompts.IMPORT_PROGRAM, user, "Program", PROGRAM_SCHEMA)
    program = to_program(_validate(ProgramOut, raw), datetime.now(UTC))
    return program, raw, resp


def import_form(
    *, upload: Upload | None = None, text: str | None = None, url: str | None = None
) -> tuple[CheckInTemplate, dict, Any]:
    """Returns the CheckInTemplate with ids and order, Spark's raw JSON, and the raw response."""
    user = _user_content(upload, text, url, "Convert this weekly check-in form.")
    raw, resp = meta.spark_json(prompts.IMPORT_FORM, user, "CheckInTemplate", TEMPLATE_SCHEMA)
    template = to_template(_validate(CheckInTemplateOut, raw))
    return template, raw, resp
