"""M0 voice smoke: does Muse Voice Transcribe return a transcript for a WAV clip?

  uv run python -m scripts.voice_probe path/to/clip.wav
  uv run python -m scripts.voice_probe path/to/clip.m4a            # converted with ffmpeg first
  uv run python -m scripts.voice_probe clip.wav --fixture           # also save to tests/fixtures/voice/

Anything that is not mono 16-bit PCM at 16 or 24 kHz is converted with ffmpeg before upload.
Output (response JSON + timing) goes to backend/private/probes/voice/, which is gitignored.
Costs $0.18 per audio hour; a 5 s clip is a fraction of a cent.
"""

from __future__ import annotations

import argparse
import json
import shutil
import time
from pathlib import Path

from app import audio, meta

ROOT = Path(__file__).resolve().parents[1]
PRIVATE = ROOT / "private" / "probes" / "voice"
FIXTURES = ROOT / "tests" / "fixtures" / "voice"


def load_wav(path: Path) -> tuple[bytes, bool]:
    data = path.read_bytes()
    try:
        audio.check_transcribe_wav(data)
        return data, False
    except ValueError as e:
        print(f"converting ({e})")
        return audio.convert_to_transcribe_wav(path), True


def main() -> None:
    p = argparse.ArgumentParser()
    p.add_argument("clip")
    p.add_argument("--fixture", action="store_true", help="also copy the response into tests/fixtures/voice/")
    args = p.parse_args()

    path = Path(args.clip)
    wav, converted = load_wav(path)
    info = audio.wav_info(wav)
    print(
        f"{path.name}: {info.duration_s:.2f} s, {info.sample_rate} Hz, {info.channels} ch, {len(wav)} bytes"
    )

    t0 = time.time()
    result = meta.transcribe_wav(wav)
    latency = time.time() - t0
    print(f"transcript: {result.get('transcript')!r}")
    print(
        f"sessionId: {result.get('sessionId')}  audio {result.get('audioDurationMs')} ms  latency {latency:.2f}s"
    )

    PRIVATE.mkdir(parents=True, exist_ok=True)
    out = PRIVATE / f"{path.stem}.json"
    out.write_text(
        json.dumps(
            {"clip": path.name, "converted": converted, "latency_s": latency, "response": result}, indent=2
        )
    )
    print(f"saved {out.relative_to(ROOT)}")
    if args.fixture:
        FIXTURES.mkdir(parents=True, exist_ok=True)
        shutil.copy(out, FIXTURES / out.name)
        print(f"fixture {FIXTURES.relative_to(ROOT) / out.name}")


if __name__ == "__main__":
    main()
