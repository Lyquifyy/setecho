# Setecho — design spec for coding agents

Setecho takes the manual work out of a coached bodybuilding prep. Sets log and count themselves, check-in photos take themselves, the WhatsApp check-in is half written before the athlete says a word, and the coach's reply updates the plan. **Setecho is the spotter, not the coach.** The athlete's human coach coaches. Setecho counts and measures every set, applies the coach's own rules, and does the photos and the paperwork.

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
10. **Session, Check-in morning, Photo session and Wrap-up are full-screen and hands-free.** No tab bar. No action may *require* a tap; every tap target has a voice equivalent. A session never requires the tripod: with the phone in a pocket, voice runs it (and the watch, if it's built).
11. **Every number shows where it came from.** A check-in answer filled from data carries a `SourceChip`. The model never produces a number; numbers come from Apple Health, the training log or what the athlete said. A logged rep count shows how it was counted: Plan, Watch, Phone, Measured or You said.
12. **The athlete's words stay theirs.** Spoken answers are tidied, not rewritten. Casual stays casual.
13. **Never coach on Setecho's own authority.** No form judgments, no nutrition advice, no rules Setecho invents. A next-set suggestion always names the coach's rule it came from, the athlete decides, and the coach sees it in the check-in. A machine-taken swap stays within the same lift or his own alternates, and every swap and reorder reaches him in the check-in. The coach's plan is shown as the coach's plan.
14. **Every voice action is echoed on screen and out loud, and can be undone by saying "undo".** A low-confidence command is asked back as the action ("Twelve reps on set 2?"), never acted on silently; chatter and other people's voices are never answered, only shown ("Heard: …").
15. Hit targets are at least 44 pt, and icon-only buttons carry an `accessibilityLabel`. The app is light mode only, the session screen included.
16. **Nothing from the coach's reply changes the plan until the athlete approves it.** Every proposed change shows the coach's exact words beside it, and an applied reply can be reverted from History.

## Tokens

| Token | Value | Use |
|---|---|---|
| `Theme.cobalt` | #2541D8 | Primary actions, links, selected tab, lockup, source chips |
| `Theme.cobaltPressed` | #1A2FA0 | Pressed primary button |
| `Theme.cobaltTint` | #E6ECFD | Source chip fill, play discs, listening indicator, tonal buttons |
| `Theme.cobaltPressedTint` | #D3DCFA | Pressed tonal button |
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
- **Hands-free screens are read from 2–3 m away:** add `.hudTarget` (96 pt bold, tabular) for "225 × 8", `.hudState` (34 pt semibold) for the state line, and `.hudLabel` (22 pt) for everything else. Nothing smaller on those screens. The one place that can't hold it is the session's lifts strip: five names don't fit across the phone at 22 pt, so it steps to 20, then 18 pt, only when today's lifts don't fit, and never truncates a name (open question for Zander).

## Components

**Built** (`ios/Setecho/DesignSystem/`):
- `ScreenScaffold`, `BrandHeader`, `TitleBlock`, `SectionCard`, `CardDivider`, `VerticalCardDivider`, `FooterBar`
- `.setechoPrimary`, `.setechoOutline`, `LinkButton`, `PlayButton`, `CloseButton`
- `TargetTag`, `LoadRepsText`, `MetricText`, `SetThumbnail`, `Format`
- `.setechoTonal` / `.setechoTonalWide` (the in-card action: cobalt text on a cobalt-tint fill, with an icon; use it instead of a bare text link when a card offers something to do), `IconButton` (44 pt round tonal icon, always labeled)
- `SegmentTabs` (tabs inside a screen; the selected tab is cobalt; a count badge goes yellow only when that count is waiting on the athlete), `TileCard` (a half-width card that is one tappable thing; two side by side), `MeterBar` (a thin cobalt progress bar), `DisclosureChevron`
- `ExerciseDisclosureRow` (one exercise as a single line, "Bench press · 4 × 8", that opens to the sheet's details)
- The spoken check-in (`Conversation.swift`): `ConversationTranscript` with `SetechoLine`, `AthleteLine` and `AnswerCard` (its `SourceChip` at `.hud` size); `AnimatedCheck` (the check that draws itself, also on a ready `FieldRow`); `StepTrack` (one segment per step, and one `.hudLabel` line naming the current one, "Photos · 3 of 5"); `VoiceBar` with `WaveformBars` and `ThinkingDots` (it names the voice while it speaks, "Setecho · Ava (Premium)"); `HoldButton`
- `LinkButton(hud: true)` for the links a hands-free screen shows once it's done ("Read it back"); `ScreenScaffold(showsFooter:)` drops the footer bar when there's nothing to start, instead of a disabled primary button

**Leaving a sheet or cover:**
- **The first screen of every sheet or cover** gets the X: `ScreenScaffold(onClose: { dismiss() })` puts a `CloseButton` in the header's top-right, where the More menu sits on a tab. There's no "Back", "Cancel" or "Done" link at the top of the content.
- **A screen pushed inside a sheet** (Import steps 2–3 and its reviews, Settings → Developer) keeps a "‹ Back" or "‹ Settings" `LinkButton` to go back one screen, plus the same X to leave the whole flow.
- **The X only leaves.** Anything that commits (Confirm, Save, Apply N changes, Send) is the footer's primary button. Changes that save as you make them (Settings, video picks) need no Done.
- **Hands-free covers** (Session, Wrap-up, Check-in morning, Photo session) keep "Hold to stop" / "Hold to cancel", so a bumped phone mid-set never ends anything.

**To add** (same folder, tokens only, each with a preview):

| Component | Use |
|---|---|
| `SourceChip(source:size:)` | Small cobalt-tint capsule (`.hud` at 22 pt on the hands-free screens) naming where an answer came from: "Withings", "MacroFactor", "Garmin", "Training log", "You said · Wed", and for rep counts "Plan", "Watch", "Phone", "Measured". Tapping it shows the underlying values. |
| `FieldRow(field:)` | One check-in field: the coach's label, the answer, its `SourceChip`, and a state (filled, drafted → yellow "Confirm" `TargetTag`, missing → secondary "Ask in wrap-up"). |
| `HUDState(state:)` | The hands-free state line, with an icon: Ready · Recording (red dot) · Saved · Rest 2:14 · Listening. |
| `ListeningIndicator` | A cobalt-tint pulse shown whenever the mic is taking commands, so the athlete knows when they're heard. |
| `VoiceEcho(text:)` | A transient line under the HUD confirming a voice action: "Set 3 → 7 reps. Say undo to revert." |
| `ChangeRow(change:)` | One proposed plan change: what it touches ("Training-day carbs"), before → after ("250 g → 225 g", before in `textSecondary` with a strikethrough), when it starts, the coach's exact words beneath in `textSecondary`, and a checkbox (cobalt when on). An unclear item uses the same row with no checkbox and an "Add by hand" link. |
| `InputStatus(camera:watch:)` | Two small icons in the HUD state line, camera and watch: cobalt when live, `textSecondary` with a slash when not. `accessibilityLabel` "Camera on, watch off". |
| `CueRow(cue:)` | One coach voice cue: the exercise it plays before, his words in `textSecondary`, a `PlayButton`, and a checkbox (cobalt when on). |
| `SuggestionTag(suggestion:)` | In the HUD during rest: "Next: 215 × 8" on a yellow fill, "his rule · RPE 9.5 vs 8" in `textSecondary`, and "Say 'go with it' or 'keep it'". |
| `EffortLine(set:)` | Under a set's result: "~1 left · slowed 38% · estimated" in `textSecondary`. |
| `RuleRow(rule:)` | One coach's rule in plain words, its source (his quote, or "you confirmed"), and a yellow "Confirm" `TargetTag` until confirmed. |
| `VideoPickRow(pick:)` | One of the two videos for the check-in: thumbnail, the caption ("Incline DB press · top set"), the cropped length, "Swap". |
| `TakenCard(offer:)` | In the HUD when a machine's taken (stretch): "Bench taken" in `.hudState`, then up to two options as `.hudLabel` lines, the first marked "His first choice", and "Say 'go with it', 'the other one' or 'I'll wait'". |
| `TagRow(exercise:)` | One exercise on the tags review: its name, movement family, main muscles and Heavy or Light, with a yellow "Confirm" `TargetTag` until confirmed. Tapping it fixes a tag. |
| `DeviationRow(deviation:)` | One gym change: planned → done ("Incline barbell → incline dumbbell press"), the reason and the day in `textSecondary`, and a checkbox (cobalt when on). |
| `AddOnRow(addOn:)` | On Import: an add-on's name, his words in `textSecondary`, "2× a week", and the cycle days it joins as chips (cobalt when chosen). |
| `PoseSlots(slots:)` | The four check-in photo slots in the coach's order, each empty, current (yellow ring) or captured (thumbnail and check). |

## Screens

Tabs: **Today / History / Check-in.** The More menu has two sections: from your coach (Import program and form, Add coach reply, Import WhatsApp chat, Import Liftoff and Garmin; Connections when built) and Settings.

### Settings (More menu)
- **Cards, in order:** You (first name, show date) · Training (training days, cardio protocol, what you can load) · Check-in (morning reminder, 7-day average weight) · Sessions ("Coach's voice in sessions" on, "Next-set suggestions" on, "Machine-taken help" on (stretch), AirPods mic) · Voice (the voice picker, Personal Voice) · Voice tone (speed, pitch, warmth, clarity, "Play sample") · Developer.
- **Developer:** a "Developer tools" switch (off). On, it adds "Open developer tools" and the Facts link on the Check-in tab. Nothing for testing or tuning appears on the everyday screens otherwise.
- **Developer tools screen:** Rehearsal (your own WhatsApp number, "Send check-ins to my own chat", "Rehearse check-in morning") · Filming (filming mode and its takes, to AirDrop) · Session data (each session's tuning JSON, to share) · Diagnostics (the phone probes and turn timings).

### Today (tab)
- **Purpose:** the home base. What's planned today, and where the current check-in stands.
- **Today's session card:** the coach's day, e.g. "Day 2", titled in the card, with "4 exercises · 9 sets". Each exercise is one `ExerciseDisclosureRow` ("Lat Pulldown · 2 × 8–10"), closed by default so the whole day fits on screen; tapping one opens the sheet's details (load, RPE, equipment, rest, his "or" options, notes, last time). Any add-on joining it sits below a `CardDivider` ("+ Abs · 1 of 2 this week"). A bottom row of tonal buttons: "Change day", "What to say" and an icon to open or close every exercise.
- **Morning card,** on a day an on-waking add-on is due: "This morning: stomach vacuums · 4 × 20 s · 2 of 4 this week", with "Start".
- **Rest day:** the session card becomes "Rest day" with his cardio line ("25 minutes of fasted LISS"). No Start button, and no footer.
- **First run** (nothing imported): the session card says to import his program, and the footer is "Import the program".
- **Check-in and Photos tiles,** side by side (`TileCard`): Check-in shows "11 of 22 ready", a `MeterBar` and the due day, and opens the Check-in tab; on check-in morning it shows a yellow "Due today" tag and starts the check-in. Photos shows last taken and next due, and opens Photo session.
- **Which day:** a seven-day cycle follows the day of the week (Day 1 on Monday); "Change day" overrides it for today.
- **Loading:** while anything is being read (Import, the draft, Review and send), one `LoadingCard` with a short line, never a bare spinner.
- **Coach reply card,** only when one is waiting: "Coach replied · voice note 1:12", a "Review changes" link to Coach reply.
- **MacroFactor reminder,** after a macro change is applied: "Update MacroFactor: training-day carbs 250 → 225 g", with a "Done" link. Setecho can't change MacroFactor itself.
- **One yellow tag at a time on Today,** in this order: a coach reply to review, MacroFactor to update, the check-in due, then today's session ("Up next") when it's still to do. The others show as secondary text.
- **Footer:** "Start session". This is the only tap of a training day.

### Import (More menu, and first run)
- **Purpose:** bring in the coach's material once, and re-import when he changes it.
- **Three steps:** the spreadsheet program, the check-in form, then his instructions (his onboarding email, pasted once). Each can be shared in as a file, pasted as text, or added as a screenshot.
- **Program review:** weeks → days → exercises → sets and reps, in cards. Uncertain cells get a yellow "Confirm" tag. Nothing is guessed silently.
- **Cycle and add-ons:** the cycle in order, with rest days marked "Rest · 25 min fasted LISS". Then one `AddOnRow` per add-on: its name, his words ("Complete this 2x per week"), and the cycle days it joins as chips, proposed and confirmed once.
- **Form review:** every field in the coach's order, with how it'll be answered: Data, Drafted, Voice or Photos, plus the source. This is the check-in map from the plan, as UI.
- **Rules review:** how the coach adjusts loads, one `RuleRow` each, drafted from his sheet and his instructions, or asked once ("How does your coach want you to adjust when a set misses the target?"). The same card lists how hard each kind of set goes, the rest after top sets, warm-ups, the check-in cadence and his quiet day, each beside his words. Nothing applies until it's confirmed.
- **Exercise tags** (Machine taken, stretch): each day's exercises as `TagRow`s, with the family, main muscles and Heavy/Light drafted, and "Confirm all". Then one card, "When a machine's taken, what does your coach want?", with the three options to put in order and confirm, and his own "or" options from the sheet beside his words.
- **Footer:** "Save program" / "Save check-in form".

### Session (full-screen, hands-free)
- **Purpose:** a whole training session with zero taps after Start. The phone stands on the tripod 2–3 m away, facing him from the bench (Settings → "Camera faces you"); he glances at it, and the ear carries the rest (four tones and three haptics: armed, set started, set ended, rest's up).
- **Built from:** `SessionHUD` (Features/Session/SessionHUD.swift), drawn from `SessionHUDModel(engine:live:)` every quarter second. The app's own grammar at hands-free scale: the cool page, white hairline cards with their title inside, navy SF Pro bold with tabular numbers, the yellow tag for the one thing waiting on him, cobalt only for the lockup, data sources ("Measured", the mic in use) and the end button, the red dot only while recording. No dark mode, no state colour fields.
- **Always on screen, top to bottom:** the lockup and the audio connection (a cobalt-tint pill naming the mic, yellow "Phone mic · too far" when it's the phone's own); the lifts strip (today's lifts as short names, a dot per set: done navy, the current one yellow, upcoming open, skipped a dash; an add-on as one entry after a hairline); the main area; the voice card; the cobalt "Hold to end session" button (a 1.2 s long press, the only tap target; "end session" by voice works too).
- **The camera card** (Ready, Armed, Recording, Rest, when the camera sees him): his own picture filling the space the cards leave, as on the Filming board. The state is the dark pill top-left ("○ Ready", yellow "● Armed · lift when ready", "● Recording · 0:24"), yellow corner brackets sit on him once the camera has locked on, and the foot of the frame says what to do ("Say "go" when you lift.", the word in bold, not a second yellow tag, "Watching you. Only your movement starts it.", "Counting when you rack it."). The front camera is shown mirrored, like a mirror.
- **States:**
  - **Ready / Armed / Recording:** a compact card above the camera: the exercise, the set as the yellow tag ("Back-off · set 2 of 2"), the target "65 lb × 8–10" at 76 pt, last time. No rep number while recording.
  - **Rest:** the camera card plays the set he just did, looping and silent, with its result on a white sticker ("9 reps", a `SourceChip`-style "Measured", "slowed 41% · failure"). Below it, the countdown (it thins from heavy to regular as the rest drains; "+0:40 over" in secondary once it runs out), and the next set as the yellow tag with what to say.
  - **Hold:** no camera: the hold's name, "Hold 2 of 4" as the yellow tag, the countdown, a track of the holds.
  - **Pocket** (the camera running but not seeing him): no camera card and no voice card; the pill reads "Pocket · buzzes on"; the countdown and the next set, larger.
  - **Done:** "Today's top sets" (each exercise's best set, "Beat the logbook" as the yellow tag), flags, notes, gym changes, SAM's median, "Your coach sees all of it on Thursday."
- **The voice card** (the check-in's voice bar at hands-free scale): his words in cobalt as the stream hears them, his words while the turn is read, Setecho's line filling from secondary to navy as it's said, the last line for 8 s; idle, "Say "…" or "…"" from `VoiceGuide.hints`.
- **A question waiting on him** (outside rest, where the next-set card carries it) stays on its own card with a yellow "Asked" tag until it's answered or lapses.
- **Coach cue, add-ons, warm-ups:** a cue is spoken; an add-on's lifts follow the day's under its name in the strip; a warm-up shows as "Warm-up 2" in the set tag.
- **Motion:** states spring into place (the set card and the rest card rise in, the yellow tag moves from the set card to the next-set card), and the target, clocks and counts roll (`.numericText`). Under Reduce Motion every one of these is a plain fade.
- **Review:** `SessionHUDRenderTests` and `SessionHUDMappingTests` render every state (`TEST_RUNNER_HUD_SHOTS=<folder>`, `TEST_RUNNER_HUD_CAMERA=<frame>` for a sample picture). `make screens` renders every screen of the app into `design/screens/` with contact sheets, for reviewing them side by side.

### How a session works (before the first session, and Settings → Sessions)
- **Shown once,** when Start session is tapped for the first time; its footer "Start session" opens the session. From Settings it's the same screen with "Done".
- **Four cards:** Set the phone down (tripod 2–3 m away, or the pocket) · Lift (the camera starts, ends and counts sets; without it, "starting" and "done, 8") · Talk between sets (in your own words; every action said back; "undo") · Not sure? Ask ("what can I say?").
- **Then one card:** "Everything you can say" (the guide below) and "Practice first" (today's session as a rehearsal: typed lines, the real backend, nothing logged).

### What you can say (Today's session card, Settings → Sessions, the intro)
- `SegmentTabs`, one guide per kind of session: **Working out** · **Abs** · **Vacuums**.
- Under each, one `SectionCard` per moment. Working out: While you lift · Before a set · After a set · Ask · Change the plan · Machine taken · For your coach · Fix and control. Abs: Add or skip · Rep sets · Planks. Vacuums: Holds · Ask · Fix and finish. Each line is the phrase in quotes, then what it does in `textSecondary`.
- The lines live in `ios/Setecho/Resources/VoiceGuide.json`; `test_voice.py` reads each one through the real rules in its state, so the guide can't list a phrase that doesn't work.

### Photo session (full-screen, hands-free)
- **Purpose:** the four check-in photos with no taps, framed like last week.
- **The order is the coach's:** Front · Right side, arms up · Back · Left side, arms up.
- **Layout:** the camera fills the screen. The pose name in `.hudState` ("Turn right · arms up"). `PoseSlots` along the bottom.
- **Flow:**
  1. The framing check speaks ("step back a little") until the whole body is in frame.
  2. The app calls each pose and waits until the athlete is still.
  3. It captures, says "Got it", and moves to the next pose.
- **Ends with the four photos as taken,** at full resolution, in his order. No collage, no cropping, no alignment. "Retake front" (or any pose) redoes that one.

### Check-in (tab)
- **Purpose:** the current check-in, filling itself as the days go.
- **Header card:** "11 of 22 ready" with a `MeterBar`, "11 to answer out loud", the due day, a tonal "Start 2-minute wrap-up" button and a Refresh `IconButton`.
- **Tabs over the form** (`SegmentTabs`): All · To do (its count on yellow) · Ready.
- **The coach's form, in his order:** the carried-over blocks (macro targets, supplements) collapsed at the top, then one `FieldRow` per field. Drafted fields show yellow "Confirm"; missing ones show "Ask in wrap-up".
- **Tapping a field** opens it to edit, with its source values listed.
- **Footer:** "Review and send".

### Check-in morning (full-screen, hands-free)
- **Purpose:** the whole check-in as one conversation on check-in morning: weight, glucose, photos, the coach's questions, then review.
- **Start:** "Hey Siri, start my Setecho check-in", the check-in-day notification, or Today's "Start check-in".
- **Layout, top to bottom** (`ConversationScreen`, shared with the wrap-up):
  - the lockup, and which check-in this is ("Thursday check-in", or "Practice run" on any other day)
  - `StepTrack`: Weight · Glucose · Photos · Questions · Review as five segments, done steps in cobalt, the current one on yellow, and one line under them naming the current step ("Photos · 3 of 5", then "All 5 done")
  - `ConversationTranscript`, sitting at the bottom of its space and growing upward: every line Setecho said (`SetechoLine`; the one being asked now in `.hudState`, earlier ones settled to `.hudLabel` secondary), the athlete's words as heard (`AthleteLine`, on the cobalt-tint bubble, right), and each answer the moment it is stored (`AnswerCard`: the check draws itself, the field, the value, its `SourceChip`)
  - `VoiceBar`: whose turn it is. A live waveform and "Your turn" / "Hearing you" while the mic is open, Setecho's own pulse while it speaks, a thinking beat while a turn is read, a quiet "Take your time" while he takes his
  - `HoldButton` "Hold to stop", which fills as it is held; once everything is answered, "Open to send" and "Read it back"
- **Voice:** an acknowledgment and the next question go out in one breath ("Okay, 180.8. And your fasted glucose?"); the coach's questions follow each other the way a person asks them ("Now, your coach's questions. …", "And how's your recovery been?", "Last one. …"), and "say that again" asks plainly.
- **Review:** every data-filled field is read back once ("Nutrition consistency came in at 86%, 6 of 7 days within targets. Sound right?"), except the weight (its own step), anything he already said or confirmed this morning, and the coach's own lines (cardio protocol, weeks to show, last check-in's weight). A number in reply replaces the value, commas and all ("10,000 steps"). "Last one" is said only before the real last check, counting the read-backs. Then the summary: one `SummaryCard` on screen (From you this morning · From Apple Health and your log · Photos · Still open, one line per field in his order) and a short spoken count ("22 of 22 ready: 11 from you this morning, 10 from Apple Health and your log, and your 4 photos"), before "ready to send?".
- **Back from a wait:** "I'm back", "ready", "go ahead" or "let's go" picks the question up again. A glucose reading is a number, never inches, whatever the coach's form files it under.
- **Paused:** the voice bar reads "Take your time. Just talk when you're ready." The mic stays open.
- **No typing.** The screen is speech only; there is no text field, in rehearsal or otherwise.
- **Photos step:** the Photo session, full-screen, then back here.
- **It understands:** "give me a couple of minutes" · "180.8, and glucose was 91" · "wait, it was 180.6" · "should I bump my carbs?" (→ "That's one for your coach. Want me to add it to your notes?") · "skip" · "go back" · "say that again".
- **Never:** advice, judgment, or a voice made to sound like the coach.
- **Ends on** Review and send.

### Wrap-up (full-screen, hands-free)
- **Purpose:** answer the fields data can't, by voice, in about 2 minutes.
- **It's also the Questions step of Check-in morning.** On its own, it's for answering what's left later in the day.
- **One question at a time,** in `.hudState`: "Hunger this week, 1 to 10?". Then `ListeningIndicator`, then the transcript, then auto-advance. Progress shows as "4 of 9", counting the measurements as one question.
- **The three tape measurements are one question:** "Waist, bicep, thigh?"
- **No weight yet today:** if this morning's weigh-in hasn't reached Apple Health, the wrap-up says "Open Withings once to sync today's weight" and carries on. If it still hasn't arrived by the last question, the wrap-up asks for it: "Today's weight?"
- **Voice:** "skip" · "go back" · "say that again".
- **Ends on Review and send.**

### Review and send
- **Purpose:** the exact message the coach receives, before it goes.
- **Content:** both messages in the coach's format and order (the plan message, then the check-in), with the four photos beneath the check-in; tapping one opens the Photo viewer, and "Compare with last week" opens it side by side. Every number can be tapped to see its source.
- **Videos for your coach:** the sets the athlete flagged ("flag that"), two at most from two different movements, each cropped to just the reps. One `VideoPickRow` each, with "Swap"; with none flagged, "Pick two". No verdicts, scores or form labels anywhere.
- **Adjustments:** the week's accepted suggestions, one line each, as they'll appear in the message.
- **Gym changes** (stretch): the week's swaps and reorders, one `DeviationRow` each, all checked. Untick one to leave it out.
- **Footer:** "Send to WhatsApp", in his order as three steps, one share sheet each: the plan message (macros, cardio, supplements), the check-in text with the four photos, then the two videos. The footer names the next step ("Next: the check-in"). If WhatsApp splits the text from the photos, the photos go first and the text right after. While rehearsal is on (Settings → Developer), a "Rehearsal" card at the top says so and every step goes to the athlete's own chat.

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
- **Garmin watch card** (stretch): "Connect" (opens the Garmin Connect app to pick the watch), then "Venu 4 · connected · last seen 2 min ago" and a "Test buzz" link. If the Setecho watch app isn't on the watch, one line says how to install it.
- **Withings card** (stretch): "Connect Withings", then "Withings · connected · last weigh-in 7:02 AM". Until it's connected, weight comes through Apple Health.
- **WhatsApp card** (stretch): "Import chat history", then the date of the last import and the message count.

### Watch (Setecho app on the Venu 4): stretch
- **Display:** round AMOLED, black background, white text. Cobalt for the logged ring. The target sits on a yellow fill with navy text, like `TargetTag`. Big numbers use the largest number font; everything else stays readable at arm's length mid-set.
- **Target:** the exercise (two lines at most), "225 × 8" big, "Set 3 of 4".
- **In set:** a red dot and the elapsed seconds. No live rep count; the count comes at the end.
- **Logged:** "8 reps" and its source ("Watch", "Phone", "Measured", "You said"), shown for 3 s with a short buzz. It updates if SAM corrects it.
- **Rest:** the countdown big, the next target small, and a long buzz at zero.
- **Disconnected:** "Open Setecho on your phone."
- **Input:** a tap anywhere is "done" (ends the set or skips the rest). The back button is undo, confirmed on screen.

### History (tab)
- **Tabs** (`SegmentTabs`): Sessions (this week, previous sessions, last time) · Check-ins · Photos · Plan. One kind of history at a time.
- **Sessions** keep the board's grouped-card layout. Each session is one line (date, day, sets) that opens to every set's clip and its count's `SourceChip`.
- **Sent check-ins** reopen read-only. Above them, **Trends**: weight, the tape and fasted glucose across every check-in, one line each, with the change since the first. Below them, **From WhatsApp**: the check-ins imported from the coach chat, each opening read-only with its photos.
- **Photos** show each week's four photos as a timeline. Tapping one opens the Photo viewer on that pose; "Compare" opens the latest week beside the one before it.
- **Plan changes** list each applied coach reply with its changes. The latest one has "Revert", which restores the previous plan. Under them, **Coach replies from WhatsApp**: his messages after each imported check-in, word for word, never applied.

### Import WhatsApp chat (More menu)
- **Purpose:** bring in the prep so far, once: past check-ins and the coach's replies, from WhatsApp's Export Chat zip.
- **Steps:** how to export, what's kept, the last import with "Start over" → "Which one is you?" (sender rows with message counts) → what was found (check-ins, replies, photos, already imported, left out) → Imported.
- **Footer:** "Choose the export" / "Continue" / "Import" / "Done".

### Import Liftoff and Garmin (More menu)
- **Purpose:** the sets he logged before Setecho, once, so Last time is right from the first session.
- **Steps:** how to export, what's kept, the last import with "Start over" → reading (`LoadingCard`) → review → Imported.
- **Review:** Found (sessions per source, the dates, what was left out) · "Liftoff weights are in pounds?" · Same day in both (only when there is one) · one card per plan day: each lift, its "Last time 225 × 9 · Oct 26" with a `SourceChip` and "Heaviest of …" in secondary, and each name matched to it with "Change" (a menu of his lifts by day, and "Keep under its own name") · Kept under their own name.
- **Footer:** "Choose the files" / "Confirm and import" / "Done".
- **Elsewhere:** History → Sessions gets "Before Setecho" (one row per imported session with its source chip, opening read-only), and `LastTimeRow`'s chip names Liftoff or Garmin.

### Photo viewer (full-screen)
- **Purpose:** see a check-in photo at full size and put it beside another week's. Viewing only: the files stay exactly as taken, nothing is cropped, aligned or changed.
- **Opens from** a photo on the History Photos tab, the Photos card on Review and send, and the review after a Photo session.
- **Layout:** the camera fill edge to edge. Top bar: the pose and date, "Compare" (`.setechoTonal`, only when another week exists), the X. The photo in the middle: pinch or double-tap to zoom, drag to pan once zoomed, swipe for the next pose. Bottom bar: `SegmentTabs` Front · Right · Back · Left. A tap on the photo hides both bars.
- **Compare:** the two weeks side by side, same pose, older on the left, each labeled with its date (and "this one" on the week opened). They zoom and pan together. A row above the pose tabs steps the other week with arrows, or picks it from a date menu.

## Flow

1. **Import once:** program and form.
2. **Training day:** Today → Start session (the day, plus any add-on) → hands-free Session → End session → Today. A morning add-on is its own short session: "Hey Siri, start my Setecho morning", or Today's Morning card.
3. **Photo day:** Today → Take photos → Photo session → Check-in.
4. **Check-in day:** "Hey Siri, start my Setecho check-in" → Check-in morning (weight, glucose, photos, questions) → Review and send → WhatsApp. The Photo session and Wrap-up still work on their own.
5. **Coach replies:** WhatsApp → Share → Setecho (or paste) → Coach reply → Apply → Today shows the updated plan. His cues play in the next sessions.
6. **Setup:** Import → Connections (Apple Health; the watch only if it's built) → Today.

## Open design questions
- **Spreadsheet delivery:** decided Oct 26, a Google Sheets link. The Import screen's first step takes a pasted link, with a file or screenshot as the fallback.
- **Change rows checked by default?** The default is checked, with the Apply tap as the approval. If that makes rubber-stamping too easy, start them unchecked.
- **Tagline:** decided: "The prep that logs itself."
