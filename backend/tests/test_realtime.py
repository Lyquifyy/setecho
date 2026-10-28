"""/voice/stream: the frame protocol and the relay, with Meta's socket faked. Never live."""

import asyncio
import json

from fastapi.testclient import TestClient

from app import realtime
from app.main import app


def test_handshake_and_event_parsing():
    hs = json.loads(realtime.handshake("k"))
    assert hs == {
        "authorization": {"accessToken": "Bearer k"},
        "audioEncoding": "PCM_24KHZ",
        "model": "muse-voice-transcribe-1.0",
        "mode": "PUSH_TO_TALK",
    }
    assert realtime.parse_event(
        json.dumps({"type": "transcript", "transcript": "one eighty", "final": False})
    ) == {"type": "transcript", "transcript": "one eighty", "final": False}
    assert realtime.parse_event(b"\x00\x01") is None and realtime.parse_event("nope") is None
    assert realtime.parse_event(json.dumps({"type": "error", "message": "bad"})) == {
        "type": "error",
        "message": "bad",
    }
    assert realtime.parse_event(json.dumps({"type": "other"})) is None


class FakeMeta:
    """Echoes a partial, then a final transcript once endStream arrives."""

    def __init__(self):
        self.sent: list = []
        self.queue: asyncio.Queue = asyncio.Queue()
        self.closed = False

    async def send(self, data):
        self.sent.append(data)
        if isinstance(data, bytes):
            await self.queue.put(
                json.dumps({"type": "transcript", "transcript": "one eighty", "final": False})
            )
        elif isinstance(data, str) and '"endStream"' in data:
            await self.queue.put(
                json.dumps({"type": "transcript", "transcript": "one eighty point eight", "final": True})
            )

    def __aiter__(self):
        return self

    async def __anext__(self):
        if self.closed:
            raise StopAsyncIteration
        return await self.queue.get()

    async def close(self):
        self.closed = True


def test_stream_relays_audio_up_and_transcripts_down(monkeypatch):
    fake = FakeMeta()

    async def connect():
        return fake

    monkeypatch.setattr(realtime, "connect_meta", connect)
    monkeypatch.setenv("MODEL_API_KEY", "k")
    client = TestClient(app)
    with client.websocket_connect("/voice/stream") as ws:
        ws.send_text(json.dumps({"type": "start"}))
        assert ws.receive_json() == {"type": "ready"}
        ws.send_bytes(b"\x00" * 3840)
        partial = ws.receive_json()
        assert partial == {"type": "transcript", "transcript": "one eighty", "final": False}
        ws.send_text(json.dumps({"type": "end"}))
        final = ws.receive_json()
        assert final == {"type": "transcript", "transcript": "one eighty point eight", "final": True}
        done = ws.receive_json()
        assert done == {"type": "done", "transcript": "one eighty point eight"}
    assert json.loads(fake.sent[0])["mode"] == "PUSH_TO_TALK"
    assert fake.sent[1] == b"\x00" * 3840 and '"endStream"' in fake.sent[2]
    assert fake.closed


def test_stream_without_a_key_or_meta_says_so(monkeypatch):
    monkeypatch.delenv("MODEL_API_KEY", raising=False)
    client = TestClient(app)
    with client.websocket_connect("/voice/stream") as ws:
        assert ws.receive_json()["type"] == "error"
    monkeypatch.setenv("MODEL_API_KEY", "k")

    async def boom():
        raise OSError("down")

    monkeypatch.setattr(realtime, "connect_meta", boom)
    with client.websocket_connect("/voice/stream") as ws:
        assert ws.receive_json() == {"type": "error", "message": "realtime unavailable: OSError"}


def test_text_turn_skips_transcription(monkeypatch):
    from app import checkin_turn
    from tests.test_checkin_turn import WEIGHT, context

    client = TestClient(app)
    body = {
        "transcript": "one eighty point eight",
        "context": json.loads(checkin_turn.turn_context_json(context(step="weight", asked=WEIGHT))),
    }
    r = client.post("/checkin/turn/text", json=body)
    assert r.status_code == 200 and r.json()["fastPath"] and r.json()["timings"]["transcribe"] == 0.0
    r = client.post("/checkin/turn/text", json={"transcript": "  ", "context": body["context"]})
    assert r.json()["intent"] == "unclear"
