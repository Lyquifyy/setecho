"""The only module that talks to Meta Model API.

Rules (see AGENTS.md):
- Nothing else in the backend imports `openai`.
- The key comes from MODEL_API_KEY in the environment. Never from a file in the repo.
- Standard tier only. Gym footage and check-in photos contain other people.

Models:
- muse-spark-1.3: reasoning and parsing (structured output via Chat Completions, tools via Responses)
- muse-voice-transcribe-1.0: speech, file mode over multipart (not the OpenAI SDK)
- sam-3.1: image masks for the check-in photos; video tracking only for the bar-speed stretch item
"""

from __future__ import annotations

import base64
import json
import os
import time
from functools import lru_cache
from pathlib import Path
from typing import Any

import httpx
from openai import AsyncOpenAI, OpenAI

BASE_URL = "https://api.meta.ai/v1"
SPARK_MODEL = os.environ.get("SETECHO_SPARK_MODEL", "muse-spark-1.3")
SAM_MODEL = "sam-3.1"
TRANSCRIBE_MODEL = "muse-voice-transcribe-1.0"
TRANSCRIBE_URL = f"{BASE_URL}/asr/transcribe"


def _key() -> str:
    key = os.environ.get("MODEL_API_KEY")
    if not key:
        raise RuntimeError("MODEL_API_KEY is not set. Export it in ~/.zshrc; never put it in the repo.")
    return key


@lru_cache
def client() -> OpenAI:
    return OpenAI(base_url=BASE_URL, api_key=_key())


@lru_cache
def aclient() -> AsyncOpenAI:
    return AsyncOpenAI(base_url=BASE_URL, api_key=_key())


# ---------------------------------------------------------------------------
# Muse Spark: structured output
# ---------------------------------------------------------------------------

UserContent = str | list[dict[str, Any]]


def data_url(data: bytes, mime: str) -> str:
    return f"data:{mime};base64,{base64.b64encode(data).decode('ascii')}"


def spark_json(system: str, user: UserContent, schema_name: str, schema: dict[str, Any]) -> tuple[dict, Any]:
    """One Chat Completions call with a strict JSON-schema response.

    `user` is plain text, or a content list for image input:
    [{"type": "text", "text": ...}, {"type": "image_url", "image_url": {"url": data_url}}].
    Returns the parsed JSON and the raw response (for usage and ids). Keep `system` and
    `schema` byte-identical across calls so prompt caching applies.
    """
    resp = client().chat.completions.create(
        model=SPARK_MODEL,
        messages=[{"role": "system", "content": system}, {"role": "user", "content": user}],
        response_format={
            "type": "json_schema",
            "json_schema": {"name": schema_name, "strict": True, "schema": schema},
        },
    )
    content = resp.choices[0].message.content or ""
    return json.loads(content), resp


# ---------------------------------------------------------------------------
# Muse Voice Transcribe: file mode
# ---------------------------------------------------------------------------


class TranscribeError(RuntimeError):
    def __init__(self, status: int, body: str):
        super().__init__(f"transcribe failed with HTTP {status}: {body[:300]}")
        self.status = status


def transcribe_wav(wav: bytes, *, session_id: str | None = None, timeout: float = 60.0) -> dict:
    """Transcribe one WAV utterance (mono, 16-bit PCM, 16 kHz or 24 kHz, up to 10 min / 32 MB).

    PUSH_TO_TALK: the app sets the turn boundaries, so `turns` comes back empty.
    400 means bad audio (no retry), 429 means back off (no retry here), 500 is retried once.
    Returns {sessionId, transcript, audioDurationMs, turns}.
    """
    request = {"model": TRANSCRIBE_MODEL, "audioEncoding": "WAV", "mode": "PUSH_TO_TALK"}
    files = {
        "request": (None, json.dumps(request), "application/json"),
        "audio": ("utterance.wav", wav, "audio/wav"),
    }
    headers = {"Authorization": f"Bearer {_key()}", "Accept": "application/json"}
    params = {"sessionId": session_id} if session_id else None
    for attempt in (1, 2):
        r = httpx.post(TRANSCRIBE_URL, headers=headers, files=files, params=params, timeout=timeout)
        if r.status_code == 500 and attempt == 1:
            time.sleep(1.0)
            continue
        if r.status_code != 200:
            raise TranscribeError(r.status_code, r.text)
        return r.json()
    raise AssertionError("unreachable")


# ---------------------------------------------------------------------------
# SAM 3.1
# ---------------------------------------------------------------------------


async def segment_image(image_data_url: str, prompt_text: str = "person"):
    """Run SAM 3.1 on one image and return the parsed ImageSegmentationResult.

    `prompt_text` is a noun phrase. An empty output (no records) means no match, which is normal.
    Downscale to about 1280 px on the long side before calling (see app.photos).
    """
    from meta_sam_parser import image_segmentation_format, parse_responses_stream

    events = await aclient().responses.create(
        model=SAM_MODEL,
        input=[
            {
                "type": "message",
                "role": "user",
                "content": [
                    {"type": "input_text", "text": prompt_text},
                    {"type": "input_image", "image_url": image_data_url},
                ],
            }
        ],
        stream=True,
        metadata={"mask_encoding": "one_bit"},
    )
    parsed = parse_responses_stream(events, image_segmentation_format())
    final = parsed.final_result
    return await (final() if callable(final) else final)


def upload_video(path: Path) -> str:
    """Upload a clip once; reuse the returned file id for SAM calls. Bar-speed stretch only."""
    with open(path, "rb") as f:
        return client().files.create(purpose="user_data", file=f).id


async def segment_video(file_id: str, prompt_text: str):
    """Run SAM 3.1 on an uploaded clip and return the parsed VideoSegmentationResult. Stretch only.

    `prompt_text` is either a noun phrase ("weight plate") or an object prompt built
    with meta_sam_parser.build_object_prompt (point/box on frame 0).
    """
    from meta_sam_parser import parse_responses_stream, video_segmentation_format

    events = await aclient().responses.create(
        model=SAM_MODEL,
        input=[
            {
                "type": "message",
                "role": "user",
                "content": [
                    {"type": "input_text", "text": prompt_text},
                    {"type": "input_video", "file_id": file_id},
                ],
            }
        ],
        stream=True,
        metadata={"mask_encoding": "one_bit"},
    )
    parsed = parse_responses_stream(events, video_segmentation_format())
    final = parsed.final_result
    return await (final() if callable(final) else final)
