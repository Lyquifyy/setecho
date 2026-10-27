# Setecho — design spec for coding agents

Setecho takes the manual work out of a coached bodybuilding prep. Sets log and count themselves, check-in photos take themselves, the weekly WhatsApp check-in is half written before the athlete says a word, and the coach's reply updates the plan. **Setecho is not a coach.** The athlete's human coach coaches. Setecho does the logging, the photos and the paperwork.

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
10. **Session, Photo session and Wrap-up are full-screen and hands-free.** No tab bar. No action may *require* a tap; every tap target has a voice equivalent. A session never requires the tripod: with the phone in a pocket, the watch and voice run it.
11. **Every number shows where it came from.** A check-in answer filled from data carries a `SourceChip`. The model never produces a number; numbers come from Apple Health, the training log or what the athlete said. A logged rep count shows how it was counted: Plan, Watch, Phone, Measured or You said.
12. **The athlete's words stay theirs.** Spoken answers are tidied, not rewritten. Casual stays casual.
13. **Never coach.** No load suggestions framed as advice, no nutrition advice, no form judgments. The coach's plan is shown as the coach's plan.
14. **Every voice action is echoed on screen and out loud, and can be undone by saying "undo".** A low-confidence transcription is asked back ("Did you say 215?"), never acted on silently.
15. Hit targets are at least 44 pt, and icon-only buttons carry an `accessibilityLabel`. The app is light mode only.
16. **Nothing from the coach's reply changes the plan until the athlete approves it.** Every proposed change shows the coach's exact words beside it, and an applied reply can be reverted from History.

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
| `SourceChip(source:)` | Small cobalt-tint capsule naming where an answer came from: "Withings", "MacroFactor", "Garmin", "Training log", "You said · Wed", and for rep counts "Plan", "Watch", "Phone", "Measured". Tapping it shows the underlying values. |
| `FieldRow(field:)` | One check-in field: the coach's label, the answer, its `SourceChip`, and a state (filled, drafted → yellow "Confirm" `TargetTag`, missing → secondary "Ask in wrap-up"). |
| `HUDState(state:)` | The hands-free state line, with an icon: Ready · Recording (red dot) · Saved · Rest 2:14 · Listening. |
| `ListeningIndicator` | A cobalt-tint pulse shown whenever the mic is taking commands, so the athlete knows when they're heard. |
| `VoiceEcho(text:)` | A transient line under the HUD confirming a voice action: "Set 3 → 7 reps. Say undo to revert." |
| `ChangeRow(change:)` | One proposed plan change: what it touches ("Training-day carbs"), before → after ("250 g → 225 g", before in `textSecondary` with a strikethrough), when it starts, the coach's exact words beneath in `textSecondary`, and a checkbox (cobalt when on). An unclear item uses the same row with no checkbox and an "Add by hand" link. |
| `InputStatus(camera:watch:)` | Two small icons in the HUD state line, camera and watch: cobalt when live, `textSecondary` with a slash when not. `accessibilityLabel` "Camera on, watch off". |
| `CueRow(cue:)` | One coach voice cue: the exercise it plays before, his words in `textSecondary`, a `PlayButton`, and a checkbox (cobalt when on). |
| `PoseSlots(slots:)` | The four check-in photo slots in the coach's order, each empty, current (yellow ring) or captured (thumbnail and check). |

## Screens

Tabs: **Today / History / Check-in.** Settings, Connections and imports live in the More menu. Settings gains one switch: "Coach's voice in sessions" (on by default).

### Today (tab)
- **Purpose:** the home base. What's planned today, and where the week's check-in stands.
- **Today's session card:** the coach's day, e.g. "Upper A · Week 4", with each exercise as "4 × 8 · RPE 8", straight from the imported spreadsheet.
- **This week's check-in card:** "11 of 22 ready", the due day, an "Open check-in" link. When the due day is close, a yellow "Wrap-up due" tag.
- **Check-in photos card:** last taken, next due, a "Take photos" link that opens Photo session.
- **Coach reply card,** only when one is waiting: "Coach replied · voice note 1:12", a "Review changes" link to Coach reply.
- **MacroFactor reminder,** after a macro change is applied: "Update MacroFactor: training-day carbs 250 → 225 g", with a "Done" link. Setecho can't change MacroFactor itself.
- **One yellow tag at a time on Today,** in this order: a coach reply to review, MacroFactor to update, the wrap-up due. The others show as secondary text.
- **Footer:** "Start session". This is the only tap of a training day.

### Import (More menu, and first run)
- **Purpose:** bring in the coach's material once, and re-import when he changes it.
- **Two steps:** the spreadsheet program, then the check-in form. Each can be shared in as a file, pasted as text, or added as a screenshot.
- **Program review:** weeks → days → exercises → sets and reps, in cards. Uncertain cells get a yellow "Confirm" tag. Nothing is guessed silently.
- **Form review:** every field in the coach's order, with how it'll be answered: Data, Drafted, Voice or Photos, plus the source. This is the check-in map from the plan, as UI.
- **Footer:** "Save program" / "Save check-in form".

### Session (full-screen, hands-free)
- **Purpose:** a whole training session with zero taps after Start. The phone sits on the tripod, 2–3 m away.
- **Layout, top to bottom:** exercise name (`.hudLabel`); target "225 × 8" with "Set 3 of 4" (`.hudTarget`, yellow tag on the set counter); `HUDState`; `InputStatus` at the end of the state line; the last set's result line with its count's `SourceChip` ("Phone", then "Measured" once SAM confirms); `VoiceEcho` when relevant; up next.
- **States:**
  - **Ready:** waiting for the bar to move.
  - **Recording:** set detected, red dot.
  - **Saved:** set logged with the phone's rep count, the plan's load, and anything said. When SAM's count differs, `VoiceEcho` shows the correction: "Set 3 → 7 reps (measured). Say undo to revert."
  - **Rest:** a countdown, the next set, and the callout text matching what's spoken in the headphones.
  - **Listening:** a voice command in progress.
- **Coach cue:** when one plays, `VoiceEcho` shows "Coach · Incline DB press" with his words.
- **Phone in a pocket:** the screen doesn't matter. The Lock Screen Live Activity and the watch carry the target and the rest countdown.
- **Voice commands:** "felt like a 9" · "that was 7 reps" · "drop to 215" / "add 5" · "skip this set" · "next exercise" · "note for check-in: …" · "undo" · "pause" · "end session" · a number, to answer "was that 7 or 8?" · "say that again" (replays the coach's cue) · "yes" / "no".
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
- **No weight yet today:** if this morning's weigh-in hasn't reached Apple Health, the wrap-up says "Open Withings once to sync today's weight" and carries on. If it still hasn't arrived by the last question, the wrap-up asks for it: "Today's weight?"
- **Voice:** "skip" · "go back" · "say that again".
- **Ends on Review and send.**

### Review and send
- **Purpose:** the exact message the coach receives, before it goes.
- **Content:** the full text in the coach's format and order, with the collage image beneath it. Every number can be tapped to see its source.
- **Clips for your coach** (stretch): a card with up to four set videos worth the coach's eyes, picked by rule, never by AI judgment. Each row shows a thumbnail, its reason ("6 of 8 reps · Bench press, set 4" or "Last set · Squat") and a remove button, plus "Add a set" from History. No verdicts, scores or form labels anywhere.
- **Footer:** "Send to WhatsApp". If WhatsApp drops the text when an image is shared, the fallback is two steps: the image goes through the share sheet, the text is copied, and a banner says "Paste the check-in text under the photo."

### Coach reply
- **Purpose:** see exactly what the coach changed before anything changes.
- **Opens from:** the Today card, the share sheet (WhatsApp → Share → Setecho), or More → "Add coach reply" (paste text or pick an audio file).
- **Reply card:** for a voice note, `PlayButton`, its length and the transcript; for a text, the text. Collapsed to 4 lines with "Show all".
- **Changes card:** one `ChangeRow` per change, grouped by what they touch: Targets, Training, Cardio, Supplements.
- **Not sure card,** only when there are any: his sentences that sound like a change but match nothing in the plan, each with "Add by hand".
- **Footer:** "Apply 4 changes"; the count follows the checkboxes. After applying, a summary card ("Program updated from Mon Nov 2 · Targets updated") and, after a macro change, the MacroFactor reminder on Today.
- **In your sessions card,** only when the reply has cues and the Settings switch is on: one `CueRow` per cue, grouped by day.
- **Not hands-free:** taps are fine here. It's reviewed at home, not between sets.

### Connections (More menu, and first run)
- **Purpose:** the outside things Setecho reads from, in one place. Not a tab: it's visited at setup and rarely after.
- **Apple Health card:** status, and the sources seen in the last 7 days (Withings, MacroFactor, Garmin), each a `SourceChip`.
- **Garmin watch card:** "Connect" (opens the Garmin Connect app to pick the watch), then "Venu 4 · connected · last seen 2 min ago" and a "Test buzz" link. If the Setecho watch app isn't on the watch, one line says how to install it.
- **Withings card** (stretch): "Connect Withings", then "Withings · connected · last weigh-in 7:02 AM". Until it's connected, weight comes through Apple Health.
- **WhatsApp card** (stretch): "Import chat history", then the date of the last import and the message count.

### Watch (Setecho app on the Venu 4)
- **Display:** round AMOLED, black background, white text. Cobalt for the logged ring. The target sits on a yellow fill with navy text, like `TargetTag`. Big numbers use the largest number font; everything else stays readable at arm's length mid-set.
- **Target:** the exercise (two lines at most), "225 × 8" big, "Set 3 of 4".
- **In set:** a red dot and the elapsed seconds. No live rep count; the count comes at the end.
- **Logged:** "8 reps" and its source ("Watch", "Phone", "Measured", "You said"), shown for 3 s with a short buzz. It updates if SAM corrects it.
- **Rest:** the countdown big, the next target small, and a long buzz at zero.
- **Disconnected:** "Open Setecho on your phone."
- **Input:** a tap anywhere is "done" (ends the set or skips the rest). The back button is undo, confirmed on screen.

### History (tab)
- **Sections:** This week · Previous sessions · Sent check-ins · Photos · Plan changes.
- **Sessions** keep the board's grouped-card layout, with each set's clip and its count's `SourceChip`.
- **Sent check-ins** reopen read-only.
- **Photos** show the collages as a timeline, with any two weeks comparable side by side.
- **Plan changes** list each applied coach reply with its changes. The latest one has "Revert", which restores the previous plan.

## Flow

1. **Import once:** program and form.
2. **Training day:** Today → Start session → hands-free Session → End session → Today.
3. **Photo day:** Today → Take photos → Photo session → Collage review → Check-in.
4. **Check-in day:** Check-in → Start wrap-up → Wrap-up → Review and send → WhatsApp.
5. **Coach replies:** WhatsApp → Share → Setecho (or paste) → Coach reply → Apply → Today shows the updated plan. His cues play in the next sessions.
6. **Setup:** Import → Connections (Apple Health, Garmin watch) → Today.

## Open design questions
- **Collage layout:** 1×4 or 2×2? Match the image the athlete sends today. Ask for a sample.
- **Spreadsheet delivery:** decided Oct 26, a Google Sheets link. The Import screen's first step takes a pasted link, with a file or screenshot as the fallback.
- **Change rows checked by default?** The default is checked, with the Apply tap as the approval. If that makes rubber-stamping too easy, start them unchecked.
- **Tagline:** "A coach that remembers every rep" conflicts with rule 13. That's the athlete's call.
