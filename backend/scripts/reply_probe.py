"""G5 extended / P2: run one of the coach's real replies through /coach/reply's logic.

  uv run python -m scripts.reply_probe <reply.txt | voice.opus> [--plan plan.json] [--no-cues] [--fixture]

With no --plan, the plan is the synthetic one built from the saved import fixtures. Output goes
to backend/private/coach/ (gitignored): the coach's words never enter the repo. `--fixture` saves
only the model's raw change list for a synthetic reply you wrote yourself. Costs one or two
Spark calls, plus Transcribe for audio (about $0.003 a minute).
"""

from __future__ import annotations

import argparse
import json
import time
from datetime import UTC, date, datetime
from pathlib import Path

from app import coach
from app.schemas import CheckInTemplateOut, Macros, MacroTargets, ProgramOut, to_program, to_template

ROOT = Path(__file__).resolve().parents[1]
FIXTURES = ROOT / "tests" / "fixtures"
PRIVATE = ROOT / "private" / "coach"


def synthetic_plan() -> coach.PlanState:
    program = to_program(
        ProgramOut.model_validate(
            json.loads((FIXTURES / "spark" / "program_synthetic_program.json").read_text())["raw"]
        ),
        datetime.now(UTC),
    )
    template = to_template(
        CheckInTemplateOut.model_validate(
            json.loads((FIXTURES / "spark" / "form_coach_form.json").read_text())["raw"]
        )
    )
    return coach.PlanState(
        version=1,
        program=program,
        targets=MacroTargets(
            training=Macros(kcal=2400, proteinG=200, carbsG=250, fatG=65),
            rest=Macros(kcal=2100, proteinG=200, carbsG=175, fatG=65),
        ),
        cardioProtocol="25 min LISS × 2 on rest days",
        carriedBlocks=template.carriedBlocks,
    )


def main() -> None:
    p = argparse.ArgumentParser()
    p.add_argument("reply", help="a .txt reply or an audio file (.opus/.ogg/.m4a/.wav)")
    p.add_argument("--plan", help="a PlanState JSON exported from the phone")
    p.add_argument("--no-cues", action="store_true")
    p.add_argument(
        "--fixture",
        action="store_true",
        help="save the result to tests/fixtures/coach/ (synthetic replies only)",
    )
    args = p.parse_args()

    plan = coach.PlanState.model_validate_json(Path(args.plan).read_text()) if args.plan else synthetic_plan()
    src = Path(args.reply)
    t0 = time.time()
    if src.suffix.lower() == ".txt":
        result = coach.read_text_reply(src.read_text(), plan, not args.no_cues, date.today())
    else:
        result = coach.read_audio_reply(src.read_bytes(), src.name, plan, not args.no_cues, date.today())
    dt = time.time() - t0

    print(f"{dt:.1f}s\n\n=== transcript\n{result.transcript}\n\n=== changes")
    for c in result.changes:
        start = f" from {c.appliesFrom}" if c.appliesFrom else ""
        print(f"  [{c.kind}] {c.label}: {c.before or '—'} → {c.after}{start}\n      “{c.quote}”")
    print("\n=== unclear")
    for u in result.unclear:
        print(f"  “{u}”")
    print("\n=== cues")
    for cue in result.cues:
        when = f" ({cue.startSec}–{cue.endSec} s)" if cue.startSec is not None else ""
        print(f"  {cue.exerciseId}{when}: “{cue.text}”")

    PRIVATE.mkdir(parents=True, exist_ok=True)
    out = {"source": src.name, "latency_s": dt, "result": result.model_dump(mode="json")}
    (PRIVATE / f"{src.stem}.json").write_text(json.dumps(out, indent=2))
    if args.fixture:
        (FIXTURES / "coach").mkdir(parents=True, exist_ok=True)
        (FIXTURES / "coach" / f"{src.stem}.json").write_text(json.dumps(out, indent=2))
        print(f"\nfixture tests/fixtures/coach/{src.stem}.json")


if __name__ == "__main__":
    main()
