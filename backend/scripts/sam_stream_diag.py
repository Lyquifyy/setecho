"""Stream one SAM video request and log when each event arrives, to see where a stream dies.
Runs anywhere the key and `app` are present, including inside the Fly machine:

  python -m scripts.sam_stream_diag /tmp/set.mp4 --prompt "weight plate"

Prints: upload time, time to the first event, event count and bytes every 50 events, and the
exception with its timing if the stream breaks. Costs one SAM call.
"""

from __future__ import annotations

import argparse
import asyncio
import time
from pathlib import Path

from app import meta


async def run(path: Path, prompt: str) -> None:
    t0 = time.time()
    file_id = meta.upload_video(path)
    print(f"uploaded {path.name} in {time.time() - t0:.1f}s -> {file_id}", flush=True)
    t1 = time.time()
    stream = await meta.aclient().responses.create(
        model=meta.SAM_MODEL,
        input=[
            {
                "type": "message",
                "role": "user",
                "content": [
                    {"type": "input_text", "text": prompt},
                    {"type": "input_video", "file_id": file_id},
                ],
            }
        ],
        stream=True,
        metadata={"mask_encoding": "one_bit"},
    )
    print(f"request sent, waiting for the first event ({time.time() - t1:.1f}s)", flush=True)
    count = 0
    chars = 0
    last = time.time()
    try:
        async for event in stream:
            now = time.time()
            if count == 0:
                print(f"first event after {now - t1:.1f}s: {getattr(event, 'type', '?')}", flush=True)
            count += 1
            delta = getattr(event, "delta", None)
            if isinstance(delta, str):
                chars += len(delta)
            if count % 50 == 0 or now - last > 20:
                print(f"  {count} events, {chars} chars, {now - t1:.1f}s", flush=True)
                last = now
        print(f"stream complete: {count} events, {chars} chars, {time.time() - t1:.1f}s", flush=True)
    except Exception as e:  # noqa: BLE001 - a diagnostic: every failure must print
        print(
            f"stream FAILED after {time.time() - t1:.1f}s at {count} events: {type(e).__name__}: {e}",
            flush=True,
        )
        cause = e.__cause__
        while cause is not None:
            print(f"  caused by {type(cause).__name__}: {cause}", flush=True)
            cause = cause.__cause__
    finally:
        meta.delete_file(file_id)


if __name__ == "__main__":
    p = argparse.ArgumentParser()
    p.add_argument("clip")
    p.add_argument("--prompt", default="weight plate")
    args = p.parse_args()
    asyncio.run(run(Path(args.clip), args.prompt))
