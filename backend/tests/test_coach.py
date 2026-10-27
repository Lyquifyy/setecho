"""The coach's reply: addressable items, the validator, before/after, cue segmentation, and the
endpoint with Spark and Transcribe replaced. Replies here are synthetic, written for the tests."""

import json
import shutil
import subprocess
from datetime import date
from pathlib import Path

import pytest
from fastapi.testclient import TestClient

from app import audio, coach, meta
from app.main import app
from app.schemas import CheckInTemplateOut, Macros, MacroTargets, ProgramOut, to_program, to_template

FIXTURES = Path(__file__).parent / "fixtures"
PROGRAM = to_program(
    ProgramOut.model_validate(
        json.loads((FIXTURES / "spark" / "program_synthetic_program.json").read_text())["raw"]
    ),
    __import__("datetime").datetime(2026, 10, 26, tzinfo=__import__("datetime").UTC),
)
TEMPLATE = to_template(
    CheckInTemplateOut.model_validate(
        json.loads((FIXTURES / "spark" / "form_coach_form.json").read_text())["raw"]
    )
)
PLAN = coach.PlanState(
    version=1,
    program=PROGRAM,
    targets=MacroTargets(training=Macros(kcal=2400, proteinG=200, carbsG=250, fatG=65),
                         rest=Macros(kcal=2100, proteinG=200, carbsG=175, fatG=65)),
    cardioProtocol="25 min LISS × 2 on rest days",
    carriedBlocks=TEMPLATE.carriedBlocks,
)  # fmt: skip
ITEMS = coach.items_for(PLAN)
BY_PATH = {i.path: i for i in ITEMS}


def change(**kw):
    base = {"kind": "macroTarget", "path": "targets.training.carbsG", "op": "decrease", "amount": 25,
            "newItem": None, "quote": "drop training day carbs by 25", "appliesFrom": None}  # fmt: skip
    return coach.ChangeOut(**{**base, **kw})


def run(transcript, *changes, unclear=(), today=None):
    return coach.validate(
        coach.ChangesOut(changes=list(changes), unclear=list(unclear)), transcript, ITEMS, today
    )


# --- items --------------------------------------------------------------------


def test_items_cover_targets_cardio_program_and_supplements():
    paths = set(BY_PATH)
    assert {"targets.training.kcal", "targets.rest.fatG", "cardioProtocol", "supplements"} <= paths
    bench = BY_PATH["program.upper_a.bench_press"]
    assert bench.label == "Upper A · Bench press" and bench.value.startswith("4 × 8 · 185 lb")
    assert BY_PATH["program.upper_a.bench_press.load"].value == "185 lb"
    assert BY_PATH["program.upper_a.bench_press.rest"].value == "150 s"
    assert BY_PATH["program.upper_a"].kind == "exerciseAdd"
    assert BY_PATH["targets.training.carbsG"].value == "250 g"
    assert any(i.kind == "supplement" and "Creatine" in i.label for i in ITEMS)
    # One entry per day/exercise name, not per week.
    assert len([p for p in paths if p.startswith("program.upper_a.bench_press")]) == 5


def test_schema_pins_path_to_the_plan():
    schema = coach.changes_schema(ITEMS)
    enum = schema["properties"]["changes"]["items"]["properties"]["path"]["enum"]
    assert set(enum) == set(BY_PATH)
    labels = coach.labels_schema(["a", "b"])
    assert labels["properties"]["segments"]["items"]["properties"]["exerciseId"]["enum"] == ["a", "b", "none"]


# --- validator ------------------------------------------------------------------


def test_valid_change_gets_before_and_after_from_code():
    v = run(
        "Looking lean. Let's drop training day carbs by 25 from Monday.",
        change(appliesFrom="2026-11-02"),
        today=date(2026, 10, 27),
    )
    assert v.unclear == []
    c = v.changes[0]
    assert (c.before, c.after, c.label, c.id) == ("250 g", "225 g", "Training-day carbs", "c1")
    assert c.appliesFrom == "2026-11-02" and c.approved


def test_quote_not_in_transcript_is_unclear():
    v = run("Keep everything the same this week.", change())
    assert v.changes == [] and v.unclear == ["drop training day carbs by 25"]


def test_quote_match_ignores_case_whitespace_and_punctuation():
    v = run("DROP   training-day carbs by 25!", change(quote="drop training day carbs by 25"))
    assert len(v.changes) == 1


def test_amount_not_in_quote_is_unclear():
    v = run("drop training day carbs a bit", change(amount=25, quote="drop training day carbs a bit"))
    assert v.changes == [] and v.unclear == ["drop training day carbs a bit"]


def test_amount_in_words_counts():
    v = run(
        "take twenty five off training day carbs", change(quote="take twenty five off training day carbs")
    )
    assert v.changes[0].after == "225 g"


def test_path_not_in_plan_is_unclear():
    v = run(
        "add 10 to the sled push",
        change(
            path="program.upper_a.sled_push.load", kind="load", amount=10, quote="add 10 to the sled push"
        ),
    )
    assert v.changes == [] and v.unclear == ["add 10 to the sled push"]


def test_op_must_fit_the_kind():
    v = run("remove training day carbs", change(op="remove", amount=None, quote="remove training day carbs"))
    assert v.changes == [] and v.unclear == ["remove training day carbs"]


def test_model_unclear_sentences_are_kept_and_not_duplicated():
    v = run(
        "drop training day carbs by 25",
        change(),
        change(quote="nonsense"),
        unclear=["nonsense", "add a sauna day"],
    )
    assert v.unclear == ["nonsense", "add a sauna day"] and len(v.changes) == 1


def test_past_start_date_applies_from_the_next_session():
    v = run("drop training day carbs by 25", change(appliesFrom="2026-10-20"), today=date(2026, 10, 27))
    assert v.changes[0].appliesFrom is None
    v = run("drop training day carbs by 25", change(appliesFrom="not a date"))
    assert v.changes[0].appliesFrom is None


@pytest.mark.parametrize(
    "path, kind, op, amount, new_item, quote, before, after",
    [
        ("targets.rest.kcal", "macroTarget", "set", 2000, None, "rest days go to 2000 calories", "2100 kcal", "2000 kcal"),
        ("targets.training.proteinG", "macroTarget", "increase", 10, None, "bump protein up 10 on training days", "200 g", "210 g"),
        ("program.upper_a.bench_press.load", "load", "increase", 5, None, "add 5 to bench", "185 lb", "190 lb"),
        ("program.upper_a.bench_press.load", "load", "set", 195, None, "bench at 195", "185 lb", "195 lb"),
        ("program.upper_a.bench_press.sets", "sets", "set", 5, None, "make bench 5 sets", "4", "5"),
        ("program.upper_a.bench_press.reps", "reps", "set", 6, None, "bench for 6 reps", "8", "6"),
        ("program.upper_a.bench_press.reps", "reps", "set", None, "10-12", "bench reps to 10-12", "8", "10–12"),
        ("program.upper_a.bench_press.reps", "reps", "increase", 2, None, "two more reps on bench", "8", "10"),
        ("program.upper_a.bench_press.rest", "rest", "set", 120, None, "rest 120 seconds on bench", "150 s", "120 s"),
        ("program.upper_a.bench_press", "exerciseSwap", "replace", None, "incline dumbbell press", "swap bench press for incline dumbbell press", None, "incline dumbbell press"),
        ("program.upper_a.bench_press", "exerciseRemove", "remove", None, None, "drop the bench press this week", None, "(removed)"),
        ("program.upper_a", "exerciseAdd", "add", None, "face pulls", "add face pulls to upper A", None, "face pulls"),
        ("supplements", "supplement", "add", None, "5g glutamine", "add 5g glutamine before bed", None, "5g glutamine"),
        ("cardioProtocol", "cardio", "replace", None, "30 min LISS x 3", "cardio goes to 30 min LISS x 3", "25 min LISS × 2 on rest days", "30 min LISS x 3"),
    ],
)  # fmt: skip
def test_before_and_after_for_every_op(path, kind, op, amount, new_item, quote, before, after):
    v = run(quote, change(path=path, kind=kind, op=op, amount=amount, newItem=new_item, quote=quote))
    assert v.unclear == [], v.unclear
    c = v.changes[0]
    expected_before = BY_PATH[path].value if before is None and BY_PATH[path].value != "(none)" else before
    assert (c.before, c.after) == (expected_before, after)


def test_rep_range_shifts_with_increase():
    row = next(i for i in ITEMS if i.path == "program.upper_a.barbell_row.reps")
    assert row.value == "8–10"
    v = run(
        "two more reps on rows",
        change(path=row.path, kind="reps", op="increase", amount=2, quote="two more reps on rows"),
    )
    assert v.changes[0].after == "10–12"


def test_swap_needs_the_new_name_in_the_quote():
    v = run("swap bench press", change(path="program.upper_a.bench_press", kind="exerciseSwap", op="replace",
                                       amount=None, newItem="incline press", quote="swap bench press"))  # fmt: skip
    assert v.changes == [] and v.unclear == ["swap bench press"]


def test_supplement_removal_addresses_the_line():
    creatine = next(i for i in ITEMS if i.kind == "supplement" and "Creatine" in i.label)
    v = run("you can stop the creatine for now", change(path=creatine.path, kind="supplement", op="remove", amount=None,
                                                          quote="stop the creatine for now"))  # fmt: skip
    assert v.changes[0].after == "(removed)" and v.changes[0].before == creatine.line


def test_numbers_in_finds_digits_and_words():
    assert coach.numbers_in("drop by 25 and go to two fifty, twenty five more") >= {25.0, 250.0}
    assert coach.numbers_in("no numbers here") == set()


# --- segmentation ---------------------------------------------------------------


def test_parse_silences_reads_ffmpeg_log():
    log = "silence_start: 1.5\nsilence_end: 2.1 | silence_duration: 0.6\nsilence_start: 9.0\n"
    s = coach.parse_silences(log)
    assert s[0] == coach.Segment(1.5, 2.1) and s[1].start == 9.0 and s[1].end == float("inf")


def test_segments_split_at_pauses_merge_short_and_split_long():
    silences = [
        coach.Segment(3.0, 3.5),
        coach.Segment(4.2, 4.5),
        coach.Segment(4.6, 5.3),
        coach.Segment(12.0, 12.25),
        coach.Segment(23.0, 23.6),
    ]
    segs = coach.segments_from_silences(30.0, silences)
    # 0-3 | 3.5-4.2 (0.7 s: merged back) + 4.2-4.6 merges | 5.3-23 (17.7 s: split at the 12.0 pause) | 23.6-30
    assert segs[0] == coach.Segment(0.0, 4.6)
    assert segs[1].start == 5.3 and abs(segs[1].end - 12.125) < 1e-9
    assert abs(segs[2].start - 12.125) < 1e-9 and segs[2].end == 23.0
    assert segs[3] == coach.Segment(23.6, 30.0)
    assert all(s.length <= coach.LONG_SEGMENT for s in segs)


def test_long_segment_without_internal_pause_splits_in_the_middle():
    segs = coach.segments_from_silences(20.0, [])
    assert [(s.start, s.end) for s in segs] == [(0.0, 10.0), (10.0, 20.0)]


def test_leading_short_segment_merges_forward():
    segs = coach.segments_from_silences(10.0, [coach.Segment(0.5, 1.0)])
    assert segs == [coach.Segment(0.0, 10.0)]


def test_split_sentences():
    assert coach.split_sentences("Nice week. Drop carbs by 25!\nKeep the cardio.  ") == [
        "Nice week.", "Drop carbs by 25!", "Keep the cardio."
    ]  # fmt: skip


def test_wav_slice_cuts_the_right_samples():
    pcm = bytes(range(256)) * 125  # 32000 bytes = 16000 samples = 1 s at 16 kHz
    wav = audio.write_wav(pcm, 16000)
    piece = coach.wav_slice(wav, 0.25, 0.5)
    info = audio.wav_info(piece)
    assert info.sample_rate == 16000 and info.frames == 4000
    assert piece[44:48] == pcm[8000:8004]


def test_label_segments_drops_unknown_exercise_ids(monkeypatch):
    monkeypatch.setattr(meta, "spark_json", lambda *a, **k: ({"segments": [
        {"index": 0, "exerciseId": "w1_upper_a_bench_press", "isCue": True},
        {"index": 1, "exerciseId": "made_up", "isCue": True},
        {"index": 7, "exerciseId": "w1_upper_a_bench_press", "isCue": True},
    ]}, None))  # fmt: skip
    labels = coach.label_segments(["Pause at the bottom on bench.", "Breathe."], PLAN)
    assert [(l.index, l.exerciseId) for l in labels] == [(0, "w1_upper_a_bench_press")]


# --- endpoint -------------------------------------------------------------------


@pytest.fixture
def client():
    return TestClient(app)


@pytest.fixture
def spark(monkeypatch):
    def fake(system, user, schema_name, schema):
        if schema_name == "CoachChanges":
            return ({"changes": [
                {"kind": "macroTarget", "path": "targets.training.carbsG", "op": "decrease", "amount": 25,
                 "newItem": None, "quote": "drop training day carbs by 25", "appliesFrom": None},
                {"kind": "load", "path": "program.upper_a.bench_press.load", "op": "increase", "amount": 500,
                 "newItem": None, "quote": "add a little to bench", "appliesFrom": None},
            ], "unclear": ["and let's add some sauna"]}, None)  # fmt: skip
        if schema_name == "CueLabels":
            return ({"segments": [
                {"index": 0, "exerciseId": "none", "isCue": False},
                {"index": 1, "exerciseId": "w1_upper_a_bench_press", "isCue": True},
                {"index": 2, "exerciseId": "none", "isCue": False},
            ]}, None)  # fmt: skip
        raise AssertionError(schema_name)

    monkeypatch.setattr(meta, "spark_json", fake)


TEXT = "Good week. On bench, pause a full second at the bottom. Drop training day carbs by 25 and add a little to bench, and let's add some sauna."


def test_text_reply_returns_changes_unclear_and_cues(client, spark):
    r = client.post(
        "/coach/reply", json={"text": TEXT, "plan": PLAN.model_dump(mode="json"), "today": "2026-10-27"}
    )
    assert r.status_code == 200, r.text
    body = r.json()
    assert body["transcript"] == TEXT
    assert [c["after"] for c in body["changes"]] == ["225 g"]
    assert body["changes"][0]["before"] == "250 g" and body["changes"][0]["label"] == "Training-day carbs"
    assert body["unclear"] == ["and let's add some sauna", "add a little to bench"]
    assert body["cues"] == [{"id": "cue1", "exerciseId": "w1_upper_a_bench_press",
                             "text": "On bench, pause a full second at the bottom.", "startSec": None, "endSec": None}]  # fmt: skip


def test_cues_off_skips_labelling(client, spark):
    r = client.post(
        "/coach/reply", json={"text": TEXT, "plan": PLAN.model_dump(mode="json"), "cuesEnabled": False}
    )
    assert r.status_code == 200 and r.json()["cues"] == []


def test_empty_text_is_422(client, spark):
    r = client.post("/coach/reply", json={"text": "  ", "plan": PLAN.model_dump(mode="json")})
    assert r.status_code == 422 and "error" in r.json()


def _opus(tmp_path: Path, seconds: float = 3.0) -> Path:
    out = tmp_path / "note.opus"
    subprocess.run(
        ["ffmpeg", "-y", "-loglevel", "error", "-f", "lavfi", "-i", f"sine=frequency=440:duration={seconds}",
         "-c:a", "libopus", "-b:a", "24k", str(out)],
        check=True,
    )  # fmt: skip
    return out


@pytest.mark.skipif(shutil.which("ffmpeg") is None, reason="ffmpeg not installed")
def test_opus_converts_to_transcribe_wav(tmp_path):
    wav = audio.convert_to_transcribe_wav(_opus(tmp_path))
    info = audio.check_transcribe_wav(wav)
    assert (info.sample_rate, info.channels, info.sample_width) == (16000, 1, 2)
    assert 2.9 < info.duration_s < 3.1


@pytest.mark.skipif(shutil.which("ffmpeg") is None, reason="ffmpeg not installed")
def test_audio_reply_transcribes_segments_and_times_the_cues(client, spark, monkeypatch, tmp_path):
    # Two bursts of tone with a second of silence between: two segments.
    out = tmp_path / "note.opus"
    subprocess.run(
        ["ffmpeg", "-y", "-loglevel", "error",
         "-f", "lavfi", "-i", "sine=frequency=440:duration=2.5",
         "-f", "lavfi", "-i", "anullsrc=r=16000:cl=mono:d=1.0",
         "-f", "lavfi", "-i", "sine=frequency=440:duration=2.5",
         "-filter_complex", "[0][1][2]concat=n=3:v=0:a=1", "-c:a", "libopus", str(out)],
        check=True,
    )  # fmt: skip
    heard = iter(["Good week.", "On bench, pause a full second at the bottom."])
    monkeypatch.setattr(meta, "transcribe_wav", lambda wav, **k: {"transcript": next(heard, "")})
    with out.open("rb") as f:
        r = client.post(
            "/coach/reply",
            files={"audio": ("note.opus", f, "audio/ogg")},
            data={"plan": PLAN.model_dump_json(), "today": "2026-10-27"},
        )
    assert r.status_code == 200, r.text
    body = r.json()
    assert body["transcript"] == "Good week. On bench, pause a full second at the bottom."
    assert len(body["cues"]) == 1
    cue = body["cues"][0]
    assert (
        cue["exerciseId"] == "w1_upper_a_bench_press"
        and 2.0 < cue["startSec"] < 4.0
        and cue["endSec"] > cue["startSec"]
    )
    # The changes parser saw the same text and found the carb change's quote missing: unclear only.
    assert body["changes"] == []
