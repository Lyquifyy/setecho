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
        meta, "transcribe_wav", lambda data, **k: {"transcript": "one eighty point eight", "sessionId": "s"}
    )

    def fake(system, user, schema_name, schema):
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
    assert "Step: weight" in seen["user"] and WEIGHT in seen["enum"] and GLUCOSE in seen["enum"]
    # An empty transcript is unclear, never acted on.
    monkeypatch.setattr(meta, "transcribe_wav", lambda data, **k: {"transcript": "", "sessionId": "s"})
    r = TestClient(app).post(
        "/checkin/turn", files={"audio": ("u.wav", wav_bytes(), "audio/wav")}, data={"context": ctx}
    )
    assert r.json()["intent"] == "unclear" and r.json()["reply"] == "Sorry, say that again?"
