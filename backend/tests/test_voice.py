"""Voice command classification. The rule layer must cover every intent it can, the Spark path
must never pass through a number the athlete did not say, and the endpoint must glue transcription
and classification together. No live calls."""

import json
from pathlib import Path

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
        # Oct 29: "five, five" after "How many?" was logged as 505 reps.
        ("five, five,", 5), ("eight eight", 8), ("one oh five", 105), ("five oh five", 505), ("two oh five", 205),
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
        ("That was at 235.", "lastSetLoad", 235),
        ("actually that was with two thirty five", "lastSetLoad", 235),
        ("It was 235 pounds", "lastSetLoad", 235),
        ("I used 235 on that one", "lastSetLoad", 235),
        ("I did that at 235", "lastSetLoad", 235),
        ("I did 235 pounds on the last set", "lastSetLoad", 235),
        ("the last set was at 185", "lastSetLoad", 185),
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
        ("Go", "starting", None),
        ("Ready", "starting", None),
        ("start", "starting", None),
        ("Done", "endSet", None),
        ("That's the set", "endSet", None),
        ("Setecho, undo", "undo", None),
        ("Top set", "topSet", None),
        ("That was my top set", "topSet", None),
        ("That was a warm-up", "warmup", None),
        ("that was just a warmup", "warmup", None),
        ("It was a warm-up", "warmup", None),
        ("Warm-up", "warmup", None),
        ("No, just a warm-up", "warmup", None),
        ("nope warm up", "warmup", None),
        ("Flag that", "flagSet", None),
        ("Send that one to coach", "flagSet", None),
        ("I'm doing day 5 today", "changeDay", 5),
        ("Doing day five", "changeDay", 5),
        ("Go with it", "acceptSuggestion", None),
        ("Keep it", "keepLoad", None),
        ("keep the weight", "keepLoad", None),
    ],
)
def test_rules_cover_the_plain_commands(transcript, intent, number):
    result = voice.classify_by_rules(transcript)
    assert result is not None, transcript
    assert result.intent == intent
    assert result.number == number
    assert result.confidence >= 0.7


def test_a_count_is_never_read_as_the_last_sets_weight():
    # "That was at 235" fixes the logged weight; a number without a load word stays a count.
    for transcript in ("that was 8", "I did 8 on that one", "it was 12"):
        result = voice.classify_by_rules(transcript)
        assert result is None or result.intent != "lastSetLoad", transcript


def test_add_on_commands_carry_the_block_name():
    ctx = CONTEXT.model_copy(update={"addOnNames": ["Abs"]})
    add = voice.classify_by_rules("Add abs", ctx)
    assert add is not None and add.intent == "addAddOn" and add.text == "Abs"
    skip = voice.classify_by_rules("skip abs today", ctx)
    assert skip is not None and skip.intent == "skipAddOn" and skip.text == "Abs"
    assert voice.classify_by_rules("skip it", ctx).intent == "skipSet"  # "skip it" is the set, not a block
    assert voice.classify_by_rules("add 5", ctx).intent == "loadDelta"


def test_add_on_rules_match_only_the_sessions_names():
    ctx = CONTEXT.model_copy(update={"addOnNames": ["Abs"], "exercisesAhead": ["Cable incline flyes"]})
    assert voice.classify_by_rules("no problem", ctx).intent == "chatter"
    assert voice.classify_by_rules("do the flyes", ctx) is None  # not an add-on: Spark reads it
    skip = voice.classify_by_rules("skip the flyes", ctx)
    assert skip.intent == "skipExercise" and skip.text == "Cable incline flyes"
    assert voice.classify_by_rules("add abs") is None  # no add-ons in the context, no add-on rule


# HANDOFF.md §7, The between-set conversation: each row was a misfire on 633ee30.
@pytest.mark.parametrize(
    ("transcript", "state", "intent", "number"),
    [
        ("that was 8", "rest", "reps", 8),
        ("that's 8", "rest", "reps", 8),
        ("that was 12", "rest", "reps", 12),
        ("done, 12", "ready", "endSet", 12),
        ("twelve", "ready", "answer", 12),
        ("five,Five,", "rest", "answer", 5),  # Oct 29: logged as 505 reps
        # Oct 29: a bare "stop" mid-set was ignored.
        ("Stop.", "recording", "endSet", None),
        ("okay, stop", "recording", "endSet", None),
        ("stop there", "hold", "endSet", None),
        ("I'm done", "recording", "endSet", None),
        ("I'm done with this set", "rest", "endSet", None),
        ("I'm done", "rest", "endSession", None),
        ("what's my next set", "rest", "question", None),
        ("wait, that was 9", "rest", "reps", 9),
        ("no problem", "rest", "chatter", None),
        ("hold on let me grab water", "rest", "pause", None),
        ("felt like a nine", "rest", "rpe", 9),
        ("That was an 8.", "rest", "rpe", 8),
        ("eight out of ten", "rest", "rpe", 8),
        ("did 12", "ready", "reps", 12),
        ("got 12", "ready", "reps", 12),
        ("12 reps", "ready", "reps", 12),
        ("actually that was 11", "rest", "reps", 11),
        ("let's go", "rest", "chatter", None),
        ("ugh, that was brutal", "rest", "chatter", None),
    ],
)
def test_between_set_phrases(transcript, state, intent, number):
    result = voice.classify_by_rules(transcript, CONTEXT.model_copy(update={"state": state}))
    assert result is not None, transcript
    assert (result.intent, result.number) == (intent, number)


@pytest.mark.parametrize("state", ["ready", "rest", "paused"])
def test_a_bare_stop_outside_a_set_is_not_a_set(state):
    # Out of a set "stop" could mean anything; Spark reads it rather than logging a set.
    assert voice.classify_by_rules("stop", CONTEXT.model_copy(update={"state": state})) is None


def test_a_bare_stop_mid_set_ends_it_through_the_turn_route():
    ruled, by = voice.route("Stop!", CONTEXT.model_copy(update={"state": "recording"}))
    assert (ruled.intent, by) == ("endSet", "rules")


@pytest.mark.parametrize(
    "transcript", ["I can't do that", "take it easy", "don't keep it", "I don't want to go with it"]
)
def test_accept_and_keep_never_fire_on_a_negation_or_a_long_sentence(transcript):
    result = voice.classify_by_rules(transcript, CONTEXT)
    assert result is None or result.intent not in ("acceptSuggestion", "keepLoad"), transcript


@pytest.mark.parametrize(
    ("transcript", "topic"),
    [
        ("what's next", "next"), ("what's after this", "next"), ("what's my next set", "next"),
        ("how long left", "restLeft"), ("how much rest", "restLeft"),
        ("what did I get", "lastSet"), ("how many was that", "lastSet"),
        ("what did I do last time", "lastTime"),
        ("what weight", "load"), ("what's the back-off", "load"),
        ("how many sets left", "setsLeft"), ("was that failure", "effort"),
        ("what did he say about these", "coachNotes"), ("what's the tempo", "coachNotes"),
        ("should I go heavier next week?", "outOfScope"), ("how's my form", "outOfScope"),
        ("what should I eat", "outOfScope"),
        ("what can I say?", "help"), ("help", "help"), ("what do I say", "help"), ("how does this work", "help"),
    ],
)  # fmt: skip
def test_questions_carry_their_topic(transcript, topic):
    result = voice.classify_by_rules(transcript, CONTEXT)
    assert result is not None and result.intent == "question" and result.topic == topic


@pytest.mark.parametrize(
    ("transcript", "intent", "number", "text"),
    [
        ("the first one", "choose", 1, None), ("go with the first one", "choose", 1, None),
        ("the other one", "choose", 2, None), ("I'll wait", "choose", None, "wait"),
        ("the incline bench is taken", "equipmentTaken", None, "incline bench"),
        ("someone's on the Smith", "equipmentTaken", None, "smith"),
        ("is there another machine I can use?", "equipmentTaken", None, None),
        ("can I swap this?", "equipmentTaken", None, None),
        ("doing dumbbells instead", "swapTo", None, "dumbbells"),
        ("it's free", "equipmentFree", None, None), ("bench is open", "equipmentFree", None, None),
        ("that's it for today", "endSession", None, None),
    ],
)  # fmt: skip
def test_choices_machines_and_the_end(transcript, intent, number, text):
    result = voice.classify_by_rules(transcript, CONTEXT)
    assert result is not None, transcript
    assert (result.intent, result.number, result.text) == (intent, number, text)


def test_logbook_and_named_sets_carry_both_numbers():
    logbook = voice.classify_by_rules("last time I did 145 for 9", CONTEXT)
    assert (logbook.intent, logbook.number, logbook.reps) == ("logbook", 145, 9)
    named = voice.classify_by_rules("set 3 of incline was 7", CONTEXT)
    assert (named.intent, named.number, named.setNumber, named.text) == ("reps", 7, 3, "incline")


@pytest.mark.parametrize(
    ("transcript", "intent"),
    [("done", "endSet"), ("done, 12", "endSet"), ("that was 8", "reps"), ("top set", "topSet"),
     ("ten", "chatter"), ("let's go", "chatter"), ("end session", "chatter"), ("what's next", "chatter"),
     ("my shoulder hurts", "chatter")],
)  # fmt: skip
def test_during_a_set_only_set_commands_count_and_spark_is_never_called(monkeypatch, transcript, intent):
    def no_spark(*a, **kw):
        raise AssertionError("Spark called during a set")

    monkeypatch.setattr(meta, "spark_json", no_spark)
    result, by = voice.route(transcript, CONTEXT.model_copy(update={"state": "recording"}))
    assert result.intent == intent and by == "rules"


def test_spark_gets_the_open_ask_and_no_token_cap(monkeypatch):
    seen = {}

    def fake(system, user, name, schema, **kw):
        seen.update(user=user, kw=kw)
        return ({"intent": "chatter", "number": None, "text": None, "fieldId": None, "confidence": 0.9}, None)

    monkeypatch.setattr(meta, "spark_json", fake)
    ctx = CONTEXT.model_copy(update={"pendingAsk": "Back-off at 145?", "lastSpoken": "Top set: 9 reps."})
    result, by = voice.route("did you see the game last night", ctx)
    assert result.intent == "chatter" and by == "spark"
    assert "Back-off at 145?" in seen["user"] and "Top set: 9 reps." in seen["user"]
    assert "max_tokens" not in seen["kw"]


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

    def fake(system, user, name, schema, **kw):
        seen["user"] = user
        return ({"intent": "setLoad", "number": 300, "text": None, "fieldId": None, "confidence": 0.9}, None)

    monkeypatch.setattr(meta, "spark_json", fake)
    result = voice.classify("my shoulder is pinching", CONTEXT)
    assert result.intent == "setLoad" and result.number is None and result.confidence <= 0.5
    assert "Bench press" in seen["user"] and "set 3 of 4" in seen["user"]


def test_spark_fallback_keeps_numbers_the_athlete_said(monkeypatch):
    monkeypatch.setattr(
        meta, "spark_json",
        lambda *a, **kw: ({"intent": "answer", "number": 6, "text": "six", "fieldId": None, "confidence": 0.8}, None),
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


def test_voice_command_text_runs_the_same_rules():
    client = TestClient(app)
    r = client.post("/voice/command/text", json={"transcript": "done, 12", "context": CONTEXT.model_dump()})
    assert r.status_code == 200, r.text
    body = r.json()
    assert body["intent"]["intent"] == "endSet" and body["intent"]["number"] == 12
    assert body["classifiedBy"] == "rules"
    empty = client.post("/voice/command/text", json={"transcript": "  ", "context": CONTEXT.model_dump()})
    assert empty.json()["intent"]["intent"] == "unknown"


# The conversations ConversationTests (iOS) drive end to end: each line, in the state it is said
# in, must be read as the fixture says, so the engine's tests and the real path can't drift apart.
CONVERSATIONS = sorted((Path(__file__).parent / "fixtures" / "conversations").glob("*.json"))


@pytest.mark.parametrize("path", CONVERSATIONS, ids=[p.stem for p in CONVERSATIONS])
def test_conversation_fixtures(monkeypatch, path):
    def no_spark(*a, **kw):
        raise AssertionError("Spark called for a line the rules should read")

    monkeypatch.setattr(meta, "spark_json", no_spark)
    for line in json.loads(path.read_text())["utterances"]:
        ctx = CONTEXT.model_copy(
            update={
                "state": line["state"],
                "exercisesAhead": line.get("exercisesAhead", []),
                "addOnNames": line.get("addOnNames", []),
            }
        )
        if line["via"] == "spark":
            assert voice.classify_by_rules(line["say"], ctx) is None, line["say"]
            continue
        result, by = voice.route(line["say"], ctx)
        assert by == "rules", line["say"]
        got = {k: getattr(result, k) for k in line["intent"]}
        assert got == line["intent"], line["say"]


def test_every_scenario_has_a_fixture():
    assert {p.stem[0] for p in CONVERSATIONS} == set("abcdefghijklm")


# The phone's "What you can say" guides (VoiceGuideView: Working out, Abs, Vacuums): every example
# on them must do what it says.
VOICE_GUIDE = Path(__file__).parents[2] / "ios" / "Setecho" / "Resources" / "VoiceGuide.json"
GUIDE_LINES = [
    line
    for guide in json.loads(VOICE_GUIDE.read_text())["guides"]
    for section in guide["sections"]
    for line in section["phrases"]
]


@pytest.mark.parametrize("line", GUIDE_LINES, ids=[f"{line['state']}:{line['say']}" for line in GUIDE_LINES])
def test_voice_guide_lines_do_what_the_guide_says(line):
    ctx = CONTEXT.model_copy(
        update={
            "state": line["state"],
            "exercisesAhead": line.get("exercisesAhead", []),
            "addOnNames": line.get("addOnNames", []),
        }
    )
    result, by = voice.route(line["say"], ctx)
    assert by == "rules", line["say"]
    assert result.intent == line["intent"], line["say"]
    assert result.topic == line.get("topic"), line["say"]
    assert result.confidence >= 0.7, line["say"]


# He drives (HANDOFF.md §7): moving around today's plan by voice.
DRIVE_CONTEXT = voice.SessionContext(
    state="rest", exercisesAhead=["Incline dumbbell press", "Cable incline flyes"]
)


@pytest.mark.parametrize(
    ("transcript", "intent", "text", "topic"),
    [
        ("go back", "goTo", "back", None),
        ("redo that set", "goTo", "back", None),
        ("I'm on flyes now", "goTo", "Cable incline flyes", None),
        ("let's do incline next", "goTo", "Incline dumbbell press", None),
        ("one more set", "addSet", None, None),
        ("let's do another set", "addSet", None, None),
        ("that's it for incline", "endExercise", "Incline dumbbell press", None),
        ("done with the flyes", "endExercise", "Cable incline flyes", None),
        ("that's it for this one", "endExercise", None, None),
        ("where am I?", "question", None, "whereAmI"),
        ("that's it for today", "endSession", None, None),
        ("done with this set", "endSet", None, None),
        ("I'm doing Day 5 today", "changeDay", None, None),
    ],
)
def test_moving_around_todays_plan(transcript, intent, text, topic):
    got = voice.classify_by_rules(transcript, DRIVE_CONTEXT)
    assert got is not None and got.intent == intent, transcript
    assert got.text == text and got.topic == topic


def test_a_move_to_something_not_in_todays_plan_goes_to_spark():
    assert voice.classify_by_rules("I'm on squats now", DRIVE_CONTEXT) is None


# ---------------------------------------------------------------------------
# Oct 30, Day 5 in the gym on the AirPods mic: what the transcriber actually heard
# ---------------------------------------------------------------------------


@pytest.mark.parametrize(
    ("transcript", "number"),
    [
        ("Done.", None),
        ("then", None),
        ("Dann.", None),
        ("Set Dan.", None),
        ("said done", None),
        ("SetSet, done.", None),
        ("then got 11.", 11),
        ("Done. 35.", 35),
        ("Set done. 35 reps.", 35),
        ("done 25", 25),
    ],
)
def test_done_as_the_transcriber_hears_it_mid_set_ends_the_set(transcript, number):
    result, by = voice.route(transcript, CONTEXT.model_copy(update={"state": "recording"}))
    assert (result.intent, result.number, by) == ("endSet", number, "rules")


@pytest.mark.parametrize(
    "transcript",
    ["then we can go over there", "Yeah, I appreciate it. Yeah.", "then got the bar", "one two three four"],
)
def test_done_sound_alikes_need_a_short_line_mid_set(transcript):
    result, _ = voice.route(transcript, CONTEXT.model_copy(update={"state": "recording"}))
    assert result.intent != "endSet"


def test_done_sound_alikes_only_count_mid_set():
    assert voice.classify_by_rules("then", CONTEXT.model_copy(update={"state": "rest"})) is None


def test_a_full_stop_is_not_part_of_a_number():
    assert voice.normalize("Done. 35.") == "done 35"
    assert voice.normalize("12.5 for 13 reps.") == "12.5 for 13 reps"


@pytest.mark.parametrize("transcript", ["Starts at", "starts at.", "Star set"])
def test_start_set_as_the_transcriber_hears_it_arms(transcript):
    assert voice.classify_by_rules(transcript, CONTEXT).intent == "starting"


def test_an_arm_word_in_a_long_sentence_is_not_an_arm():
    said = "straight on your muscles when you're lifting? Really?"
    assert voice.classify_by_rules(said, CONTEXT) is None


@pytest.mark.parametrize(
    "transcript", ["Hey, never mind.", "Change the third rep. Or never mind.", "forget it"]
)
def test_never_mind_never_undoes(transcript):
    assert voice.classify_by_rules(transcript, CONTEXT).intent == "chatter"


def test_words_after_never_mind_are_read_on_their_own():
    result = voice.classify_by_rules("never mind, that was 10", CONTEXT)
    assert (result.intent, result.number) == ("reps", 10)
