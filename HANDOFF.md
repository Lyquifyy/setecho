# Setecho — build handoff for a coding agent

**Read order:** `AGENTS.md` (rules) → this file (what to build and how) → `DESIGN.md` (screens and components). The plan of record with the schedule is the Claude Doc "Setecho hackathon build plan". If anything here conflicts with `AGENTS.md`, `AGENTS.md` wins.

**How to work:**
- Build milestone by milestone, in order.
- After each milestone, run its acceptance checks, then stop and report: what passed, what didn't, what you need from the human.
- Never skip a gate. Never start a stretch item while a must-have is failing.
- Commit after each working piece with a clear message. The commit history is part of the hackathon submission.

---

## 1. The product

Setecho takes the manual work out of a coached bodybuilding prep. The athlete has a human coach who sends a training program as a spreadsheet and expects a weekly check-in in WhatsApp.

Setecho:
1. **Imports the coach's material once:** the spreadsheet program and the check-in form.
2. **Logs training hands-free.** The phone sits on a tripod with a DJI wireless mic. Sets are detected automatically, results are read aloud over the athlete's music, and corrections are spoken.
3. **Takes the four check-in photos hands-free,** aligned to last week.
4. **Fills half the check-in from data.** Weight (Withings), macros (MacroFactor), and steps and sleep (Garmin) all arrive through Apple Health. The rest is asked in a 2-minute voice wrap-up.
5. **Sends the check-in to WhatsApp** in the coach's exact format.

**Setecho is not a coach.** It never recommends loads, nutrition or form. That keeps it off the hackathon's "avoid" list ("sports analyzers or coaches", "AI nutrition coach"), and it is also the product truth: the human coach coaches.

**Hackathon facts:**
- Meta Global AI Developer Hackathon, indie track.
- Build period: Oct 27 – Nov 4, 2026.
- Submission due **Wed Nov 4, 9:00 PM ET**, with a 3-minute demo video, a public repo and a write-up.
- Judged on Impact 30%, Use of Meta AI tooling 25%, Technical depth 20%, Demo 25%.
- Only work built during the event counts.

---

## 2. What exists today

| Path | State |
|---|---|
| `ios/Setecho/DesignSystem/` | **Done.** Tokens (`Theme`), type, `SectionCard`, buttons, `TargetTag`, `LoadRepsText`, `MetricText`, `FooterBar`, `ScreenScaffold`, `BrandHeader`, `TitleBlock`, `Format`, and a `ComponentGallery` preview. Use these; don't restyle. |
| `ios/Setecho/Assets.xcassets` | **Done.** App icon, `Lockup`, `Logo`, `Wordmark` (vector, template), `AccentColor`. |
| `ios/Setecho/App/` | Placeholder tabs Today / History / Check-in. Replace them. |
| `ios/project.yml` | XcodeGen. iOS 26, Swift 6 (strict concurrency), bundle id `com.getsetecho.app`. Never edit the `.xcodeproj`. |
| `backend/app/meta.py` | The only Meta client. Has `client()`, `aclient()`, `upload_video()`, `segment_video()`. **Delete the stale stubs** `parse_program`, `review_set` and `ask_coach`; they belong to the old concept. |
| `backend/app/main.py` | FastAPI with `/health` only. |
| `backend/scripts/` | `smoke.py` (one live call) and `sam_probe.py` (SAM on a video clip). |
| `design/` | Approved boards and brand files. Read-only. |

Commands: `make test`, `make lint`, `make dev`, `make smoke`, `make ios`, `make ios-test`.

---

## 3. Architecture

```
iPhone (Setecho app)                                Backend (FastAPI, stateless)            Meta Model API
- HealthKit reads (weight, macros, steps, sleep)    - holds MODEL_API_KEY                   - muse-spark-1.3
- camera + on-device set detection (Vision)   <-->  - /import/*   (Spark, structured)  -->  - muse-voice-transcribe-1.0
- audio: DJI mic in, AirPods out, iOS speech        - /voice/*    (Transcribe + Spark)      - sam-3.1
- photo session: on-device framing + stillness      - /photos/*   (SAM image masks)
- stores everything locally (JSON files)            - /checkin/*  (agent + validator)
- share sheet -> WhatsApp
```

- **The phone owns all data.** Program, template, sessions, sets, notes, photos and check-ins are stored on the device as Codable JSON under Application Support, plus JPEG and MOV files. The backend keeps nothing between requests.
- **The backend exists to hold the key and talk to Meta.** It also does deterministic work: rendering the check-in text and validating numbers.
- **The model never produces a number.** Numbers come from HealthKit, the training log, or the athlete's own words (extracted, then echoed back for confirmation).
- **No text-to-speech exists on Meta Model API,** so spoken callouts and questions use `AVSpeechSynthesizer` on the phone.
- **Set videos stay on the phone** and are not uploaded in the must-have scope. Only the bar-speed stretch item uploads clips.

---

## 4. Data model

Swift `Codable` structs in `ios/Setecho/Models/`. The backend mirrors the same JSON with Pydantic models in `backend/app/schemas.py`. Field names are identical, in camelCase.

```swift
// Coach's program (from the spreadsheet)
struct Program: Codable { var name: String; var weeks: [ProgramWeek]; var importedAt: Date; var flags: [ImportFlag] }
struct ProgramWeek: Codable { var number: Int; var days: [ProgramDay] }
struct ProgramDay: Codable, Identifiable { var id: String; var name: String /* "Upper A" */; var exercises: [PlannedExercise] }
struct PlannedExercise: Codable, Identifiable {
  var id: String; var name: String; var sets: [PlannedSet]
  var restSeconds: Int?            // from the sheet if present
  var notes: String?
}
struct PlannedSet: Codable { var reps: Int?; var repsMin: Int?; var repsMax: Int?; var loadLb: Double?; var rpe: Double?; var rir: Int? }  // "6-8 reps" = repsMin 6, repsMax 8
struct ImportFlag: Codable { var path: String /* "week 4 / Upper A / Bench / set 2" */; var message: String }

// Coach's check-in form
struct CheckInTemplate: Codable { var fields: [FieldSpec]; var carriedBlocks: [CarriedBlock] }
struct CarriedBlock: Codable { var title: String; var text: String }  // macro targets, supplements: copied verbatim
struct FieldSpec: Codable, Identifiable {
  var id: String                 // stable slug, e.g. "avg_daily_steps"
  var label: String              // the coach's exact wording, e.g. "Average daily steps"
  var prompt: String?            // the coach's hint text, e.g. "(scale 1-10)"
  var kind: FieldKind            // .number, .scale10, .percent, .date, .text, .measurement, .photo
  var source: FieldSource        // .data(DataKey), .drafted(DataKey), .voice, .photo, .calculated(DataKey)
  var order: Int
}
enum DataKey: String, Codable {   // every number the app can fill
  case weeksToShow, planAccuracy, nutritionConsistency, trainingConsistency, cardioProtocol,
       performanceNotes, lastRefeedDate, avgDailySteps, lastCheckInWeight, currentWeight, sleepDuration
}

// Training
struct Session: Codable, Identifiable { var id: UUID; var programDayId: String; var startedAt: Date; var endedAt: Date?; var sets: [LoggedSet]; var notes: [VoiceNote] }
struct LoggedSet: Codable, Identifiable {
  var id: UUID; var exerciseId: String; var setIndex: Int
  var loadLb: Double; var reps: Int; var rpe: Double?
  var startedAt: Date; var endedAt: Date; var clipFile: String?     // local MOV
  var edits: [SetEdit]                                              // audit trail for "that was 7 reps"
}
struct VoiceNote: Codable, Identifiable { var id: UUID; var at: Date; var transcript: String; var targetFieldId: String? }

// Photos
struct PhotoSet: Codable, Identifiable { var id: UUID; var takenAt: Date; var poses: [PosePhoto]; var collageFile: String }
struct PosePhoto: Codable { var pose: Pose; var file: String; var bodyBox: CGRect /* from the SAM mask, image px */; var alignedFile: String }
enum Pose: String, Codable, CaseIterable { case front, rightArmsUp, back, leftArmsUp }

// Check-in
struct CheckInDraft: Codable, Identifiable { var id: UUID; var weekStart: Date; var weekEnd: Date; var answers: [FieldAnswer]; var photoSetId: UUID?; var sentAt: Date? }
struct FieldAnswer: Codable {
  var fieldId: String; var text: String                  // exactly what goes to the coach
  var state: AnswerState                                 // .filled, .drafted, .missing, .confirmed
  var provenance: [Provenance]                           // what the text was built from
}
struct Provenance: Codable { var source: String /* "Withings via Apple Health" */; var detail: String /* "Oct 19–25: 181.2, 181.0, …" */ }
```

`FieldSource` and `FieldKind` are Codable enums with associated values, encoded as `{"type": "...", "key": "..."}`.

---

## 5. Backend API contract

Base URL comes from `SETECHO_API_BASE` (`ios/Config/Local.xcconfig`). All bodies are JSON unless marked multipart. Every endpoint returns `422` with `{"error": "..."}` when validation fails, and never guesses.

| Method, path | Request | Response | Meta call |
|---|---|---|---|
| `GET /health` | — | `{ok, models}` | none |
| `POST /import/program` | multipart: `file` (`.csv`, `.xlsx` or an image) **or** `text` | `Program` with `flags` | Spark, structured output |
| `POST /import/form` | `{text}` or multipart `file` (screenshot) | `CheckInTemplate` | Spark, structured output |
| `POST /voice/command` | multipart: `audio` (WAV) + `context` JSON | `{transcript, intent: VoiceIntent}` | Transcribe, then Spark structured output |
| `POST /photos/segment` | multipart: `image` (JPEG) | `{width, height, box: [x,y,w,h], maskPng: base64}` | SAM 3.1 image |
| `POST /checkin/draft` | `{template, facts: WeekFacts, notes: [VoiceNote], training: TrainingSummary, lastCheckIn?: CheckInDraft, styleExamples: [String]}` | `CheckInDraft` | Spark tool calling, then a validator |
| `POST /checkin/answer` | multipart: `audio` + `{fieldId, field: FieldSpec, styleExamples}` | `{transcript, answer: FieldAnswer}` | Transcribe, then Spark structured output |
| `POST /checkin/render` | `{template, draft}` | `{text}`, the WhatsApp message | none (templating) |

**Conversions on the backend:** `.xlsx` → rows with `openpyxl`, then CSV text into the Spark prompt. Never send raw binary to Spark. For any audio that isn't WAV 16 kHz or 24 kHz mono 16-bit, convert with ffmpeg (already installed on the Mac).

**`WeekFacts`** is computed on the phone from HealthKit and the log, and sent as plain numbers so the backend can cite them:

```json
{ "weekStart": "2026-10-19", "weekEnd": "2026-10-25",
  "daily": [ { "date": "2026-10-19", "isTrainingDay": true, "kcal": 2410, "proteinG": 212, "carbsG": 248, "fatG": 64,
               "steps": 10412, "sleepHours": 7.4, "weighInLb": 181.2, "liss": [{"type":"walking","minutes":25}] } ],
  "targets": { "training": {"kcal":2425,"proteinG":210,"carbsG":250,"fatG":65}, "rest": {"kcal":2125,"proteinG":210,"carbsG":175,"fatG":65} },
  "showDate": null, "lastCheckInWeightLb": 181.5 }
```

The numbers above are illustrative. Never commit the athlete's real values; see §11.

**`VoiceIntent`** is the structured output for every spoken command:

```json
{ "intent": "rpe | reps | setLoad | loadDelta | skipSet | nextExercise | note | undo | pause | resume | endSession | starting | endSet | answer | unknown",
  "number": 9, "text": "digestion's been off since Wednesday", "fieldId": null, "confidence": 0.0 }
```

If `confidence` is under 0.7, or the intent is `unknown`, the app asks back ("Did you say 215?") and does nothing yet.

---

## 6. Meta Model API cheat sheet

All calls go through `backend/app/meta.py`. Base URL `https://api.meta.ai/v1`, key from `MODEL_API_KEY`, Standard tier only.

**Structured output (Muse Spark).** Use **Chat Completions** with `response_format`. On the Responses API, `response_format` does nothing; that API uses `text.format`.

```python
resp = client().chat.completions.create(
    model="muse-spark-1.3",
    messages=[{"role": "system", "content": SYSTEM}, {"role": "user", "content": user_text}],
    response_format={"type": "json_schema", "json_schema": {"name": "Program", "schema": PROGRAM_SCHEMA, "strict": True}},
)
data = json.loads(resp.choices[0].message.content)
```

With `strict: True`:
- The root must be an object.
- Every object needs `additionalProperties: false` and must list all of its properties in `required`.
- No `oneOf` or `allOf`; `anyOf` is allowed below the root.
- Use `{"type": ["number", "null"]}` for optional values.
- Nesting is capped at 10 levels.

`client().beta.chat.completions.parse(..., response_format=PydanticModel)` also works.

**Tool calling (the check-in agent).** The Responses API is recommended.
- Tools are `{"type": "function", "name", "description", "parameters"}`.
- Calls arrive as `function_call` items in `resp.output`, each with `call_id` and `arguments`.
- Return each result with `{"type": "function_call_output", "call_id": ..., "output": json.dumps(result)}`, plus `previous_response_id=resp.id`.
- `tool_choice` must be `"auto"`, and parallel calls are on by default.
- Validate every argument in code.

**Image input to Spark** (a program or form screenshot): pass the image as a base64 data URL in the user content. See `https://dev.meta.ai/docs/image-understanding.md`.

**Muse Voice Transcribe, file mode** (used for every command and wrap-up answer):
- `POST https://api.meta.ai/v1/asr/transcribe`, with `Authorization: Bearer <key>`, as `multipart/form-data`.
- Part `request` (JSON, `application/json`): `{"model": "muse-voice-transcribe-1.0", "audioEncoding": "...", "mode": "PUSH_TO_TALK"}`.
- Part `audio` (`audio/wav`): RIFF/WAVE, **mono, 16-bit PCM, 16 kHz or 24 kHz**. Up to 10 minutes and 32 MB.
- Response JSON: `{sessionId, transcript, audioDurationMs, turns: []}`. `turns` is empty in `PUSH_TO_TALK`.
- Use `PUSH_TO_TALK`, since the app's voice detection sets the turn boundaries.
- Errors: 400 for bad audio, 429 means back off, 500 means retry once. Log the `sessionId`.
- Cost: $0.18 per audio hour.
- Use `httpx` or `requests`, not the OpenAI SDK. Confirm the exact `audioEncoding` value for WAV in the request schema linked from `https://dev.meta.ai/docs/api-reference/voice/transcribe.md`.

**Muse Voice Transcribe, realtime** (stretch only):
- `wss://api.meta.ai/v1/asr/realtime`. The first text frame is the handshake: `{"authorization":{"accessToken":"Bearer <key>"},"audioEncoding":"PCM_24KHZ","model":"muse-voice-transcribe-1.0","mode":"PUSH_TO_TALK"}`.
- Then send binary PCM16 mono 24 kHz frames, paced in real time (80 ms frames). The server rejects streams more than 5 s ahead.
- End with `{"type":"endStream"}`. Transcript events look like `{"type":"transcript","transcript":...,"final":bool}`.
- The key must stay on the backend, so the phone would stream through a backend relay.

**SAM 3.1 on an image** (check-in photos):

```python
with client().responses.stream(model="sam-3.1", input=[{"type": "message", "role": "user", "content": [
        {"type": "input_text", "text": "person"},
        {"type": "input_image", "image_url": f"data:image/jpeg;base64,{b64}"}]}],
        metadata={"mask_encoding": "one_bit"}) as stream:
    ...
```

- Keep the prompt to a noun phrase ("person"). An empty `output_text` means no match, which is normal.
- Parse with `meta_sam_parser`; see `https://dev.meta.ai/docs/sam/reading-segmentation.md`. Take the largest mask.
- Downscale images to about 1280 px on the long side before sending.

**SAM 3.1 on video** (bar-speed stretch only): the existing `meta.segment_video()` and `scripts/sam_probe.py`.

Prompt caching is automatic for repeated prefixes. Keep system prompts and schemas byte-identical across calls.

---

## 7. iOS implementation notes

### Project config (`ios/project.yml` + `ios/Config/Info.plist`)
- Add the HealthKit capability: an entitlements file with `com.apple.developer.healthkit = true`, referenced from `project.yml`.
- Add `NSHealthShareUsageDescription`: "Setecho reads your weight, nutrition, steps and sleep to fill in your coach's check-in."
- Camera, microphone and photo strings already exist. Update the camera string to "Setecho films your sets and takes your check-in photos."
- Background modes: `audio`, so the session keeps listening and speaking with the screen locked.
- Signing: the human sets `DEVELOPMENT_TEAM` in `Local.xcconfig`. HealthKit needs a real device for real data; the simulator only has sample data you add.

### Storage
`Store` is an `@MainActor @Observable` class that saves Codable JSON to Application Support, with one file per collection plus media files. No SwiftData; keep it simple and testable.

### HealthKit (read-only)
- **Types:** `bodyMass`, `dietaryEnergyConsumed`, `dietaryProtein`, `dietaryCarbohydrates`, `dietaryFatTotal`, `stepCount`, `sleepAnalysis`, workouts.
- **Daily sums** via `HKStatisticsCollectionQuery` (`.cumulativeSum`, one-day intervals, local midnight anchor): energy, protein, carbs, fat, steps.
- **Weight:** the first `bodyMass` sample each morning, in pounds.
- **Sleep:** per night, sum the asleep stages (`asleepCore`, `asleepDeep`, `asleepREM`, `asleepUnspecified`) for samples ending that morning.
- **LISS:** Garmin workouts of walking, elliptical, stair climbing or cycling type, with their minutes.
- Show which source app each value came from (`HKSource.name`) in `Provenance`.

### Deterministic check-in fields (computed in Swift, sent as `WeekFacts`, rendered by the backend)

| Field | Rule (defaults the athlete can change in Settings) |
|---|---|
| Accuracy on plan | Days within macro tolerance and sessions completed vs. planned, shown as "100% (7 of 7 days, 5 of 5 sessions)" |
| Nutrition consistency | A day is on plan if kcal is within ±5% of that day type's target and protein, carbs and fat are each within ±10 g. Day type = training if a Setecho session happened that day or the program schedules lifting. |
| Training consistency | Sessions done vs. scheduled, plus PRs (a set heavier, or the same load for more reps, than the best for that exercise in earlier weeks logged in Setecho; with no history yet, report no PRs rather than guess) |
| Current cardio protocol | The protocol text from settings, plus logged LISS: "25 min LISS × 2 (logged: 2 sessions, 51 min). Steps: avg 10.2k" |
| Average daily steps | The 7-day mean, rounded to 100 |
| Current body weight | The check-in morning's weigh-in (setting: or the 7-day average) |
| Last check-in body weight | The weight in the last sent check-in |
| Date of last refeed or cheat meal | Drafted: the latest day with kcal above that day's target +20%. Always "Confirm" |
| Notes on sleep | Prefilled with "Avg 7.4 h/night (Garmin)", then the athlete adds the quality note by voice |
| Weeks away from target date | From the show date in settings, else "N/A" |

### Audio (gate G2 decides this)
- Use `AVAudioSession` category `.playAndRecord`, mode `.default`, options `[.mixWithOthers, .allowBluetoothA2DP]`.
- **Never `.allowBluetooth`** (HFP): it drops the athlete's music to call quality.
- Prefer the DJI receiver as input: pick the `availableInputs` entry whose `portType == .usbAudio`, and call `setPreferredInput`.
- Output stays on the AirPods over A2DP.
- **Callouts:** before speaking, reactivate with `[.duckOthers, .allowBluetoothA2DP]`. Speak with `AVSpeechSynthesizer` (`usesApplicationAudioSession = true`). After `didFinish`, go back to `.mixWithOthers` so the music returns to full volume.
- **Voice detection:** an `AVAudioEngine` input tap, RMS in dBFS against a noise floor learned over the first 2 s, with 300 ms onset and 700 ms hangover. Keep utterances to 10 s or less.
- **Utterance format:** convert to 16 kHz mono Int16 with `AVAudioConverter` and write the WAV header yourself. Upload to `/voice/command`.
- **Listen only in the Ready and Rest states,** never while a set records. That cuts false commands from gym noise. If false triggers still happen, add a setting that requires the prefix "Setecho …".

### Set detection (Session screen)
- **Capture:** `AVCaptureSession` on the back 1× wide camera, 1080p. Run `VNDetectHumanBodyPoseRequest` on every 4th frame, about 15 fps.
- **Signal:** the mean y of both wrists, normalized and smoothed with a 5-frame median.
- **Start:** the wrist signal's range over the last 2 s exceeds 0.08, with at least one direction reversal. Start `AVCaptureMovieFileOutput` and set the state to Recording.
- **End:** range under 0.03 for 4 s. Stop recording and log the set from the plan.
- **Always available fallback:** the voice intents `starting` and `endSet`.
- **Tune the thresholds on real footage.** Save the wrist series from each test session to a debug JSON file so it can be tuned offline.
- **Logging rule:** load comes from the plan, or the last voice override for that exercise. Reps come from the plan unless the athlete says "that was N". RPE is spoken.
- **Callout template** (deterministic, no model): "Set 3 done. Next, 225 for 8. Rest two thirty." Then show the rest countdown; the rest time comes from the program, defaulting to 150 s.
- **Undo:** keep a stack of applied actions. "Undo" reverts the last one and says what it reverted.

### Photo session
- **Capture:** back camera, `AVCapturePhotoOutput`, portrait.
- **Live checks run on the device**, with no network: `VNGeneratePersonSegmentationRequest` (`.balanced`) at about 10 fps.
  - **Framing:** the mask's bounding box sits inside the frame with at least 4% margin on every side. Otherwise speak "step back a little", "move left" or "move right", at most once every 3 s.
  - **Stillness:** the mask IoU between consecutive checks stays above 0.97 for 1.2 s.
- **Flow:** speak the pose (Front → "Turn right, arms up" → "Turn around" → "Turn left, arms up"), wait for stillness, capture, say "Got it".
- **Alignment (SAM 3.1):** send each captured still to `/photos/segment` and take the person box. Scale each photo so the body box height matches the reference week's (the first photo set ever), center the box horizontally, then crop to 3:4.
- **Never alter pixels** beyond crop and scale.
- **Collage:** 2×2 by default (front, right / back, left), or 1×4 as a setting. Write a JPEG, about 2400 px wide, to the photo set.

### Check-in
1. Build `WeekFacts`, `TrainingSummary` and the week's `VoiceNote`s, then call `/checkin/draft`.
2. Show the coach's form in his order (DESIGN.md, Check-in).
3. **Wrap-up:** for each `.missing` or `.voice` field, speak the coach's label as a question. For example, "Energy levels, 1 to 10?". The three tape measurements are one question: "Waist, bicep and thigh?".
4. Record one utterance and call `/checkin/answer`.
5. Speak back a one-line confirmation: "Energy 6. Next: appetite." Support "skip", "go back" and "say that again".
6. **Send:** `/checkin/render` → `UIActivityViewController` with `[collageImage, text]`. Gate G6 decides whether WhatsApp keeps both.
7. **Fallback:** share only the image, put the text on `UIPasteboard`, and show the banner "Paste the check-in text under the photo." Mark the draft `sentAt` when the share completes.

---

## 8. Model prompts

Keep the prompts in `backend/app/prompts.py` and the schemas in `backend/app/schemas.py`, versioned. These are the starting texts.

**Import program** (`/import/program`, structured output, schema = `Program` minus `importedAt`):

> You convert a strength coach's training spreadsheet into JSON. Copy exercise names, set counts, reps, rep ranges, loads, RPE/RIR and rest times exactly as written. Never invent a value. If a cell is ambiguous, keep your best reading and add an entry to `flags` explaining what is unclear. Weeks and days follow the sheet's own order and names.

**Import form** (`/import/form`, structured output, schema = `CheckInTemplate`):

> You convert a coach's weekly check-in form into a template. Keep every field label exactly as written, in order, including hint text in parentheses as `prompt`. Blocks that are the coach's instructions rather than questions (macro targets, supplement lists) become `carriedBlocks` with their text copied verbatim. For each field, choose `kind` and a `source` from this list of available data keys: {DataKey list with one-line meanings}. Use `voice` when no data key fits. Never answer the fields.

**Check-in agent** (`/checkin/draft`, Responses API with tools):
- **Tools:** `get_week_facts()`, `get_training_summary()`, `get_notes()` and `get_last_checkin()`. They return what the phone sent.
- **The agent writes only the text fields:**
  - "Notes on performance", drafted
  - "Biggest win", a suggestion, marked drafted
  - mid-week notes routed to their fields
- **Every data field comes from code** (§7 table), never from the model.
- **The validator checks every number in the agent's text** against `WeekFacts` and the training summary. Any number not found makes that answer `.drafted`, with a "Check this" provenance. Never hide a mismatch.

> You fill in an athlete's weekly check-in for their coach, in the athlete's own voice. Here are examples of how they write: {styleExamples}. Use only facts returned by your tools. Do not give advice, judge form or suggest changes; the coach does that. Keep answers short and casual, like the examples.

**Voice command** (`/voice/command`, structured output = `VoiceIntent`):

> Classify one short spoken command from an athlete during a lifting session. Context: {state, exercise, set, planned load and reps}. Map to one intent. Numbers are pounds for loads and counts for reps; "felt like a 9" is rpe 9. If unsure, return intent "unknown" with low confidence.

**Wrap-up answer** (`/checkin/answer`, structured output = `{text, number?, measurements?: {waistIn, bicepIn, thighIn}, confidence}`):

> Turn the athlete's spoken answer to "{label}" into the text they'd type. Keep their words and tone; fix only filler and false starts. Extract the number for scale or measurement fields. "Twenty-four and three quarters" is 24.75.

---

## 9. Milestones

Dates match the plan's schedule. Each milestone ends with its checks passing and a commit.

### M0 — Gates (Tue Oct 27)
Small throwaway test targets in `ios/Probes/`, not in the app target, plus backend scripts. The gate numbers match the plan's "Tuesday's gates" list.

- [ ] **G1 organizers.** The human asks at office hours whether this counts as a "sports analyzer or coach", and whether AI coding assistants are fine. Nothing to build.
- [ ] **G2 audio probe.** A tiny SwiftUI app: play nothing, record 5 s from the preferred USB input to WAV, speak a test sentence with ducking. **Human checks:** Spotify on AirPods stays full quality; the sentence ducks and then restores the music.
- [ ] **G3 HealthKit probe.** Print the last 7 days of every type in §7 with source names. **Human checks:** the numbers match MacroFactor, Withings and Garmin.
- [ ] **G4 SAM photo probe.** `scripts/sam_photo_probe.py <jpg>…` calls SAM on four pose photos and saves mask overlays to `tests/fixtures/sam/`. **Pass:** one clean person mask per photo, arms included.
- [ ] **G5 import probe.** `scripts/import_probe.py <sheet> <form.txt>` prints the `Program` and `CheckInTemplate`. **Pass:** the human confirms every exercise, set and rep, and all 22 fields with sources.
- [ ] **G6 share probe.** Share one image plus text to WhatsApp. **Human checks:** whether both arrive together.
- [ ] **Voice smoke.** `scripts/voice_probe.py <wav>` returns a transcript from Muse Voice Transcribe.

Report the results to the human before M1. A failed gate switches to its fallback (plan, "Tuesday's gates").

### M1 — Imports, Apple Health, deploy (Wed Oct 28)
- [ ] `/import/program`, `/import/form` and the schemas, with offline tests on fixture outputs saved from the probes.
- [ ] iOS: Store, models, and the Import screens (DESIGN.md, Import), with a "Confirm" tag on flags.
- [ ] iOS: `HealthService` returns `WeekFacts`. Unit-test the day-type and adherence rules with synthetic samples.
- [ ] Today screen, showing the imported day.
- [ ] Backend: a `Dockerfile` and deploy config. The **human** creates the host account and runs the deploy; Fly.io is the suggested default. The app points at the public URL.
- **Done when:** the real sheet and form import on the phone, and Today shows today's session.

### M2–M3 — Hands-free training (Thu Oct 29 – Fri Oct 30)
- [ ] `AudioService` (§7 Audio), `VoiceService` (voice detection → `/voice/command`), `/voice/command` with intent tests from fixture transcripts.
- [ ] `SetDetector` (Vision wrist signal) with the debug export; Session screen states and `HUDState`, `ListeningIndicator`, `VoiceEcho`.
- [ ] Logging rules, the callout template, the rest timer, undo, and end session.
- [ ] **First gym test on Fri Oct 30:** the human runs a real session.
- **Done when:** a real session has zero taps after Start, every set is logged correctly or fixed by voice, and the music stays full quality.

### M4 — Hands-free photos (Sat Oct 31)
- [ ] Photo session (§7), `/photos/segment`, alignment, collage, `PoseSlots`, Collage review with a last-week toggle.
- **Done when:** four photos and a collage with no taps, framed to match the previous set.

### M5 — The check-in (Sun Nov 1, feature freeze tonight)
- [ ] `/checkin/draft` (agent + validator), `/checkin/answer`, `/checkin/render`. The render test reproduces the coach's form exactly: labels, order, carried blocks.
- [ ] The Check-in screen with `FieldRow` and `SourceChip`, Wrap-up, Review and send, and WhatsApp share with the fallback.
- **Done when:** a real week's check-in is drafted, the wrap-up takes 3 minutes or less, and the message arrives in WhatsApp in the coach's format with the collage.

### M6 — Rehearsal (Mon Nov 2)
- [ ] A full end-to-end run: session, photos, check-in. Fix bugs only.
- [ ] History tab (DESIGN.md).
- [ ] Stretch only if everything is green, in this order: posing-practice rounds, bar speed, prep questions, watch.

### M7–M8 — Film and submit (Tue Nov 3 – Wed Nov 4)
- [ ] The README states what was built during Oct 26 – Nov 4 and which Meta model does what.
- [ ] Repo flipped public. Video and write-up submitted by 9:00 PM ET. The human records and edits the video.

---

## 10. Tests
- **Backend:** `make test` stays offline. Save real model outputs from the probes into `backend/tests/fixtures/`, then test parsing, validation and rendering against them.
- **Required tests:**
  - the render reproduces the form order and carried blocks exactly
  - the validator flags a number not in `WeekFacts`
  - the voice-intent mapping covers every intent
  - the WAV header writer produces 16 kHz mono 16-bit
- **iOS:** `make ios-test`. Unit-test the adherence and day-type rules, PR detection, the set logging rules, undo, the collage layout math and the HealthKit aggregation, all with synthetic samples.
- **Never** hit the live API in tests.

## 11. Privacy and repo hygiene (the repo becomes public)
- **Never commit:**
  - the athlete's photos, set videos or audio
  - real Health values or real check-in answers
  - the coach's name or phone number
  - API keys, `.env` files or `Local.xcconfig`
- `.gitignore` already blocks clips, `.env` and `Local.xcconfig`. Add `*.wav`, `*.jpg` outside `design/`, and `ios/Probes/output/`.
- **Fixtures use synthetic values.** The form fixture keeps the coach's field labels, with placeholder numbers for macro targets and supplement doses.
- Photos go to Meta only through `/photos/segment`, Standard tier.

## 12. Things only the human can do
- Put `MODEL_API_KEY` in `~/.zshrc`, claim the $150 credits, and set a spend limit.
- Set the Apple team ID in `Local.xcconfig`, and test on the real iPhone, since HealthKit and the DJI mic need a device.
- Create the backend host account and deploy.
- Keep the GitHub repo private while building (run `git remote add origin https://github.com/Lyquifyy/setecho.git` when ready), and make it public before submitting.
- Ask the office-hours question, and get the coach's OK to appear in the demo.
- Do the physical tests: the gym sessions, photo rounds and WhatsApp send.

## 13. Defaults for open questions (change when the human answers)
| Question | Default |
|---|---|
| How the spreadsheet arrives | **Decided Oct 26: a Google Sheets link.** The backend fetches the sheet's CSV export (`/export?format=csv`); the sheet must be shared "anyone with the link". A `.csv`/`.xlsx` file, pasted text and a screenshot stay as fallbacks |
| Check-in day | **Decided Oct 26: Thursday morning**; wrap-up reminder Wednesday 7 PM |
| G1 organizers | **Decided Oct 26: not a sports analyzer or coach.** Human confirms in writing on Oct 27 |
| Gates G2–G6 | **Decided Oct 26: build on the plan's defaults** and test on the phone from TestFlight, not from the Mac. The probe screens live behind the More menu until M6 |
| Collage layout | 2×2: front, right / back, left |
| "Current body weight" | Check-in morning weigh-in |
| Rest time when the sheet has none | 150 s |
| Macro tolerance | kcal ±5%; protein, carbs and fat ±10 g |
| Tagline | Unchanged until the human decides |
