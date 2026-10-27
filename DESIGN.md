# Setecho — design spec for coding agents

Setecho takes the manual work out of a coached bodybuilding prep. Sets log themselves, check-in photos take themselves, and the weekly WhatsApp check-in is half written before the athlete says a word. **Setecho is not a coach.** The athlete's human coach coaches. Setecho does the logging, the photos and the paperwork.

Read this before writing any UI in `ios/`. The design system (tokens, type, components, brand assets) is built. Build the screens below from it.

- **Visual language:** the approved boards in `design/cobalt-cards/screens/`. They set the look: white grouped cards, cobalt actions, a yellow next target. Their screen list is out of date. The "Screens" section below is the source of truth for what to build.
- **Plan of record:** "Setecho hackathon build plan" (Claude Docs). It holds the schedule, gates, cut list and check-in field map.
- **Brand files:** `design/cobalt-cards/brand/final/`.
- **Tokens:** `design/cobalt-cards/design-tokens.json`, mirrored in `ios/Setecho/DesignSystem/Theme.swift`.
- **Component gallery:** the "Components" preview in `ios/Setecho/DesignSystem/ComponentGallery.swift`.

## Hard rules

1. **Never hard-code a color, radius or spacing in a view.** Use `Theme.*`. If a token is missing, add it to `Theme.swift` and to the table below.
2. **Cobalt `#2541D8` is for actions, active controls and data sources only:** buttons, links, the selected tab, the brand lockup, source chips. Never decoration.
3. **Yellow `#F0CD50` marks the one next thing waiting on the athlete:** the next set's target, the selected plate, a check-in field drafted for confirmation. It is always a fill behind navy text. Never yellow text, never a yellow card.
4. **Navy `#171D36` is the reading color.** Secondary text is `Theme.textSecondary`, never navy with opacity.
5. **One `SectionCard` per semantic group.** Related rows share a card, separated by `CardDivider`. Never nest cards. Never one card per metric.
6. **Section titles are sentence case and sit inside the card.**
7. **Every number uses tabular digits.** Loads are in pounds, formatted only through `Format`.
8. **The wordmark is an image** (`Image("Lockup")` / `Image("Wordmark")`). Never type "Setecho" in a serif font.
9. **One primary button per screen**, in the `FooterBar`.
10. **Session, Photo session and Wrap-up are full-screen and hands-free.** No tab bar. No action may *require* a tap; every tap target has a voice equivalent.
11. **Every number shows where it came from.** A check-in answer filled from data carries a `SourceChip`. The model never produces a number; numbers come from Apple Health, the training log or what the athlete said.
12. **The athlete's words stay theirs.** Spoken answers are tidied, not rewritten. Casual stays casual.
13. **Never coach.** No load suggestions framed as advice, no nutrition advice, no form judgments. The coach's plan is shown as the coach's plan.
14. **Every voice action is echoed on screen and out loud, and can be undone by saying "undo".** A low-confidence transcription is asked back ("Did you say 215?"), never acted on silently.
15. Hit targets are at least 44 pt, and icon-only buttons carry an `accessibilityLabel`. The app is light mode only.

## Tokens

| Token | Value | Use |
|---|---|---|
| `Theme.cobalt` | #2541D8 | Primary actions, links, selected tab, lockup, source chips |
| `Theme.cobaltPressed` | #1A2FA0 | Pressed primary button |
| `Theme.cobaltTint` | #E6ECFD | Source chip fill, play discs, listening indicator |
| `Theme.page` | #EEF2F9 | Screen background |
| `Theme.surface` | #FFFFFF | Cards, footer surface |
| `Theme.nearWhite` | #FAFCFF | Fields |
| `Theme.navy` | #171D36 | Primary text |
| `Theme.textSecondary` | #4C5573 | Labels, metadata, placeholders |
| `Theme.yellow` | #F0CD50 | The next thing waiting on the athlete |
| `Theme.border` | #D1D9EC | Card hairlines and dividers |
| `Theme.fieldFill` | #E4E9F4 | Search and text fields |
| `Theme.recording` | #E5484D | Recording dot only |
| `Theme.cameraFill` | #10142A | Camera and thumbnail placeholders |
| Card radius / padding / gap | 16 / 16–18 / 16 pt | `SectionCard`, `Theme.gutter` |
| Control radius | 12 pt | Buttons, fields |

**Type:** SF Pro everywhere except the wordmark image.
- **Standard screens:** `.screenTitle`, `.sectionTitle`, `.metricXL` / `.metricL`.
- **Hands-free screens are read from 2–3 m away:** add `.hudTarget` (96 pt bold, tabular) for "225 × 8", `.hudState` (34 pt semibold) for the state line, and `.hudLabel` (22 pt) for everything else. Nothing smaller on those screens.

## Components

**Built** (`ios/Setecho/DesignSystem/`):
- `ScreenScaffold`, `BrandHeader`, `TitleBlock`, `SectionCard`, `CardDivider`, `VerticalCardDivider`, `FooterBar`
- `.setechoPrimary`, `.setechoOutline`, `LinkButton`, `PlayButton`
- `TargetTag`, `LoadRepsText`, `MetricText`, `SetThumbnail`, `Format`

**To add** (same folder, tokens only, each with a preview):

| Component | Use |
|---|---|
| `SourceChip(source:)` | Small cobalt-tint capsule naming where an answer came from: "Withings", "MacroFactor", "Garmin", "Training log", "You said · Wed". Tapping it shows the underlying values. |
| `FieldRow(field:)` | One check-in field: the coach's label, the answer, its `SourceChip`, and a state (filled, drafted → yellow "Confirm" `TargetTag`, missing → secondary "Ask in wrap-up"). |
| `HUDState(state:)` | The hands-free state line, with an icon: Ready · Recording (red dot) · Saved · Rest 2:14 · Listening. |
| `ListeningIndicator` | A cobalt-tint pulse shown whenever the mic is taking commands, so the athlete knows when they're heard. |
| `VoiceEcho(text:)` | A transient line under the HUD confirming a voice action: "Set 3 → 7 reps. Say undo to revert." |
| `PoseSlots(slots:)` | The four check-in photo slots in the coach's order, each empty, current (yellow ring) or captured (thumbnail and check). |

## Screens

Tabs: **Today / History / Check-in.** Settings and imports live in the More menu.

### Today (tab)
- **Purpose:** the home base. What's planned today, and where the week's check-in stands.
- **Today's session card:** the coach's day, e.g. "Upper A · Week 4", with each exercise as "4 × 8 · RPE 8", straight from the imported spreadsheet.
- **This week's check-in card:** "11 of 22 ready", the due day, an "Open check-in" link. When the due day is close, a yellow "Wrap-up due" tag.
- **Check-in photos card:** last taken, next due, a "Take photos" link that opens Photo session.
- **Footer:** "Start session". This is the only tap of a training day.

### Import (More menu, and first run)
- **Purpose:** bring in the coach's material once, and re-import when he changes it.
- **Two steps:** the spreadsheet program, then the check-in form. Each can be shared in as a file, pasted as text, or added as a screenshot.
- **Program review:** weeks → days → exercises → sets and reps, in cards. Uncertain cells get a yellow "Confirm" tag. Nothing is guessed silently.
- **Form review:** every field in the coach's order, with how it'll be answered: Data, Drafted, Voice or Photos, plus the source. This is the check-in map from the plan, as UI.
- **Footer:** "Save program" / "Save check-in form".

### Session (full-screen, hands-free)
- **Purpose:** a whole training session with zero taps after Start. The phone sits on the tripod, 2–3 m away.
- **Layout, top to bottom:** exercise name (`.hudLabel`); target "225 × 8" with "Set 3 of 4" (`.hudTarget`, yellow tag on the set counter); `HUDState`; the last set's result line; `VoiceEcho` when relevant; up next.
- **States:**
  - **Ready:** waiting for the bar to move.
  - **Recording:** set detected, red dot.
  - **Saved:** set logged from the plan's load and reps, plus anything said.
  - **Rest:** a countdown, the next set, and the callout text matching what's spoken in the headphones.
  - **Listening:** a voice command in progress.
- **Voice commands:** "felt like a 9" · "that was 7 reps" · "drop to 215" / "add 5" · "skip this set" · "next exercise" · "note for check-in: …" · "undo" · "pause" · "end session".
- **Lock screen / Live Activity:** the rest countdown and the next set, for when the phone is pocketed between stations.
- **The only tap target:** "End session", which needs a long press. Saying "end session" works too.

### Photo session (full-screen, hands-free)
- **Purpose:** the four check-in photos with no taps, framed like last week.
- **The order is the coach's:** Front · Right side, arms up · Back · Left side, arms up.
- **Layout:** the camera fills the screen. A faint outline of last week's position shows for alignment. The pose name in `.hudState` ("Turn right · arms up"). `PoseSlots` along the bottom.
- **Flow:**
  1. The framing check speaks ("step back a little") until the whole body is in frame.
  2. The app calls each pose and waits until the athlete is still.
  3. It captures, says "Got it", and moves to the next pose.
- **Ends on Collage review:** the four photos as one image in the coach's layout, each cropped and scaled to match last week. A toggle compares with last week side by side. Alignment only: the image is never edited.

### Check-in (tab)
- **Purpose:** the week's check-in, filling itself as the week goes.
- **Header card:** "11 of 22 ready · 11 to answer", the due day, and a "Start 2-minute wrap-up" link.
- **The coach's form, in his order:** the carried-over blocks (macro targets, supplements) collapsed at the top, then one `FieldRow` per field. Drafted fields show yellow "Confirm"; missing ones show "Ask in wrap-up".
- **Tapping a field** opens it to edit, with its source values listed.
- **Footer:** "Review and send".

### Wrap-up (full-screen, hands-free)
- **Purpose:** answer the fields data can't, by voice, in about 2 minutes.
- **One question at a time,** in `.hudState`: "Hunger this week, 1 to 10?". Then `ListeningIndicator`, then the transcript, then auto-advance. Progress shows as "4 of 9", counting the measurements as one question.
- **The three tape measurements are one question:** "Waist, bicep, thigh?"
- **Voice:** "skip" · "go back" · "say that again".
- **Ends on Review and send.**

### Review and send
- **Purpose:** the exact message the coach receives, before it goes.
- **Content:** the full text in the coach's format and order, with the collage image beneath it. Every number can be tapped to see its source.
- **Footer:** "Send to WhatsApp". If WhatsApp drops the text when an image is shared, the fallback is two steps: the image goes through the share sheet, the text is copied, and a banner says "Paste the check-in text under the photo."

### History (tab)
- **Sections:** This week · Previous sessions · Sent check-ins · Photos.
- **Sessions** keep the board's grouped-card layout, with each set's clip.
- **Sent check-ins** reopen read-only.
- **Photos** show the collages as a timeline, with any two weeks comparable side by side.

## Flow

1. **Import once:** program and form.
2. **Training day:** Today → Start session → hands-free Session → End session → Today.
3. **Photo day:** Today → Take photos → Photo session → Collage review → Check-in.
4. **Check-in day:** Check-in → Start wrap-up → Wrap-up → Review and send → WhatsApp.

## Open design questions
- **Collage layout:** 1×4 or 2×2? Match the image the athlete sends today. Ask for a sample.
- **Spreadsheet delivery:** decided Oct 26, a Google Sheets link. The Import screen's first step takes a pasted link, with a file or screenshot as the fallback.
- **Tagline:** "A coach that remembers every rep" conflicts with rule 13. That's the athlete's call.
