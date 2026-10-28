"""POST /voice/speak: the natural voice, streamed (HANDOFF.md §9, block 1). A small adapter over
ElevenLabs Flash v2.5 or Cartesia Sonic, chosen by the VOICE_PROVIDER secret; the key lives in Fly
secrets. The service receives only the text being spoken: no audio, no health data, no name
beyond what is in the line. Never a voice made to sound like the coach. The README names it as
the one non-Meta piece.
"""

from __future__ import annotations

import os
from collections.abc import AsyncIterator

import httpx
from fastapi import APIRouter
from fastapi.responses import StreamingResponse
from pydantic import Field

from app.schemas import StrictModel

router = APIRouter()

ELEVENLABS_URL = "https://api.elevenlabs.io/v1/text-to-speech/{voice}/stream"
ELEVENLABS_MODEL = "eleven_flash_v2_5"
ELEVENLABS_DEFAULT_VOICE = "21m00Tcm4TlvDq8ikWAM"  # a stock voice; the human may set ELEVENLABS_VOICE_ID
CARTESIA_URL = "https://api.cartesia.ai/tts/bytes"
CARTESIA_MODEL = "sonic-2"
CARTESIA_VERSION = "2024-06-10"
MAX_TEXT = 400


class SpeakRequest(StrictModel):
    text: str = Field(max_length=MAX_TEXT)


class SpeakStatus(StrictModel):
    provider: str | None
    configured: bool
    format: str


def provider() -> str | None:
    """elevenlabs, cartesia, or None when no natural voice is configured."""
    name = os.environ.get("VOICE_PROVIDER", "").strip().lower()
    if name == "elevenlabs" and os.environ.get("ELEVENLABS_API_KEY"):
        return "elevenlabs"
    if name == "cartesia" and os.environ.get("CARTESIA_API_KEY"):
        return "cartesia"
    return None


def audio_format() -> str:
    return "audio/mpeg"


def request_for(name: str, text: str) -> tuple[str, dict[str, str], dict]:
    """URL, headers and JSON body for one provider. Both return MP3 so the phone plays either."""
    if name == "elevenlabs":
        voice = os.environ.get("ELEVENLABS_VOICE_ID", ELEVENLABS_DEFAULT_VOICE)
        return (
            ELEVENLABS_URL.format(voice=voice) + "?output_format=mp3_22050_32",
            {"xi-api-key": os.environ["ELEVENLABS_API_KEY"], "Content-Type": "application/json"},
            {
                "text": text,
                "model_id": ELEVENLABS_MODEL,
                "voice_settings": {"stability": 0.5, "similarity_boost": 0.6},
            },
        )
    if name == "cartesia":
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
                "output_format": {"container": "mp3", "bit_rate": 64000, "sample_rate": 22050},
                "language": "en",
            },
        )
    raise ValueError(f"unknown voice provider {name!r}")


async def stream_speech(text: str) -> AsyncIterator[bytes]:
    name = provider()
    if name is None:
        raise ValueError("no natural voice is configured")
    url, headers, body = request_for(name, text)
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
    return SpeakStatus(provider=name, configured=name is not None, format=audio_format())


@router.post("/voice/speak")
async def speak(req: SpeakRequest) -> StreamingResponse:
    """The line as MP3, streamed as the provider sends it. 422 when no voice is configured, so the
    phone falls back to the system voice at once."""
    text = req.text.strip()
    if not text:
        raise ValueError("nothing to say")
    if provider() is None:
        raise ValueError("no natural voice is configured")
    return StreamingResponse(stream_speech(text), media_type=audio_format())
