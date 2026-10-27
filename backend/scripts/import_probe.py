"""M0 gate G5: does Muse Spark read the coach's spreadsheet and check-in form correctly?

  uv run python -m scripts.import_probe program.xlsx form.txt
  uv run python -m scripts.import_probe program.csv form.png          # either can be an image
  uv run python -m scripts.import_probe --program-only program.xlsx
  uv run python -m scripts.import_probe --form-only form.txt
  uv run python -m scripts.import_probe ... --fixture                 # also save raw JSON to tests/fixtures/spark/

Prints the Program (weeks / days / exercises / sets) and the CheckInTemplate (fields with
sources), then saves the raw Spark JSON and usage to backend/private/probes/import/ (gitignored).
Pass: the human confirms every exercise, set and rep, and all 22 fields with their sources.
Only use --fixture on synthetic inputs; the real form holds the coach's targets.
"""

from __future__ import annotations

import argparse
import json
import shutil
import time
from pathlib import Path

from app import importing
from app.schemas import CheckInTemplate, PlannedSet, Program

ROOT = Path(__file__).resolve().parents[1]
PRIVATE = ROOT / "private" / "probes" / "import"
FIXTURES = ROOT / "tests" / "fixtures" / "spark"


def fmt_set(s: PlannedSet) -> str:
    reps = str(s.reps) if s.reps is not None else f"{s.repsMin}-{s.repsMax}" if s.repsMin is not None else "?"
    parts = [f"{reps} reps"]
    if s.loadLb is not None:
        parts.append(f"{s.loadLb:g} lb")
    if s.rpe is not None:
        parts.append(f"RPE {s.rpe:g}")
    if s.rir is not None:
        parts.append(f"RIR {s.rir}")
    return " · ".join(parts)


def print_program(p: Program) -> None:
    print(f"\n=== Program: {p.name} ({len(p.weeks)} weeks)")
    for week in p.weeks:
        print(f"Week {week.number}")
        for day in week.days:
            print(f"  {day.name}  [{day.id}]")
            for ex in day.exercises:
                rest = f", rest {ex.restSeconds}s" if ex.restSeconds else ""
                notes = f"  note: {ex.notes}" if ex.notes else ""
                print(f"    {ex.name} ({len(ex.sets)} sets{rest}){notes}")
                for i, s in enumerate(ex.sets, 1):
                    print(f"      set {i}: {fmt_set(s)}")
    print(f"flags: {len(p.flags)}")
    for f in p.flags:
        print(f"  ! {f.path}: {f.message}")


def print_template(t: CheckInTemplate) -> None:
    print(f"\n=== Check-in template: {len(t.fields)} fields, {len(t.carriedBlocks)} carried blocks")
    for b in t.carriedBlocks:
        print(f"  [carried] {b.title}: {b.text.strip().splitlines()[0]!r} ...")
    for f in t.fields:
        src = f.source.type + (f"({f.source.key})" if f.source.key else "")
        prompt = f"  {f.prompt}" if f.prompt else ""
        print(f"  {f.order + 1:2d}. {f.label}{prompt}  -> {f.kind}, {src}  [{f.id}]")


def save(name: str, payload: dict, fixture: bool) -> None:
    PRIVATE.mkdir(parents=True, exist_ok=True)
    out = PRIVATE / f"{name}.json"
    out.write_text(json.dumps(payload, indent=2, default=str))
    print(f"saved {out.relative_to(ROOT)}")
    if fixture:
        FIXTURES.mkdir(parents=True, exist_ok=True)
        shutil.copy(out, FIXTURES / out.name)
        print(f"fixture {FIXTURES.relative_to(ROOT) / out.name}")


def save_invalid(name: str, source: Path, error: importing.ImportValidationError) -> None:
    """Spark answered but the JSON failed validation: keep the raw output so the schema can be fixed."""
    PRIVATE.mkdir(parents=True, exist_ok=True)
    out = PRIVATE / f"{name}.invalid.json"
    out.write_text(json.dumps({"source": source.name, "error": str(error.error), "raw": error.raw}, indent=2))
    print(f"\nINVALID: {error.error}\nraw output saved to {out.relative_to(ROOT)}")


def main() -> None:
    p = argparse.ArgumentParser()
    p.add_argument(
        "inputs", nargs="+", help="<sheet> <form>, or one of them with --program-only / --form-only"
    )
    p.add_argument("--program-only", action="store_true")
    p.add_argument("--form-only", action="store_true")
    p.add_argument("--fixture", action="store_true", help="also copy raw output into tests/fixtures/spark/")
    args = p.parse_args()

    sheet = form = None
    if args.program_only:
        sheet = Path(args.inputs[0])
    elif args.form_only:
        form = Path(args.inputs[0])
    else:
        if len(args.inputs) != 2:
            p.error("give <sheet> <form>, or use --program-only / --form-only")
        sheet, form = Path(args.inputs[0]), Path(args.inputs[1])

    if sheet:
        t0 = time.time()
        try:
            program, raw, resp = importing.import_program(upload=importing.Upload.from_path(sheet))
        except importing.ImportValidationError as e:
            save_invalid(f"program_{sheet.stem}", sheet, e)
            raise SystemExit(1) from e
        dt = time.time() - t0
        print_program(program)
        print(f"spark: {dt:.1f}s, usage {resp.usage.model_dump() if resp.usage else None}")
        save(
            f"program_{sheet.stem}",
            {"source": sheet.name, "latency_s": dt, "raw": raw, "program": program.model_dump(mode="json")},
            args.fixture,
        )
    if form:
        t0 = time.time()
        try:
            template, raw, resp = importing.import_form(upload=importing.Upload.from_path(form))
        except importing.ImportValidationError as e:
            save_invalid(f"form_{form.stem}", form, e)
            raise SystemExit(1) from e
        dt = time.time() - t0
        print_template(template)
        print(f"spark: {dt:.1f}s, usage {resp.usage.model_dump() if resp.usage else None}")
        save(
            f"form_{form.stem}",
            {"source": form.name, "latency_s": dt, "raw": raw, "template": template.model_dump(mode="json")},
            args.fixture,
        )


if __name__ == "__main__":
    main()
