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
    CheckInSchedule,
    CheckInTemplateOut,
    FormImport,
    ImportFlag,
    Program,
    ProgramOut,
    ProgressionRule,
    RestRule,
    RoleTarget,
    RulesImport,
    RulesOut,
    WarmupRule,
    form_targets,
    strict_schema,
    to_program,
    to_template,
)

IMAGE_SUFFIXES = {".png", ".jpg", ".jpeg", ".webp", ".gif"}
TEXT_SUFFIXES = {".csv", ".txt", ".tsv", ".md"}
SHEET_SUFFIXES = {".xlsx", ".xlsm"}
PROGRAM_SCHEMA = strict_schema(ProgramOut)
TEMPLATE_SCHEMA = strict_schema(CheckInTemplateOut)
RULES_SCHEMA = strict_schema(RulesOut)
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
    out = _validate(ProgramOut, raw)
    if isinstance(user, str):
        # A rule the sheet does not contain is dropped to flags (HANDOFF.md §8, Rules from the sheet).
        kept, dropped = [], []
        for r in out.rules:
            if quote_in_text(r.quote, user) and not _personal(r.quote):
                kept.append(r)
            else:
                dropped.append(r)
        out.rules = kept
        out.flags = list(out.flags) + [
            ImportFlag(
                path="rules", message=f'A rule whose words are not in the sheet was left out: "{r.quote}"'
            )
            for r in dropped
        ]
    program = to_program(out, datetime.now(UTC))
    return program, raw, resp


def import_form(
    *, upload: Upload | None = None, text: str | None = None, url: str | None = None
) -> tuple[FormImport, dict, Any]:
    """Returns the template with ids and order plus the targets and cardio protocol read from the
    form's blocks, Spark's raw JSON, and the raw response."""
    user = _user_content(upload, text, url, "Convert this weekly check-in form.")
    raw, resp = meta.spark_json(prompts.IMPORT_FORM, user, "CheckInTemplate", TEMPLATE_SCHEMA)
    out = _validate(CheckInTemplateOut, raw)
    cardio = (out.cardioProtocol or "").strip() or None
    return FormImport(template=to_template(out), targets=form_targets(out), cardioProtocol=cardio), raw, resp


# ---------------------------------------------------------------------------
# /import/rules: the coach's written instructions, validated against his own words
# ---------------------------------------------------------------------------

RULES_SOURCE = "Coach's instructions"

_NUMBER_WORDS = {
    "zero": 0, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8,
    "nine": 9, "ten": 10, "eleven": 11, "twelve": 12, "fifteen": 15, "twenty": 20, "thirty": 30,
    "forty": 40, "fifty": 50, "sixty": 60, "ninety": 90, "hundred": 100,
    # cadence words that carry a count
    "once": 1, "weekly": 1, "single": 1, "twice": 2, "other": 2, "biweekly": 2, "fortnight": 2,
    "fortnightly": 2, "couple": 2, "pair": 2, "triple": 3, "thrice": 3, "half": 0.5,
}  # fmt: skip
_WEEKDAYS = ("sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday")
_LINK = re.compile(r"https?://|www\.|\b[a-z0-9-]+\.(com|net|org|io|app|co)\b|@[a-z0-9]", re.IGNORECASE)
_PHONE = re.compile(r"\(?\d{3}\)?[-.\s]\d{3}[-.\s]\d{4}")
_PROMO = re.compile(r"\b(code|coupon|discount)\b.{0,20}\b[A-Z0-9]{4,}\b")


def _squash(text: str) -> str:
    return re.sub(r"\s+", "", text.lower())


def quote_in_text(quote: str, text: str) -> bool:
    """The quote is a verbatim span of the text, ignoring case and whitespace."""
    q = _squash(quote)
    return bool(q) and q in _squash(text)


def numbers_in(text: str) -> set[float]:
    """Every number the text carries: digits (including each side of "3-4" and "20-25%", and the hour of
    "9:00"), number words, and the cadence words that mean a count ("every other week")."""
    found: set[float] = set()
    for m in re.finditer(r"\d+(?:\.\d+)?", text):
        found.add(float(m.group()))
    for word in re.findall(r"[a-z]+", text.lower()):
        if word in _NUMBER_WORDS:
            found.add(float(_NUMBER_WORDS[word]))
    return found


def _has_number(value: float | None, quote: str, *, minutes_ok: bool = False) -> bool:
    if value is None:
        return True
    numbers = numbers_in(quote)
    v = abs(float(value))
    if v in numbers:
        return True
    return minutes_ok and v % 60 == 0 and v / 60 in numbers  # "3-4 minutes" is 180-240 s


def _weekday_in(weekday: int, quote: str) -> bool:
    return 1 <= weekday <= 7 and _WEEKDAYS[weekday - 1] in quote.lower()


def _hour_in(due_by: str, quote: str) -> bool:
    m = re.match(r"^(\d{1,2}):(\d{2})$", due_by.strip())
    if not m:
        return False
    hour = int(m.group(1))
    numbers = numbers_in(quote)
    return hour in numbers or (hour > 12 and hour - 12 in numbers) or (hour == 12 and "noon" in quote.lower())


def _personal(quote: str) -> bool:
    return bool(_LINK.search(quote) or _PHONE.search(quote) or _PROMO.search(quote))


def validate_rules(out: RulesOut, text: str) -> RulesImport:
    """Every quote must appear in the text and every number in a rule must appear in its quote
    (HANDOFF.md §5). Anything that fails moves to `flags` with its quote; a quote carrying a link,
    a phone number or a promo code is dropped without being repeated."""
    flags: list[ImportFlag] = list(out.flags)

    def check(path: str, quote: str, ok: bool, what: str) -> bool:
        if _personal(quote):
            flags.append(
                ImportFlag(path=path, message="Left out: the sentence carries a link, number or code")
            )
            return False
        if not quote_in_text(quote, text):
            flags.append(ImportFlag(path=path, message=f'The words were not found in the text: "{quote}"'))
            return False
        if not ok:
            flags.append(ImportFlag(path=path, message=f'A number is not in his words: "{quote}" ({what})'))
            return False
        return True

    rules: list[ProgressionRule] = []
    for i, r in enumerate(out.rules):
        q = r.quote
        amount_ok = _has_number(r.amount, q) or (r.adjust == "loadSteps" and r.amount == 1)
        ok = _has_number(r.byRPE, q) and amount_ok and _has_number(r.minPct, q) and _has_number(r.maxPct, q)
        if r.adjust == "backOff" and (r.minPct is None or r.maxPct is None):
            ok = False
        if check(f"rules[{i}]", q, ok, "the amount"):
            rules.append(ProgressionRule(id=f"rule_{len(rules) + 1}", source=RULES_SOURCE, **r.model_dump()))

    role_targets: list[RoleTarget] = []
    for i, t in enumerate(out.roleTargets):
        q = t.quote
        ok = _has_number(t.rir, q) or (t.rir == 0 and re.search(r"\bfail", q.lower()) is not None)
        if check(f"roleTargets[{i}]", q, ok, "reps in reserve"):
            role_targets.append(RoleTarget(source=RULES_SOURCE, **t.model_dump()))

    rest_rules: list[RestRule] = []
    for i, rr in enumerate(out.restRules):
        q = rr.quote
        ok = _has_number(rr.minSeconds, q, minutes_ok=True) and _has_number(rr.maxSeconds, q, minutes_ok=True)
        ok = ok and 0 < rr.minSeconds <= rr.maxSeconds
        if check(f"restRules[{i}]", q, ok, "the rest time"):
            rest_rules.append(RestRule(**rr.model_dump()))

    warmups: WarmupRule | None = None
    if (w := out.warmups) is not None:
        ok = (
            _has_number(w.minSets, w.quote)
            and _has_number(w.maxSets, w.quote)
            and _has_number(w.maxReps, w.quote)
        )
        if check("warmups", w.quote, ok and 0 < w.minSets <= w.maxSets, "the sets or reps"):
            warmups = WarmupRule(**w.model_dump())

    schedule: CheckInSchedule | None = None
    if (c := out.checkInSchedule) is not None:
        ok = (
            _has_number(c.everyWeeks, c.quote)
            and _weekday_in(c.weekday, c.quote)
            and _hour_in(c.dueBy, c.quote)
        )
        if check("checkInSchedule", c.quote, ok, "the cadence, day or time"):
            schedule = CheckInSchedule(**c.model_dump())

    quiet_days: list[int] = []
    for i, d in enumerate(out.quietDays):
        if (
            check(f"quietDays[{i}]", d.quote, _weekday_in(d.weekday, d.quote), "the day")
            and d.weekday not in quiet_days
        ):
            quiet_days.append(d.weekday)

    return RulesImport(
        rules=rules, roleTargets=role_targets, restRules=rest_rules, warmups=warmups,
        checkInSchedule=schedule, quietDays=quiet_days, flags=flags,
    )  # fmt: skip


def import_rules(text: str) -> tuple[RulesImport, dict, Any]:
    """His onboarding email, pasted once: every rule it states, each with his quote, nothing confirmed."""
    if not text or not text.strip():
        raise ImportError_("nothing to import: paste the coach's instructions")
    user = f"List the rules in these instructions.\n\n{text.strip()}"
    raw, resp = meta.spark_json(prompts.IMPORT_RULES, user, "Rules", RULES_SCHEMA)
    return validate_rules(_validate(RulesOut, raw), text), raw, resp
