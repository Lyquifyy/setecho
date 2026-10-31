# Setecho demo motion

Reusable 1920 × 1080, 30 fps motion graphics for the hackathon edit. The 40-second montage is a graphics preview, **not the three-minute product demo or evidence of a live gym session**. It contains no athlete data, simulated app screenshots, voice synthesis or product model calls. The pipeline represents the intended workflow and explicitly waits for athlete approval before a coach reply updates the plan.

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

- `setecho-demo-graphics.mp4`: 40-second preview combining all four scenes.
- `TitleCard.mp4`: 5-second SVG logo draw, wordmark and tagline.
- `Pipeline.mp4`: 14 seconds, speak → workout log → progress update via WhatsApp → coach reply → plan update. The final link activates only after a visible approval pause.
- `MetaStack.mp4`: 14-second tooling slide with correct model responsibilities and on-device speech attribution.
- `lower-third-logging.mov`, `lower-third-check-in.mov`, `lower-third-coach-reply.mov`: 5-second transparent ProRes 4444 overlays. Place over real footage in the editor; they are transparent full-frame, with the graphic inside the bottom safe area.
- `TwoClocks.mp4`: 10 seconds, the same check-in typed against spoken. Both clocks run at the stated speed; the spoken side stops at its measured time and its "Me talking" counter advances only while the athlete was speaking. Values come from `props/two-clocks.json` (timings from a filming-mode manifest, no words).
- `FirstWeek.mp4`: 5-second end card, before against after for the Day 5 session and the check-in, from `props/first-week.json`.
- `CoachQuote.mp4`: 5 seconds, the coach's words as text (never his voice). Rendered only when `props/coach-quote.json` exists with his exact words: `{"quote": "…", "attribution": "My coach, replying to my first check-in sent with Setecho"}`. Without that file there is nothing to render, so the placeholder can never ship.
- `<Composition>-<frame>.png`: review frames (`npm run stills`).

When a number changes (for example, once a manual check-in is timed), edit the props JSON (`manualSeconds`, `manualTimed: true`, and the matching `first-week.json` row) and rerender. The code never holds a number.

The lower third takes `title`, `detail` and `preview` props. Copy a JSON file in `props/` and render it:

```sh
npx remotion render src/index.ts LowerThird out/custom.mov --props=props/check-in.json --codec=prores --prores-profile=4444 --pixel-format=yuva444p10le --image-format=png
```

Keep titles short (about 45 characters) and details to one line (about 80 characters). The graphic stays fully on-screen for most of its duration and exits during the final 18 frames. Use `preview: true` only for a demonstration background, never for the exported overlay.

## Edit map

| Montage time | Asset |
| --- | --- |
| 00:00–00:05 | Title / logo reveal |
| 00:05–00:12 | Voice-logging explanation with a fictional example |
| 00:12–00:26 | Pipeline |
| 00:26–00:40 | Meta tooling |

Use the individual exports in the final edit and let real product footage do the demonstrating. No custom-domain availability, App Store release or hackathon acceptance is implied by these graphics. Motion is for prerecorded video; the app and landing page handle Reduce Motion separately.

Renderer API: [Remotion rendering](https://www.remotion.dev/docs/cli/render), [Composition](https://www.remotion.dev/docs/composition), [Sequence](https://www.remotion.dev/docs/sequence).

## Copy for judges

Use “Train with your coach. Skip the paperwork.” for the title, with “Setecho logs every workout and fills in your weekly report to your coach, hands-free.” under it. Explain a check-in as a progress update sent to the coach, and a rep as one repetition of an exercise. The overview includes a fictional voice-logging example instead of editor instructions. Keep these explanations in the final edit; see `../COPY.md` for consistent terminology.
