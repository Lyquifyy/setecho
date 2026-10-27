import math
import struct

import pytest

from app import audio


def _tone(seconds: float, rate: int) -> bytes:
    n = int(seconds * rate)
    return b"".join(struct.pack("<h", int(12000 * math.sin(2 * math.pi * 440 * i / rate))) for i in range(n))


def test_write_wav_is_16k_mono_16bit():
    wav = audio.write_wav(_tone(0.5, 16000), 16000)
    info = audio.check_transcribe_wav(wav)
    assert (info.sample_rate, info.channels, info.sample_width) == (16000, 1, 2)
    assert info.frames == 8000
    assert abs(info.duration_s - 0.5) < 1e-9
    assert wav[:4] == b"RIFF" and wav[8:12] == b"WAVE"


def test_24k_is_accepted_and_44k_is_not():
    assert audio.wav_info(audio.write_wav(_tone(0.1, 24000), 24000)).transcribe_ready
    with pytest.raises(ValueError, match="16 or 24 kHz"):
        audio.check_transcribe_wav(audio.write_wav(_tone(0.1, 44100), 44100))


def test_garbage_is_rejected():
    with pytest.raises(ValueError, match="not a WAV"):
        audio.check_transcribe_wav(b"not audio at all")
