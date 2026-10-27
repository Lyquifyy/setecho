# Setecho — build handoff for a coding agent

**Read order:** `AGENTS.md` (rules) → this file (what to build and how) → `DESIGN.md` (screens and components). The plan of record with the schedule is the Claude Doc "Setecho hackathon build plan". If anything here conflicts with `AGENTS.md`, `AGENTS.md` wins.

**Start here (Oct 27):** most of the app was built on Oct 26. §9 lists what exists, what's untested, and the build order for the rest of the week: rep counting, the coach reply loop with voice cues, and the Garmin watch.

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
2. **Logs training hands-free, with or without the camera.** A Setecho app on the athlete's Garmin watch catches every set at every station from wrist motion, with nothing to set up. For the lifts the athlete wants measured or filmed, the phone goes on a tripod: it detects the set, counts the reps instantly, and SAM 3.1 then measures them from the set's video. A DJI wireless mic takes spoken corrections, and results are read aloud over the athlete's music. There's no mode to pick: Setecho uses whatever is there.
3. **Takes the four check-in photos hands-free,** aligned to last week.
4. **Fills half the check-in from data.** Weight (Withings), macros (MacroFactor), and steps and sleep (Garmin) all arrive through Apple Health. The rest is asked in a 2-minute voice wrap-up.
5. **Sends the check-in to WhatsApp** in the coach's exact format.
6. **Turns the coach's reply into plan changes.** The athlete shares the coach's WhatsApp text or voice note into Setecho. Each change is listed next to the coach's exact words, and nothing changes until the athlete approves it. Optionally, the coach's own voice plays in the athlete's headphones before the exercise he talked about.

**Setecho is not a coach.** It never recommends loads, nutrition or form. That keeps it off the hackathon's "avoid" list ("sports analyzers or coaches", "AI nutrition coach"), and it is also the product truth: the human coach coaches. Counting reps is logging: it records what happened and never judges it.

**Hackathon facts:**
- Meta Global AI Developer Hackathon, indie track.
- Build period: Oct 27 – Nov 4, 2026.
- Submission due **Wed Nov 4, 9:00 PM ET**, with a 3-minute demo video, a public repo and a write-up.
- Judged on Impact 30%, Use of Meta AI tooling 25%, Technical depth 20%, Demo 25%.
- Only work built during the event counts.

---

## 2. What exists today

Built on Oct 26 (commits up to `7596d21`). **None of it has been used in a real gym session yet.**

| Area | State |
|---|---|
| `ios/Setecho/DesignSystem/` | Tokens, type, components including `HUD`, `CheckInRows`, `PoseSlots`. Use these; don't restyle. |
| `ios/Setecho/Features/` | Today, Import, Session, Photos (session and collage review), Check-in (form, wrap-up, review and send), History, Settings. |
| `ios/Setecho/Services/` | `Store`, `APIClient`, `HealthService`, `Adherence`, `AudioService`, `VoiceDetector`, `SetDetector` + `WristSignal`, `PersonSegmenter`, `PhotoAlign`, `PhotoCapture`, `CheckInSchedule`, `Settings`. |
| `ios/Probes/` | The M0 phone probes (audio, Apple Health, WhatsApp share), shipped inside the app behind the More menu. |
| `ios/project.yml` | XcodeGen. iOS 26, Swift 6 (strict concurrency), bundle id `com.getsetecho.app`. Never edit the `.xcodeproj`. `make testflight` uploads a build. |
| `backend/app/` | `/health`, `/import/program` (incl. Google Sheets links), `/import/form`, `/voice/command`, `/photos/segment`, `/checkin/draft`, `/checkin/answer`, `/checkin/render`. `meta.py` is the only Meta client. |
| Deploy | Fly app `setecho-api` at `https://setecho-api.fly.dev` (README, "Deploy the backend"). |
| `design/` | Approved boards and brand files. Read-only. |

**Not built yet:** rep counting, the coach reply loop and voice cues, the Garmin watch app, and the stretch items. §9 has the order.

Commands: `make test`, `make lint`, `make dev`, `make smoke`, `make ios`, `make ios-test`, `make testflight`; add `make watch` and `make watch-sim` with the watch app (§7, Garmin watch).

---

## 3. Architecture

```
iPhone (Setecho app)                                Backend (FastAPI, stateless)            Meta Model API
- HealthKit reads (weight, macros, steps, sleep)    - holds MODEL_API_KEY                   - muse-spark-1.3
- camera + on-device set detection (Vision)   <-->  - /import/*   (Spark, structured)  -->  - muse-voice-transcribe-1.0
- instant rep count from body pose                  - /sets/*     (SAM video: rep counts)   - sam-3.1
- audio: DJI mic in, AirPods out, iOS speech        - /voice/*    (Transcribe + Spark)
- photo session: on-device framing + stillness      - /photos/*   (SAM image masks)
- stores everything locally (JSON files)            - /checkin/*  (agent + validator)
- share sheet -> WhatsApp                           - /coach/*    (Transcribe + Spark + validator)
- share extension <- coach's WhatsApp replies
- WatchService <-> Garmin Connect app <-> Setecho watch app (Venu 4, Connect IQ: wrist sets and reps, haptics)
```

- **The phone owns all data.** Program, template, sessions, sets, notes, photos and check-ins are stored on the device as Codable JSON under Application Support, plus JPEG and MOV files. The backend keeps nothing between requests.
- **The backend exists to hold the key and talk to Meta.** It also does deterministic work: rendering the check-in text and validating numbers.
- **The model never produces a number.** Numbers come from HealthKit, the training log, or the athlete's own words (extracted, then echoed back for confirmation).
- **No text-to-speech exists on Meta Model API,** so spoken callouts and questions use `AVSpeechSynthesizer` on the phone.
- **Set clips are uploaded for counting, then dropped.** After each set the phone sends a small copy (720p, 10 fps, no audio) to `/sets/count`. The backend forwards it to SAM 3.1 and keeps nothing. The full-quality MOV stays on the phone.
- **Sets come from up to three inputs: camera, watch and voice.** Any combination works and nothing has to be switched; §7, Session inputs, has the rules. The watch app makes no network or model calls: it talks only to the phone.
- **Every rep count has two sources when the camera is on duty.** The phone counts instantly from body pose. SAM's count, measured from the plate, arrives during rest and wins when it's confident. What the athlete says ("that was 7") beats both.
- **The coach's reply never changes anything by itself.** `/coach/reply` returns proposed changes. The phone applies only the ones the athlete approves, and keeps the previous plan so an applied reply can be reverted.

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
  var equipment: Equipment        // .barbell, .dumbbell, .machine, .cable, .bodyweight: decides what SAM tracks
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
  var loadLb: Double; var reps: Int; var rpe: Double?               // reps = the number in the log; repCount says where it came from
  var repCount: RepCount
  var startedAt: Date; var endedAt: Date; var clipFile: String?     // local MOV, trimmed to the set
  var edits: [SetEdit]                                              // audit trail for "that was 7 reps"
}
struct RepCount: Codable {
  var source: RepSource            // .plan, .watch, .phone, .measured, .spoken: which number `reps` holds
  var watch: Int?                  // wrist count from the watch app, with its confidence in watchConfidence
  var watchConfidence: Double?
  var phone: Int?                  // instant count from body pose, at set end
  var measured: Int?               // SAM count from /sets/count
  var confidence: Double?          // SAM count confidence, 0-1
  var repTimes: [Double]           // seconds from clip start, one per measured rep
  var status: CountStatus          // .counting, .done, .failed (offline or no track: the phone count stands)
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

// The plan the coach controls, versioned so an applied reply can be reverted
struct PlanState: Codable {
  var version: Int; var program: Program; var targets: MacroTargets; var cardioProtocol: String
  var carriedBlocks: [CarriedBlock]                      // macro text, supplements: the coach's words
  var replyId: UUID?                                     // the reply that produced this version
}
struct MacroTargets: Codable { var training: Macros; var rest: Macros }
struct Macros: Codable { var kcal: Int; var proteinG: Int; var carbsG: Int; var fatG: Int }

// Coach reply
struct CoachReply: Codable, Identifiable {
  var id: UUID; var receivedAt: Date
  var kind: ReplyKind                                    // .text, .voiceNote
  var audioFile: String?                                 // local copy of the voice note
  var transcript: String                                 // the text, or Voice Transcribe's transcript
  var changes: [PlanChange]
  var unclear: [String]                                  // his sentences that sound like a change but match nothing in the plan
  var appliedVersion: Int?                               // the PlanState version it produced
}
struct PlanChange: Codable, Identifiable {
  var id: String
  var kind: ChangeKind     // .macroTarget, .cardio, .exerciseSwap, .exerciseAdd, .exerciseRemove, .sets, .reps, .load, .rest, .supplement, .other
  var path: String         // one of the addressable paths the backend listed, e.g. "targets.training.carbsG", "program.upper-a.incline-db-press.sets"
  var op: ChangeOp         // .set, .increase, .decrease, .replace, .add, .remove
  var amount: Double?      // the number he said ("drop carbs by 25" → 25); must appear in `quote`
  var before: String?      // the current value at `path`, filled by the backend from the plan, never by the model
  var after: String?       // computed by the backend from before + op + amount; for a swap or an addition, his words for the new item
  var quote: String        // his exact words, verbatim from the transcript
  var appliesFrom: Date?   // "from Monday"; nil = the next session
  var approved: Bool       // set on the phone
}

// Coach voice cue: one sentence of his, about one exercise, played before it (optional, Settings)
struct VoiceCue: Codable, Identifiable {
  var id: String; var replyId: UUID
  var exerciseId: String                                 // a PlannedExercise id from the current plan
  var text: String                                       // his words
  var audioFile: String?                                 // m4a cut from his voice note; nil for a text reply (iOS speech reads it)
  var startSec: Double?; var endSec: Double?             // where it sits in the voice note
  var approved: Bool
  var lastPlayedAt: Date?
}

// Watch messages, decoded from the Connect IQ dictionary payloads (§7, Garmin watch)
enum WatchEvent { case hello(version: Int), setStart(at: Date), setEnd(startAt: Date, at: Date, reps: Int?, confidence: Double?), tap(WatchTap), pong(watchMs: Int64, echoMs: Int64) }
enum WatchTap: String { case done, undo, skipRest }
```

**Migrations** (no data loss; the athlete has real data on the phone by Thursday):
- `LoggedSet.repCount` decodes as `RepCount(source: .plan, …, status: .done)` when missing.
- `PlanState` is new. Today the program lives in `Store.program`, the carried blocks in `Store.template`, the cardio protocol in `Settings.cardioProtocol`, and the targets are parsed from the Nutrition block in `CheckInCoordinator.targets(from:)`. On first launch after the update, seed `PlanState` version 1 from those four, save it as `plan.json`, and from then on every reader goes through `store.plan`. Keep `targets(from:)` as the seeding function only.


`FieldSource` and `FieldKind` are Codable enums with associated values, encoded as `{"type": "...", "key": "..."}`.

---

## 5. Backend API contract

Base URL comes from `SETECHO_API_BASE` (`ios/Config/Local.xcconfig`). All bodies are JSON unless marked multipart. Every endpoint returns `422` with `{"error": "..."}` when validation fails, and never guesses.

| Method, path | Request | Response | Meta call |
|---|---|---|---|
| `GET /health` | — | `{ok, models}` | none |
| `POST /import/program` | multipart: `file` (`.csv`, `.xlsx` or an image) **or** `text` | `Program` with `flags` | Spark, structured output |
| `POST /import/form` | `{text}` or multipart `file` (screenshot) | `{template: CheckInTemplate, targets: MacroTargets, cardioProtocol}` | Spark, structured output |
| `POST /voice/command` | multipart: `audio` (WAV) + `context` JSON | `{transcript, intent: VoiceIntent}` | Transcribe, then Spark structured output |
| `POST /sets/count` | multipart: `video` (MP4, 720p, 10 fps, no audio) + `context` JSON `{exerciseId, equipment, plannedReps, phoneReps}` | `{reps, repTimes, confidence, trackFound, frames}` | SAM 3.1 video |
| `POST /photos/segment` | multipart: `image` (JPEG) | `{width, height, box: [x,y,w,h], maskPng: base64}` | SAM 3.1 image |
| `POST /checkin/draft` | `{template, facts: WeekFacts, notes: [VoiceNote], training: TrainingSummary, lastCheckIn?: CheckInDraft, styleExamples: [String]}` | `CheckInDraft` | Spark tool calling, then a validator |
| `POST /checkin/answer` | multipart: `audio` + `{fieldId, field: FieldSpec, styleExamples}` | `{transcript, answer: FieldAnswer}` | Transcribe, then Spark structured output |
| `POST /checkin/render` | `{template, draft}` | `{text}`, the WhatsApp message | none (templating) |
| `POST /coach/reply` | `{text, plan: PlanState}`, or multipart `audio` (a WhatsApp voice note: `.opus`/`.ogg`, `.m4a` or `.wav`) + `plan` JSON | `{transcript, changes: [PlanChange], unclear: [String], cues: [VoiceCue]}` | Transcribe (audio only, per segment), then Spark structured output, then a validator |

**Conversions on the backend:** `.xlsx` → rows with `openpyxl`, then CSV text into the Spark prompt. Never send raw binary to Spark. For any audio that isn't WAV 16 kHz or 24 kHz mono 16-bit, convert with ffmpeg: `ffmpeg -i in.opus -ac 1 -ar 16000 -c:a pcm_s16le out.wav`. WhatsApp voice notes are Opus in an Ogg container. ffmpeg is on the Mac, and the backend's Dockerfile must install it too. Split audio longer than 9 minutes into chunks and join the transcripts.

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
{ "intent": "rpe | reps | setLoad | loadDelta | skipSet | nextExercise | note | undo | pause | resume | endSession | starting | endSet | replayCue | yes | no | answer | unknown",
  "number": 9, "text": "digestion's been off since Wednesday", "fieldId": null, "confidence": 0.0 }
```

If `confidence` is under 0.7, or the intent is `unknown`, the app asks back ("Did you say 215?") and does nothing yet.

**`/sets/count`** lives in `backend/app/reps.py`: pure NumPy and SciPy, tested on fixtures.
1. Call SAM 3.1 on the video with the equipment's prompt: barbell "weight plate", dumbbell "dumbbell", machine and cable "weight stack", bodyweight "person". Keep the object tracked on the most frames. If no object is tracked on at least 80% of frames, return `trackFound: false` and no count.
2. Per frame, take the mask centroid (x, y) in pixels, with the frame's real timestamp from the file (rule 7).
3. Find the main direction of motion (the first principal component of the centroids) and project onto it. Fill gaps up to 0.5 s by interpolation, then smooth with a Savitzky–Golay filter (window 5, order 2).
4. The rest position is the median of the first and last 0.5 s. Let d(t) = |projection − rest position|.
5. Reps are the peaks of d(t) (`scipy.signal.find_peaks`) with prominence of at least 35% of d's 95th percentile, at least 0.8 s apart. A half rep that doesn't reach the prominence isn't counted.
6. `confidence` = tracked-frame share × (1 − min(1, coefficient of variation of the rep intervals)), clipped to 0–1. Under 0.6 is low.
7. Return `repTimes` at the peaks. Tune the 35% and 0.8 s on the G7 clips and keep the tuned values as constants in `reps.py`.

**`/coach/reply`** lives in `backend/app/coach.py`.
1. Build the addressable items from `PlanState`: each has a path, a plain label ("Training-day carbs") and its current value. Program items are per day and exercise (`program.<dayId>.<exerciseId>`, plus `.sets`, `.reps`, `.load`, `.rest`); a program change applies to every remaining week from `appliesFrom`.
2. The structured-output schema is built per request, with `path` as an enum of those paths, so the model can't invent an item.
3. The validator checks every change:
   - `quote` appears in the transcript, ignoring case and whitespace.
   - `amount`, when present, appears in `quote` as digits or number words.
   - For a swap or an addition, the new item's name appears in `quote`.
   - `before` and `after` are filled by code from the plan, `op` and `amount`, never taken from the model.
   - A change that fails any check moves to `unclear` with its quote. Never drop one silently.
4. A change whose `appliesFrom` is already past applies from the next session.
5. **Voice cues** (only when `cuesEnabled` is true in the request):
   - For audio, cut the note at pauses with `ffmpeg -af silencedetect=noise=-35dB:d=0.4`. Merge segments under 1.5 s into a neighbour, and split segments over 15 s at their longest internal pause.
   - Transcribe each segment (file mode). The reply's `transcript` is the segments joined, so the change parser sees the same text.
   - For text, the segments are its sentences.
   - Spark labels each segment with `exerciseId` (a per-request enum of the plan's exercise ids, plus `"none"`) and `isCue`. A cue is his instruction about how to do an exercise: tempo, form, setup, effort. A plan change is never a cue; it goes to `changes`.
   - Return one `VoiceCue` per cue segment with its `startSec`/`endSec`. The validator drops a cue whose `exerciseId` isn't in the plan.

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
- The coach's voice notes use the same call, after the ffmpeg conversion in §5.
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

**SAM 3.1 on video** (rep counting; bar speed if it comes back from the stretch list):
- The existing `meta.segment_video()` and `scripts/sam_probe.py`.
- Prompt by equipment: "weight plate", "dumbbell", "weight stack", "person" (§5, `/sets/count`).
- Send 720p at 10 fps with no audio track. Cost: $0.20 per 1,000 frames with a 50-frame minimum per request, so a 40-second set is about 400 frames, about $0.08, and a 20-set session about $1.60. Repeat tests run on saved fixtures.
- Timestamps come from the file (`ffprobe -show_frames`), never frame index ÷ 10.

Prompt caching is automatic for repeated prefixes. Keep system prompts and schemas byte-identical across calls.

---

## 7. iOS implementation notes

### Project config (`ios/project.yml` + `ios/Config/Info.plist`)
- Add the HealthKit capability: an entitlements file with `com.apple.developer.healthkit = true`, referenced from `project.yml`.
- Add `NSHealthShareUsageDescription`: "Setecho reads your weight, nutrition, steps and sleep to fill in your coach's check-in."
- Camera, microphone and photo strings already exist. Update the camera string to "Setecho films your sets and takes your check-in photos."
- Background modes: `audio`, so the session keeps listening and speaking with the screen locked.
- A share extension target, `SetechoShare`, and the app group `group.com.getsetecho.app` on both targets (§7, Coach reply).
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
- **Weight fallback (P2):** Withings only writes to Apple Health when its app is opened. When the wrap-up starts or the check-in is drafted and there's no `bodyMass` sample since 4 AM that day, say and show "Open Withings once to sync today's weight". Offer an "Open Withings" link only if `canOpenURL` confirms a scheme for the Withings app; never guess one. Re-query when Setecho comes back to the foreground. The wrap-up carries on meanwhile. Once the direct connection is in (P6, Withings direct), it replaces this.

### Deterministic check-in fields (computed in Swift, sent as `WeekFacts`, rendered by the backend)

| Field | Rule (defaults the athlete can change in Settings) |
|---|---|
| Accuracy on plan | Days within macro tolerance and sessions completed vs. planned, shown as "100% (7 of 7 days, 5 of 5 sessions)" |
| Nutrition consistency | A day is on plan if kcal is within ±5% of that day type's target and protein, carbs and fat are each within ±10 g. Day type = training if a Setecho session happened that day or the program schedules lifting. |
| Training consistency | Sessions done vs. scheduled, plus PRs (a set heavier, or the same load for more reps, than the best for that exercise in earlier weeks logged in Setecho; with no history yet, report no PRs rather than guess) |
| Current cardio protocol | The protocol text from the current plan (`PlanState.cardioProtocol`), plus logged LISS: "25 min LISS × 2 (logged: 2 sessions, 51 min). Steps: avg 10.2k" |
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
- **Start:** the wrist signal's range over the last 2 s exceeds 0.08, with at least one direction reversal. Set the state to Recording. The set's real start is the last moment before that when the signal was still (range under 0.03 for 1 s).
- **End:** range under 0.03 for 4 s. The set's real end is the last moment the signal moved. Log the set (Rep counting, below).
- **Recording:** the camera records continuously, and each file runs from one set's end to the next set's end, so every set has pre-roll. At set end, stop the file and start the next one right away. Then export the window [start − 3 s, end + 1 s] twice: at full quality as the set's clip, and at 720p, 10 fps with no audio for `/sets/count` (`AVAssetExportSession` with a video composition, `frameDuration` 1/10 s). Delete the untrimmed file.
- **Always available fallback:** the voice intents `starting` and `endSet`.
- **Tune the thresholds on real footage.** Save the wrist series from each test session to a debug JSON file so it can be tuned offline.
- **Logging rule:** load comes from the plan, or the last voice override for that exercise. Reps follow Rep counting, below. RPE is spoken.
- **Callout template** (deterministic, no model): "8 reps. Next, 225 for 8. Rest two thirty." Then show the rest countdown; the rest time comes from the program, defaulting to 150 s.
- **Undo:** keep a stack of applied actions. "Undo" reverts the last one and says what it reverted.

### Rep counting
- **Phone count** (`RepCounter.swift`, mirroring `reps.py` steps 4–5): over the set window, use the joint (wrists, elbows, hips, knees, ankles, Vision confidence above 0.3) whose smoothed y has the largest range, then count the same way as the backend at 15 fps. If no joint moves more than 0.05, or tracking drops for more than 20% of the set, there's no phone count and the set logs the plan's reps.
- **At set end,** speak the phone count first: "8 reps. Next, 225 for 8. Rest two thirty." If it's under the plan's minimum, say so as a fact: "6 reps, 2 short of plan."
- **Measured count:** upload the 720p clip to `/sets/count` as soon as it's exported. When it returns during the same rest:
  - **Same number:** say nothing. The set's chip changes from "Phone" to "Measured".
  - **Different, confidence 0.6 or more:** update the log (undoable) and say "Set 3: 7, not 8." `VoiceEcho` shows it.
  - **Different, confidence under 0.6:** ask "Set 3, was that 7 or 8?" No answer keeps the phone count.
  - **Arrives after the next set started:** hold it, and apply it at the next rest. Never speak during a set.
- **"That was N" always wins** and sets the source to `.spoken`.
- **Offline or failed:** retry the upload in the background for up to 10 minutes. The phone count stands.
- **Shared tests:** `RepCounter` and `reps.py` run on the same synthetic series in `backend/tests/fixtures/reps/` and must give the same counts.

### Session inputs: camera, watch and voice
A session never requires the tripod. Three inputs feed the same `SessionEngine`, in any combination, and the athlete never picks a mode.
- **Camera on duty:** body pose finds at least 6 joints with confidence above 0.3 in at least half the frames of the last 10 s. Otherwise the camera is off duty: it neither starts nor ends sets, and no clip is kept. A pocketed phone is simply off duty.
- **Set start:** the first of camera start, watch `setStart` and voice "starting". A start from another input within 3 s of the first is the same set.
- **Set end:** voice ("done", "that was 8", `endSet`) ends it at once. Otherwise the camera's end when it's on duty, else the watch's `setEnd`.
- **Reps, highest first:** You said → Measured (SAM, confidence ≥ 0.6) → Phone (camera) → Watch (confidence ≥ 0.6) → Plan. The set's `SourceChip` shows which one won.
- **No camera and no watch:** voice starts and ends sets. When the athlete says "next exercise" with planned sets still unlogged, ask "Log the other 2 sets of incline press from the plan?" "Yes" logs them with source Plan; "no" skips them.
- **The rest timer** starts at set end, whichever input ended it.
- **HUD:** the state line shows which inputs are live (camera, watch), so the athlete can tell at a glance (DESIGN.md, `InputStatus`).
- **An input dropping out never stops the session.** A lost watch shows "Watch off" and the session carries on with camera and voice.

### Garmin watch (Connect IQ app)
The athlete wears a Garmin Venu 4. The watch app is a second, small app in Monkey C under `watch/`. It does motion, haptics and messages only: no network, no models.
- **Project:** `watch/manifest.xml` (a watch app; permissions `Sensor`, `Communications`, `Fit`; products: the Venu 4 device ids listed by the SDK Manager, both sizes), `watch/monkey.jungle`, `watch/source/*.mc`, `watch/resources/`. The app UUID in the manifest is the same constant the iOS side uses.
- **Make targets:** `make watch` builds `watch/bin/SetechoWatch.prg` with `monkeyc` and the developer key at `~/.garmin/developer_key.der` (outside the repo). `make watch-sim` runs it in the Connect IQ simulator. The human copies the `.prg` to the watch's `GARMIN/APPS` folder over USB (OpenMTP on macOS if the watch mounts as MTP).
- **Motion:** `Sensor.registerSensorDataListener` with the accelerometer at 25 Hz and a 1 s period. Keep a ring buffer of the last 90 s.
  - **Set start:** the standard deviation of acceleration magnitude over the last 2 s rises above `startStd`, with at least 2 direction reversals on the dominant axis. The start time is the first sample of that window.
  - **Set end:** below `endStd` for 4 s.
  - **Reps:** on the axis with the largest variance over the set window, a 5-sample moving average, then the same peak rule as `reps.py` (prominence ≥ 35% of the range, ≥ 0.8 s apart). Confidence comes from the spread of rep intervals, as in `reps.py`.
  - **Thresholds come from the phone** in the `config` message at session start, so tuning never needs a new sideload. Start from `startStd` 120 mg and `endStd` 40 mg, and tune on real sets.
- **Messages:** dictionaries through `Communications.transmit` (watch → phone) and `registerForPhoneAppMessages` (phone → watch), each under 1 KB.
  - **Watch → phone:** `{"t":"hello","v":1}`, `{"t":"setStart","at":ms}`, `{"t":"setEnd","startAt":ms,"at":ms,"reps":8,"conf":0.72}`, `{"t":"tap","a":"done"|"undo"|"skipRest"}`, `{"t":"pong","at":watchMs,"echo":phoneMs}`.
  - **Phone → watch:** `{"t":"config","startStd":…,"endStd":…}`, `{"t":"ping","at":phoneMs}`, `{"t":"target","ex":"Incline DB press","load":"70","reps":"8","set":"2/4"}`, `{"t":"logged","reps":8,"src":"Watch"}`, `{"t":"rest","endsAt":ms}`, `{"t":"end"}`.
  - **Clock:** the phone pings at session start and converts watch times to phone time from the round trip. The link through the Garmin Connect app can take a few seconds, so never rely on arrival time.
- **Screens and input:** DESIGN.md, Watch. A tap anywhere is "done" (ends the set, or skips the rest). The back button is undo, with a confirm on screen.
- **Haptics:** `Attention.vibrate`, short when a set is logged, long when rest ends.
- **Garmin stats stay:** `ActivityRecording` records the session as a strength-training activity, started with the session and saved at the end. Heart rate and the workout reach Garmin Connect as usual.
- **iOS:** `WatchService` wraps Garmin's Connect IQ companion SDK for iOS (`https://github.com/garmin/connectiq-companion-app-sdk-ios`; follow its `documentation/`). Expect device selection to go through the Garmin Connect app and come back through a URL scheme. Add that scheme and any query schemes the SDK needs to `project.yml`. Expose `events: AsyncStream<WatchEvent>` and `send(_:)`.
- **Connections screen** (More → Connections): Garmin watch with Connect, status, last message time and "Test buzz". DESIGN.md has the layout.
- **Debug:** append each set's watch summary and the matching camera/plan result to the session debug JSON, for tuning offline.

### Coach voice cues (optional)
His instructions about a specific exercise, played in his own voice before that exercise. Off with one switch: Settings → "Coach's voice in sessions", on by default. When it's off, the phone sends `cuesEnabled: false` and nothing is cut or played.
1. **Cutting:** `/coach/reply` returns `cues` with times. The phone cuts each one from its local copy of the voice note with `AVAssetExportSession` (`timeRange`, `.m4a`) into `media/cues/`. Text replies have no audio; iOS speech reads them as "Coach says: …".
2. **Review:** the Coach reply screen lists them under "In your sessions" (DESIGN.md, `CueRow`). Only approved cues play.
3. **Playback:** when an exercise becomes current and the state is Ready, before its first set of the session, play its approved cue once. Duck the music, play, restore, exactly like a callout. Never during a set. "Say that again" (`replayCue`) replays the last cue. `VoiceEcho` shows "Coach · Incline DB press".
4. **Lifetime:** cues stay active until the coach's next reply replaces them.

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

### Coach reply
- **The first `PlanState`** comes from the imports: the program, plus the macro targets and cardio protocol read out of the form's carried blocks (part of `/import/form`'s structured output), confirmed on the Form review screen.

1. **Getting the reply in.** Build the in-app path first: Today or More → "Add coach reply" → paste text, or pick an audio file (`.fileImporter` allowing `.audio` and `.opus`). Then the `SetechoShare` share extension: it accepts text or one audio file, writes it to the app group's `inbox/`, and tells the athlete "Sent to Setecho." The app checks the inbox at launch and when it comes to the foreground.
2. **Read it.** Call `/coach/reply` with the reply and the current `PlanState`. Show the Coach reply screen (DESIGN.md).
3. **Apply.** Approving builds a new `PlanState` version from the approved changes, in Swift, deterministically. A macro or supplement change also edits the carried block's text: replace the old value on the matching line when it appears there exactly once; otherwise open the block for a manual edit. Keep every version. History → Plan changes can revert the latest one.
4. **Everything downstream reads the new version:** Today's session, the Session targets, `WeekFacts.targets`, the cardio protocol, and the check-in's carried blocks.
5. **MacroFactor:** Setecho can't change MacroFactor's targets, and Apple Health doesn't carry them. After a macro change is applied, Today shows "Update MacroFactor: training-day carbs 250 → 225 g" until the athlete marks it done.

### Clips for your coach (stretch)
This replaces any AI form or posing critique. Setecho gives the coach evidence, never a verdict, and **no model is involved**.

- **Selection rule (deterministic, in Swift):** from the check-in week's sessions, pick:
  1. the last logged set of each session's first exercise
  2. any set where logged reps < planned reps (or < `repsMin`)
- Keep at most 4, preferring rule 2, then the most recent.
- **Each clip:**
  - trim the set's MOV to its `startedAt − 1 s … endedAt + 1 s`
  - export as H.264 720p with `AVAssetExportSession`, aiming for 20 MB or less
  - tag it with a reason: "Last set · Bench press" or "6 of 8 reps · Bench press, set 4"
- **UI:** a "Clips for your coach" card on Review and send. One row per clip, with a thumbnail, the reason as a secondary line, and a remove button. The athlete can add any other set from History.
- **Message:** `/checkin/render` appends one line after the coach's last field, "Clips attached: Bench press set 4 (6 of 8 reps), Squat set 3", and the clips join the share items after the collage.
- **Risk:** check that WhatsApp accepts the image, the text and several videos in one share. If not, share the clips as a second batch right after the check-in.

---

## 8. Model prompts

Keep the prompts in `backend/app/prompts.py` and the schemas in `backend/app/schemas.py`, versioned. These are the starting texts.

**Import program** (`/import/program`, structured output, schema = `Program` minus `importedAt`):

> You convert a strength coach's training spreadsheet into JSON. Copy exercise names, set counts, reps, rep ranges, loads, RPE/RIR and rest times exactly as written. Never invent a value. If a cell is ambiguous, keep your best reading and add an entry to `flags` explaining what is unclear. Weeks and days follow the sheet's own order and names. Set each exercise's `equipment` from its name (barbell, dumbbell, machine, cable or bodyweight); if the name doesn't make it clear, pick the likeliest and add a flag.

**Import form** (`/import/form`, structured output, schema = `CheckInTemplate`):

> You convert a coach's weekly check-in form into a template. Keep every field label exactly as written, in order, including hint text in parentheses as `prompt`. Blocks that are the coach's instructions rather than questions (macro targets, supplement lists) become `carriedBlocks` with their text copied verbatim. For each field, choose `kind` and a `source` from this list of available data keys: {DataKey list with one-line meanings}. Use `voice` when no data key fits. Never answer the fields. Also copy the macro targets (training and rest day kcal, protein, carbs, fat) and the cardio protocol out of those blocks into `targets` and `cardioProtocol`; if a number isn't clearly written there, leave it null.

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

**Coach reply** (`/coach/reply`, structured output = `{changes: [...], unclear: [String]}`, with `path` as a per-request enum):

> You read a strength coach's reply to his athlete's weekly check-in and list every change he makes to the athlete's plan. The plan's items are listed with a path, a label and the current value: {items}. For each change, pick the item's path, the operation, and the number he said, and copy his exact words into `quote`. List only changes he actually makes; a question, praise or "let's see how it goes" is not a change. If he changes something that isn't in the list, or you can't tell which item he means, put his sentence in `unclear`. Never work out a new value and never suggest one.

**Cue labels** (`/coach/reply`, structured output = `{segments: [{index, exerciseId, isCue}]}`, `exerciseId` as a per-request enum):

> Each numbered segment is one sentence or phrase from a coach's reply. For each, give the exercise it's about, from this list: {exercises}, or "none". Mark `isCue` true only when it tells the athlete how to perform that exercise (tempo, form, setup, effort). A change to sets, reps, load, macros, cardio or supplements is not a cue. Never rewrite his words.

---

## 9. Build order (Oct 27 – Nov 4)

Each phase ends with its checks passing, a commit, and a TestFlight build the human can take to the gym. Report after each phase: what passed, what didn't, what you need from the human.

**Stretch items** happen only when P1–P5 are green, in this order: Withings direct, WhatsApp history import, set clips turned into content, clips for your coach, bar speed. Posing practice is out of this build.

### Status (Oct 27 morning)
- **Built Oct 26:** everything in §2. The backend probes for G4 (SAM photo), G5 (import) and the voice smoke ran live; their fixtures are in `backend/tests/fixtures/`.
- **Decided Oct 26** (§13): the spreadsheet arrives as a Google Sheets link; the check-in is due **Thursday morning**; the backend is on Fly.
- **Untested:** every phone flow, in a real gym or at home.

### Gates still open
- [ ] **G1 organizers.** The human confirms in writing that an app that counts reps from phone video, to log them for a human coach, isn't a "sports analyzer or coach".
- [ ] **G2 audio, G3 Apple Health, G6 share.** The human runs the probes from TestFlight (More → Probes). G6 also covers exporting one of the coach's voice notes out of WhatsApp.
- [ ] **G5, extended.** Run `import_probe` on two other coaches' check-in forms the human brings, and `reply_probe` on two of his real past replies.
- [ ] **G7 SAM reps.** `scripts/sam_reps_probe.py <mov> --equipment barbell` (built in P1) downscales the clip to 720p at 10 fps, calls SAM with "weight plate", runs `reps.py`, and prints the count, the rep times and the seconds from upload to count. Raw output goes to `backend/private/`; `--fixture` saves only the per-frame centroid series. **Pass:** the count matches the human's count of a real set of 8, one plate is tracked on every frame, and it takes under 60 s.
- [ ] **G8 watch** (Wed Oct 28). A minimal watch app sends `setEnd` with a wrist count after each set to a probe screen under More → Probes, which shows each message and its delay. **Pass:** messages arrive within 3 s, and counts match on 3 sets each of bench press, rows and curls. **Fallback:** camera and voice only; the watch moves to the stretch list.

### P1 — Rep counting (Tue Oct 27)
- [ ] `scripts/sam_reps_probe.py` (G7: §6 SAM on video, §5 `/sets/count`).
- [ ] `backend/app/reps.py` and `/sets/count`, with the synthetic series and tests.
- [ ] `SetDetector`: continuous recording split at set ends, the real start and end, and the two exports (§7, Set detection). Today it starts `AVCaptureMovieFileOutput` at set start, which loses the first rep.
- [ ] `RepCounter` on the pose frames, extending `WristSignal` to every joint.
- [ ] `LoggedSet.repCount` with its migration; the measured-count rules and callouts; `SourceChip` on Session and History.
- **Done when:** G7 passes on the human's clip, and a simulated session in `SessionEngineTests` logs a phone count, then applies a measured correction with undo.

### P2 — Coach reply and voice cues (Wed Oct 28)
This must ship to TestFlight by Wednesday evening: the coach's reply to Thursday's check-in is the first real test.
- [ ] `PlanState` and its migration (§4). Every plan reader goes through `store.plan`.
- [ ] `/coach/reply` with changes, unclear items and cues; the validator; prompts; tests on synthetic replies.
- [ ] The Coach reply screen, the Today card, the MacroFactor reminder, and revert under History → Plan changes.
- [ ] Getting replies in: paste and audio file import first, then the `SetechoShare` share extension.
- [ ] Voice cues: cutting, review, playback rules, `replayCue`, and the Settings switch.
- [ ] The weight fallback (§7, HealthKit), before Thursday's check-in.
- **Done when:** two of his past replies (one text, one voice note) produce the right changes and cues, and a simulated session plays the cue before the right exercise and never during a set.

### P3 — First real check-in (Wed Oct 28 evening – Thu Oct 29 morning)
- **The human:** wrap-up from the Wednesday 7 PM reminder, photo session Thursday morning, review, and send. Screen-record review and send.
- **The agent:** fixes only, from whatever broke.
- **When the coach replies,** the human shares it in and screen-records the Coach reply screen.

### P4 — Garmin watch (Thu Oct 29 – Fri Oct 30)
- [ ] The watch app (§7, Garmin watch), starting from the G8 probe.
- [ ] `WatchService`, the Connections screen, and the input rules (§7, Session inputs), with the `config` thresholds sent from the phone.
- [ ] Watch summaries in the session debug JSON.
- **Done when:** a real session with the tripod on some exercises and the phone in a pocket for the rest has zero taps after Start, and every set is logged with the right source.

### P5 — Tune (Fri Oct 30 – Sat Oct 31)
- [ ] Thresholds for `SetDetector`, `RepCounter` and the watch, from the debug JSON of real sessions.
- [ ] Fixes from P3 and P4.
- **Done when:** three real sessions in a row where every set's reps are right or were fixed by voice.

### P6 — Stretch (Sat Oct 31 – Sun Nov 1), only if P1–P5 are green
In the order above. Specs:
- **Withings direct.** The athlete's scale is on Wi-Fi, so each weigh-in reaches Withings' servers within moments. Reading it from Withings' public API means the Withings app never has to be opened. About half a day.
  - **Human:** registers a Public API app on Withings' developer dashboard (no contract), with the callback `https://setecho-api.fly.dev/withings/callback`, and sets `WITHINGS_CLIENT_ID` and `WITHINGS_CLIENT_SECRET` as Fly secrets. Never in the repo.
  - **Sign-in:** the phone opens `https://account.withings.com/oauth2_user/authorize2` (scope `user.metrics`, a random `state`) in `ASWebAuthenticationSession`.
    - `GET /withings/callback` only redirects to `setecho://withings?code=…&state=…`.
    - The phone checks `state` and posts the code to `POST /withings/token` at once, because the code expires in 30 s.
    - The backend exchanges it at `https://wbsapi.withings.net/v2/oauth2` (`action=requesttoken`) and returns `{accessToken, refreshToken, expiresAt}`.
  - **Tokens:** the phone keeps them in the Keychain, so the backend stays stateless. The access token lasts 3 hours. `POST /withings/token` with `{refreshToken}` refreshes it. Withings rotates the refresh token, and the old one stops working 8 hours later, so save the new one every time.
  - **Weights:** `POST /withings/weights` `{accessToken, lastUpdate}` calls `https://wbsapi.withings.net/measure` (`action=getmeas`, `meastypes=1`, `category=1`, `lastupdate`).
    - Decode `value × 10^unit` kg, convert to lb, and return `[{at, lb}]`.
    - Follow `more`/`offset` until `more` is 0.
  - **When:** fetch when Setecho comes to the foreground and when the check-in is drafted, never more than once every 10 minutes (Withings' rule). No webhooks: they'd need a stateful backend and push, and the check-in only needs the weight when it's drafted.
  - **HealthService:** weight comes from Withings direct when connected, else Apple Health, with provenance "Withings" vs "Withings via Apple Health". If both have the same weigh-in, keep the direct one.
  - **Connections:** a Withings card (DESIGN.md).
  - **Tests:** value/unit decoding, kg → lb, pagination, refresh rotation, and the fallback to Apple Health when the token is missing or refused.
- **WhatsApp history import.** The athlete exports the coach chat in WhatsApp (Export Chat → Include Media) and shares the ZIP in.
  - Parse `_chat.txt` into messages: timestamp, sender, text, attachment. Handle both date formats (`[10/19/26, 7:42:11 AM]` and `[2026-10-19, 07:42:11]`), multi-line messages, and `<Media omitted>`.
  - Ask once which sender is the athlete and which is the coach.
  - Classify each message: check-in, coach reply, program file, photo, other. Keep only the first four; drop the rest on the backend.
  - Past check-ins become history values through the form template. His replies run through `/coach/reply` against the plan as it stood then, building a timeline of changes with his quotes. Photo collages join the photo timeline. Past check-ins also become the check-in agent's `styleExamples`.
  - Re-importing skips messages already seen (timestamp + sender + text).
- **Set clips turned into content.** For a set the athlete picks in History:
  - Render a vertical post on the backend with OpenCV and ffmpeg: the lifter kept bright and the background dimmed (SAM "person" masks), the plate's path drawn from the `/sets/count` track, a rep counter that ticks at the measured `repTimes`, and the load and prep week as text.
  - No judgement words anywhere.
  - Return an MP4 for the share sheet.

### P7 — Rehearsal and freeze (Mon Nov 2)
- [ ] A full end-to-end run: a session mixing tripod and pocket, photos, check-in, coach reply. Fix bugs only.
- [ ] Feature freeze tonight.

### P8 — Film (Tue Nov 3)
- [ ] The human films the gym and photo segments. The check-in and coach reply segments use the P3 recordings.

### P9 — Submit (Wed Nov 4)
- [ ] The README states what was built during Oct 26 – Nov 4 and which Meta model does what.
- [ ] Repo flipped public. Video and write-up submitted by 9:00 PM ET. The human edits the video.

---

## 10. Tests
- **Backend:** `make test` stays offline. Save real model outputs from the probes into `backend/tests/fixtures/`, then test parsing, validation and rendering against them.
- **Required tests:**
  - the render reproduces the form order and carried blocks exactly
  - the validator flags a number not in `WeekFacts`
  - the voice-intent mapping covers every intent
  - the WAV header writer produces 16 kHz mono 16-bit
  - `reps.py` counts the synthetic series and the saved G7 centroid series correctly, including a paused rep and a half rep
  - the coach-reply validator moves a change to `unclear` when its quote isn't in the transcript, its amount isn't in the quote, or its path isn't in the plan
  - `before` and `after` are computed by code for every `op`
  - a generated Opus file converts to 16 kHz mono 16-bit WAV (skipped if ffmpeg is missing)
  - cue segmentation merges and splits segments by the §5 rules, and a cue with an unknown `exerciseId` is dropped
- **iOS:** `make ios-test`. Unit-test the adherence and day-type rules, PR detection, the set logging rules, undo, the collage layout math, the HealthKit aggregation, `RepCounter` on the shared series, the measured-count rules, each change kind's apply logic and plan revert, the `PlanState` and `repCount` migrations, the input rules in §7 (every start/end/reps precedence case), watch message decoding and clock conversion, and cue playback timing (Ready only, once per session, never during a set), all with synthetic samples.
- **Never** hit the live API in tests.

## 11. Privacy and repo hygiene (the repo becomes public)
- **Never commit:**
  - the athlete's photos, set videos or audio
  - real Health values or real check-in answers
  - the coach's name, phone number, replies or voice notes (`/coach/reply` fixtures are synthetic replies written for the tests)
  - API keys, `.env` files or `Local.xcconfig`
- `.gitignore` already blocks clips, `.env` and `Local.xcconfig`. Add `*.wav`, `*.opus`, `*.ogg`, `*.m4a`, `*.jpg` outside `design/`, and `ios/Probes/output/`.
- **Fixtures use synthetic values.** The form fixture keeps the coach's field labels, with placeholder numbers for macro targets and supplement doses.
- Photos go to Meta only through `/photos/segment`, set clips only through `/sets/count` (downscaled, no audio), and the coach's voice notes only through `/coach/reply`. All Standard tier: gyms have bystanders. Cut cue clips of the coach's voice stay on the phone, under `media/cues/`. Withings tokens live in the Keychain, never on the backend or in the repo.

## 12. Things only the human can do
- Put `MODEL_API_KEY` in `~/.zshrc`, claim the $150 credits, and set a spend limit.
- Set the Apple team ID in `Local.xcconfig`, and test on the real iPhone, since HealthKit and the DJI mic need a device.
- Create the backend host account and deploy.
- Keep the GitHub repo private while building (run `git remote add origin https://github.com/Lyquifyy/setecho.git` when ready), and make it public before submitting.
- Ask the office-hours question, and get the coach's OK to appear in the demo.
- Tell the coach his voice notes are transcribed through Meta's API, and collect two of his past replies (one text, one voice note) for G5 and P2.
- Hand-count every set during the gym tests.
- Garmin setup (Wed Oct 28, about an hour): install the Connect IQ SDK Manager, the SDK and the Venu 4 device files; generate a developer key outside the repo; install OpenMTP if the watch mounts as MTP; sideload the G8 probe.
- Ask the coach whether his voice can play in your sessions, and appear in the demo.
- Bring two other coaches' check-in forms for G5.
- For Withings direct (stretch): register the Withings developer app and set its two Fly secrets.
- Do the physical tests: the gym sessions, photo rounds and WhatsApp send.

## 13. Defaults for open questions (change when the human answers)
| Question | Default |
|---|---|
| How the spreadsheet arrives | **Decided Oct 26: a Google Sheets link.** The backend fetches the sheet's CSV export (`/export?format=csv`); the sheet must be shared "anyone with the link". A `.csv`/`.xlsx` file, pasted text and a screenshot stay as fallbacks |
| Check-in day | **Decided Oct 26: Thursday morning**; wrap-up reminder Wednesday 7 PM |
| G1 organizers | **Decided Oct 26: not a sports analyzer or coach.** Human confirms in writing on Oct 27 |
| Gates G2–G6 | **Decided Oct 26: build on the plan's defaults** and test on the phone from TestFlight, not from the Mac. The probe screens live behind the More menu until the P7 freeze (Mon Nov 2) |
| Collage layout | 2×2: front, right / back, left |
| "Current body weight" | Check-in morning weigh-in |
| Rest time when the sheet has none | 150 s |
| Macro tolerance | kcal ±5%; protein, carbs and fat ±10 g |
| Proposed changes on the review screen | Checked; the "Apply" tap is the approval |
| A change with no start date | Applies from the next session |
| Reps in the log | You said, then Measured, then Phone, then Watch, then Plan (§7, Session inputs) |
| Coach's voice in sessions | On; Settings switch, plus a checkbox per cue |
| Watch thresholds | `startStd` 120 mg, `endStd` 40 mg, sent from the phone; tune in P5 |
| Tagline | Unchanged until the human decides |
