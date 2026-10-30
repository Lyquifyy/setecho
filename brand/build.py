#!/usr/bin/env python3
# /// script
# requires-python = ">=3.12"
# dependencies = ["fonttools==4.60.1", "pillow==12.0.0", "resvg-py==0.2.4"]
# ///
"""Rebuild every Setecho brand asset from licensed glyphs and one mark path.

Run: uv run brand/build.py. No network access or model calls at build time.
"""
from __future__ import annotations

import hashlib
import io
import json
import math
from pathlib import Path
import xml.etree.ElementTree as ET

from fontTools.ttLib import TTFont
from fontTools.varLib.instancer import instantiateVariableFont
from fontTools.pens.svgPathPen import SVGPathPen
from fontTools.pens.transformPen import TransformPen
from fontTools.pens.recordingPen import RecordingPen
from fontTools.pens.boundsPen import BoundsPen
from fontTools.pens.basePen import BasePen
from fontTools.svgLib.path import parse_path
from PIL import Image
import resvg_py

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent
OUT = HERE / "dist"
CATALOG = ROOT / "ios/Setecho/Assets.xcassets"
COBALT, NAVY, WHITE = "#2541D8", "#171D36", "#FFFFFF"
NS = "http://www.w3.org/2000/svg"
FONT = HERE / "fonts/SourceSerif4Variable-Roman.ttf"
FONT_HASH = "14d360ee1b76655da9276628b229e11671bc1f5d1083636144db6677d452cf55"
TRACKING = -10
KERN = dict(zip(["Se", "et", "te", "ec", "ch", "ho"], [-12, -4, -6, -10, -24, -4]))


def n(value):
    return f"{value:.3f}".rstrip("0").rstrip(".") or "0"


def svg(body, width, height, label="Setecho"):
    return (f'<svg xmlns="{NS}" viewBox="0 0 {n(width)} {n(height)}" '
            f'role="img" aria-label="{label}"><title>{label}</title>{body}</svg>\n')


def raster(source, width, height):
    return Image.open(io.BytesIO(resvg_py.svg_to_bytes(svg_string=source, width=width, height=height)))


def glyph_word(typeface, text, *, sloped=False, tracking=TRACKING, pairs=KERN):
    """Outline the actual font contours; customize only the e's crossbar points."""
    glyphs = typeface.getGlyphSet()
    all_paths = RecordingPen()
    x = 0
    for index, char in enumerate(text):
        glyph = glyphs[typeface.getBestCmap()[ord(char)]]
        recording = RecordingPen()
        glyph.draw(recording)
        if char == "e" and sloped:
            # Source Serif 4's horizontal crossbar lives at y=247..272.
            # Raise its right edge by tan(5°), leaving bowl, serif and stem intact.
            # All controls in the band follow the same affine slope so curves stay smooth.
            recording.value = [(op, tuple(
                (px, py + math.tan(math.radians(5)) * (px - 172))
                if 245 <= py <= 279 else (px, py)
                for px, py in points)) for op, points in recording.value]
        recording.replay(TransformPen(all_paths, (1, 0, 0, 1, x, 0)))
        x += glyph.width + tracking
        if index + 1 < len(text):
            x += pairs.get(char + text[index + 1], 0)
    bounds = BoundsPen(glyphs)
    all_paths.replay(bounds)
    left, bottom, right, top = bounds.bounds
    pen = SVGPathPen(glyphs, ntos=n)
    all_paths.replay(TransformPen(pen, (1, 0, 0, -1, -left, top)))
    return pen.getCommands(), right - left, top - bottom


class SwiftPen(BasePen):
    def __init__(self):
        super().__init__(None)
        self.lines = []

    def point(self, p):
        return f"CGPoint(x: {n(p[0])}, y: {n(p[1])})"

    def _moveTo(self, p):
        self.lines.append(f"path.move(to: {self.point(p)})")

    def _lineTo(self, p):
        self.lines.append(f"path.addLine(to: {self.point(p)})")

    def _curveToOne(self, c1, c2, p):
        self.lines.append(f"path.addCurve(to: {self.point(p)}, control1: {self.point(c1)}, control2: {self.point(c2)})")

    def _qCurveToOne(self, c, p):
        self.lines.append(f"path.addQuadCurve(to: {self.point(p)}, control: {self.point(c)})")

    def _closePath(self):
        self.lines.append("path.closeSubpath()")

    def _endPath(self):
        pass


if hashlib.sha256(FONT.read_bytes()).hexdigest() != FONT_HASH:
    raise SystemExit("Source Serif font hash differs; check provenance before rebuilding.")
OUT.mkdir(parents=True, exist_ok=True)
font = instantiateVariableFont(TTFont(FONT), {"wght": 700, "opsz": 60})
glyphs = font.getGlyphSet()
word, ww, wh = glyph_word(font, "Setecho", sloped=True)
source = ET.parse(HERE / "source/mark.svg").getroot()
raw = source.find(f"{{{NS}}}path")
mark_pen = SVGPathPen(None, ntos=n)
# Normalize the approved original's coordinates into its viewBox once.
parse_path(raw.attrib["d"], TransformPen(mark_pen, (1, 0, 0, 1, -19.25, -18.75)))
mark = mark_pen.getCommands()
mw, mh = 971.8, 919.8
logo_height = float(font["OS/2"].sCapHeight) * 1.12
scale = logo_height / mh
logo_y = (wh - logo_height) / 2
word_x = mw * scale + logo_height * 0.29
lw, lh = word_x + ww, max(wh, logo_height)

for suffix, color in [("", COBALT), ("-white", WHITE), ("-navy", NAVY)]:
    (OUT / f"mark{suffix}.svg").write_text(svg(f'<path fill="{color}" d="{mark}"/>', mw, mh))
    (OUT / f"wordmark{suffix}.svg").write_text(svg(f'<path fill="{color}" d="{word}"/>', ww, wh))
    lockup = (f'<path fill="{color}" transform="translate(0 {n(logo_y)}) scale({n(scale)})" d="{mark}"/>'
              f'<path fill="{color}" transform="translate({n(word_x)} 0)" d="{word}"/>')
    (OUT / f"lockup{suffix}.svg").write_text(svg(lockup, lw, lh))

# An outline-to-fill reveal with a static/reduced-motion fallback, no JavaScript.
reveal = f'''<style>
.outline{{fill:none;stroke:{COBALT};stroke-width:14;stroke-linecap:round;stroke-linejoin:round;stroke-dasharray:1;stroke-dashoffset:0;animation:draw 1.05s cubic-bezier(.16,1,.3,1) both}}
.solid{{fill:{COBALT};opacity:1;animation:fill .35s .7s both}}
@keyframes draw{{from{{stroke-dashoffset:1}}to{{stroke-dashoffset:0}}}}
@keyframes fill{{from{{opacity:0}}to{{opacity:1}}}}
@media(prefers-reduced-motion:reduce){{.outline{{display:none}}.solid{{animation:none}}}}
</style><g transform="translate(12 12)"><path class="outline" pathLength="1" d="{mark}"/><path class="solid" d="{mark}"/></g>'''
(OUT / "logo-reveal.svg").write_text(svg(reveal, mw + 24, mh + 24, "Setecho logo reveal"))

# One square master; OS masks the corners. RGB PNGs are fully opaque.
icon_scale = 1024 * 0.60 / mw
ix, iy = (1024 - mw * icon_scale) / 2, (1024 - mh * icon_scale) / 2
icon = svg(f'<path fill="{COBALT}" d="M0 0H1024V1024H0Z"/><path fill="white" transform="translate({n(ix)} {n(iy)}) scale({n(icon_scale)})" d="{mark}"/>', 1024, 1024)
(OUT / "app-icon.svg").write_text(icon)
icons = OUT / "icons"
icons.mkdir(exist_ok=True)
icon_sizes = [16, 20, 29, 32, 40, 48, 58, 60, 64, 76, 80, 87, 120, 128, 152, 167, 180, 192, 256, 512, 1024]
for size in icon_sizes:
    raster(icon, size, size).convert("RGB").save(icons / f"icon-{size}.png")
raster(icon, 256, 256).save(OUT / "favicon.ico", sizes=[(16, 16), (32, 32), (48, 48), (64, 64)])
(OUT / "favicon.svg").write_text(icon)
raster(icon, 180, 180).convert("RGB").save(OUT / "apple-touch-icon.png")

# OG is outlined too, so renders never depend on local fonts.
sans_path = HERE / "fonts/SourceSans3-Semibold.ttf"
sans_hash = "a3f4f8dcf343a8f24dc61951de93f3ba1558b15cd250ba24af8a40e957081b7d"
if hashlib.sha256(sans_path.read_bytes()).hexdigest() != sans_hash:
    raise SystemExit("Source Sans font hash differs; check provenance before rebuilding.")
tagline, tw, th = glyph_word(TTFont(sans_path), "The prep that logs itself.", sloped=False, tracking=0, pairs={})
ls = 970 / lw
ts = 785 / tw
og = svg(f'<path fill="{COBALT}" d="M0 0H1200V630H0Z"/>'
         f'<g transform="translate(115 140) scale({n(ls)})">'
         f'<path fill="white" transform="translate(0 {n(logo_y)}) scale({n(scale)})" d="{mark}"/>'
         f'<path fill="white" transform="translate({n(word_x)} 0)" d="{word}"/></g>'
         f'<path fill="white" transform="translate(115 395) scale({n(ts)})" d="{tagline}"/>', 1200, 630)
(OUT / "og.svg").write_text(og)
raster(og, 1200, 630).convert("RGB").save(OUT / "og.png")

for asset, name in [("Logo", "mark"), ("Wordmark", "wordmark"), ("Lockup", "lockup")]:
    (CATALOG / f"{asset}.imageset/{asset}.svg").write_text((OUT / f"{name}.svg").read_text())
icon_folder = CATALOG / "AppIcon.appiconset"
(icon_folder / "AppIcon-1024.png").write_bytes((icons / "icon-1024.png").read_bytes())
# iOS 26 uses the universal 1024 source; explicitly export the legacy slots for reuse.
manifest = {"images": [{"filename": "AppIcon-1024.png", "idiom": "universal", "platform": "ios", "size": "1024x1024"}], "info": {"author": "xcode", "version": 1}}
(icon_folder / "Contents.json").write_text(json.dumps(manifest, indent=2) + "\n")
slots = []
for idiom, sizes, scales in [("iphone", [20, 29, 40, 60], [2, 3]), ("ipad", [20, 29, 40, 76], [1, 2])]:
    for size in sizes:
        for multiplier in scales:
            slots.append({"idiom": idiom, "size": f"{size}x{size}", "scale": f"{multiplier}x", "filename": f"icon-{size * multiplier}.png"})
slots += [{"idiom": "ipad", "size": "83.5x83.5", "scale": "2x", "filename": "icon-167.png"}, {"idiom": "ios-marketing", "size": "1024x1024", "scale": "1x", "filename": "icon-1024.png"}]
(icons / "Contents.json").write_text(json.dumps({"images": slots, "info": {"author": "xcode", "version": 1}}, indent=2) + "\n")

swift = SwiftPen()
parse_path(mark, swift)
(ROOT / "ios/Setecho/DesignSystem/BrandMarkShape.swift").write_text('''// Generated by brand/build.py from the same canonical path as brand/dist/mark.svg.
// Do not hand-edit. The aspect ratio is preserved and centered in the supplied rect.
import SwiftUI

struct BrandMarkShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
''' + "\n".join("        " + line for line in swift.lines) + f'''
        let scale = min(rect.width / {mw}, rect.height / {mh})
        let transform = CGAffineTransform(a: scale, b: 0, c: 0, d: scale,
                                          tx: rect.midX - {mw} * scale / 2,
                                          ty: rect.midY - {mh} * scale / 2)
        return path.applying(transform)
    }}
}}
''')
manifest = {"font_sha256": FONT_HASH, "supporting_font_sha256": sans_hash, "font_axes": {"wght": 700, "opsz": 60}, "e_crossbar_degrees": 5, "tracking": TRACKING, "kerning": KERN, "outputs": {p.relative_to(OUT).as_posix(): hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted(OUT.rglob("*")) if p.is_file() and p.name != "manifest.json"}}
(OUT / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
print(f"Generated {len(manifest['outputs'])} assets, iOS vectors/icon and BrandMarkShape.swift")
