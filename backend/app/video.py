"""Video helpers around ffmpeg and ffprobe: the real frame timestamps a clip carries (AGENTS.md
rule 7: iPhone video has a variable frame rate), and the small silent copy that goes to SAM.
"""

from __future__ import annotations

import subprocess
from pathlib import Path

COUNT_HEIGHT = 720
COUNT_FPS = 15  # rep speed needs the extra frames over 10 (HANDOFF.md §6, SAM on video)
MAX_COUNT_FRAMES = 3600  # four minutes at 15 fps; a set is never that long


def frame_times(path: Path) -> list[float]:
    """Presentation timestamps of every video frame, in seconds, from the container."""
    cmd = [
        "ffprobe", "-v", "error", "-select_streams", "v:0",
        "-show_entries", "frame=pts_time", "-of", "csv=p=0", str(path),
    ]  # fmt: skip
    out = subprocess.run(cmd, capture_output=True, text=True, check=True).stdout
    times: list[float] = []
    for line in out.splitlines():
        value = line.strip().rstrip(",")
        if not value or value == "N/A":
            continue
        times.append(float(value))
    times.sort()
    return times


def prepare_for_count(src: Path, dst: Path, height: int = COUNT_HEIGHT, fps: int = COUNT_FPS) -> Path:
    """720p, 15 fps, no audio, H.264 faststart: what the phone sends and what SAM gets."""
    dst.parent.mkdir(parents=True, exist_ok=True)
    cmd = [
        "ffmpeg", "-y", "-loglevel", "error", "-i", str(src),
        "-vf", f"scale=-2:{height},fps={fps}", "-an",
        "-c:v", "libx264", "-preset", "veryfast", "-crf", "23", "-pix_fmt", "yuv420p",
        "-movflags", "+faststart", "-map_metadata", "-1", str(dst),
    ]  # fmt: skip
    subprocess.run(cmd, check=True)
    return dst


def has_ffmpeg() -> bool:
    try:
        subprocess.run(["ffmpeg", "-version"], capture_output=True, check=True)
        subprocess.run(["ffprobe", "-version"], capture_output=True, check=True)
        return True
    except (OSError, subprocess.CalledProcessError):
        return False
