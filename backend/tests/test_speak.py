"""/voice/speak: the provider adapter, unconfigured by default, and the request shapes. No network."""

import pytest
from fastapi.testclient import TestClient

from app import speak
from app.main import app


def test_unconfigured_means_no_provider_and_a_422(monkeypatch):
    for key in ("VOICE_PROVIDER", "ELEVENLABS_API_KEY", "CARTESIA_API_KEY"):
        monkeypatch.delenv(key, raising=False)
    client = TestClient(app)
    assert client.get("/voice/speak/status").json() == {
        "provider": None,
        "configured": False,
        "format": "audio/mpeg",
    }
    r = client.post("/voice/speak", json={"text": "Morning. Step on the scale."})
    assert r.status_code == 422 and "no natural voice" in r.json()["error"]
    monkeypatch.setenv("VOICE_PROVIDER", "elevenlabs")  # named but no key: still unconfigured
    assert speak.provider() is None


def test_each_provider_gets_only_the_text(monkeypatch):
    monkeypatch.setenv("VOICE_PROVIDER", "elevenlabs")
    monkeypatch.setenv("ELEVENLABS_API_KEY", "k")
    url, headers, body = speak.request_for("elevenlabs", "Fasted glucose?")
    assert "text-to-speech" in url and headers["xi-api-key"] == "k" and body["text"] == "Fasted glucose?"
    assert body["model_id"] == "eleven_flash_v2_5" and set(body) == {"text", "model_id", "voice_settings"}
    monkeypatch.setenv("VOICE_PROVIDER", "cartesia")
    monkeypatch.setenv("CARTESIA_API_KEY", "c")
    assert speak.provider() == "cartesia"
    url, headers, body = speak.request_for("cartesia", "Fasted glucose?")
    assert (
        headers["X-API-Key"] == "c"
        and body["transcript"] == "Fasted glucose?"
        and body["model_id"] == "sonic-2"
    )
    assert "health" not in str(body) and set(body) == {
        "model_id",
        "transcript",
        "voice",
        "output_format",
        "language",
    }
    with pytest.raises(ValueError):
        speak.request_for("other", "x")


def test_text_is_capped_and_never_empty(monkeypatch):
    monkeypatch.setenv("VOICE_PROVIDER", "cartesia")
    monkeypatch.setenv("CARTESIA_API_KEY", "c")
    client = TestClient(app)
    assert client.post("/voice/speak", json={"text": "   "}).status_code == 422
    assert client.post("/voice/speak", json={"text": "x" * 401}).status_code == 422
