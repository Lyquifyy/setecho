# Setecho vector and export kit

The logo assets are real paths. No SVG embeds a bitmap, web font, `<text>` element or remote reference.

## Rebuild

```sh
uv run brand/build.py
```

The script pins fonttools, Pillow and resvg-py in its inline dependency metadata. After the first dependency install it runs offline. Font inputs are vendored with their SIL Open Font Licenses and checked against SHA-256 before conversion. `dist/manifest.json` records input settings and every output hash. Running it twice with the same inputs produces identical files.

The wordmark outlines **Source Serif 4 Bold**, `wght=700`, `opsz=60`, through fonttools. Tracking is −10 font units, with the approved pair adjustments `Se −12`, `et −4`, `te −6`, `ec −10`, `ch −24`, `ho −4`. The two e crossbars rise 5° from left to right; only their crossbar contour points change. All other glyph contours remain the font's own.

The canonical mark in `source/mark.svg` preserves the existing app's stacked-tab geometry. The builder normalizes that path once, then uses it for every export, the animated SVG and SwiftUI's `BrandMarkShape`. The serif wordmark remains an image; supporting OG text uses outlined Source Sans 3 Semibold for a portable sans-serif rendering. App UI continues to use SF Pro.

## Outputs

- `dist/mark.svg`, `wordmark.svg`, `lockup.svg`: cobalt, plus `-navy` and `-white` variants.
- `dist/logo-reveal.svg`: 1.05-second outline-to-fill reveal. Its SVG CSS respects Reduce Motion; static viewers display the filled mark. The demo uses the same geometry with frame-driven timing.
- `dist/app-icon.svg`: white mark, 60% of width, on a square cobalt field. No pre-rounded corners.
- `dist/icons/`: 21 PNG sizes from 16 to 1024 px and a complete legacy iPhone/iPad `Contents.json`. Copy the directory into an `.appiconset` when a legacy catalog is needed.
- `dist/favicon.svg`, `favicon.ico` (16/32/48/64), `apple-touch-icon.png` (180).
- `dist/og.svg` and `og.png`: 1200 × 630 social preview.
- The app's `Logo`, `Wordmark` and `Lockup` image sets, its universal 1024 AppIcon, and `BrandMarkShape.swift` are regenerated directly.

The iOS 26 catalog intentionally uses its universal 1024 source; Xcode derives its platform renditions. The separately exported legacy catalog contains all older explicit slots. All square app-icon PNGs and the OG PNG are opaque RGB.

## Font provenance

Unmodified fonts downloaded from Adobe's official release branches on October 29, 2026. Exact hashes are pinned in `build.py` and the generated manifest; regeneration never downloads mutable URLs.

- [Source Serif](https://github.com/adobe-fonts/source-serif): `VAR/SourceSerif4Variable-Roman.ttf`; license in `fonts/OFL.md`.
- [Source Sans](https://github.com/adobe-fonts/source-sans): `TTF/SourceSans3-Semibold.ttf`; license in `fonts/SourceSans-OFL.md`.

These are build inputs only. The app and website display outlines and do not load the typefaces at runtime.
