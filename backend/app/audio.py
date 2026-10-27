"""WAV helpers for Muse Voice Transcribe: mono, 16-bit PCM, 16 kHz or 24 kHz, RIFF/WAVE.

The phone writes this format itself (HANDOFF.md §7 Audio). The backend validates what it
receives, and converts anything else with ffmpeg before it goes to Meta.
"""

from __future__ import annotations

import io
import struct
import subprocess
import wave
from dataclasses import dataclass
from pathlib import Path

TRANSCRIBE_RATES = (16000, 24000)
MAX_BYTES = 32 * 1024 * 1024
MAX_SECONDS = 10 * 60


@dataclass(frozen=True)
class WavInfo:
    sample_rate: int
    channels: int
    sample_width: int  # bytes per sample; 2 = 16-bit
    frames: int

    @property
    def duration_s(self) -> float:
        return self.frames / self.sample_rate if self.sample_rate else 0.0

    @property
    def transcribe_ready(self) -> bool:
        return self.channels == 1 and self.sample_width == 2 and self.sample_rate in TRANSCRIBE_RATES


def wav_info(data: bytes) -> WavInfo:
    with wave.open(io.BytesIO(data), "rb") as w:
        return WavInfo(w.getframerate(), w.getnchannels(), w.getsampwidth(), w.getnframes())


def check_transcribe_wav(data: bytes) -> WavInfo:
    """Raise ValueError when the clip would be rejected by the transcribe endpoint."""
    if len(data) > MAX_BYTES:
        raise ValueError(f"WAV is {len(data)} bytes; the limit is {MAX_BYTES}")
    try:
        info = wav_info(data)
    except (wave.Error, EOFError) as e:
        raise ValueError(f"not a WAV file: {e}") from e
    if not info.transcribe_ready:
        raise ValueError(
            f"WAV must be mono 16-bit at 16 or 24 kHz; got {info.channels} ch, "
            f"{info.sample_width * 8}-bit, {info.sample_rate} Hz"
        )
    if info.duration_s > MAX_SECONDS:
        raise ValueError(f"WAV is {info.duration_s:.0f} s; the limit is {MAX_SECONDS} s")
    return info


def write_wav(pcm16_mono: bytes, sample_rate: int = 16000) -> bytes:
    """RIFF/WAVE header + little-endian 16-bit mono PCM. Mirrors the Swift writer on the phone."""
    data_size = len(pcm16_mono)
    byte_rate = sample_rate * 2
    header = b"RIFF" + struct.pack("<I", 36 + data_size) + b"WAVE"
    header += b"fmt " + struct.pack("<IHHIIHH", 16, 1, 1, sample_rate, byte_rate, 2, 16)
    header += b"data" + struct.pack("<I", data_size)
    return header + pcm16_mono


def convert_to_transcribe_wav(src: Path, sample_rate: int = 16000) -> bytes:
    """Any audio ffmpeg can read -> mono 16-bit PCM WAV at `sample_rate`, metadata stripped."""
    if sample_rate not in TRANSCRIBE_RATES:
        raise ValueError(f"sample_rate must be one of {TRANSCRIBE_RATES}")
    cmd = [
        "ffmpeg", "-loglevel", "error", "-i", str(src),
        "-ac", "1", "-ar", str(sample_rate), "-c:a", "pcm_s16le", "-map_metadata", "-1",
        "-f", "wav", "pipe:1",
    ]  # fmt: skip
    return subprocess.run(cmd, check=True, capture_output=True).stdout
