"""Video helpers around ffmpeg and ffprobe: the real frame timestamps a clip carries (AGENTS.md
rule 7: iPhone video has a variable frame rate), and the small silent copy that goes to SAM.
"""

from __future__ import annotations

import json
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


def display_size(path: Path) -> tuple[int, int]:
    """The frame size as ffmpeg decodes it: the stored size, turned when the file says to rotate."""
    cmd = [
        "ffprobe", "-v", "error", "-select_streams", "v:0",
        "-show_entries", "stream=width,height:stream_side_data=rotation", "-of", "json", str(path),
    ]  # fmt: skip
    info = json.loads(subprocess.run(cmd, capture_output=True, text=True, check=True).stdout)
    stream = info["streams"][0]
    width, height = int(stream["width"]), int(stream["height"])
    rotation = next(
        (int(d.get("rotation", 0)) for d in stream.get("side_data_list", []) if "rotation" in d), 0
    )
    return (height, width) if abs(rotation) % 180 == 90 else (width, height)


def crop_box_pixels(
    box: list[float], size: tuple[int, int], *, front: bool = False
) -> tuple[int, int, int, int]:
    """The phone's box (x, y, w, h, normalized, top-left origin, in the upright portrait frame Vision
    saw with orientation .right) as an even-sized pixel crop (w, h, x, y) of the decoded frame. A
    landscape frame is the sensor's own orientation: the upright frame turned 90° clockwise from it,
    so its x is the upright y and its y runs from the upright right edge. The front camera (unmirrored,
    orientation .left) turns the other way: its y is the upright x and its x runs from the upright bottom."""
    x, y, w, h = (min(1.0, max(0.0, v)) for v in box)
    width, height = size
    if width > height:
        x, y, w, h = (1 - y - h, x, h, w) if front else (y, 1 - x - w, h, w)
    px, py = round(x * width), round(y * height)
    pw = min(width - px, round(w * width)) // 2 * 2
    ph = min(height - py, round(h * height)) // 2 * 2
    return pw, ph, px, py


def crop(src: Path, dst: Path, box: list[float], *, front: bool = False) -> Path:
    """The count clip cut to his station before SAM sees it: same frames, same timestamps (rule 7)."""
    pw, ph, px, py = crop_box_pixels(box, display_size(src), front=front)
    if pw < 16 or ph < 16:
        raise ValueError(f"crop box too small: {box}")
    cmd = [
        "ffmpeg", "-y", "-loglevel", "error", "-i", str(src),
        "-vf", f"crop={pw}:{ph}:{px}:{py}", "-fps_mode", "passthrough", "-an",
        "-c:v", "libx264", "-preset", "veryfast", "-crf", "20", "-pix_fmt", "yuv420p",
        "-movflags", "+faststart", "-map_metadata", "-1", str(dst),
    ]  # fmt: skip
    subprocess.run(cmd, check=True, capture_output=True)
    return dst


def has_ffmpeg() -> bool:
    try:
        subprocess.run(["ffmpeg", "-version"], capture_output=True, check=True)
        subprocess.run(["ffprobe", "-version"], capture_output=True, check=True)
        return True
    except (OSError, subprocess.CalledProcessError):
        return False
