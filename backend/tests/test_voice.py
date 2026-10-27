"""Voice command classification. The rule layer must cover every intent it can, the Spark path
must never pass through a number the athlete did not say, and the endpoint must glue transcription
and classification together. No live calls."""

import json

import pytest
from fastapi.testclient import TestClient

from app import audio, meta, voice
from app.main import app

CONTEXT = voice.SessionContext(
    state="rest", exerciseName="Bench press", setIndex=3, setCount=4, plannedLoadLb=225, plannedReps=8
)


@pytest.mark.parametrize(
    ("said", "expected"),
    [
        ("two fifteen", 215), ("two twenty five", 225), ("one eighty", 180), ("a hundred and eighty five", 185),
        ("two hundred and twenty five", 225), ("nine", 9), ("nine and a half", 9.5), ("9.5", 9.5),
        ("twenty four and three quarters", 24.75), ("215", 215), ("seven", 7), ("thirty one", 31),
        ("sixteen", 16), ("five pounds", 5), ("nothing here", None),
    ],
)  # fmt: skip
def test_parse_number(said, expected):
    assert voice.parse_number(said) == expected


@pytest.mark.parametrize(
    ("transcript", "intent", "number"),
    [
        ("Felt like a nine.", "rpe", 9),
        ("That was an 8.", "rpe", 8),
        ("RPE 7", "rpe", 7),
        ("that was 7 reps", "reps", 7),
        ("I only got six", "reps", 6),
        ("Seven reps", "reps", 7),
        ("Drop to 215.", "setLoad", 215),
        ("go to two twenty five", "setLoad", 225),
        ("Add 5.", "loadDelta", 5),
        ("take off ten", "loadDelta", -10),
        ("Drop 5", "loadDelta", -5),
        ("skip this set", "skipSet", None),
        ("Next exercise", "nextExercise", None),
        ("Undo.", "undo", None),
        ("Scratch that", "undo", None),
        ("Pause", "pause", None),
        ("Resume", "resume", None),
        ("End session.", "endSession", None),
        ("I'm done", "endSession", None),
        ("Starting", "starting", None),
        ("Here we go", "starting", None),
        ("Done", "endSet", None),
        ("That's the set", "endSet", None),
        ("Setecho, undo", "undo", None),
        ("Top set", "topSet", None),
        ("That was my top set", "topSet", None),
        ("That was a warm-up", "warmup", None),
        ("that was just a warmup", "warmup", None),
        ("Flag that", "flagSet", None),
        ("Send that one to coach", "flagSet", None),
        ("I'm doing day 5 today", "changeDay", 5),
        ("Doing day five", "changeDay", 5),
    ],
)
def test_rules_cover_the_plain_commands(transcript, intent, number):
    result = voice.classify_by_rules(transcript)
    assert result is not None, transcript
    assert result.intent == intent
    assert result.number == number
    assert result.confidence >= 0.7


def test_add_on_commands_carry_the_block_name():
    add = voice.classify_by_rules("Add abs")
    assert add is not None and add.intent == "addAddOn" and add.text == "abs"
    skip = voice.classify_by_rules("skip abs today")
    assert skip is not None and skip.intent == "skipAddOn" and skip.text == "abs"
    assert voice.classify_by_rules("skip it").intent == "skipSet"  # "skip it" is the set, not a block
    assert voice.classify_by_rules("add 5").intent == "loadDelta"


def test_rules_keep_note_text_verbatim():
    result = voice.classify_by_rules("Note for check-in: digestion's been off since Wednesday")
    assert result is not None and result.intent == "note"
    assert result.text == "digestion's been off since Wednesday"


def test_rules_leave_the_rest_to_spark():
    assert voice.classify_by_rules("my left shoulder is pinching a little on the way up") is None
    assert voice.classify_by_rules("") is None


def test_every_intent_is_in_the_schema():
    schema = voice.VOICE_INTENT_SCHEMA
    assert set(schema["properties"]["intent"]["enum"]) == set(voice.INTENTS)
    assert set(voice.INTENTS) >= {"rpe", "reps", "setLoad", "loadDelta", "skipSet", "nextExercise", "note",
                                  "undo", "pause", "resume", "endSession", "starting", "endSet", "answer", "unknown"}  # fmt: skip


def test_spark_fallback_strips_numbers_the_athlete_did_not_say(monkeypatch):
    seen = {}

    def fake(system, user, name, schema):
        seen["user"] = user
        return ({"intent": "setLoad", "number": 300, "text": None, "fieldId": None, "confidence": 0.9}, None)

    monkeypatch.setattr(meta, "spark_json", fake)
    result = voice.classify("my shoulder is pinching", CONTEXT)
    assert result.intent == "setLoad" and result.number is None and result.confidence <= 0.5
    assert "Bench press" in seen["user"] and "set 3 of 4" in seen["user"]


def test_spark_fallback_keeps_numbers_the_athlete_said(monkeypatch):
    monkeypatch.setattr(
        meta, "spark_json",
        lambda *a: ({"intent": "answer", "number": 6, "text": "six", "fieldId": None, "confidence": 0.8}, None),
    )  # fmt: skip
    result = voice.classify("six I guess", CONTEXT)
    assert result.number == 6 and result.confidence == 0.8


def _wav() -> bytes:
    return audio.write_wav(b"\x00\x00" * 1600, 16000)


def test_voice_command_endpoint(monkeypatch):
    monkeypatch.setattr(
        meta, "transcribe_wav", lambda data, **k: {"transcript": "Felt like a nine.", "sessionId": "s1"}
    )
    client = TestClient(app)
    r = client.post(
        "/voice/command",
        files={"audio": ("u.wav", _wav(), "audio/wav")},
        data={"context": json.dumps(CONTEXT.model_dump())},
    )
    assert r.status_code == 200, r.text
    body = r.json()
    assert body["transcript"] == "Felt like a nine."
    assert body["intent"]["intent"] == "rpe" and body["intent"]["number"] == 9
    assert body["sessionId"] == "s1"


def test_voice_command_rejects_bad_audio():
    client = TestClient(app)
    r = client.post(
        "/voice/command",
        files={"audio": ("u.wav", b"not audio", "audio/wav")},
        data={"context": json.dumps(CONTEXT.model_dump())},
    )
    assert r.status_code == 422
    assert "not a WAV" in r.json()["error"]


def test_voice_command_surfaces_transcribe_errors(monkeypatch):
    def boom(data, **k):
        raise meta.TranscribeError(429, "slow down")

    monkeypatch.setattr(meta, "transcribe_wav", boom)
    client = TestClient(app)
    r = client.post(
        "/voice/command",
        files={"audio": ("u.wav", _wav(), "audio/wav")},
        data={"context": json.dumps(CONTEXT.model_dump())},
    )
    assert r.status_code == 429
    assert "429" in r.json()["error"]


def test_empty_transcript_is_unknown(monkeypatch):
    monkeypatch.setattr(meta, "transcribe_wav", lambda data, **k: {"transcript": "", "sessionId": "s2"})
    client = TestClient(app)
    r = client.post(
        "/voice/command",
        files={"audio": ("u.wav", _wav(), "audio/wav")},
        data={"context": json.dumps(CONTEXT.model_dump())},
    )
    assert r.status_code == 200
    assert r.json()["intent"]["intent"] == "unknown"
