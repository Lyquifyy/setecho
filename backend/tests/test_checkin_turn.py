"""/checkin/turn: a pause, a resume, a two-field answer, a correction and a question for the coach,
with any number not in the transcript turned into `unclear`. Transcribe and Spark are replaced."""

import json
from pathlib import Path

from fastapi.testclient import TestClient

from app import audio, checkin, checkin_turn, meta
from app.main import app
from app.schemas import CheckInTemplateOut, to_template

FIXTURES = Path(__file__).parent / "fixtures"
TEMPLATE = to_template(
    CheckInTemplateOut.model_validate(
        json.loads((FIXTURES / "spark" / "form_coach_form.json").read_text())["raw"]
    )
)
IDS = [f.id for f in TEMPLATE.fields]


def wav_bytes() -> bytes:
    return audio.write_wav(b"\x00\x00" * 16000)


def field(part):
    return next(f for f in IDS if part in f)


WEIGHT = field("current_body_weight")
GLUCOSE = field("glucose")
ENERGY = field("energy")
NOTES_FIELD = field("additional_notes")


def context(step="questions", asked=None, pending=None, answered=()):
    return checkin_turn.TurnContext(
        template=TEMPLATE, step=step, askedFieldId=asked, pending=pending or [], askedOn="2026-10-29",
        answered=[checkin.FieldAnswer(fieldId=f, text=t, state="filled", provenance=[]) for f, t in answered],
    )  # fmt: skip


def out(intent, answers=(), reply="Got it.", confidence=0.9):
    return checkin_turn.TurnOut(
        intent=intent,
        answers=[checkin_turn.TurnAnswerOut(**a) for a in answers],
        reply=reply,
        confidence=confidence,
    )


def test_a_pause_and_a_resume_change_nothing():
    r = checkin_turn.validate_turn(
        out("pause", reply="No worries, just tell me whenever you're ready."),
        "give me a couple of minutes",
        context(asked=WEIGHT),
    )
    assert r.intent == "pause" and r.answers == [] and r.reply.startswith("No worries")
    r = checkin_turn.validate_turn(out("resume", reply="Welcome back."), "ok I'm back", context(asked=WEIGHT))
    assert r.intent == "resume" and r.answers == []


def test_one_utterance_answers_two_fields_with_their_numbers_checked():
    r = checkin_turn.validate_turn(
        out("answer", [{"fieldId": WEIGHT, "text": "", "number": 180.8}, {"fieldId": GLUCOSE, "text": "", "number": 91}],
            reply="Weight 180.8 and glucose 91, got it."),
        "one eighty point eight, and glucose was ninety one", context(step="weight", asked=WEIGHT, pending=[GLUCOSE]),
    )  # fmt: skip
    assert r.intent == "answer"
    assert [(a.fieldId, a.text, a.state) for a in r.answers] == [
        (WEIGHT, "180.8", "filled"),
        (GLUCOSE, "91", "filled"),
    ]
    assert r.answers[0].provenance[0].source == "You said · 10/29/26"
    assert r.answers[0].provenance[0].detail == "one eighty point eight, and glucose was ninety one"


def test_a_correction_names_a_field_already_answered():
    r = checkin_turn.validate_turn(
        out("correction", [{"fieldId": WEIGHT, "text": "", "number": 180.6}], reply="Changed to 180.6."),
        "wait, it was 180.6",
        context(asked=GLUCOSE, answered=[(WEIGHT, "180.8")]),
    )
    assert r.intent == "correction" and r.answers[0].text == "180.6"


def test_an_unclear_turn_says_why_without_the_words():
    r = checkin_turn.validate_turn(
        out("answer", [{"fieldId": WEIGHT, "text": "", "number": 181.0}]),
        "it was 180.8",
        context(asked=WEIGHT),
    )
    assert r.intent == "unclear" and r.unclearReason == "number"
    r2 = checkin_turn.validate_turn(out("unclear", reply="Sorry?"), "mm", context())
    assert r2.unclearReason == "model"


def test_a_change_request_names_the_field_to_ask_again():
    r = checkin_turn.validate_turn(
        out("change", [{"fieldId": ENERGY, "text": ""}], reply="Sure, I'll ask energy again."),
        "let me change my energy answer",
        context(step="review", answered=[(ENERGY, "7/10")]),
    )
    assert r.intent == "change" and r.changeFieldId == ENERGY and r.answers == []
    unknown = checkin_turn.TurnOut(intent="change", answers=[], reply="Which one?", confidence=0.5)
    r2 = checkin_turn.validate_turn(unknown, "I want to change something", context(step="review"))
    assert r2.intent == "change" and r2.changeFieldId is None


def test_a_question_for_the_coach_is_offered_for_the_notes():
    r = checkin_turn.validate_turn(
        out("forCoach", [{"fieldId": NOTES_FIELD, "text": "Should I bump my carbs?"}],
            reply="That's one for your coach. Want me to add it to your notes?"),
        "should I bump my carbs", context(asked=ENERGY),
    )  # fmt: skip
    assert (
        r.intent == "forCoach"
        and r.answers[0].fieldId == NOTES_FIELD
        and r.answers[0].text == "Should I bump my carbs?"
    )


def test_a_number_not_in_the_transcript_makes_the_turn_unclear():
    r = checkin_turn.validate_turn(
        out("answer", [{"fieldId": WEIGHT, "text": "", "number": 181.8}]),
        "one eighty point eight",
        context(asked=WEIGHT),
    )
    assert r.intent == "unclear" and r.answers == [] and r.reply == "Sorry, say that again?"
    r = checkin_turn.validate_turn(
        out("answer", [{"fieldId": ENERGY, "text": "", "number": 6}], reply="Energy 7, noted."),
        "six",
        context(asked=ENERGY),
    )
    assert r.intent == "unclear"  # the reply carries a number the athlete never said
    r = checkin_turn.validate_turn(
        out("answer", [{"fieldId": "no_such_field", "text": "x"}]), "x", context(asked=ENERGY)
    )
    assert r.intent == "unclear"


def test_the_reply_is_short_and_never_advice():
    long = " ".join(["word"] * 21)
    assert checkin_turn.validate_turn(out("chitchat", reply=long), "hi", context()).intent == "unclear"
    advice = checkin_turn.validate_turn(
        out("chitchat", reply="You should bump your carbs a bit."), "hmm", context()
    )
    assert advice.intent == "unclear"
    ok = checkin_turn.validate_turn(out("chitchat", reply="Take your time."), "hang on", context())
    assert ok.intent == "chitchat" and ok.reply == "Take your time."


def test_scale_and_measurement_answers_keep_the_athletes_style():
    r = checkin_turn.validate_turn(
        out("answer", [{"fieldId": ENERGY, "text": "pretty good", "number": 6}]),
        "six, pretty good",
        context(asked=ENERGY),
    )
    assert r.answers[0].text == "6/10, pretty good"
    waist, bicep, thigh = field("waist"), field("bicep"), field("thigh")
    r = checkin_turn.validate_turn(
        out("answer", [
            {"fieldId": waist, "text": "", "measurements": {"waistIn": 31, "bicepIn": 16, "thighIn": 24.75}},
            {"fieldId": bicep, "text": "", "measurements": {"waistIn": 31, "bicepIn": 16, "thighIn": 24.75}},
            {"fieldId": thigh, "text": "", "measurements": {"waistIn": 31, "bicepIn": 16, "thighIn": 24.75}},
        ]),
        "waist thirty one, bicep sixteen, thigh twenty four and three quarters", context(asked=waist, pending=[bicep, thigh]),
    )  # fmt: skip
    assert [a.text for a in r.answers] == ["31 in", "16 in", "24 3/4 in"]


def test_spoken_numbers_reads_digits_and_words():
    said = checkin_turn.spoken_numbers("one eighty point eight, and glucose was ninety one")
    assert {180.8, 91} <= said
    assert 6 in checkin_turn.spoken_numbers("uh six, energy was good")
    assert 24.75 in checkin_turn.spoken_numbers("thigh twenty four and three quarters")


def test_schema_uses_the_fields_as_an_enum_and_stays_strict():
    from tests.test_schemas import assert_strict

    schema = checkin_turn.schema_for([WEIGHT, GLUCOSE])
    assert_strict(schema)
    assert schema["properties"]["answers"]["items"]["properties"]["fieldId"]["enum"] == sorted(
        [WEIGHT, GLUCOSE]
    )
    assert set(schema["properties"]["intent"]["enum"]) == set(checkin_turn.INTENTS)


def test_turn_endpoint(monkeypatch):
    seen = {}
    monkeypatch.setattr(
        meta,
        "transcribe_wav",
        lambda data, **k: {"transcript": "one eighty point eight this morning", "sessionId": "s"},
    )

    def fake(system, user, schema_name, schema, **kw):
        seen["user"] = user
        seen["enum"] = schema["properties"]["answers"]["items"]["properties"]["fieldId"]["enum"]
        return {"intent": "answer", "answers": [{"fieldId": WEIGHT, "text": "", "number": 180.8, "measurements": None}],
                "reply": "180.8, got it.", "confidence": 0.9}, None  # fmt: skip

    monkeypatch.setattr(meta, "spark_json", fake)
    ctx = checkin_turn.turn_context_json(context(step="weight", asked=WEIGHT, pending=[GLUCOSE]))
    r = TestClient(app).post(
        "/checkin/turn", files={"audio": ("u.wav", wav_bytes(), "audio/wav")}, data={"context": ctx}
    )
    assert r.status_code == 200, r.text
    body = r.json()
    assert (
        body["intent"] == "answer"
        and body["answers"][0]["text"] == "180.8"
        and body["reply"] == "180.8, got it."
    )
    assert body["fastPath"] is False and set(body["timings"]) == {"transcribe", "spark", "validate"}
    assert "Step: weight" in seen["user"] and WEIGHT in seen["enum"] and GLUCOSE in seen["enum"]
    # An empty transcript is unclear, never acted on.
    monkeypatch.setattr(meta, "transcribe_wav", lambda data, **k: {"transcript": "", "sessionId": "s"})
    r = TestClient(app).post(
        "/checkin/turn", files={"audio": ("u.wav", wav_bytes(), "audio/wav")}, data={"context": ctx}
    )
    assert r.json()["intent"] == "unclear" and r.json()["reply"] == "Sorry, say that again?"


def test_a_plain_number_is_answered_by_code_without_spark():
    ctx = context(step="weight", asked=WEIGHT, pending=[GLUCOSE])
    r = checkin_turn.fast_turn("one eighty point eight", ctx)
    assert r is not None and r.fastPath and r.answers[0].text == "180.8" and r.reply == "180.8, got it."
    r = checkin_turn.fast_turn("180.8.", context(step="weight", asked=WEIGHT))
    assert r is not None and r.answers[0].text == "180.8"  # Transcribe ends a number with a period
    r = checkin_turn.fast_turn("uh, 91", context(step="glucose", asked=GLUCOSE))
    assert r is not None and r.answers[0].fieldId == GLUCOSE and r.answers[0].text == "91"
    r = checkin_turn.fast_turn("six", context(asked=ENERGY))
    assert r is not None and r.answers[0].text == "6/10" and r.reply == "6, got it."
    # Words beyond a number go to Spark; so does a number for no field; so does a scale out of range.
    assert checkin_turn.fast_turn("six, energy was good", context(asked=ENERGY)) is None
    assert checkin_turn.fast_turn("91", context(step="photos")) is None
    assert checkin_turn.fast_turn("eleven", context(asked=ENERGY)) is None
    assert checkin_turn.fast_turn("give me a couple of minutes", context(asked=WEIGHT)) is None
    assert (
        checkin_turn.fast_turn("180.8, and glucose was 91", context(asked=WEIGHT, pending=[GLUCOSE])) is None
    )


def test_the_three_tape_measurements_are_one_fast_answer():
    waist, bicep, thigh = field("waist"), field("bicep"), field("thigh")
    r = checkin_turn.fast_turn(
        "thirty one, sixteen, twenty four and three quarters", context(asked=waist, pending=[bicep, thigh])
    )
    assert r is not None and r.fastPath
    assert [(a.fieldId, a.text) for a in r.answers] == [
        (waist, "31 in"),
        (bicep, "16 in"),
        (thigh, "24 3/4 in"),
    ]
    assert r.reply == "Waist 31, Bicep 16, Thigh 24 3/4."
    r = checkin_turn.fast_turn("31", context(asked=waist, pending=[bicep, thigh]))
    assert r is not None and len(r.answers) == 1


def test_turn_endpoint_takes_the_fast_path_and_reports_timings(monkeypatch):
    called = []
    monkeypatch.setattr(meta, "transcribe_wav", lambda data, **k: {"transcript": "180.8", "sessionId": "s"})
    monkeypatch.setattr(meta, "spark_json", lambda *a, **k: called.append(1) or ({}, None))
    ctx = checkin_turn.turn_context_json(context(step="weight", asked=WEIGHT))
    r = TestClient(app).post(
        "/checkin/turn", files={"audio": ("u.wav", wav_bytes(), "audio/wav")}, data={"context": ctx}
    )
    assert r.status_code == 200 and r.json()["fastPath"] is True and r.json()["answers"][0]["text"] == "180.8"
    assert called == [] and set(r.json()["timings"]) == {"transcribe", "spark", "validate"}
