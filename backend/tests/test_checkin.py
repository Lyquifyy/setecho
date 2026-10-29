"""The check-in: data fields from code, the validator, the agent's place, rendering in the coach's
form, and the wrap-up answers. Offline; Spark and Transcribe are replaced."""

import json
from pathlib import Path

import pytest
from fastapi.testclient import TestClient

from app import checkin, meta
from app.main import app
from app.schemas import CheckInTemplateOut, to_template

FIXTURES = Path(__file__).parent / "fixtures"
TEMPLATE = to_template(
    CheckInTemplateOut.model_validate(
        json.loads((FIXTURES / "spark" / "form_coach_form.json").read_text())["raw"]
    )
)


def day(d, training, kcal=None, p=None, c=None, f=None, steps=None, sleep=None, weight=None, liss=()):
    return checkin.DayFacts(date=d, isTrainingDay=training, kcal=kcal, proteinG=p, carbsG=c, fatG=f, steps=steps,
                            sleepHours=sleep, weighInLb=weight, liss=[checkin.LissSession(**x) for x in liss])  # fmt: skip


FACTS = checkin.WeekFacts(
    weekStart="2026-10-23", weekEnd="2026-10-29",
    daily=[
        day("2026-10-23", True, 2400, 200, 250, 65, steps=10412, sleep=7.4, weight=181.6, liss=[{"type": "walking", "minutes": 25}]),
        day("2026-10-24", False, 2100, 200, 175, 65, steps=9950, sleep=7.0, weight=181.4),
        day("2026-10-25", False, 2600, 200, 175, 65, steps=10800, sleep=7.8, weight=181.0, liss=[{"type": "walking", "minutes": 26}]),
        day("2026-10-26", True, 2410, 205, 248, 64, steps=10100, sleep=7.4, weight=180.8),
        day("2026-10-27", True),
    ],
    targets=checkin.MacroTargets(training=checkin.Macros(kcal=2400, proteinG=200, carbsG=250, fatG=65),
                                 rest=checkin.Macros(kcal=2100, proteinG=200, carbsG=175, fatG=65)),
    showDate=None, lastCheckInWeightLb=181.5,
    sources={"calories": "MacroFactor", "weight": "Withings", "steps": "Garmin", "sleep": "Garmin", "workouts": "Garmin"},
    cardioProtocol="25 min LISS × 2 on rest days",
)  # fmt: skip
TRAINING = checkin.TrainingSummary(sessionsDone=4, sessionsScheduled=5, setsLogged=38,
                                   prs=[checkin.PersonalRecord(exercise="Bench press", loadLb=190, reps=8)])  # fmt: skip
NOTES = [checkin.VoiceNote(id="n1", at="2026-10-25T18:00:00Z", transcript="digestion's been off since Wednesday",
                           targetFieldId="notes_on_digestion")]  # fmt: skip


def request(agent_answers=None, **overrides):
    kwargs = {"template": TEMPLATE, "facts": FACTS, "notes": NOTES, "training": TRAINING, "lastCheckIn": None,
                  "styleExamples": ["100%, macros were hit every day this week!"], "draftId": "11111111-1111-1111-1111-111111111111"}  # fmt: skip
    kwargs.update(overrides)
    return checkin.DraftRequest(**kwargs)


def by_id(draft):
    return {a.fieldId: a for a in draft.answers}


def test_a_weight_read_straight_from_withings_says_so():
    direct = FACTS.model_copy(update={"sources": FACTS.sources | {"weight.direct": "Withings"}})
    draft = checkin.build_draft(request(facts=direct), agent=lambda req, fields: {})
    weight = by_id(draft)["current_body_weight"]
    assert weight.text == "180.8"
    assert weight.provenance[0].source == "Withings"


def test_data_fields_come_from_code_with_sources():
    draft = checkin.build_draft(request(), agent=lambda req, fields: {})
    a = by_id(draft)
    assert a["weeks_away_from_target_date"].text == "N/A"
    assert a["accuracy_on_plan"].text == "78% (3 of 4 days on macros, 4 of 5 sessions)"
    assert a["nutrition_consistency"].text == "75%, 3 of 4 days within targets (off on 10/25/26)"
    assert a["training_consistency"].text == "80%, 4 of 5 sessions. PRs: Bench press 190×8"
    assert (
        a["current_cardio_protocol_assigned"].text
        == "25 min LISS × 2 on rest days"  # the coach's protocol only; the log stays in the provenance
    )
    assert a["average_daily_steps"].text == "10.3k"
    assert a["last_check_in_body_weight"].text == "181.5"
    assert a["current_body_weight"].text == "180.8"
    assert a["current_body_weight"].provenance[0].source == "Withings via Apple Health"
    assert a["notes_on_sleep"].text == "Avg 7.4 h/night" and a["notes_on_sleep"].state == "drafted"
    # His free meal is untracked: with no note and no training day logged well under target, it is asked.
    assert a["date_of_last_refeed_or_cheat_meal"].state == "missing"
    assert a["notes_on_performance"].text == "Beat the logbook on Bench press 190 for 8"
    # Voice fields with nothing said are missing; a mid-week note lands in its field as a draft.
    assert a["energy_levels"].state == "missing"
    assert (
        a["notes_on_digestion"].state == "drafted"
        and a["notes_on_digestion"].text == "digestion's been off since Wednesday"
    )
    assert a["notes_on_digestion"].provenance[0].source == "You said · 10/25/26"
    assert len(draft.answers) == 22 and draft.id == "11111111-1111-1111-1111-111111111111"


def test_agent_drafts_are_validated_against_the_facts():
    def agent(req, fields):
        assert {f.id for f in fields} == {
            "notes_on_performance",
            "biggest_win_this_last_week",
            "notes_on_digestion",
        }
        return {
            "biggest_win_this_last_week": "Hit 180.8 on the scale this week, lightest in years!",
            "notes_on_performance": "Benched 190 for 8, a PR, and squatted 315 for 5.",
        }

    a = by_id(checkin.build_draft(request(), agent=agent))
    win = a["biggest_win_this_last_week"]
    assert win.state == "drafted" and "180.8" in win.text
    assert not any(p.source == "Check this" for p in win.provenance)
    perf = a["notes_on_performance"]
    assert perf.state == "drafted"
    flagged = [p for p in perf.provenance if p.source == "Check this"]
    assert flagged and "315" in flagged[0].detail and "5" not in flagged[0].detail.split("315")[0]


def test_agent_failure_leaves_data_fields_intact():
    def boom(req, fields):
        raise RuntimeError("spark down")

    a = by_id(checkin.build_draft(request(), agent=boom))
    assert a["current_body_weight"].text == "180.8"
    assert a["biggest_win_this_last_week"].state == "missing"
    assert a["notes_on_performance"].state == "drafted"


def test_validate_finds_only_unknown_numbers():
    known = checkin.known_numbers(FACTS, TRAINING, None)
    assert checkin.validate("181.5 to 180.8, 10.3k steps, 4 of 5 sessions", known) == []
    assert checkin.validate("I weighed 179 and slept 9.9 hours", known) == ["179", "9.9"]


def test_render_reproduces_the_coachs_form():
    draft = checkin.build_draft(
        request(), agent=lambda req, fields: {"biggest_win_this_last_week": "Hit 180.8!"}
    )
    text = checkin.render(TEMPLATE, draft)
    lines = text.splitlines()
    assert lines[0] == "Nutrition:"
    assert "Current Supplements:" in text and "Creatine Monohydrate - 5g daily" in text
    # Every field label in the coach's order, prompt included, carried blocks first.
    (
        [f"{f.label} {f.prompt}".strip() if f.prompt else f.label for f in TEMPLATE.orderedFields]
        if hasattr(TEMPLATE, "orderedFields")
        else None
    )
    expected_order = [
        "Weeks away from target date (if in prep): N/A",
        "Biggest win this last week: Hit 180.8!",
        "Accuracy on plan: 78% (3 of 4 days on macros, 4 of 5 sessions)",
        "Energy Levels (scale 1-10):",
        "Measure right thigh (flexed):",
        "Additional notes or concerns:",
    ]
    positions = [text.index(e) for e in expected_order]
    assert positions == sorted(positions)
    assert text.index("Current Supplements:") < text.index("Weeks away from target date")
    assert "Check-in photos" not in text
    assert not text.endswith("\n")


def test_render_endpoint():
    draft = checkin.build_draft(request(), agent=lambda req, fields: {})
    r = TestClient(app).post(
        "/checkin/render", json={"template": TEMPLATE.model_dump(), "draft": draft.model_dump()}
    )
    assert r.status_code == 200
    assert r.json()["text"].startswith("Nutrition:")
    assert len(r.json()["messages"]) == 2


def test_render_accepts_the_draft_as_the_phone_sends_it():
    """Oct 28: the phone's draft carries its video picks and accepted adjustments; a render, and a
    draft request with last week's check-in, must accept them."""
    draft = checkin.build_draft(request(), agent=lambda req, fields: {})
    body = draft.model_dump()
    body["videoPicks"] = [
        {"setId": "A1", "caption": "Squat · top set", "cropStart": 1.5, "cropEnd": 22.0},
        {
            "setId": "B2",
            "caption": "From your camera roll",
            "cropStart": 0,
            "cropEnd": 31.0,
            "sourceFile": "roll-1.mov",
        },
    ]
    body["adjustments"] = ["7D7E1A52-0000-4000-8000-000000000000"]
    r = TestClient(app).post("/checkin/render", json={"template": TEMPLATE.model_dump(), "draft": body})
    assert r.status_code == 200, r.text
    req = json.loads(request().model_dump_json())
    req["lastCheckIn"] = body
    assert TestClient(app).post("/checkin/draft", json=req).status_code != 422


def test_without_a_protocol_the_cardio_field_is_asked():
    req = request()
    req.facts.cardioProtocol = None
    draft = checkin.build_draft(req, agent=lambda req, fields: {})
    cardio = next(a for a in draft.answers if "cardio" in a.fieldId)
    assert cardio.state == "missing" and cardio.text == ""


def test_render_returns_the_plan_message_then_the_questionnaire():
    """His email asks for two separate messages (HANDOFF.md §7, Check-in, step 6)."""
    draft = checkin.build_draft(request(), agent=lambda req, fields: {})
    messages = checkin.render_messages(TEMPLATE, draft)
    assert len(messages) == 2
    plan, form = messages
    assert plan.startswith("Nutrition:") and "Current Supplements:" in plan
    assert "Weeks away from target date" not in plan
    assert form.startswith("Weeks away from target date") and "Nutrition:" not in form
    assert checkin.render(TEMPLATE, draft) == plan + "\n\n" + form
    # A form with no carried blocks is one message.
    bare = TEMPLATE.model_copy(update={"carriedBlocks": []})
    assert len(checkin.render_messages(bare, draft)) == 1


def test_render_puts_adjustments_and_gym_changes_in_his_notes_field():
    draft = checkin.build_draft(request(), agent=lambda req, fields: {})
    lines = [
        "Incline press set 3, 225 → 215 (RPE 9.5 vs 8)",
        "Bench set 1, 190 → 195 next session (rest-pause over goal)",
    ]
    changes = ["Tue, Smith close-grip press → close-grip bench press (Smith taken)"]
    _, plain = checkin.render_messages(TEMPLATE, draft)
    _, form = checkin.render_messages(TEMPLATE, draft, adjustments=lines, deviations=changes)
    notes = next(line for line in form.splitlines() if line.startswith("Additional notes or concerns"))
    assert notes.endswith(
        "Adjusted by your rule: Incline press set 3, 225 → 215 (RPE 9.5 vs 8); Bench set 1, 190 → 195 next session "
        "(rest-pause over goal). Gym changes: Tue, Smith close-grip press → close-grip bench press (Smith taken)."
    )
    # His format keeps its shape: the same lines, no heading added after his last field.
    assert len(form.splitlines()) == len(plain.splitlines())
    assert "Adjustments (your rule)" not in form and "Adjustments" not in plain
    r = TestClient(app).post(
        "/checkin/render",
        json={
            "template": TEMPLATE.model_dump(),
            "draft": draft.model_dump(),
            "adjustments": lines,
            "deviations": changes,
        },
    )
    assert r.status_code == 200 and "Gym changes: Tue, Smith close-grip press" in r.json()["messages"][1]


def test_notes_field_is_his_additional_notes_else_the_last_spoken_text_field():
    assert checkin.notes_field_id(TEMPLATE) is not None and "additional_notes" in checkin.notes_field_id(
        TEMPLATE
    )


def test_free_meal_is_drafted_from_a_note_then_the_untracked_meal_else_asked():
    def refeed(req):
        return by_id(checkin.build_draft(req, agent=lambda r, f: {}))["date_of_last_refeed_or_cheat_meal"]

    # A spoken note wins, with the note's day.
    noted = request(
        notes=NOTES
        + [checkin.VoiceNote(id="n2", at="2026-10-24T20:10:00Z", transcript="free meal today, pizza")]
    )
    a = refeed(noted)
    assert a.text == "10/24/26" and a.state == "drafted" and a.provenance[0].source == "You said · 10/24/26"
    # Else the latest training day logged more than 25% under target: the untracked meal.
    facts = FACTS.model_copy(
        update={"daily": FACTS.daily[:3] + [day("2026-10-26", True, 1700, 150, 150, 50)] + FACTS.daily[4:]}
    )
    a = refeed(request(facts=facts))
    assert a.text == "10/26/26" and a.state == "drafted" and "untracked" in a.provenance[0].detail
    # A high-calorie day no longer counts: his free meal never shows in the log.
    assert refeed(request()).state == "missing"


def test_draft_endpoint(monkeypatch):
    monkeypatch.setattr(
        checkin, "run_agent", lambda req, fields: {"biggest_win_this_last_week": "Lightest in years!"}
    )
    r = TestClient(app).post("/checkin/draft", json=json.loads(request().model_dump_json()))
    assert r.status_code == 200, r.text
    answers = {a["fieldId"]: a for a in r.json()["answers"]}
    assert answers["biggest_win_this_last_week"]["text"] == "Lightest in years!"
    assert answers["current_body_weight"]["state"] == "filled"


def _wav() -> bytes:
    from app import audio

    return audio.write_wav(b"\x00\x00" * 1600, 16000)


def _answer(monkeypatch, transcript, spark_raw, fields):
    monkeypatch.setattr(meta, "transcribe_wav", lambda data, **k: {"transcript": transcript})
    monkeypatch.setattr(meta, "spark_json", lambda *a: (spark_raw, None))
    return TestClient(app).post(
        "/checkin/answer",
        files={"audio": ("a.wav", _wav(), "audio/wav")},
        data={"fields": json.dumps([f.model_dump() for f in fields]), "askedOn": "2026-10-29"},
    )


def field(fid):
    return next(f for f in TEMPLATE.fields if f.id == fid)


def test_answer_scale_field(monkeypatch):
    r = _answer(monkeypatch, "uh six, energy was good this week",
                {"text": "energy was good this week!", "number": 6, "measurements": None, "confidence": 0.9},
                [field("energy_levels")])  # fmt: skip
    assert r.status_code == 200, r.text
    body = r.json()
    assert body["answers"][0]["text"] == "6/10, energy was good this week!"
    assert body["answers"][0]["state"] == "filled"
    assert body["answers"][0]["provenance"][0] == {
        "source": "You said · 10/29/26",
        "detail": "uh six, energy was good this week",
    }


def test_answer_three_measurements_in_one_breath(monkeypatch):
    fields = [field("measurement_of_waist"), field("measure_right_bicep"), field("measure_right_thigh")]
    r = _answer(monkeypatch, "waist thirty one, bicep sixteen, thigh twenty four and three quarters",
                {"text": "", "number": None, "measurements": {"waistIn": 31, "bicepIn": 16, "thighIn": 24.75}, "confidence": 0.95},
                fields)  # fmt: skip
    assert r.status_code == 200, r.text
    texts = [a["text"] for a in r.json()["answers"]]
    assert texts == ["31 in", "16 in", "24 3/4 in"]


def test_answer_low_confidence_is_drafted(monkeypatch):
    r = _answer(monkeypatch, "mumble", {"text": "mumble", "number": None, "measurements": None, "confidence": 0.3},
                [field("notes_on_recovery")])  # fmt: skip
    assert r.json()["answers"][0]["state"] == "drafted"


def test_answer_empty_transcript_is_missing(monkeypatch):
    r = _answer(monkeypatch, "", {}, [field("notes_on_recovery")])
    assert r.status_code == 200 and r.json()["answers"][0]["state"] == "missing"


@pytest.mark.parametrize(("value", "text"), [(24.75, "24 3/4"), (31, "31"), (16.5, "16 1/2"), (15.3, "15.3")])
def test_tape_format(value, text):
    from app.checkin_api import _fmt_in

    assert _fmt_in(value) == text


def test_optional_keys_may_be_omitted_as_swift_encodes_them():
    """Swift's Encodable drops nil keys, so every optional must default to None."""
    body = json.loads(request().model_dump_json())
    body.pop("lastCheckIn")
    body["facts"].pop("showDate")
    body["facts"].pop("cardioProtocol")
    for d in body["facts"]["daily"]:
        for k in ("kcal", "proteinG", "carbsG", "fatG", "steps", "sleepHours", "weighInLb"):
            d.pop(k, None)
    for f in body["template"]["fields"]:
        f.pop("prompt", None)
        f["source"].pop("key", None)
    for n in body["notes"]:
        n.pop("targetFieldId", None)
    r = TestClient(app).post("/checkin/draft", json=body)
    assert r.status_code == 200, r.text


def test_request_validation_errors_use_the_error_contract():
    r = TestClient(app).post("/checkin/draft", json={"template": {}})
    assert r.status_code == 422
    assert r.json()["error"].startswith("template.fields") or "facts" in r.json()["error"]


def test_current_goals_is_drafted_from_the_last_check_in():
    goal = next((f for f in TEMPLATE.fields if "goal" in f.label.lower()), None)
    if goal is None:
        return  # his form has no goals field
    last = checkin.CheckInDraft(id="old", weekStart="2026-10-16", weekEnd="2026-10-22",
                                answers=[checkin.FieldAnswer(fieldId=goal.id, text="Get to 175 by the show", state="filled", provenance=[])])  # fmt: skip
    a = by_id(checkin.build_draft(request(lastCheckIn=last), agent=lambda r, f: {}))[goal.id]
    assert (
        a.text == "Get to 175 by the show"
        and a.state == "drafted"
        and a.provenance[0].source == "Last check-in"
    )
    assert by_id(checkin.build_draft(request(), agent=lambda r, f: {}))[goal.id].state == "missing"


def test_the_questionnaire_heading_opens_the_second_message():
    draft = checkin.build_draft(request(), agent=lambda req, fields: {})
    with_heading = TEMPLATE.model_copy(update={"questionnaireHeading": "Overview:"})
    plan, form = checkin.render_messages(with_heading, draft)
    assert form.startswith("Overview:\nWeeks away from target date") and "Overview:" not in plan
    assert not checkin.render_messages(TEMPLATE, draft)[1].startswith("Overview:")
