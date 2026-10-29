"""Contact sheets from the screen renders (`make screens`), so the whole app can be reviewed at once.

Reads <folder>/manifest.json (written by ScreenRenderTests) and writes, into the same folder:
  contact-sheet.png       every first-screen render, one row per group
  contact-<group>.png     one group's first-screen renders, larger
  contact-sheet-full.png  the full-scroll renders side by side

Usage: uv run --no-project --with pillow python ios/scripts/contact_sheet.py design/screens
"""

import json
import re
import sys
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

PAGE = (238, 242, 249)  # Theme.page
NAVY = (23, 29, 54)
SECONDARY = (76, 85, 115)
BORDER = (209, 217, 236)

GAP = 28
MARGIN = 48


def font(size: int, bold: bool = False) -> ImageFont.ImageFont:
    for path in (
        "/System/Library/Fonts/SFNS.ttf",
        "/System/Library/Fonts/Helvetica.ttc",
        "/Library/Fonts/Arial.ttf",
    ):
        try:
            f = ImageFont.truetype(path, size)
            if bold and path.endswith("SFNS.ttf"):
                try:
                    f.set_variation_by_name("Bold")
                except (OSError, ValueError):
                    pass
            return f
        except OSError:
            continue
    return ImageFont.load_default()


def slug(text: str) -> str:
    return re.sub(r"[^a-z0-9]+", "-", text.lower()).strip("-")


def thumb(path: Path, width: int, max_height: int | None = None) -> Image.Image:
    image = Image.open(path).convert("RGB")
    height = round(image.height * width / image.width)
    image = image.resize((width, height), Image.LANCZOS)
    if max_height and image.height > max_height:
        image = image.crop((0, 0, width, max_height))
    return image


def fit(draw: ImageDraw.ImageDraw, text: str, f: ImageFont.ImageFont, width: int) -> str:
    """The caption, cut with an ellipsis so it never runs into the next frame's."""
    if draw.textlength(text, font=f) <= width:
        return text
    while text and draw.textlength(text + "…", font=f) > width:
        text = text[:-1]
    return text.rstrip() + "…"


def sheet(
    rows: list[tuple[str, list[dict]]], folder: Path, width: int, per_row: int, max_height: int | None = None
) -> Image.Image:
    """One block per group: its title, then its frames in rows of `per_row`, each captioned."""
    title_font, caption_font = font(34, bold=True), font(22)
    caption_h = 40
    blocks: list[tuple[str, list[list[tuple[Image.Image, str]]]]] = []
    for group, entries in rows:
        frames = [(thumb(folder / e["file"], width, max_height), e["title"]) for e in entries]
        blocks.append((group, [frames[i : i + per_row] for i in range(0, len(frames), per_row)]))

    total_w = MARGIN * 2 + per_row * width + (per_row - 1) * GAP
    total_h = MARGIN
    for _, lines in blocks:
        total_h += 56
        for line in lines:
            total_h += max(f.height for f, _ in line) + caption_h + GAP
        total_h += GAP
    canvas = Image.new("RGB", (total_w, total_h), PAGE)
    draw = ImageDraw.Draw(canvas)

    y = MARGIN
    for group, lines in blocks:
        draw.text((MARGIN, y), group, font=title_font, fill=NAVY)
        y += 56
        for line in lines:
            x = MARGIN
            for frame, caption in line:
                canvas.paste(frame, (x, y))
                draw.rectangle((x - 1, y - 1, x + frame.width, y + frame.height), outline=BORDER, width=1)
                draw.text(
                    (x, y + frame.height + 10),
                    fit(draw, caption, caption_font, frame.width),
                    font=caption_font,
                    fill=SECONDARY,
                )
                x += width + GAP
            y += max(f.height for f, _ in line) + caption_h + GAP
        y += GAP
    return canvas


def main(folder: Path) -> None:
    manifest = json.loads((folder / "manifest.json").read_text())
    first = [e for e in manifest if e.get("tall") != "1"]
    tall = [e for e in manifest if e.get("tall") == "1"]

    groups: dict[str, list[dict]] = {}
    for entry in first:
        groups.setdefault(entry["group"], []).append(entry)

    if groups:
        sheet(list(groups.items()), folder, width=300, per_row=9).save(folder / "contact-sheet.png", optimize=True)
        for group, entries in groups.items():
            sheet([(group, entries)], folder, width=520, per_row=min(5, len(entries))).save(
                folder / f"contact-{slug(group)}.png", optimize=True
            )
    if tall:
        sheet([("Full scroll", tall)], folder, width=360, per_row=min(8, len(tall))).save(
            folder / "contact-sheet-full.png", optimize=True
        )
    print(f"{len(first)} screens in {len(groups)} groups, {len(tall)} full-scroll → {folder}")


if __name__ == "__main__":
    main(Path(sys.argv[1] if len(sys.argv) > 1 else "design/screens"))
