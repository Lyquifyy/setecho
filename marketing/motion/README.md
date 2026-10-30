# Setecho demo motion

Reusable 1920 × 1080, 30 fps motion graphics for the hackathon edit. The 28-second montage is a graphics preview, **not the three-minute product demo or evidence of a live gym session**. It contains no athlete data, simulated app screenshots, voice synthesis or product model calls. The pipeline represents the intended workflow and explicitly waits for athlete approval before a coach reply updates the plan.

## Build and render

From this directory:

```sh
npm ci
npm run check
npm run studio
npm run render
npm run stills
```

Run the repository's brand generator first if `brand/dist` is absent. `sync-assets` copies the canonical mark, wordmark and lockup from that folder; it extracts the mark's exact path geometry for a deterministic frame-driven SVG draw. It never substitutes typed lettering for the outlined wordmark. No font downloads are needed at render time. Body text uses the SF Pro system stack on macOS; other hosts use their system fallback.

`render` uses installed Google Chrome on macOS when available. Set `REMOTION_BROWSER_EXECUTABLE` for another installed Chrome. Otherwise Remotion uses its normal browser setup. Dependencies are pinned by the lockfile. Zod is overridden to 4.6.6 to fix GHSA-mrhx-c7xc-m3w5; Remotion 4.0.539 prints a version warning because it requests 4.5.4. Type checking and full frame renders were verified with the patched dependency. The frame renderer has no random values, timers, network assets or CSS animations.

## Outputs

All render outputs are under ignored `out/`:

- `setecho-demo-graphics.mp4`: 28-second preview combining all four scenes.
- `TitleCard.mp4`: 4-second SVG logo draw, wordmark and tagline.
- `Pipeline.mp4`: 12 seconds, voice → log → WhatsApp check-in → coach reply → plan update. The final link activates only after a visible approval pause.
- `MetaStack.mp4`: 7-second tooling slide with correct model responsibilities and on-device speech attribution.
- `lower-third-logging.mov`, `lower-third-check-in.mov`, `lower-third-coach-reply.mov`: 5-second transparent ProRes 4444 overlays. Place over real footage in the editor; they are transparent full-frame, with the graphic inside the bottom safe area.
- `TitleCard.png`, `Pipeline.png`, `MetaStack.png`: review frames (`npm run stills`).

The lower third takes `title`, `detail` and `preview` props. Copy a JSON file in `props/` and render it:

```sh
npx remotion render src/index.ts LowerThird out/custom.mov --props=props/check-in.json --codec=prores --prores-profile=4444 --pixel-format=yuva444p10le --image-format=png
```

Keep titles short (about 45 characters) and details to one line (about 80 characters). The graphic stays fully on-screen for most of its duration and exits during the final 18 frames. Use `preview: true` only for a demonstration background, never for the exported overlay.

## Edit map

| Montage time | Asset |
| --- | --- |
| 00:00–00:04 | Title / logo reveal |
| 00:04–00:09 | Lower-third example on a neutral preview background |
| 00:09–00:21 | Pipeline |
| 00:21–00:28 | Meta tooling |

Use the individual exports in the final edit and let real product footage do the demonstrating. No custom-domain availability, App Store release or hackathon acceptance is implied by these graphics. Motion is for prerecorded video; the app and landing page handle Reduce Motion separately.

Renderer API: [Remotion rendering](https://www.remotion.dev/docs/cli/render), [Composition](https://www.remotion.dev/docs/composition), [Sequence](https://www.remotion.dev/docs/sequence).
