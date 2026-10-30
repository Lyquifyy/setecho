# Setecho launch kit

Built October 29, 2026, using the app's cobalt-card design and canonical outlined brand assets.

- `../brand/`: fonttools source, licensed fonts, sloped-e wordmark, mark, full icon exports, favicon, OG image and SVG reveal.
- `motion/`: editable Remotion compositions and render instructions. Rendered clips are in ignored `motion/out/`; the 40-second montage previews the graphics, not the three-minute product demo.
- `site/`: buildless responsive landing page, interactive synthetic walkthrough, real SwiftUI screenshots and GitHub/Cloudflare hosting instructions.
- `explorations/`: local-only generated lifestyle, device mockup and pitch-background images. The generated device mockup is exploratory; its screen rendering is not pixel-exact evidence. The website uses untouched simulator renders in CSS device frames.

## App motion

`BrandReveal` draws the same generated `BrandMarkShape` used by the SVG exports, then fills it. The app shows the short reveal once per window; it never delays the underlying services or intercepts taps. The OS launch screen remains static.

The live mic level drives `WaveformBars`. Stored set results arrive with the session's existing state transition; saved load and rep changes use numeric text transitions. `FieldRow` animates actual answer changes, and `AnimatedCheck` confirms ready fields. The coach reply animates applied status only after the existing Apply action; the original quote and before/after values remain visible. Reduce Motion stops continuous waveform/dot motion and replaces new spatial transitions with fades.

## Evidence and boundaries

- 655 offline backend tests passed; 280 iOS simulator tests passed on iPhone 17 Pro / iOS 26.5 after the final app edits.
- Browser walkthrough approval gate, reset, privacy dialog, image loading and overflow checked at desktop and mobile widths.
- Independent visual review completed; its mobile target and transcript expansion findings were fixed. The design detector fell back to regex because optional HTML parser dependencies were absent, so its clean output is not a full accessibility audit.
- Brand rebuilds are hash-identical; raster dimensions and icon opacity verified. Remotion type checking and seven video exports verified, including lower-third alpha.
- These are simulator/synthetic and rendered-video checks. Physical-device motion, a gym session and a full submission rehearsal remain separate.
- No live Meta calls, athlete media, real Health values or coach messages were used. Generated images were made with the requested image-generation tool outside the product; every product runtime model remains Meta's.

Website deployment and custom-domain setup are documented in `site/README.md`.
