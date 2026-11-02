"""WebSocket /voice/stream: realtime transcription (HANDOFF.md §9, block 1). The phone streams
PCM16 mono 24 kHz as it is captured; the backend relays it to Voice Transcribe's realtime
endpoint and sends every transcript event straight back, so the words are ready the moment the
athlete stops talking. The key never leaves the backend. File mode (/checkin/turn with audio) is
the fallback when the socket fails.

Phone → backend: a JSON text frame {"type": "start"}, then binary PCM frames (80 ms each),
then {"type": "end"}. Backend → phone: {"type": "ready"}, then {"type": "transcript", "transcript":
..., "final": bool} as Meta sends them, then {"type": "done", "transcript": ...} after the end, or
{"type": "error", "message": ...}.
"""

from __future__ import annotations

import asyncio
import contextlib
import json
import logging
import os
from typing import Any

from fastapi import APIRouter, WebSocket, WebSocketDisconnect

from app import budget

router = APIRouter()
log = logging.getLogger(__name__)

REALTIME_URL = "wss://api.meta.ai/v1/asr/realtime"
TRANSCRIBE_MODEL = "muse-voice-transcribe-1.0"
FINAL_TIMEOUT = 4.0


def handshake(key: str) -> str:
    return json.dumps(
        {
            "authorization": {"accessToken": f"Bearer {key}"},
            "audioEncoding": "PCM_24KHZ",
            "model": TRANSCRIBE_MODEL,
            "mode": "PUSH_TO_TALK",
        }
    )


def parse_event(raw: str | bytes) -> dict[str, Any] | None:
    """A transcript event from Meta, as the phone needs it; None for anything else."""
    if isinstance(raw, bytes):
        return None
    try:
        event = json.loads(raw)
    except json.JSONDecodeError:
        return None
    if not isinstance(event, dict):
        return None
    if event.get("type") == "transcript":
        return {
            "type": "transcript",
            "transcript": event.get("transcript", ""),
            "final": bool(event.get("final")),
        }
    if event.get("type") == "error":
        return {"type": "error", "message": str(event.get("message") or event)}
    return None


async def connect_meta():
    import websockets

    return await websockets.connect(REALTIME_URL, max_size=None, open_timeout=5)


@router.websocket("/voice/stream")
async def voice_stream(phone: WebSocket) -> None:
    await phone.accept()
    key = os.environ.get("MODEL_API_KEY")
    if not key:
        await phone.send_json({"type": "error", "message": "no key"})
        await phone.close()
        return
    # The spend guard: a few sockets at once, the rest fall back to file mode on the phone.
    if not budget.budget.acquire_socket():
        await phone.send_json(
            {"type": "error", "message": f"{budget.ERROR}: realtime sockets are all in use"}
        )
        await phone.close()
        return
    try:
        await _relay(phone, key)
    finally:
        budget.budget.release_socket()


async def _relay(phone: WebSocket, key: str) -> None:
    try:
        meta_ws = await connect_meta()
    except Exception as e:  # noqa: BLE001 - any failure here means the file-mode fallback
        await phone.send_json({"type": "error", "message": f"realtime unavailable: {type(e).__name__}"})
        await phone.close()
        return
    final: dict[str, Any] = {"transcript": ""}
    ended = asyncio.Event()

    async def relay_up() -> None:
        try:
            while True:
                message = await phone.receive()
                if message.get("type") == "websocket.disconnect":
                    break
                if (data := message.get("bytes")) is not None:
                    await meta_ws.send(data)
                elif (text := message.get("text")) is not None:
                    try:
                        frame = json.loads(text)
                    except json.JSONDecodeError:
                        continue
                    if frame.get("type") == "end":
                        await meta_ws.send(json.dumps({"type": "endStream"}))
                        return
        except WebSocketDisconnect:
            pass

    async def relay_down() -> None:
        try:
            async for raw in meta_ws:
                event = parse_event(raw)
                if event is None:
                    continue
                if event["type"] == "transcript":
                    final["transcript"] = event["transcript"]
                    await phone.send_json(event)
                    if event["final"]:
                        ended.set()
                else:
                    await phone.send_json(event)
                    ended.set()
                    return
        except Exception as e:  # noqa: BLE001 - the stream closed under us: the phone gets what it has
            log.info("realtime stream closed: %s", e)
            ended.set()

    try:
        await meta_ws.send(handshake(key))
        await phone.send_json({"type": "ready"})
        down = asyncio.create_task(relay_down())
        await relay_up()
        try:
            await asyncio.wait_for(ended.wait(), timeout=FINAL_TIMEOUT)
        except TimeoutError:
            pass
        down.cancel()
        await phone.send_json({"type": "done", "transcript": final["transcript"]})
    except WebSocketDisconnect:
        pass
    except Exception as e:  # noqa: BLE001
        log.info("voice stream ended: %s", e)
        with contextlib.suppress(Exception):
            await phone.send_json({"type": "error", "message": type(e).__name__})
    finally:
        with contextlib.suppress(Exception):
            await meta_ws.close()
        with contextlib.suppress(Exception):
            await phone.close()
