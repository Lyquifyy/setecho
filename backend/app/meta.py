"""The only module that talks to Meta Model API.

Rules (see AGENTS.md):
- Nothing else in the backend imports `openai`.
- The key comes from MODEL_API_KEY in the environment. Never from a file in the repo.
- Standard tier only. Gym footage contains other people.
"""

from __future__ import annotations

import os
from functools import lru_cache
from pathlib import Path

from openai import AsyncOpenAI, OpenAI

BASE_URL = "https://api.meta.ai/v1"
SPARK_MODEL = os.environ.get("CHALKLINE_SPARK_MODEL", "muse-spark-1.3")
SAM_MODEL = "sam-3.1"


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


def upload_video(path: Path) -> str:
    """Upload a clip once; reuse the returned file id for SAM and Spark calls."""
    with open(path, "rb") as f:
        return client().files.create(purpose="user_data", file=f).id


async def segment_video(file_id: str, prompt_text: str):
    """Run SAM 3.1 on an uploaded clip and return the parsed VideoSegmentationResult.

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


def parse_program(image_path: Path) -> dict:
    """Program photo -> structured weeks (Muse Spark, JSON schema output)."""
    raise NotImplementedError


def review_set(file_id: str, history_prefix: str) -> dict:
    """Spoken notes (RPE, note, timestamp) + form review on sets that broke."""
    raise NotImplementedError


def ask_coach(question: str, history_prefix: str) -> dict:
    """Coach answer with set-id citations. History goes first so caching applies."""
    raise NotImplementedError
