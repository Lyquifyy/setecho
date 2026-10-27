"""Live probe of the check-in agent: Muse Spark drafts the text fields through tool calls over
synthetic facts and the coach's form layout, and the validator checks every number.

  uv run python -m scripts.checkin_probe
  uv run python -m scripts.checkin_probe --fixture     # save the raw draft to tests/fixtures/checkin/

Costs one or two Spark calls. Facts are synthetic; nothing personal goes out.
"""

from __future__ import annotations

import argparse
import json
import time
from pathlib import Path

from app import checkin
from app.schemas import CheckInTemplateOut, to_template

ROOT = Path(__file__).resolve().parents[1]
FIXTURES = ROOT / "tests" / "fixtures"
PRIVATE = ROOT / "private" / "probes" / "checkin"


def synthetic_request() -> checkin.DraftRequest:
    template = to_template(
        CheckInTemplateOut.model_validate(
            json.loads((FIXTURES / "spark" / "form_coach_form.json").read_text())["raw"]
        )
    )

    def day(d, training, kcal=None, p=None, c=None, f=None, steps=None, sleep=None, weight=None, liss=()):
        return checkin.DayFacts(date=d, isTrainingDay=training, kcal=kcal, proteinG=p, carbsG=c, fatG=f, steps=steps,
                                sleepHours=sleep, weighInLb=weight, liss=[checkin.LissSession(**x) for x in liss])  # fmt: skip

    facts = checkin.WeekFacts(
        weekStart="2026-10-23", weekEnd="2026-10-29",
        daily=[
            day("2026-10-23", True, 2400, 200, 250, 65, steps=10412, sleep=7.4, weight=181.6, liss=[{"type": "walking", "minutes": 25}]),
            day("2026-10-24", False, 2100, 200, 175, 65, steps=9950, sleep=7.0, weight=181.4),
            day("2026-10-25", False, 2600, 200, 175, 65, steps=10800, sleep=7.8, weight=181.0, liss=[{"type": "walking", "minutes": 26}]),
            day("2026-10-26", True, 2410, 205, 248, 64, steps=10100, sleep=7.4, weight=180.8),
            day("2026-10-27", True, 2390, 198, 252, 66, steps=11020, sleep=7.1, weight=180.6),
        ],
        targets=checkin.MacroTargets(training=checkin.Macros(kcal=2400, proteinG=200, carbsG=250, fatG=65),
                                     rest=checkin.Macros(kcal=2100, proteinG=200, carbsG=175, fatG=65)),
        showDate=None, lastCheckInWeightLb=181.5,
        sources={"calories": "MacroFactor", "weight": "Withings", "steps": "Garmin", "sleep": "Garmin", "workouts": "Garmin"},
        cardioProtocol="25 min LISS × 2 on rest days",
    )  # fmt: skip
    training = checkin.TrainingSummary(sessionsDone=4, sessionsScheduled=5, setsLogged=38,
                                       prs=[checkin.PersonalRecord(exercise="Bench press", loadLb=190, reps=8)],
                                       exercises=["Bench press", "Barbell row", "Back squat"])  # fmt: skip
    notes = [checkin.VoiceNote(id="n1", at="2026-10-25T18:00:00Z", transcript="digestion's been off since Wednesday",
                               targetFieldId="notes_on_digestion")]  # fmt: skip
    examples = [
        line.strip()
        for line in (FIXTURES / "checkin" / "style_examples.txt").read_text().splitlines()
        if line.strip() and not line.startswith("#")
    ]
    return checkin.DraftRequest(template=template, facts=facts, notes=notes, training=training, lastCheckIn=None,
                                styleExamples=examples, draftId="probe")  # fmt: skip


def main() -> None:
    p = argparse.ArgumentParser()
    p.add_argument("--fixture", action="store_true")
    args = p.parse_args()

    req = synthetic_request()
    wanted = checkin.agent_fields(req.template, req.notes)
    print("agent fields:", [f.id for f in wanted])
    t0 = time.time()
    drafted = checkin.run_agent(req, wanted)
    dt = time.time() - t0
    known = checkin.known_numbers(req.facts, req.training, None)
    print(f"spark agent: {dt:.1f}s")
    for fid, text in drafted.items():
        bad = checkin.validate(text, known)
        print(f"  {fid}: {text!r}" + (f"\n    CHECK THIS: {bad}" if bad else ""))

    draft = checkin.build_draft(req, agent=lambda r, f: drafted)
    text = checkin.render(req.template, draft)
    print("\n=== rendered\n" + text)

    PRIVATE.mkdir(parents=True, exist_ok=True)
    out = {"latency_s": dt, "drafted": drafted, "draft": draft.model_dump(), "rendered": text}
    (PRIVATE / "draft_synthetic.json").write_text(json.dumps(out, indent=2))
    if args.fixture:
        (FIXTURES / "checkin").mkdir(parents=True, exist_ok=True)
        (FIXTURES / "checkin" / "draft_synthetic.json").write_text(json.dumps(out, indent=2))
        print("fixture tests/fixtures/checkin/draft_synthetic.json")


if __name__ == "__main__":
    main()
