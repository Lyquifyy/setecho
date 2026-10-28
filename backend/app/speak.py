"""POST /voice/speak: the natural voice, streamed (HANDOFF.md §9, block 1). A small adapter over
ElevenLabs Flash v2.5 (the human's pick, Oct 27) or Cartesia Sonic; the key, voice and model live in
Fly secrets. Numbers become words before the text leaves ("180.8" → "one eighty point eight"). Live
lines stream as PCM 24 kHz so the phone can play chunks as they arrive; pre-generated lines come
back as MP3 for the phone's cache. The service receives only the text being spoken: no audio, no
health data, no name beyond what is in the line. Never a voice made to sound like the coach. The
README names it as the one non-Meta piece.
"""

from __future__ import annotations

import os
from collections.abc import AsyncIterator
from typing import Literal

import httpx
from fastapi import APIRouter
from fastapi.responses import StreamingResponse
from pydantic import Field

from app import spoken
from app.schemas import StrictModel

router = APIRouter()

ELEVENLABS_URL = "https://api.elevenlabs.io/v1/text-to-speech/{voice}/stream"
ELEVENLABS_DEFAULT_MODEL = "eleven_flash_v2_5"
ELEVENLABS_DEFAULT_VOICE = "21m00Tcm4TlvDq8ikWAM"  # a stock voice; ELEVENLABS_VOICE_ID overrides it
# The human's settings (Oct 27): stability 0.5, similarity 0.75, speed 0.95, English.
ELEVENLABS_VOICE_SETTINGS = {"stability": 0.5, "similarity_boost": 0.75, "speed": 0.95}
ELEVENLABS_LANGUAGE = "en"
# Live lines stream as PCM so chunks play as they arrive; cached lines are MP3.
FORMATS = {"live": ("pcm_24000", "audio/pcm"), "cache": ("mp3_44100_128", "audio/mpeg")}
CARTESIA_URL = "https://api.cartesia.ai/tts/bytes"
CARTESIA_MODEL = "sonic-2"
CARTESIA_VERSION = "2024-06-10"
MAX_TEXT = 400

Mode = Literal["live", "cache"]


class SpeakRequest(StrictModel):
    text: str = Field(max_length=MAX_TEXT)
    mode: Mode = Field(
        default="live", description="live: PCM 24 kHz streamed; cache: MP3 for the phone's cache"
    )


class SpeakStatus(StrictModel):
    provider: str | None
    configured: bool
    format: str
    liveFormat: str = "audio/pcm"
    cacheFormat: str = "audio/mpeg"
    sampleRate: int = 24000


def provider() -> str | None:
    """elevenlabs, cartesia, or None when no natural voice is configured. VOICE_PROVIDER picks;
    without it, whichever key is set."""
    name = os.environ.get("VOICE_PROVIDER", "").strip().lower()
    has_eleven = bool(os.environ.get("ELEVENLABS_API_KEY"))
    has_cartesia = bool(os.environ.get("CARTESIA_API_KEY"))
    if name == "elevenlabs" and has_eleven:
        return "elevenlabs"
    if name == "cartesia" and has_cartesia:
        return "cartesia"
    if not name:
        if has_eleven:
            return "elevenlabs"
        if has_cartesia:
            return "cartesia"
    return None


def audio_format(mode: Mode = "live") -> str:
    return FORMATS[mode][1]


def request_for(name: str, text: str, mode: Mode = "live") -> tuple[str, dict[str, str], dict]:
    """URL, headers and JSON body for one provider, with every number already in words."""
    text = spoken.words(text)
    if name == "elevenlabs":
        voice = os.environ.get("ELEVENLABS_VOICE_ID", ELEVENLABS_DEFAULT_VOICE)
        model = os.environ.get("ELEVENLABS_MODEL", ELEVENLABS_DEFAULT_MODEL)
        return (
            ELEVENLABS_URL.format(voice=voice) + f"?output_format={FORMATS[mode][0]}",
            {"xi-api-key": os.environ["ELEVENLABS_API_KEY"], "Content-Type": "application/json"},
            {
                "text": text,
                "model_id": model,
                "language_code": ELEVENLABS_LANGUAGE,
                "voice_settings": dict(ELEVENLABS_VOICE_SETTINGS),
            },
        )
    if name == "cartesia":
        container = (
            {"container": "raw", "encoding": "pcm_s16le", "sample_rate": 24000}
            if mode == "live"
            else {"container": "mp3", "bit_rate": 128000, "sample_rate": 44100}
        )
        return (
            CARTESIA_URL,
            {
                "X-API-Key": os.environ["CARTESIA_API_KEY"],
                "Cartesia-Version": CARTESIA_VERSION,
                "Content-Type": "application/json",
            },
            {
                "model_id": CARTESIA_MODEL,
                "transcript": text,
                "voice": {"mode": "id", "id": os.environ.get("CARTESIA_VOICE_ID", "")},
                "output_format": container,
                "language": "en",
            },
        )
    raise ValueError(f"unknown voice provider {name!r}")


async def stream_speech(text: str, mode: Mode = "live") -> AsyncIterator[bytes]:
    name = provider()
    if name is None:
        raise ValueError("no natural voice is configured")
    url, headers, body = request_for(name, text, mode)
    async with (
        httpx.AsyncClient(timeout=httpx.Timeout(20.0, connect=5.0)) as client,
        client.stream("POST", url, headers=headers, json=body) as r,
    ):
        if r.status_code != 200:
            detail = (await r.aread())[:200].decode("utf-8", "replace")
            raise ValueError(f"{name} answered {r.status_code}: {detail}")
        async for chunk in r.aiter_bytes():
            if chunk:
                yield chunk


@router.get("/voice/speak/status", response_model=SpeakStatus)
def speak_status() -> SpeakStatus:
    name = provider()
    return SpeakStatus(provider=name, configured=name is not None, format=audio_format("cache"))


@router.post("/voice/speak")
async def speak(req: SpeakRequest) -> StreamingResponse:
    """The line as PCM 24 kHz (live) or MP3 (cache), streamed as the provider sends it. 422 when no
    voice is configured, so the phone falls back to the system voice at once."""
    text = req.text.strip()
    if not text:
        raise ValueError("nothing to say")
    if provider() is None:
        raise ValueError("no natural voice is configured")
    return StreamingResponse(stream_speech(text, req.mode), media_type=audio_format(req.mode))
