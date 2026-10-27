"""Offline tests against real model output saved by the M0 probes (synthetic inputs only)."""

import asyncio
import json
from datetime import UTC, datetime
from pathlib import Path

import numpy as np

from app import photos
from app.schemas import CheckInTemplateOut, ProgramOut, to_program, to_template

FIXTURES = Path(__file__).parent / "fixtures"


def test_voice_fixture_is_push_to_talk_transcript():
    d = json.loads((FIXTURES / "voice" / "say_test_16k.json").read_text())
    r = d["response"]
    assert r["transcript"] == "Set three done, felt like a nine, drop to 215."
    assert r["turns"] == []  # PUSH_TO_TALK returns no turns
    assert 3500 <= r["audioDurationMs"] <= 4000
    assert r["sessionId"].startswith("voyager/transcribe/")


def test_sam_raw_output_replays_to_the_drawn_circle():
    raw = (FIXTURES / "sam" / "photos" / "shape.raw.txt").read_text()
    meta = json.loads((FIXTURES / "sam" / "photos" / "shape.json").read_text())
    result = asyncio.run(photos.replay_raw(raw))
    assert result.outcome.status == "completed"
    best = photos.largest_mask(result)
    assert best is not None
    assert list(photos.box_of(best)) == meta["box"] == [482, 232, 437, 437]

    w, h = meta["prepared"]["width"], meta["prepared"]["height"]
    mask = photos.full_frame_mask(best, w, h)
    assert mask.shape == (h, w)
    coverage = mask.mean()
    assert 0.12 < coverage < 0.16  # a radius-220 disc in 1200 x 900 is 14.1%
    ys, xs = np.nonzero(mask)
    assert abs(xs.mean() - 700) < 4 and abs(ys.mean() - 450) < 4  # centred where it was drawn


def test_program_fixture_validates_and_gets_ids():
    d = json.loads((FIXTURES / "spark" / "program_synthetic_program.json").read_text())
    out = ProgramOut.model_validate(d["raw"])
    program = to_program(out, datetime(2026, 10, 27, tzinfo=UTC))
    assert [w.number for w in program.weeks] == [1, 2]
    upper = program.weeks[0].days[0]
    assert upper.id == "w1_upper_a"
    bench = upper.exercises[0]
    assert bench.id == "w1_upper_a_bench_press"
    assert [(s.reps, s.loadLb, s.rpe) for s in bench.sets] == [(8, 185.0, 8.0)] * 4
    assert bench.restSeconds == 150
    row = upper.exercises[1]
    assert (row.sets[0].reps, row.sets[0].repsMin, row.sets[0].repsMax) == (None, 8, 10)
    leg_press = program.weeks[0].days[1].exercises[2]
    assert leg_press.name == "Leg press" and all(s.reps is None for s in leg_press.sets)
    assert any("AMRAP" in f.message for f in program.flags)
    assert len(program.flags) == 4


def test_form_fixture_matches_the_plans_field_map():
    d = json.loads((FIXTURES / "spark" / "form_synthetic_form.json").read_text())
    template = to_template(CheckInTemplateOut.model_validate(d["raw"]))
    assert len(template.fields) == 23  # the 22 fields plus the photos
    assert [b.title for b in template.carriedBlocks] == [
        "Macro targets (until I change them):",
        "Supplements:",
    ]
    assert template.carriedBlocks[1].text == "Creatine 5 g daily\nVitamin D 2000 IU daily\nFish oil 2 g daily"

    by_id = {f.id: f for f in template.fields}
    assert [f.order for f in template.fields] == list(range(23))
    expected = {
        "weeks_away_from_target_date": ("calculated", "weeksToShow"),
        "accuracy_on_plan": ("data", "planAccuracy"),
        "nutrition_consistency": ("data", "nutritionConsistency"),
        "training_consistency": ("data", "trainingConsistency"),
        "current_cardio_protocol": ("data", "cardioProtocol"),
        "notes_on_performance": ("drafted", "performanceNotes"),
        "date_of_last_refeed_or_cheat_meal": ("drafted", "lastRefeedDate"),
        "average_daily_steps": ("data", "avgDailySteps"),
        "last_check_in_body_weight": ("data", "lastCheckInWeight"),
        "current_body_weight": ("data", "currentWeight"),
        "notes_on_sleep": ("drafted", "sleepDuration"),
    }
    for field_id, (source_type, key) in expected.items():
        assert (by_id[field_id].source.type, by_id[field_id].source.key) == (source_type, key), field_id
    voice = [f for f in template.fields if f.source.type == "voice"]
    assert len(voice) == 11 and all(f.source.key is None for f in voice)
    assert by_id["energy_levels"].prompt == "(scale 1-10)" and by_id["energy_levels"].kind == "scale10"
    assert by_id["waist_measurement"].kind == "measurement"
    assert template.fields[-1].source.type == "photo"
