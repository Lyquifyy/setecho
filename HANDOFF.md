# Setecho — build handoff for a coding agent

**Read order:** `AGENTS.md` (rules) → this file (what to build and how) → `DESIGN.md` (screens and components). The plan of record with the schedule is the Claude Doc "Setecho hackathon build plan". If anything here conflicts with `AGENTS.md`, `AGENTS.md` wins.

**Start here (Oct 27):** most of the app was built on Oct 26. §9 lists what exists, what's untested, and the build order for the rest of the week: SAM as the count of record, Check-in morning, the coach reply loop, then measured effort with the coach's rules and the spotter voice. Stretch items come after, starting with Machine taken.

**How to work:**
- Build milestone by milestone, in order.
- After each milestone, run its acceptance checks, then stop and report: what passed, what didn't, what you need from the human.
- Never skip a gate. Never start a stretch item while a must-have is failing.
- Commit after each working piece with a clear message. The commit history is part of the hackathon submission.

---

## 1. The product

Setecho takes the manual work out of a coached bodybuilding prep. The athlete has a human coach who sends a training program as a spreadsheet and expects a check-in in WhatsApp every week or two.

Setecho:
1. **Imports the coach's material once:** the spreadsheet program, the check-in form, and the coach's own rules for adjusting loads. The sheet's days become the training cycle in order, and rest days stay rest days. Blocks the coach adds on top of days ("abs 2x per week", "vacuums 4x per week upon waking") become add-ons that join the days the athlete picks, so one day can hold two workouts.
2. **Logs training hands-free.** For the lifts the athlete wants measured or filmed, the phone goes on a tripod: it detects each set, and SAM 3.1 counts the reps from the set's video and measures how hard the set was from how much the reps slowed down. Without the tripod, the athlete's voice logs the set. A DJI wireless mic takes spoken commands, and a spotter's voice talks over the athlete's music. A Garmin watch app is a stretch item.
3. **Suggests the next set's weight with the coach's own rules.** When a set lands above or below the coach's target effort, Setecho applies the adjustment rule the coach wrote, or the athlete confirmed as his, and says it during rest. The athlete decides, and the coach sees every adjustment in the check-in. **Stretch:** when a machine is taken, it offers the same lift on other equipment, or moves up a later lift from today that won't tire a muscle a heavier lift still needs, in the order the coach said he prefers. Every swap and reorder goes into the check-in. For each check-in it also crops the two sets the athlete flagged for the coach's video review to just the reps.
4. **Takes the four check-in photos hands-free,** in his order, and sends them exactly as taken, at full resolution. No collage, no cropping, no alignment (decided Oct 27 evening).
5. **Fills half the check-in from data.** Weight (Withings), macros (MacroFactor), and steps and sleep (Garmin) all arrive through Apple Health. On check-in morning the rest is one hands-free conversation: Setecho asks for the weight, the photos and the rest of the coach's questions, and understands natural answers like "give me a couple of minutes".
6. **Sends the check-in to WhatsApp** in the coach's exact format and order: the plan message (macros, cardio, supplements), then the questionnaire with the photos, then the two videos.
7. **Turns the coach's reply into plan changes.** The athlete shares the coach's WhatsApp text or voice note into Setecho. Each change is listed next to the coach's exact words, and nothing changes until the athlete approves it. Optionally, the coach's own voice plays in the athlete's headphones before the exercise he talked about.

**Setecho is the spotter, not the coach.** It never writes the program, never judges form and never gives nutrition advice. A load suggestion only ever applies the coach's own rule, a machine-taken swap stays within the same lift or his own alternates, the athlete makes the call, and the coach sees every adjustment. That keeps it as far from the hackathon's "avoid" list ("sports analyzers or coaches", "AI nutrition coach") as this feature allows, and the organizers are asked about the suggestions and the swaps directly (§9, G1). It's also the product truth: the human coach coaches.

**Hackathon facts:**
- Meta Global AI Developer Hackathon, indie track.
- Build period: from the end of the kickoff stream (12:24 PM ET, Oct 26) to Nov 4, 2026.
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
| `ios/Probes/` | The M0 phone probes (audio, Apple Health, WhatsApp share), shipped inside the app under Settings → Developer. |
| `ios/project.yml` | XcodeGen. iOS 26, Swift 6 (strict concurrency), bundle id `com.getsetecho.app`. Never edit the `.xcodeproj`. `make testflight` uploads a build. |
| `backend/app/` | `/health`, `/import/program` (incl. Google Sheets links), `/import/form`, `/voice/command`, `/photos/segment`, `/checkin/draft`, `/checkin/answer`, `/checkin/render`. `meta.py` is the only Meta client. |
| Deploy | Fly app `setecho-api` at `https://setecho-api.fly.dev` (README, "Deploy the backend"). |
| `design/` | Approved boards and brand files, **local only**: gitignored and never committed (§11). Read-only. |

**Not built yet:** rep counting, the coach reply loop and voice cues, the Garmin watch app, and the stretch items. §9 has the order.

Commands: `make test`, `make lint`, `make dev`, `make smoke`, `make ios`, `make ios-test`, `make testflight`; add `make watch` and `make watch-sim` with the watch app (§7, Garmin watch).

---

## 3. Architecture

```
iPhone (Setecho app)                                Backend (FastAPI, stateless)            Meta Model API
- HealthKit reads (weight, macros, steps, sleep)    - holds MODEL_API_KEY                   - muse-spark-1.3
- camera + on-device set detection (Vision)   <-->  - /import/*   (Spark, structured)  -->  - muse-voice-transcribe-1.0
- fallback rep count from body pose                 - /sets/*     (SAM: reps and effort)    - sam-3.1
- audio: DJI mic in, AirPods out, iOS speech        - /voice/*    (Transcribe + Spark)
- photo session: on-device framing + stillness      - /photos/*   (SAM image masks)
- stores everything locally (JSON files)            - /checkin/*  (agent + validator)
- share sheet -> WhatsApp                           - /coach/*    (Transcribe + Spark + validator)
- share extension <- coach's WhatsApp replies       - /spotter/*  (Spark: spotter lines)
- (stretch) WatchService <-> Garmin Connect app <-> Setecho watch app (Venu 4)
```

- **The phone owns all data.** Program, template, sessions, sets, notes, photos and check-ins are stored on the device as Codable JSON under Application Support, plus JPEG and MOV files. The backend keeps nothing between requests.
- **The backend exists to hold the key and talk to Meta.** It also does deterministic work: rendering the check-in text and validating numbers.
- **The model never produces a number.** Numbers come from HealthKit, the training log, or the athlete's own words (extracted, then echoed back for confirmation).
- **No text-to-speech exists on Meta Model API,** so the voice is the phone's `AVSpeechSynthesizer` (§7, The spotter voice). **Every model the app calls at runtime must be Meta's** (the organizers, Oct 28; disclosing another doesn't change that), so there is no voice service. Every word it says is written by the app and Muse Spark.
- **Set clips are uploaded for counting, then dropped.** After each set the phone sends a small copy (720p, 15 fps, no audio) to `/sets/count`. The backend forwards it to SAM 3.1 and keeps nothing. The full-quality MOV stays on the phone.
- **Sets come from the camera and the athlete's voice,** plus the Garmin watch if that stretch item is built. Any combination works and nothing has to be switched; §7, Session inputs, has the rules.
- **SAM 3.1 is the count of record on tripod sets.** Its count and the set's measured effort are spoken during rest. The phone's own pose count is a silent fallback, used only when SAM fails or is slower than 60 s. What the athlete says ("that was 7") beats both.
- **A load suggestion only ever applies the coach's rule.** The rule engine is deterministic Swift; Muse Spark only puts its result into words (§7, Measured effort and the coach's rules).
- **Machine taken (stretch) is code, not the model.** `TakenEngine.swift` picks the options from the exercise tags confirmed at import and the coach's stated preference. Muse Spark only drafts the tags at import and understands what the athlete says (§7, Machine taken).
- **The coach's reply never changes anything by itself.** `/coach/reply` returns proposed changes. The phone applies only the ones the athlete approves, and keeps the previous plan so an applied reply can be reverted.

---

## 4. Data model

Swift `Codable` structs in `ios/Setecho/Models/`. The backend mirrors the same JSON with Pydantic models in `backend/app/schemas.py`. Field names are identical, in camelCase.

```swift
// Coach's program (from the spreadsheet)
struct Program: Codable { var name: String; var weeks: [ProgramWeek]; var addOns: [AddOn]; var importedAt: Date; var flags: [ImportFlag] }
struct ProgramWeek: Codable { var number: Int; var days: [ProgramDay] }
struct ProgramDay: Codable, Identifiable {
  var id: String; var name: String /* "Day 1", "Rest" */; var exercises: [PlannedExercise]
  var kind: DayKind                // .training, .rest: a rest day has no lifts and is never a session
  var cardio: String?              // his words for the day's cardio, e.g. "25 minutes of fasted LISS"
}
struct PlannedExercise: Codable, Identifiable {
  var id: String; var name: String; var sets: [PlannedSet]
  var equipment: Equipment        // .barbell, .dumbbell, .machine, .cable, .bodyweight: decides what SAM tracks
  var restSeconds: Int?            // from the sheet if present
  var notes: String?
  var tags: ExerciseTags?          // movement family, muscles and tier: drafted at import, confirmed once (Machine taken)
  var alternates: [Alternate]      // the coach's own "or" options, from the sheet or his replies; empty when he gave none
}
struct ExerciseTags: Codable {
  var family: String?              // a family id from ExerciseFamilies.json, e.g. "incline-press"; nil when none fits
  var primary: [Muscle]; var secondary: [Muscle]
  var tier: LiftTier               // .heavy (compound) or .light (isolation)
  var confirmed: Bool
}
enum Muscle: String, Codable, CaseIterable { case chest, frontDelts, sideDelts, rearDelts, triceps, biceps, forearms, lats, upperBack, traps, lowerBack, abs, quads, hamstrings, glutes, adductors, calves }
enum LiftTier: String, Codable { case heavy, light }
struct Alternate: Codable { var name: String; var quote: String; var source: String /* "Sheet, row 12" · "Coach's reply, Oct 29" */ }
struct PlannedSet: Codable {
  var reps: Int?; var repsMin: Int?; var repsMax: Int?; var loadLb: Double?; var rpe: Double?; var rir: Int?
  var seconds: Int?                // a timed set: a hold ("20 seconds", "60 sec each") or a duration ("5 minutes" = 300); reps stay nil
  var totalReps: Int?              // a rest-pause set's target ("20 total reps")
  var role: SetRole?               // .top, .backOff ("1 top set. 1 back down set"), .restPause; nil = a straight set
}  // "6-8 reps" = repsMin 6, repsMax 8
struct ImportFlag: Codable { var path: String /* "week 4 / Upper A / Bench / set 2" */; var message: String }
// A block the coach adds on top of days, outside the cycle (§7, Training cycle and add-ons)
struct AddOn: Codable, Identifiable {
  var id: String; var name: String /* "Abs", "Stomach vacuums" */; var exercises: [PlannedExercise]
  var perWeek: Int                 // "2x per week" → 2
  var timing: AddOnTiming          // .withSession (joins that day's session, after the last lift), .onWaking (its own short morning session)
  var quote: String                // his words: "Complete these 4x per week upon waking:"
}

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
struct Session: Codable, Identifiable { var id: UUID; var programDayId: String?; var startedAt: Date; var endedAt: Date?; var sets: [LoggedSet]; var notes: [VoiceNote]; var deviations: [PlanDeviation]
  var addOnIds: [String] }          // programDayId is nil for a session that is only an add-on (the morning vacuums)
struct LoggedSet: Codable, Identifiable {
  var id: UUID; var exerciseId: String; var setIndex: Int
  var doneAs: String?               // the variant done when the lift was swapped; history and suggestions key on exerciseId + doneAs
  var loadLb: Double; var reps: Int; var rpe: Double?               // reps = the number in the log; repCount says where it came from
  var seconds: Int?                 // a timed set: how long it ran (holds, the bike)
  var role: SetRole?                // .warmup, .top, .backOff, .restPause; nil = a straight set
  var flaggedForCoach: Bool         // "flag that": a candidate for the check-in's two videos
  var repCount: RepCount
  var startedAt: Date; var endedAt: Date; var clipFile: String?     // local MOV, trimmed to the set
  var edits: [SetEdit]                                              // audit trail for "that was 7 reps"
}
struct RepCount: Codable {
  var source: RepSource            // .plan, .watch, .phone, .measured, .spoken: which number `reps` holds
  var watch: Int?                  // wrist count from the watch app, with its confidence in watchConfidence
  var watchConfidence: Double?
  var phone: Int?                  // fallback count from body pose, at set end
  var measured: Int?               // SAM count from /sets/count
  var confidence: Double?          // SAM count confidence, 0-1
  var repTimes: [Double]           // seconds from clip start, one per measured rep
  var velocityLossPct: Double?     // how much the reps slowed, 0–100 (SAM; the phone's pose signal as the fallback)
  var estimatedRIR: Double?        // reps in reserve estimated from velocityLossPct; always shown as "estimated"
  var status: CountStatus          // .counting, .done, .failed (offline or no track: the phone count stands)
}

// The coach's load-adjustment rules, and what they suggested
struct ProgressionRule: Codable, Identifiable {
  var id: String
  var appliesTo: String?           // an exercise id, or nil for every exercise
  var when: RuleTrigger            // .aboveTarget(byRPE: Double), .belowTarget(byRPE: Double), .repsBelowMin, .allSetsAtTopOfRange, .afterTopSet, .restPauseOverGoal, .topSetPastRange
  var adjust: RuleAdjustment       // .percent(Double) or .pounds(Double), signed; .reps(Int) for "keep the weight, drop a rep"; .backOff(minPct, maxPct) for "20–25% lighter than the top set"; .loadSteps(Int)
  var scope: RuleScope             // .nextSet, or .nextSession (double progression)
  var source: String               // "Sheet note, row 4" · "Coach's voice note, Oct 29" · "Athlete: confirmed with the coach"
  var quote: String?               // his exact words, when it came from his material
  var confirmed: Bool              // nothing applies until the athlete confirms it
}
struct LoadSuggestion: Codable, Identifiable {
  var id: UUID; var setId: UUID; var ruleId: String
  var fromLb: Double; var toLb: Double            // rounded to what the athlete can load (Settings)
  var reason: String               // "RPE 9.5 vs target 8 (measured: about 1 rep left)"
  var decision: SuggestionDecision // .pending, .accepted, .kept
}
struct VideoPick: Codable { var setId: UUID; var caption: String /* "Incline DB press · top set" */; var cropStart: Double; var cropEnd: Double /* seconds into the clip: just the reps */ }

// Machine taken (stretch): what the coach wants, and what happened
struct TakenRule: Codable {
  var order: [TakenOption]         // in his order, e.g. [.alternate, .sameLift, .moveUp, .wait]
  var source: String; var quote: String?
  var confirmed: Bool              // until confirmed, only Wait and the athlete's own swaps
}
enum TakenOption: String, Codable { case alternate /* his listed alternate */, sameLift /* the same lift on other equipment */, moveUp /* a later lift from today */, wait }
struct PlanDeviation: Codable, Identifiable {
  var id: UUID; var sessionId: UUID; var at: Date
  var kind: DeviationKind          // .swap, .reorder
  var plannedExerciseId: String    // the lift whose equipment was taken
  var doneAs: String?              // swap: what was done instead, e.g. "Incline dumbbell press"
  var movedExerciseId: String?     // reorder: the later lift that moved up
  var reason: String               // "Bench taken"
  var option: TakenOption?         // which of his options it was; nil when the athlete named the swap himself
}
struct VoiceNote: Codable, Identifiable { var id: UUID; var at: Date; var transcript: String; var targetFieldId: String? }

// Photos
struct PhotoSet: Codable, Identifiable { var id: UUID; var takenAt: Date; var poses: [PosePhoto]; var collageFile: String }
struct PosePhoto: Codable { var pose: Pose; var file: String; var bodyBox: CGRect /* from the SAM mask, image px */; var alignedFile: String }
enum Pose: String, Codable, CaseIterable { case front, rightArmsUp, back, leftArmsUp }

// Check-in
struct CheckInDraft: Codable, Identifiable { var id: UUID; var weekStart: Date; var weekEnd: Date; var answers: [FieldAnswer]; var photoSetId: UUID?; var videoPicks: [VideoPick]; var adjustments: [UUID] /* accepted LoadSuggestion ids */; var deviations: [UUID] /* the week's PlanDeviation ids, all in by default */; var sentAt: Date? }
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
  var rules: [ProgressionRule]                           // how he wants loads adjusted
  var takenRule: TakenRule?                              // what he wants when a machine is taken
  var cycle: CycleCursor?                                // the cycle day Today shows
  var addOnDays: [AddOnDays]                             // which cycle days each add-on joins: the athlete's choice
  var roleTargets: [RoleTarget]                          // effort targets per set role, for sheets that give only rep ranges
  var checkInSchedule: CheckInSchedule?                  // from his written instructions, confirmed
  var quietDays: [Int]                                   // weekdays he asked not to be messaged (1 = Sunday)
  var restRules: [RestRule]                              // e.g. 3–4 min after a top set
  var warmups: WarmupRule?                               // warm-up sets he expects before each lift
  var replyId: UUID?                                     // the reply that produced this version
}
struct CycleCursor: Codable { var dayId: String; var since: Date /* the calendar day it first showed */ }
struct AddOnDays: Codable { var addOnId: String; var dayIds: [String] }
struct RoleTarget: Codable { var role: SetRole; var rir: Double /* 0 = to failure */; var source: String; var quote: String?; var confirmed: Bool }
struct CheckInSchedule: Codable { var everyWeeks: Int; var weekday: Int /* 5 = Thursday */; var dueBy: String /* "09:00" */; var timeZone: String /* "America/Chicago" */; var quote: String?; var confirmed: Bool }
struct RestRule: Codable { var after: SetRole; var minSeconds: Int; var maxSeconds: Int; var quote: String?; var confirmed: Bool }
struct WarmupRule: Codable { var minSets: Int; var maxSets: Int; var maxReps: Int; var quote: String?; var confirmed: Bool }
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
  var kind: ChangeKind     // .macroTarget, .cardio, .exerciseSwap, .exerciseAdd, .exerciseRemove, .sets, .reps, .load, .rest, .supplement, .rule (a load-adjustment rule; `after` holds its new wording), .alternate ("if it's taken, do X"; `after` holds X), .other
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
- `PlanState.rules`, `CheckInDraft.videoPicks`, `CheckInDraft.adjustments`, `CheckInDraft.deviations`, `Session.deviations` and `PlannedExercise.alternates` decode as empty when missing; `tags`, `takenRule` and `doneAs` decode as nil. `Program.addOns`, `PlanState.addOnDays`, `PlanState.roleTargets` and `Session.addOnIds` decode as empty, `ProgramDay.kind` as `.training`, and `PlanState.cycle` is seeded as the cycle day after the last completed session. `checkInSchedule` and `warmups` decode as nil, `quietDays` and `restRules` as empty, `LoggedSet.role` as nil and `flaggedForCoach` as false, and an old `VideoPick.reason` becomes its caption with no crop.
- `PlanState` is new. Today the program lives in `Store.program`, the carried blocks in `Store.template`, the cardio protocol in `Settings.cardioProtocol`, and the targets are parsed from the Nutrition block in `CheckInCoordinator.targets(from:)`. On first launch after the update, seed `PlanState` version 1 from those four, save it as `plan.json`, and from then on every reader goes through `store.plan`. Keep `targets(from:)` as the seeding function only.


`FieldSource` and `FieldKind` are Codable enums with associated values, encoded as `{"type": "...", "key": "..."}`.

---

## 5. Backend API contract

Base URL comes from `SETECHO_API_BASE` (`ios/Config/Local.xcconfig`). All bodies are JSON unless marked multipart. Every endpoint returns `422` with `{"error": "..."}` when validation fails, and never guesses.

| Method, path | Request | Response | Meta call |
|---|---|---|---|
| `GET /health` | — | `{ok, models}` | none |
| `POST /import/program` | multipart: `file` (`.csv`, `.xlsx` or an image) **or** `text` | `Program` with `flags`, its `addOns` and each day's `kind`, plus drafted `rules`, and each exercise's drafted `tags` and `alternates` | Spark, structured output |
| `POST /import/form` | `{text}` or multipart `file` (screenshot) | `{template: CheckInTemplate, targets: MacroTargets, cardioProtocol}` | Spark, structured output |
| `POST /import/rules` | `{text}`: his written instructions, e.g. the onboarding email, pasted once | `{rules: [ProgressionRule], roleTargets, restRules, warmups, checkInSchedule, quietDays, flags}`, each with his quote, nothing confirmed | Spark, structured output, then a validator |
| `POST /voice/command` | multipart: `audio` (WAV) + `context` JSON | `{transcript, intent: VoiceIntent, classifiedBy}` | Transcribe, then the rules, then Spark structured output (never Spark during a set) |
| `POST /voice/command/text` | `{transcript, context: SessionContext}` (the realtime stream's words) | `{transcript, intent: VoiceIntent, classifiedBy}` | the rules, then Spark structured output (never Spark during a set) |
| `POST /sets/count` | multipart: `video` (MP4, 720p, 15 fps, no audio) + `context` JSON `{exerciseId, equipment, plannedReps, phoneReps, setRole}` | `{reps, repTimes, repSpeeds, velocityLossPct, confidence, trackFound, frames}` | SAM 3.1 video |
| `POST /photos/segment` | multipart: `image` (JPEG) | `{width, height, box: [x,y,w,h], maskPng: base64}` | SAM 3.1 image |
| `POST /checkin/draft` | `{template, facts: WeekFacts, notes: [VoiceNote], training: TrainingSummary, lastCheckIn?: CheckInDraft, styleExamples: [String]}` | `CheckInDraft` | Spark tool calling, then a validator |
| `POST /checkin/answer` | multipart: `audio` + `{fieldId, field: FieldSpec, styleExamples}` | `{transcript, answer: FieldAnswer}` | Transcribe, then Spark structured output |
| `POST /checkin/turn` | multipart: `audio` (WAV) + `context` JSON `{template, step, askedFieldId, pending: [fieldId], answered: [FieldAnswer], styleExamples, offered?}` | `{transcript, intent, answers: [FieldAnswer], reply, confidence}` | Transcribe, then Spark structured output, then a validator |
| `POST /checkin/render` | `{template, draft}` | `{messages: [String]}`: the plan message (carried blocks), then the questionnaire | none (templating) |
| `POST /coach/reply` | `{text, plan: PlanState}`, or multipart `audio` (a WhatsApp voice note: `.opus`/`.ogg`, `.m4a` or `.wav`) + `plan` JSON | `{transcript, changes: [PlanChange], unclear: [String], cues: [VoiceCue]}` | Transcribe (audio only, per segment), then Spark structured output, then a validator |
| `POST /spotter/line` | `{moment, facts, recent: [String], styleHints}` | `{text}` | Spark structured output, then a validator |
| `POST /session/turn/text` | `{transcript, state, recentTurns: [{heard, said}], facts: SessionFacts}` | `{transcript, actions: [VoiceIntent], reply, expectsAnswer, addressed, classifiedBy, unclearReason, timings}` | the fast path, else Spark structured output (low effort), then a validator; never Spark during a set |
| `POST /session/turn` | multipart: `audio` (WAV) + `request` (the same JSON, empty transcript) | as above | Transcribe, then as above |

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
{ "intent": "rpe | reps | setLoad | loadDelta | skipSet | nextExercise | note | undo | pause | resume | endSession | starting | endSet | replayCue | yes | no | answer | topSet | warmup | addAddOn | skipAddOn | changeDay | flagSet | acceptSuggestion | keepLoad | chatter | question | choose | skipExercise | logbook | equipmentTaken | equipmentFree | swapTo | unknown",
  "number": 9, "reps": null, "setNumber": null, "text": "digestion's been off since Wednesday",
  "topic": "next | restLeft | lastSet | lastTime | load | setsLeft | effort | coachNotes | outOfScope | help | null", "fieldId": null, "confidence": 0.0 }
```

`SessionContext` carries the state, the target, and for Spark the open ask (`pendingAsk`), the app's last line (`lastSpoken`), `exercisesAhead` and `addOnNames`. A bare number is reps (his coach uses no RPE); RPE needs "felt like", "RPE", "a/an N" or "out of ten". During a set (`state: recording`) only the rules' `endSet`, `reps` and `topSet` count; everything else comes back `chatter`. Confidence 0.7 and over acts; 0.4–0.7 is asked back as the action ("Twelve reps on set 2?"); `chatter`, `unknown` and anything under 0.4 are silent (§7, The between-set conversation). The phone decodes an intent it doesn't know as `unknown`.

`/voice/command` and `/voice/command/text` stay for older builds; sessions use `/session/turn/text` since Oct 28 evening (the phone falls back to the old path on a 404).

`exerciseId` is a per-request enum of today's exercise ids, or null: "incline's taken" names incline press, and "the bench is taken" with nothing named means the next exercise up. `urgent` is true only for a `note` about pain or an injury (§7, Machine taken).

**`/sets/count`** lives in `backend/app/reps.py`: pure NumPy and SciPy, tested on fixtures.
1. Call SAM 3.1 on the video with the equipment's prompt: barbell "weight plate", dumbbell "dumbbell", machine and cable "weight stack", bodyweight "person". Keep the object tracked on the most frames. If no object is tracked on at least 80% of frames, return `trackFound: false` and no count.
2. Per frame, take the mask centroid (x, y) in pixels, with the frame's real timestamp from the file (rule 7).
3. Find the main direction of motion (the first principal component of the centroids) and project onto it. Fill gaps up to 0.5 s by interpolation, then smooth with a Savitzky–Golay filter (window 5, order 2).
4. The rest position is the median of the first and last 0.5 s. Let d(t) = |projection − rest position|.
5. Reps are the peaks of d(t) (`scipy.signal.find_peaks`) with prominence of at least 35% of d's 95th percentile, at least 0.8 s apart. A half rep that doesn't reach the prominence isn't counted.
6. `confidence` = tracked-frame share × (1 − min(1, coefficient of variation of the rep intervals)), clipped to 0–1. Under 0.6 is low.
7. Return `repTimes` at the peaks. Tune the 35% and 0.8 s on the G7 clips and keep the tuned values as constants in `reps.py`.
8. **Rep speed:** each rep's lifting phase runs from its deepest point (the peak of d(t)) back toward the rest position, until d(t) falls to 20% of that peak. `repSpeeds` = the mean |d′(t)| over that phase, in px/s, using real timestamps. Pixels are fine: the next step is a ratio, so no scale is needed.
9. **Velocity loss:** `velocityLossPct` = 100 × (1 − the mean of the last two rep speeds ÷ the fastest of the first two), floored at 0. Sets under 3 reps, and rest-pause sets (`setRole` `restPause`), return none: the pauses inside a rest-pause set make the slowdown meaningless. The phone maps it to estimated reps in reserve (§7, Measured effort).

**`/import/rules`** lives in `backend/app/importing.py`. It reads the coach's written instructions once, so every rule Setecho applies traces to his words.
1. Spark structured output (§8, Rules from his instructions) returns only what he states: set effort targets per role, back-off loads, rest after each kind of set, warm-ups, when to add weight, the check-in cadence and deadline, and days he doesn't want messages.
2. **The validator:** every `quote` appears in the text (ignoring case and whitespace), and every number in a rule appears in its quote. Anything that fails moves to `flags` with its quote.
3. Nothing personal is kept: no names, phone numbers, links, discount codes, macros or supplement doses. Macros and supplements come in through `/import/form`'s carried blocks, as before.
4. The phone shows each rule on Import beside his words; nothing applies until the athlete confirms it.

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

**`/checkin/turn`** lives in `backend/app/checkin_turn.py`. It handles one spoken turn of Check-in morning (§7).
1. Transcribe the utterance (file mode).
2. Spark structured output, with `fieldId` as a per-request enum of the template's fields, and `intent` one of `answer`, `correction`, `change`, `keep`, `decline`, `pause`, `resume`, `skip`, `goBack`, `repeat`, `forCoach`, `ready`, `chitchat`, `unclear`.
3. One utterance can answer several fields ("180.8, and glucose was 91"). A `correction` names a field that's already answered.
4. **Offers and waits (Oct 28: "let's keep that" wasn't heard as a yes).** `offered` names what the phone just offered for a yes or a no: Apple Health's weigh-in, a data field read back, a drafted answer, or adding a question to the notes. `keep` is any agreement ("let's keep that", "sounds good to me"), `decline` a no with no new value, and a new value is an `answer` for that field. A short reply is read by code before Spark (`conversational`, mirrored on the phone by `SpokenReply`): keep, decline, a wait ("hang on, let me check", "give me two minutes" → `pause`, "Take your time.", the offer stays open), or thinking out loud ("um" → nothing said, still listening). Anything with a number, a "but", a yes and a no together, or more than eight words goes to Spark with the offer in its context.
5. `forCoach` is a question meant for the coach ("should I bump my carbs?"). Once the athlete says yes, it's appended to "Additional notes or concerns" in their words.
6. **The validator:**
   - Every number in `answers` and in `reply` appears in the transcript, as digits or number words.
   - Every `fieldId` exists.
   - `reply` is 20 words or fewer and gives no advice (the prompt, plus a short blocklist check).
   - A turn that fails any check becomes `unclear`, with the reply "Sorry, say that again?"
7. The backend never chooses the next question; the phone does.

**`/session/turn`** lives in `backend/app/session_turn.py`. One thing he said between sets, as a conversation turn (§7, Talk to it like a person).
1. **Fast path** (the rule layer, no model, the engine's template as the reply, within a second): arm phrases ("go", "starting", "here we go", "lifting", "top set", "back-off", "set two", "alright, going"), "done" with or without a number, "that was N" and a bare number, "go with it", "keep it", "undo", "flag that", "what can I say?", and yes, no or a choice when `facts.openAsk` is set. Rule-layer chatter ("let's go", "ugh") comes back `addressed: false`. A fast line whose number the rules dropped ("twelve on those, I'm done") goes to Spark instead.
2. **During a set** (`state: recording`) only the rules' set commands count; everything else is `addressed: false`, and Spark is never called.
3. **Spark** gets `facts` (`SessionFacts`, built by `SessionEngine.turnFacts`: today's plan and where he is, every set with its count, source and effort, the rest left as "1:40", the open ask, last time per exercise, his confirmed rules in his coach's words, his sheet notes, the add-ons, his alternates and the machine-taken options on offer), the last 8 exchanges and the transcript. It returns `addressed`, `actions` (the engine's own intents, several per turn, in order), `reply` (20 words or fewer), `expectsAnswer` and `outOfScope`.
4. **The validator:** a count (`reps`, `endSet`, `answer`, `rpe`) must be in his words now or in the recent exchanges; any other number in an action or the reply must be in the facts, his words or the recent exchanges (spoken forms count: "one forty" is 1:40, "two twenty five" is 225); the reply gives no advice and judges nothing (a blocklist on top of the prompt). `outOfScope`, or advice in the reply, becomes the coach line ("That's one for your coach. Want me to note it for Thursday?") plus a `question`/`outOfScope` action so the engine opens the note offer. A bad reply with good actions keeps the actions and drops the reply (the engine's templates speak); otherwise the rules' full reading with the template, else "Sorry, say that again?". A model failure falls back the same way.
5. Fixtures: `backend/tests/fixtures/session_turns/` (scenarios A–L in natural speech, each line said several ways, with Spark's answers canned, plus `m_conversation`: multi-action turns, follow-ups, an invented number). `test_session_turn.py` also traces every number in every reply to the facts or his words.

**`/sets/count` crop (Oct 28 evening):** `cropBox` [x, y, w, h], normalized, top-left, in the upright portrait frame (Vision with orientation `.right`), is his station: his boxes over the set, joined, plus half his size each side and a quarter above and below for the bar and plates (`BodyTracker.cropBox`; none when it would be over 85% of the frame). The backend cuts the clip to it with ffmpeg (`video.crop`: same frames, `-fps_mode passthrough`, so the real timestamps hold) before probing and uploading; a landscape clip is the sensor's orientation and the box is turned to match. A crop that fails counts the whole frame. The full-quality clip for his coach is never cropped.

**`/spotter/line`** lives in `backend/app/spotter.py`. It writes one spoken line for a moment when speed doesn't matter, mainly the rest after a set.
1. **Input:**
   - `moment`: `restAfterSet`, `exerciseStart` or `sessionEnd`.
   - `facts`, computed on the phone: reps and their source, load, velocity loss, estimated reps in reserve, the target, the suggestion and its rule, PRs, the set number.
   - The last 5 lines spoken this session, and style hints: the athlete's first name, casual.
2. Spark returns `{text}`: one or two short sentences, at most 30 words, that sound like a training partner, not a report.
3. **The validator:** every number in `text` is one of the `facts`; nothing beyond the suggestion it was given; no opening shared with any of the last 5 lines. A line that fails falls back to the template (§7).
4. The set-end callout never waits for this; only rest-time lines do.

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

**SAM 3.1 on video** (rep counts and effort):
- The existing `meta.segment_video()` and `scripts/sam_probe.py`.
- Prompt by equipment: "weight plate", "dumbbell", "weight stack", "person" (§5, `/sets/count`).
- Send 720p at 15 fps with no audio track; rep speed needs the extra frames. Cost: $0.20 per 1,000 frames with a 50-frame minimum per request, so a 40-second set is about 600 frames, about $0.12, and a 20-set session about $2.40. Repeat tests run on saved fixtures.
- Timestamps come from the file (`ffprobe -show_frames`), never frame index ÷ 15.

Prompt caching is automatic for repeated prefixes. Keep system prompts and schemas byte-identical across calls.

---

## 7. iOS implementation notes

### Project config (`ios/project.yml` + `ios/Config/Info.plist`)
- Add the HealthKit capability: an entitlements file with `com.apple.developer.healthkit = true`, referenced from `project.yml`.
- Add `NSHealthShareUsageDescription`: "Setecho reads your weight, nutrition, steps and sleep to fill in your coach's check-in."
- Camera, microphone and photo strings already exist. Update the camera string to "Setecho films your sets and takes your check-in photos."
- Background modes: `audio`, so the session keeps listening and speaking with the screen locked.
- An App Shortcut (App Intents) for "Start my Setecho check-in" (§7, Check-in morning).
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
- **Weight on check-in morning:** Withings only writes to Apple Health when its app is opened. So Check-in morning (below) asks for the weight, unless a `bodyMass` sample since 4 AM is already in Apple Health, or Withings direct (P6) has it.

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
| Date of last refeed or cheat meal | His free meal is untracked, so a high-calorie day won't show it. Drafted from a spoken note ("free meal today") if there is one, else the latest training day logged more than 25% under target (the untracked meal), else asked. Always "Confirm" |
| Notes on sleep | Prefilled with "Avg 7.4 h/night (Garmin)", then the athlete adds the quality note by voice |
| Weeks away from target date | From the show date in settings, else "N/A" |
| Current goal(s) | If his form has it: drafted from the last check-in's answer and read back for a yes |

### Audio (gate G2 decides this)
- Use `AVAudioSession` category `.playAndRecord`, mode `.default`, options `[.mixWithOthers, .allowBluetoothA2DP]`.
- **Never `.allowBluetooth`** (HFP): it drops the athlete's music to call quality.
- Prefer the DJI receiver as input: pick the `availableInputs` entry whose `portType == .usbAudio`, and call `setPreferredInput`.
- Output stays on the AirPods over A2DP.
- **Callouts:** before speaking, reactivate with `[.duckOthers, .allowBluetoothA2DP]`. Speak with `AVSpeechSynthesizer` (`usesApplicationAudioSession = true`). After `didFinish`, go back to `.mixWithOthers` so the music returns to full volume.
- **Voice detection:** an `AVAudioEngine` input tap, RMS in dBFS against a noise floor learned over the first 2 s, with 300 ms onset and 700 ms hangover. Keep utterances to 10 s or less.
- **Utterance format:** convert to 16 kHz mono Int16 with `AVAudioConverter` and write the WAV header yourself. Upload to `/voice/command`.
- **Listen only in the Ready and Rest states,** never while a set records. That cuts false commands from gym noise. If false triggers still happen, add a setting that requires the prefix "Setecho …".

### Training cycle, rest days and add-ons
A coach's sheet isn't always one tab per training day. The athlete's has a tab per day (Day 1, Day 2, Day 3, Rest, Day 5, Day 6, Rest 2), and an "Ab Training" tab first that isn't a day at all: two blocks to do on top of other days. The import and Today must read it the way he does.
- **What the import returns** (§8, Import program):
  - **The cycle:** the training and rest days, in the sheet's order. A rest day (`kind: .rest`) has no lifts; its cardio line ("25 minutes of fasted LISS") goes in `cardio`, verbatim.
  - **Add-ons:** a block with a frequency ("Complete these 4x per week upon waking", "Complete this 2x per week") is an `AddOn`, never a day, wherever its tab sits. "Upon waking" means `.onWaking`; otherwise `.withSession`. His sentence goes in `quote`.
  - **Timed sets:** "20 seconds", "60 sec each" and "5 minutes" set `seconds`, with reps nil. A warm-up like "Stationary Bike, 5 minutes" is an exercise with one timed set.
  - **Set roles:** "1 top set. 1 back down set" (or "work down") on 2 sets makes set 1 `.top` and set 2 `.backOff`. "1 top set. 1 rest pause (20)" makes set 2 `.restPause` with `totalReps` 20. "20 total reps" with "rest pause set" is one `.restPause` set.
  - **Rest period:** a day-level "Rest Period: 90-180 seconds" applies to every exercise that day: `restSeconds` 180 for the countdown, plus a quiet "ready when you are" at 90.
  - **A slash name** ("Hanging/Lying Leg Raises") is one exercise with his two options. Keep the name; the second option goes in `alternates`.
- **Import review:** the cycle in order with rest days marked, then one card per add-on with his words and the days it joins (DESIGN.md, Import). Setecho proposes the days and the athlete confirms them once:
  - `.withSession`: spread over the training days as evenly as the cycle allows (2× in his cycle: Day 2 and Day 5).
  - `.onWaking`: spread over the whole cycle, rest days included.
- **Which day is today** (`PlanState.cycle`). This replaces `Store.nextDay`, which picks the first day never completed: after one full cycle that's always the first tab.
  - On the first launch of each calendar day, move the cursor to the next cycle day if the current one is a rest day, or a training day whose session is complete. Wrap at the end of the cycle (the last week of a multi-week program wraps to week 1).
  - A missed training day doesn't move: it waits for the next day, the way athletes follow a split.
  - "Change day" on Today, or saying "I'm doing Day 5 today" at the start of a session, moves the cursor by hand.
  - Rest day: Today shows "Rest day" and his cardio line. There's no session to start; the LISS shows up through Apple Health as before.
- **Two workouts in one day:**
  - **With the session:** on a day an add-on joins, its exercises go after the day's last lift, in the same session, under its own name in Up next ("Abs"). "Add abs" or "skip abs" by voice changes today only.
  - **Catch-up:** if there are fewer days left in the check-in week than the add-on still needs, it joins today's session anyway, and Setecho says so: "Adding abs today, 1 of 2 this week."
  - **On waking:** its own short session (`programDayId` nil), started by "Hey Siri, start my Setecho morning" (an App Shortcut) or Today's Morning card. It runs hands-free like any session, at home, with no tripod.
  - A second session the same day is fine: Today keeps offering whatever is still due, and an add-on never moves the cycle.
- **Timed sets in a session:** no set detection, no clip, no SAM. "Plank, 60 seconds. Say go." Then the countdown in the HUD, "10 seconds", "Time." The set logs `seconds`. Rest between holds is the sheet's, else 30 s. "Done" ends a hold early and logs how long it ran.
- **Rest-pause sets:** his definition is three rounds to failure with 15 deep breaths between. Set detection holds the set open through the pauses (§7, Set detection), and the count is the total across the rounds: "22 total, measured." No effort estimate.
- **Warm-up sets.** His instructions call for 1–3 warm-up sets of 6–8 reps at most before each lift, never exhausting, and the sheet doesn't list them. Without this, set detection would log about 15 warm-ups a session as working sets.
  - Each exercise starts in warm-up mode: "Incline DB press. Warm-ups first."
  - Saying "top set" (`topSet`) before a set makes it the top set. "That was a warm-up" (`warmup`) or "that was my top set" fixes one either way, with undo.
  - Otherwise each detected set is classified at set end from the phone's count and pose signal: 8 reps or fewer with under 20% slowdown is a warm-up ("Warm-up 2."); anything else is the next working set in the plan's order (top, then back-off).
  - Warm-ups log with `role: .warmup`, aren't uploaded to SAM, and never count anywhere. A warm-up reclassified by voice uploads then; its clip is still on the phone.
- **In the check-in:** `TrainingSummary` carries each add-on's count for the week ("Abs 2 of 2, vacuums 3 of 4"), so "Training consistency" can cite it.

### Set detection (Session screen)
- **Capture:** `AVCaptureSession` on the back 1× wide camera, 1080p. Run `VNDetectHumanBodyPoseRequest` on every 4th frame, about 15 fps.
- **Signal:** the mean y of both wrists, normalized and smoothed with a 5-frame median.
- **Start:** the wrist signal's range over the last 2 s exceeds 0.08, with at least one direction reversal. Set the state to Recording. The set's real start is the last moment before that when the signal was still (range under 0.03 for 1 s).
- **End:** range under 0.03 for 4 s (a rest-pause set ends after its third round, after 75 s still, or on "done", so its pauses stay inside one set). The set's real end is the last moment the signal moved. Log the set (Rep counting, below).
- **Recording:** the camera records continuously, and each file runs from one set's end to the next set's end, so every set has pre-roll. At set end, stop the file and start the next one right away. Then export the window [start − 3 s, end + 1 s] twice: at full quality as the set's clip, and at 720p, 15 fps with no audio for `/sets/count` (`AVAssetExportSession` with a video composition, `frameDuration` 1/15 s). Delete the untrimmed file.
- **Always available fallback:** the voice intents `starting` and `endSet`.
- **Tune the thresholds on real footage.** Save the wrist series from each test session to a debug JSON file so it can be tuned offline.
- **Logging rule:** load comes from the plan, or the last voice override for that exercise. Reps follow Rep counting, below. RPE is spoken.
- **Set-end callout** (deterministic, no model, instant): "Set 3 done. Rest two thirty." Then show the rest countdown; the rest time comes from the program, defaulting to 150 s. The count, the effort and the next target come during rest (Rep counting, below).
- **Undo:** keep a stack of applied actions. "Undo" reverts the last one and says what it reverted.

### Rep counting
- **SAM is the count of record on tripod sets.** Upload the 15 fps clip to `/sets/count` as soon as it's exported. When it returns during the rest:
  - **Confidence 0.6 or more:** log it as Measured and say it with the effort (§7, Measured effort): "8 reps, measured. The last two slowed a lot, so about 1 left in the tank."
  - **Under 0.6:** ask "Set 3, was that 8?" A yes logs it as Measured, a number logs it as You said, and no answer keeps the phone's count.
  - **Arrives after the next set started:** log it quietly, and mention it at the next rest only if it changed the count: "Set 3 updated: 7, measured." Never speak during a set.
- **The phone's count is a silent fallback** (`RepCounter.swift`, mirroring `reps.py` steps 4–5).
  - Over the set window, use the joint (wrists, elbows, hips, knees, ankles, Vision confidence above 0.3) whose smoothed y has the largest range, and count the same way at 15 fps.
  - It's never spoken while SAM is pending. If SAM fails, or hasn't answered 60 s after the set ended, say the phone's count ("8 reps") and log it as Phone. A later SAM result replaces it as above.
  - If no joint moves more than 0.05, there's no phone count and the set logs the plan's reps.
- **Short of plan** is said as a fact: "6 reps, 2 short of plan."
- **"That was N" always wins** and sets the source to `.spoken`.
- **Offline:** retry the upload in the background for up to 10 minutes.
- **Latency check:** if SAM's median time from set end to result on real sets is over 60 s, the phone fallback becomes the usual spoken path, and the effort for the suggestion comes from the phone's pose signal (the same velocity-loss math on the joint series). SAM still lands as the record in the log and the check-in. Report the measured median after P1b.
- **Shared tests:** `RepCounter` and `reps.py` run on the same synthetic series in `backend/tests/fixtures/reps/` and must give the same counts.

### Session inputs: camera and voice (watch in P6)
A session never requires the tripod. The camera and the athlete's voice feed the same `SessionEngine`, in any combination, and the athlete never picks a mode. The Garmin watch joins as a third input if that stretch item is built; the rules below already allow for it.
- **Camera on duty:** body pose finds at least 6 joints with confidence above 0.3 in at least half the frames of the last 10 s. Otherwise the camera is off duty: it neither starts nor ends sets, and no clip is kept. A pocketed phone is simply off duty.
- **Set start:** the first of camera start, watch `setStart` and voice "starting". A start from another input within 3 s of the first is the same set.
- **Set end:** voice ("done", "that was 8", `endSet`) ends it at once. Otherwise the camera's end when it's on duty, else the watch's `setEnd`.
- **Reps, highest first:** You said → Measured (SAM, confidence ≥ 0.6) → Phone (camera) → Watch (confidence ≥ 0.6) → Plan. The set's `SourceChip` shows which one won.
- **No camera and no watch:** voice starts and ends sets. When the athlete says "next exercise" with planned sets still unlogged, ask "Log the other 2 sets of incline press from the plan?" "Yes" logs them with source Plan; "no" skips them.
- **The rest timer** starts at set end, whichever input ended it.
- **HUD:** the state line shows which inputs are live (camera, watch), so the athlete can tell at a glance (DESIGN.md, `InputStatus`).
- **An input dropping out never stops the session.** A lost watch shows "Watch off" and the session carries on with camera and voice.

### The between-set conversation (Oct 28)
Everything he says between sets is heard, does the right thing and gets a sensible answer, or is ignored if it was just talk. Nothing he says can corrupt the log or end the session by accident. `SessionConversation` is the coordinator's voice path; `ConversationTests` drive it.
- **Hearing:** see Hearing him in a gym, below (Oct 28 evening replaced the 13 dB / 0.2 s session VAD). A realtime stream opens per utterance, and its words go to `/session/turn/text`; the WAV goes to `/session/turn` when the stream has none. Utterances are queued and handled in order, none dropped. An 8 s timeout; on failure the HUD says "Didn't catch that" and nothing is spoken. The soft chime plays the moment the words are in (never mid-set). Each utterance is saved in the session debug JSON: seconds, transcript, intent, who read it, and the seconds from end of speech to transcript, intent and first audio.
- **During a set** the mic stays open, and only the rule layer's "done" (with or without a number), counts and "top set" act. Spark is never called. With the camera on duty a spoken "done" still ends the set at once, keeping the phone's count and the clip for SAM.
- **Counts** (`routeCount`): during a set it is the set's. In rest after set S, a count corrects S; "done, N" more than 20 s after S is a new set (the rest was cut short). In Ready, a count logs a **new** set for the current target when the camera is off duty, the set is voice-only, or it was "done, N"; with the camera on duty a bare "that was N" corrects the last set only if it's the same exercise and ended under 3 minutes ago, else "Twelve for set 2 of flyes?". "Done" with no number and no phone count logs the set and asks "How many?"; no answer by the end of rest keeps the plan's reps (chip Plan). A count never edits a set of another exercise unless it is named ("set 3 of incline was 7").
- **One open ask** (`SessionEngine.Ask`): count confirm, suggestion, How many?, end session, count for, clarify, note offer, log plan sets. The latest owns yes, no, numbers and the choices; opening another lets the older one lapse with its default (a suggestion is kept, a count stays). A question, a note, an RPE or chatter leaves it standing ("what's the back-off?" then "go with it"). End session, clarify, count-for and note offers expire after 30 s.
- **Ending by voice** ("end session", "I'm done", "that's it for today") asks "End the session? Six sets logged."; only a yes ends it. The long-press End stays immediate.
- **Chatter** (exclamations, other people, music) and `unknown` are silent: "Heard: …" on the HUD for 3 seconds. *Since Oct 28 evening Spark decides this (`addressed: false`), along with questions and notes: Talk to it like a person, below. The templates below are the fallback when its reply fails the validator.*
- **Questions**, every answer a template from the log: next, rest left ("One forty left."), last set ("Set 2: 8 reps, measured." or "Still counting."), last time (the logbook line), load (the target or the pending suggestion), sets left ("Two more of these, then cable incline flyes."), effort (the measured fact, or "No measure on that one."), coach notes ("His note: …"), out of scope ("That's one for your coach. Want me to note it for Thursday?", a yes makes it a note), help ("what can I say?", "how does this work": the few lines that work in this state, from `VoiceGuide.spokenHelp`). The full list is the phone's "What you can say" screen (`Resources/VoiceGuide.json`, every line checked by `test_voice.py`), and a one-time "How a session works" screen comes before the first session.
- **Notes** about how something felt become a note with "Noted for Thursday."
- **"Next exercise" with sets left** asks "Log the other 2 sets of flyes from the plan?" Yes logs them with source Plan; no skips them.
- **"Skip the flyes"** skips that exercise today, logged as a `PlanDeviation`.
- **"Top set"** answers "Top set. Last time 145 for 9. Beat the logbook." (the cold open).
- **Last time:** each lift's last top set, typed from his paper logbook on Today and History (`LastTimeRow`), or said in Ready ("last time I did 145 for 9"). Saved as a `LogbookEntry`; `Store.lastSets` reads it beneath the log, so a set logged in the app wins.
- **Machine taken (Oct 28 evening):** "the bench is taken" / "someone's on the Smith" / "can I swap this?" (`equipmentTaken`; a named exercise still to do today, else the one up now). `TakenEngine` walks his confirmed `PlanState.takenRule` (asked once on the rules review, `TakenRuleCard`: his listed alternates and the same lift on other equipment, in his order, then wait) and keeps the first two that exist: his "or" options in his words, then the catalog's variants (`Resources/ExerciseFamilies.json`, 18 families) minus the equipment taken now or earlier today, the variant he did most recently first. Said at once as a template: "Smith's taken. His first choice is close-grip bench press. Or close-grip dumbbell press. Say 'go with it', 'the other one', or 'I'll wait'." (`Ask.takenOffer`, shown on the HUD as the `TakenCard`). A pick is logged as a `PlanDeviation` (the reason, "Smith taken") with "Close-grip bench press. Noted for Thursday."; its sets carry `doneAs`, and its load comes from that variant's own history (`Store.variantLoads`) or is asked, never converted. "I'll wait" keeps the rest running; "it's free" brings the lift back. With no confirmed rule, or Settings → "Machine-taken help" off, only wait and his own swap ("doing dumbbells instead", `swapTo`, always on). The plan never changes. Moving a later lift up (the fatigue check and the exercise tags) is not built.
- **In the check-in:** the period's accepted suggestions and gym changes go in his own notes field (`notes_field_id`, the same field as `flow.notesField`) as plain sentences, "Adjusted by your rule: …." and "Gym changes: Tue, Smith close-grip press → close-grip bench press (Smith taken).", with no line or section added. Review and send lists each under "In his notes" with a checkbox to leave it out.
- **Developer → Rehearse a session:** today's plan with the camera and mic off; typed lines go through the real backend and are spoken back; nothing is logged.

### Sets start on his word, and the camera follows only him (Oct 28 evening)
The first gym test (Wed Oct 28, a busy gym): the camera saw other people moving and recorded their sets as his. Now the camera never starts a set on its own.
- **Settings → "Start sets from the camera"** (`cameraStartsSets`, off): any movement in frame starts a set, for an empty home gym.
- **Arming:** on the tripod (camera on duty, not a voice-only set), "go" arms the next set (`SessionEngine.arm`, intent `starting`); so does "top set". The arm phrases are in the rule layer, instant, with the chime and no speech: "go", "starting", "here we go", "lifting", "top set", "back-off", "set two", "alright, going". His movement then starts the set (`cameraStarted`), with the clip's 3 s pre-roll so a late arm loses nothing. An arm with no movement in 20 s lapses silently (`tickArm`), which is why the phrase list can be generous. With the phone in a pocket, "go" starts the set at once, as before.
- **Lock-on** (`BodyTracker`, pure, tested): the pose request now reports every body in the frame. When he arms, the body whose box is largest and nearest the centre is him; from then on that box is followed frame to frame (IoU ≥ 0.2 or a centroid shift ≤ 0.12), and every other body is ignored. Before the first arm it follows the same pick; lost for 5 s, it picks again. If the arm picks someone other than the body being followed, the wrist history is cleared. `SetDetector.startsAllowed` is true only while armed, while a set runs, or with camera starts on; unarmed, a start is swallowed.
- **SAM sees only his station:** the count clip carries his joined boxes as `cropBox` (§5, `/sets/count` crop). The full-quality clip for his coach stays uncropped.
- **If he forgets to arm:** "done, 9" still logs the set by voice (unmeasured). For his first three sessions (`Settings.sessionsStarted`), the end of a rest says "Say go when you lift." instead of "Go.", and the intro ends with it.
- **Tests:** `ArmingTests` (two bodies, the other moving first starts nothing; only his set starts; the 20 s lapse; "done, 9" unarmed; pockets; the reminder; the crop).

### Hearing him in a gym (Oct 28 evening)
The gym test caught about half of what he said: the phone's mic on a tripod 2–3 m away, under gym music, and a VAD that needed 13 dB over the room for 350 ms (200 ms in sessions), so short commands never made it. His session JSON tonight should confirm it; tune from it.
- **A mic on him by default:** "Use AirPods mic" is on by default (sessions and the check-in), with music in full quality. A plugged-in external mic (the DJI receiver) wins over both. The HUD shows the live input (`AudioService.inputLabel`: "AirPods mic", "External mic", "Phone mic"). With the camera on and the phone's own mic, the session says once at the start: "I hear you best through your AirPods mic."
- **Apple's voice processing:** Developer → Hearing → "Apple voice processing" (off): `setVoiceProcessingEnabled(true)` with minimum ducking of other audio. Every utterance record says whether it was on; compare the catch rate with and without it on real gym audio, keep whichever hears more, and check it doesn't break the AirPods high-quality path.
- **Voice Transcribe decides where speech ends:** the realtime stream opens at a lower trigger (6 dB over the floor for 150 ms), before the utterance threshold. A final segment from the stream while the room has been quiet 250 ms ends the turn at once (`endIfQuiet`), instead of waiting out the hangover. An episode that never reaches the threshold is a near miss: its stream's words, if any, are heard like any utterance (a quiet "go"); a stream with no words costs nothing downstream. *Still PUSH_TO_TALK: a realtime mode with server-side turn detection is unverified.*
- **Session VAD** (`VoiceDetector.Config.session`): 8 dB over the floor (a head-worn mic), 150 ms onset, 0.15 s of speech minimum (`speechSeconds`), 0.8 s hangover, 10 s maximum. A maximum-length "utterance" raises the floor to just under its median level, never lowers it. The floor follows the room only below the stream trigger, so his soft speech never drags it up.
- **Never deaf:** utterances are queued, never dropped. With a head-worn input he can interrupt: speech 6 dB above the threshold while Setecho is talking stops the line and drops the lines queued behind it (they're on the HUD). With the phone's mic the mic stays closed while a line plays.
- **His music never stops (Oct 28 evening, gym test):** with "Use AirPods mic" on and music playing, the old screen showed "Restore: … OSStatus error 560557684" (`'!int'`, `cannotInterruptOthers`) from the restore after a line (`AirPodsMic.apply(ducking: false)` then `setActive(true)`). Now every configuration carries `.mixWithOthers` (ducking adds `.duckOthers` to it); lowering is an activation with `.duckOthers`, and restoring only changes the options on the active session, with no second `setActive(true)`. A failure is logged, the mixable configuration put back, and after two failures in a run the per-line lowering stops (lines play over the music at full volume; the configuration is never changed per line again). Every step (`lower`, `restore`, `configure`, `route change`) goes to the debug JSON's `audio` list with the options asked for and applied, the route, whether other audio was playing, and the error by its four-character code; nothing raw reaches the screen (the current session screen shows no audio errors; "Audio couldn't start" is kept only for a failed configure). Developer → Hearing → "Test music with each mic setting" runs lower-and-restore under the phone mic, the AirPods mic (HFP) and high-quality recording with the mic open, to find on the device which one makes the session non-mixable. *Unverified on a device: whether restoring without a reactivation un-ducks his music on iOS 26.*
- **Log the misses:** every utterance, near miss and barge-in goes to the session debug JSON (`kind`, `levelAboveFloorDB`, `speechSeconds`, `input`, `voiceProcessing`, transcript, actions, reply, `addressed`, and the seconds to transcript, turn and first audio), so "never detected" is told apart from "misheard".
- **Test, for the human:** 20 scripted phrases at normal volume with music playing, AirPods mic against phone mic. Target 18 of 20 or better with AirPods.

### Talk to it like a person (Oct 28 evening)
He hasn't memorized the commands, and nobody will. Every utterance the fast path doesn't take is a conversation turn with Muse Spark (`/session/turn/text`, §5), the same pattern as Check-in morning's `/checkin/turn`. This replaces P0 §6 (silent chatter), P1 §11 (question topics) and P1 §12 (notes) from the afternoon plan; their scenarios stay as tests.
- **What it gets:** `SessionEngine.turnFacts` (every number comes from the engine) and the session's last 8 exchanges, so follow-ups work: "what about the other one?", "same as last set", "actually make it 140".
- **Actions** are the engine's own intents, typed, several per turn ("that was 9, and the incline's taken" is `reps` then `equipmentTaken`); `SessionConversation` applies each in order, and undo works on all of them. During a set only the rules' set commands act.
- **The reply:** what a training partner would say back, 20 words or fewer, spoken at once. When an action opens a question of its own (a count to confirm, the machine-taken offer, "End the session?"), the engine's exact words are spoken instead. A question with no action is answered by the reply alone.
- **Not addressed to Setecho** (talk to someone else, half-heard words): nothing happens and nothing is spoken; "Heard: …" on the HUD.
- **What stays as it was:** the fast path (§5) and the measured lines (the count, the effort, the back-off, the logbook line): they're the facts, and the demo's script.
- **Latency:** the chime plays the moment the words are in (before the turn, never mid-set), then Spark at low effort. Target 2 s or less from the end of speech to the reply; the debug JSON logs it.
- **Guidance, so he never needs a list:** before his first session ever, about 15 seconds: "Talk to me like a spotter. Say go when you lift, tell me what you got, or ask me anything about today. If a machine's taken, just say so." On screen, two or three things to say that fit the moment (`VoiceGuide.hints`): Ready "go", "what did I do last time?"; Rest "that was 9", "how long left?", "the bench is taken"; an open ask, its answers. "What can I say?" gets a short spoken answer for the moment (fast path, `VoiceGuide.spokenHelp`). Every action is confirmed in plain words, so a mishearing is obvious and "undo" fixes it. When unsure, it asks a real question ("Was that nine reps, or how hard it felt?").
- **P0 §5, one open ask at a time, stays:** the open ask is `facts.openAsk`.
- **Tests:** `test_session_turn.py` (scenarios A–L in natural speech, multi-action turns, follow-ups, talk not meant for Setecho, out-of-scope questions, every number traced) and `ConversationTests` (several actions, the reply, an action that asks, nothing for talk to someone else, mid-set gating).

### He drives, Setecho follows (Oct 28 night)
From the gym test: "it felt like it was skipping past things and moving on its own", and he kept checking the phone. The plan moves only when a set he armed ends, he logs a set by voice, or he says so. Nothing moves on a timer, on the camera alone, or because a guess was made. `DriveTests` holds each rule.
- **The end of a rest changes nothing.** At zero: the rest's-up bell, "Rest's up." the first time in a session, and the countdown keeps going into overtime (`.rest(remaining:)` goes negative; the HUD shows +0:40 in a calmer colour). No "Go.", no switch to Ready. A count in overtime is routed as in Ready (a correction only within 3 minutes of the last set, else "Twelve for set 2 of flyes?").
- **Holds start on his "go":** "Three, two, one. Hold." Settings → "Start holds automatically" stays, now off by default. The intro of a morning of holds ends "Say go."
- **Between exercises:** after an exercise's last set, "Incline press done. Cable flyes next." Flyes become the target, but nothing about them starts (warm-up mode, the load question) until he arms a set of them, logs one, or talks about them (`exerciseEntered`, `enterIfNeeded`). Then "Warm-ups first." and/or "Weight for these?" "One more set" adds a set to the exercise just finished. A coach cue plays when the rest is up.
- **Nothing changes silently.** Every automatic decision is said in a few words, and "undo" reverses it: "Logged as warm-up one." (undo makes it a working set), a count replaced by SAM ("Set 3 updated: 7, measured."), a set logged from his voice (its count said back), a suggestion lapsing ("Keeping 225."), a "How many?" left at the plan's reps ("Set 2 stays at 8, the plan's.").
- **Moving around by voice** (new intents, rule layer and Spark): `goTo` ("go back" / "redo that set": back to the last set's slot; "I'm on flyes now" / "let's do incline next": that exercise moves up to now and the rest keep their order, resuming at its first unlogged set, logged as a `.reorder` gym change so the coach sees it), `addSet` ("one more set"), `endExercise` ("that's it for incline": its unlogged sets stay unlogged; plan sets are never logged without his yes; with none logged it's a skip), and "where am I?" ("Incline press, set 2 of 2, back-off."). Each is undone by "undo" (`.cursor` restores the order and the cursor).
- **A late SAM count** is spoken only if it changes a number he already heard; otherwise the screen updates and nothing is said.
- **Still to do from his debug JSON:** find every point where the plan moved without his word and turn each into a test. No session JSON had arrived when this was built.

### Built for not looking (Oct 28 night)
The ear carries the whole session; the screen is for a glance. The test is his: a whole Day 5 session without looking at the phone once, and knowing where he is the whole time.
- **Sounds** (`VoiceOutput.cue`, generated tones at the chime's level, never louder than the voice): armed (a rising tick), set started (a soft click), set ended (two tones, down), rest's up (a bell), and the existing "heard you" chime. `Outcome.sound` carries them from the engine.
- **Haptics** (`SessionHaptics`) for the pocket: armed, set ended, rest's up. The audio session allows haptics while recording (`setAllowHapticsAndSystemSoundsDuringRecording`).
- **The camera faces the wrong way:** the back camera points the screen away from him, so every check meant walking round the tripod. Settings → "Camera faces you" (`frontCameraInSessions`, off until measured) uses the front camera, unmirrored (Vision orientation `.left`; `CountContext.camera: "front"` turns the backend's crop to match), 1080p where the front camera allows it. **Before turning it on by default:** measure SAM's count front against back on a few clips.

### The session screen (Oct 28 night, wired in)
DESIGN.md (Session) has the screen. After two rounds of review (the first redesign was "too basic", then a cue-card direction used colours from outside the app), it is the app's own grouped cards at hands-free scale with his own camera in the middle.
- `SessionView` draws `SessionHUD` from `SessionHUDModel(engine:live:)` (Features/Session/SessionHUDMapping.swift) every quarter second: the phase from the engine (armed while "go" waits, the elapsed clock, the rest and its length, a hold, the end), the lifts strip from the plan and the log, the last set as Results shows it, the next set as the yellow tag, any open question on a card, the voice card from the mic and the conversation (the stream's words, the turn being read, the line being said filling at about 2.6 words a second, the last line for 8 s), and the session-end summary.
- **The camera card:** the set detector's own capture session (`SessionCameraPreview`, the front camera mirrored), the lock-on brackets where his body is (`SetDetector.trackedBox`, mirrored and aspect-fill aware), and during rest the set he just did (`ReplayView`, looping, silent; the clip stays as the sensor recorded it, so SAM's 720p copy keeps its full width, and the player turns it upright).
- **It assumes the front camera:** with the back camera the picture is the gym, not him, and the screen faces away. Settings → "Camera faces you" is still off until SAM's count is measured front against back.
- `SessionHUDMappingTests` cover the mapping; `SessionHUDRenderTests` and a scripted live rest render every state for review.

### Add-ons in a session (Oct 28)
- **Holds run themselves** (Settings → "Start holds automatically", on): after the intro and when a rest ends, "Three." "Two." "One." "Hold." each on its own second; a new timed exercise after another gets five seconds: "Plank, sixty seconds. Starting in five." The countdown is from the wall clock (`holdStartedAt`), "10 seconds." on a hold of 30 s or more, the last three counted aloud, then "Time." and the rest (the sheet's, else 30 s). No "Go." before a hold. "Go", "ready" or "start" starts a lead-in early; "hold on" delays it; "done" or "stop" ends a hold early.
- **One name:** a morning add-on whose exercise has its name says it once: "Stomach vacuums: four holds of twenty seconds." The HUD shows it once.
- **No camera** for an all-timed session.
- **Warm-ups** belong to the day's own lifts: never an add-on's exercises, never bodyweight ones. A set with no top or back-off role asks "Weight for these?".
- **Add-on sets go by voice:** the camera neither starts nor ends them and SAM never counts them. "Done, 12" logs one; "done" alone asks "How many?". A set with no load shows "12 reps".
- `SpokenText.clean` reads a slash between words as "or" ("Hanging or Lying Leg Raises").
- **The screen stays awake** for the whole session. Still to test: with the phone locked by hand in a pocket, that background audio keeps the mic, the voice and the clock running.

### Measured effort and the coach's rules
Setecho never invents a load change. It measures how hard a set was, compares that with the coach's target, and applies the coach's own rule. The athlete decides, and the coach sees every adjustment.

**The athlete's coach, from his onboarding email:** top sets and back-off sets both go to muscle failure, inside the listed rep range; back-off sets are 20–25% lighter than the top set, after 3–4 minutes' rest; a rest-pause set that beats its total-rep goal means more weight next week; progress means beating the logbook (more load, more reps or better execution) every week. So for him, measured effort answers one question: did that set really reach failure?
- **Effort, per set:**
  - **Spoken RPE** ("felt like a 9") is the athlete's word, and it wins.
  - **Measured:** `velocityLossPct` from SAM (or the phone's pose signal as the fallback), mapped to estimated reps in reserve. The starting map, tuned in P5: under 10% → 4+ left · 10–20% → 3 · 20–30% → 2 · 30–40% → 1 · over 40% → 0. It's stronger on barbell lifts (the research is on bench press and squat), and it's labelled "estimated" everywhere.
  - **Calibration:** whenever the athlete says an RPE, store (velocity loss, 10 − RPE) for that exercise. After 5 pairs, fit that exercise's map to his own sets.
- **Targets** come from the sheet: an RPE or RIR per set, or a rep range. A sheet with rep ranges and no effort targets (the athlete's has top and back-down sets and no RPE anywhere) gets one more one-time question on Import: "How close to failure does your coach want top sets, and back-down sets?" It's stored as `roleTargets`, with his words if he gave them, and confirmed like a rule. For the athlete, `/import/rules` finds the answer in his email: failure (0 in reserve) for both top and back-off sets.
- **Rules** (`ProgressionRule`, §4):
  - **From his material:** `/import/program` drafts rules from the sheet's notes ("if RPE is over 9, drop 5%"), and `/coach/reply` can add or change them as `.rule` changes. Each carries his quote. `/import/rules` drafts the rest from his written instructions (§5).
  - **Asked once:** if the sheet has targets but no rule, Import asks "How does your coach want you to adjust when a set misses the target?" with three examples to pick from or say: drop or add 5%, drop or add 5 lb, keep the weight and adjust the reps. The athlete confirms it's what the coach wants.
  - **Nothing applies unconfirmed.** With no confirmed rule there's no suggestion: Setecho still says the measured effort, and the coach sees it in the check-in.
- **The engine** (`RuleEngine.swift`, deterministic, unit-tested):
  - After each set, compare effort with the target, find the confirmed rule that matches, and compute the next set's load.
  - Round to what the athlete can load (Settings: barbell steps, dumbbell steps, machine stack steps).
  - At most one step per set, and never more than 10% from the coach's planned load in a session. A back-off rule is the exception: it's computed from the top set actually done.
  - **No planned loads** (his sheet has none): a set's load is last time's for the same exercise and role, plus any confirmed next-session step, else asked: "Weight for the top set?"
  - Double progression (the top of the rep range on every set) suggests the change for the **next session**, never mid-session.
  - **Set roles:** a set is compared with its own target, never with a set of another role. A top set's suggestion is for the next session's top set. A back-off set's load comes from his back-off rule when there is one; his is 20–25% lighter than the top set, so Setecho says the load step nearest 22.5% lighter. With no rule, it comes from its own history or the athlete. A rest-pause set gets no mid-session suggestion; its total is logged against `totalReps`.
  - **Next session:** a rest-pause total over its goal suggests one load step up next time (his rule, in his words). A top set that reached failure past the top of its range does too; that rule is drafted from his rep window, so it applies only once the athlete confirms it.
- **Saying it:** during rest, after the measured count. For the athlete: "Top set: 11 reps, measured. Slowed 46%, that's failure. Back-off at 170, his rule: 20 to 25% lighter. Say 'go with it' or a weight."
  - If the measure says reps were left, it's said as a fact against his target, never as advice: "About 2 left by the measure. His target is failure."
  - On a sheet with RPE targets: "Your target was RPE 8, so his rule says 215 next. Say 'go with it' or 'keep it'."
  - "Go with it" (or yes; intent `acceptSuggestion`) sets the next target, shown with the HUD's yellow tag. "Keep it" (or no; intent `keepLoad`) keeps the plan's load. No answer keeps the plan's load.
  - Every decision is logged as a `LoadSuggestion`.
- **Rest after a top set:** his 3–4 minutes (`restRules`) overrides the sheet's day range: the countdown runs to 4:00, with a quiet "ready when you are" at 3:00.
- **The logbook line:** at each exercise's top set, the spotter says last time's and his phrase: "Last time 80s for 9. Beat the logbook." Numbers from the log.
- **Off switch:** Settings → "Next-set suggestions" (on). When it's off, effort is still measured and still reaches the coach.
- **In the check-in:** `/checkin/render` appends one line after his last field: "Adjustments (your rule): Incline press set 3, 225 → 215 (RPE 9.5 vs 8)". Only accepted suggestions are listed.
- **Videos for his check-in:** §7, Two videos for your coach. He asks for two movements the athlete feels unsteady on, so the athlete picks them; Setecho never ranks sets for review.

### Machine taken (stretch, P6)
A busy gym means the bench is taken. Setecho offers what the coach would accept, in the order he said he prefers, and reports every change to him. It never picks a lift outside the same movement or his own alternates, and it never changes the plan.
- **Tags, at import:** `/import/program` also returns each exercise's `tags` (§8, Import program): a movement family from `ios/Setecho/Resources/ExerciseFamilies.json` (a per-request enum, plus none), the main and secondary muscles, and heavy or light. The athlete confirms them once on Import (DESIGN.md, Exercise tags). Until they're confirmed, no reorder is offered.
- **The catalog** (`ExerciseFamilies.json`, hand-written, about 30 families) lists each family's variants by equipment, with their names. For example, `incline-press`: barbell "Incline barbell press", dumbbell "Incline dumbbell press", Smith "Incline Smith press", machine "Incline machine press". Variant names come from the catalog, never the model.
- **His preference, asked once** on Import's rules review: "When a machine's taken, what does your coach want: the same lift on other equipment, move a later lift up, or wait?" The athlete puts them in order (or says it) and confirms it's what the coach wants. It's stored as `PlanState.takenRule`.
  - His "or" options in the sheet ("Hack squat or leg press") are drafted at import as `alternates`, with his words.
  - `/coach/reply` can add one as an `.alternate` change.
- **Trigger:** "the bench is taken" or "incline's taken" (`equipmentTaken`). With no exercise named, it's the next one up; during rest, the next set's exercise.
- **The engine** (`TakenEngine.swift`, deterministic, unit-tested). For the taken exercise T, walk his options in his order and keep the first two that exist:
  - **Alternate:** his listed alternates, in his order.
  - **Same lift:** the other variants in T's family, minus the taken equipment and anything already taken this session. Prefer the variant done most recently, then the catalog's order.
  - **Move up:** the first later exercise in today's plan, C, that passes the fatigue check.
    - A heavy C always passes: flat press can go before incline press.
    - A light C passes only if its main muscles don't overlap the main or secondary muscles of any heavy lift still due before it in the plan, T included. Flyes or pushdowns before incline press fail. Lateral raises pass.
    - **Pre-exhaust:** if today's plan already puts a light lift before a heavy one for the same muscle (pec deck before incline press), he does that on purpose, so a light lift for that muscle may move ahead too.
    - T then comes right after C. If it's still taken then, the engine runs again.
  - **Wait:** always available, and last. The rest timer keeps running, and "it's free" (`equipmentFree`) brings T back.
  - **With no confirmed `takenRule`:** only Wait, plus whatever the athlete names himself.
- **Saying it**, templated and instant (not `/spotter/line`, because he's standing there waiting):
  - "Bench is taken. His first choice is the same lift on dumbbells. Or flat press first. Say 'go with it', 'the other one', or 'I'll wait'."
  - If nothing passes: "Nothing else fits before incline without tiring your chest. Wait, or do it on dumbbells?"
- **The athlete can name it himself:** "doing dumbbells instead" (`swapTo`) always works, even with the feature off. It's logged as he said it, matched to a catalog variant when one fits.
- **Logging:** each swap or reorder is a `PlanDeviation` on the session, confirmed with a spoken "Noted for Thursday." A swapped set logs `doneAs`. The plan itself never changes.
- **Loads on a swapped lift:** from that variant's own history (its last top set), or the athlete says it ("fifties"). **Never convert between barbell and dumbbell loads.** Next-set suggestions key on `exerciseId + doneAs`, so a variant with no history gets none until its first set is logged.
- **In the check-in:** the week's deviations are all in by default, and the athlete can untick one on Review and send. `/checkin/render` adds one line after the adjustments: "Gym changes: Tue, incline barbell → incline dumbbell press (bench taken). Tue, flat press moved ahead of incline press (bench taken)."
- **Pain doesn't wait for Thursday:** a `note` marked `urgent` ("my elbow's bugging me on these") gets "That's one for him. Want me to message him now?"
  - Yes puts a ready message on screen at session end, and on the Lock Screen: "Send to coach" opens WhatsApp with the text (`https://wa.me/?text=…`), and the athlete sends it himself.
  - On his quiet day (Sunday, per `quietDays`), it offers a Monday 8 AM reminder instead, unless the athlete says it's urgent.
  - Setecho never advises on pain. The note also goes in the check-in.
- **Off switch:** Settings → "Machine-taken help" (on). When it's off, the athlete's own swaps and the logging still work.

### The spotter voice
The athlete should feel like he's talking with a training partner, not a machine. It has one consistent personality, and it's never the coach's voice.
- **What it says:**
  - The set-end callout is instant and templated, with a few variants rotated so it never repeats back to back.
  - Rest-time lines are templates, said the moment SAM answers (Oct 28: `/spotter/line` is off the session path; Spark-written lines are out). The endpoint and its validator stay in the backend, unused by sessions.
  - It remembers the session: PRs, "third set in a row at the top of your range", and what he said earlier.
  - It uses his first name sparingly, and never comments on form or food.
- **When:** it's quiet during sets, answers a voice command within about a second, and never talks over the athlete.
- **The voice itself:** a `Speaker` protocol with one implementation, `SystemSpeaker` (`AVSpeechSynthesizer`, on the device). The natural-voice service (ElevenLabs) was removed on Oct 28: every runtime model must be Meta's.
  - **Voice:** Ava (Premium) by default, then Zoe (Premium), then Evan (Enhanced), found by name and quality in `speechVoices()`; any installed English voice can be picked in Settings → Voice. With none of them, Settings says "Download Ava (Premium): Settings → Accessibility → Read & Speak → Voices → English" and the best installed English voice speaks. Siri's voices can't be used: iOS never lists them to apps.
  - **Every utterance:** SSML, one `<prosody rate pitch>` and no `<break>` (added pauses on top of the voice's own made every comma stall, Oct 28). **An SSML utterance ignores `utterance.rate` and `pitchMultiplier`** (measured: identical audio at 0.42 and 0.55), so both live in the prosody: the rate slider maps to a speed by measured durations (0.42 → 91%, 0.50 → 100%, 0.55 → 129%), pitch 0.90–1.10 to −10%…+10%. Each line gets a small, steady variation (speed ±3%, pitch ±2%, from a stable hash of its words, so pre-rendered files stay valid). Volume 1.0, no pre- or post-utterance delay.
  - **Tone (Settings → Voice, saved per voice):** Speed 0.42–0.55 (default 0.49), Pitch 0.90–1.10 (1.0), Warmth −3…+6 dB (+2, a low shelf at 180 Hz), Clarity −4…+4 dB (−1, a bell at 3 kHz), Play sample and Reset. Audio processing only, no models.
  - **One output chain (`VoiceOutput`):** `AVSpeechSynthesizer.write` → buffers (copied to float) → `AVAudioPlayerNode` → `AVAudioUnitEQ` → `AUDynamicsProcessor` (threshold −20 dB, 5 dB makeup) → output. A live line plays from its first buffer (0.42 s after the call on the Mac's voice, the synthesizer's own start); pre-rendered files play through the same chain, so warmth and clarity change without re-rendering. Numbers and dates become words on the phone (`SpokenText`: "180.8" → "one eighty point eight", "225 for 8" → "two twenty five for eight", "10/24/26" → "October twenty fourth").
  - **Human through content (`SpokenFacts`, Oct 28):** a read-back carries one fact from the log where there is one, computed in code from his last check-in sent before today (a rehearsal sent this morning doesn't count): "Apple Health has you at 180.8, down 0.4 from last week. Should I use that?", "Average daily steps came in at 9.4k, up 500 from last week." Weight, the tape, steps, glucose, the percentages ("points") and the 1–10 scales compare; dates, words, weeks out and last week's own weight don't. "From last week" when the last check-in was 5–9 days ago, else "since your last check-in". Acknowledgments take turns ("Got it", "Okay", "Nice", never the same twice in a row; the reply's own "got it" is swapped for the one in turn), and "Nice" never comes before a change, so a weight going up is never praised or judged. When a turn is heard a soft chime plays (two quiet sine partials, a quarter-second fade, generated in `VoiceOutput`), and nothing is spoken until the reply.
  - **Cleaned for the ear (`SpokenText.clean`, Oct 28):** what the voice is given, never what the coach reads. Units after a number become words ("7.2 h/night" → "hours a night", "31 in" → "inches", "lbs", "kcal", "g", "min", "s"), "mg/dL" is dropped, "Avg" → "average", "225×8" → "225 for 8", ranges "1-10" and "–" → "to", asides in parentheses become a clause, "·", "—", "&", "→" and line breaks become pauses or words; "9.4k" is said "nine thousand four hundred". The data read-back's tail changes line to line ("Sound right?", "Look right?", "That right?").
  - **Lines:** written to be heard, the way a person asks: "How were your energy levels this week, out of ten?", "How's your recovery been this week?", "What did the tape say for your waist, bicep and thigh?", "Apple Health has you at 180.8. Should I use that?", "Quick check on your data. Average daily steps came in at 9.4k. Sound right?" (`WrapUpModel.question`, from the form's labels). The same line never twice in a row (a fixed alternate, or "Again, …"). Session callouts stay short on purpose.
  - **Personal Voice (optional, Oct 28):** Settings → Voice → "Use my Personal Voice" asks iOS once (`requestPersonalVoiceAuthorization`), then speaks every line with the athlete's own Personal Voice (made on the phone in Settings → Accessibility → Personal Voice, with "Allow Apps to Request to Use" on). It is an on-device Apple model like the other voices; **confirm it with the organizers** with the rest of the list. Off goes back to the default. A line that won't pre-render in it is spoken live.
  - **Loudspeaker, not the earpiece:** every activation adds `.defaultToSpeaker` (`AirPodsMic.options`). Without it, `.playAndRecord` with nothing plugged in played every check-in line through the earpiece, thin and quiet, while "Play sample" used the loudspeaker (Oct 28). AirPods still take the output when connected. Check-in morning shows "Voice · Ava (Premium)" at the bottom, so a fallback voice is visible. If Ava or Zoe Premium is missing, Ava or Zoe Enhanced comes next, then Evan.
  - **Pre-rendered:** the fixed lines of Check-in morning, the wrap-up and the photo session (and the coach's questions) are written to CAF files with `AVSpeechSynthesizer.write` when the flow starts, one line at a time with the next line due first, keyed by the line, voice, rate and pauses, and play at once through one `AVAudioEngine`; anything else is spoken live.
- **One voice everywhere:** sessions, Check-in morning and the wrap-up all use the same `Speaker`.

### Garmin watch (Connect IQ app): stretch, P6
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
- **Framing check, on the device:** head to toe in frame with margin on every side, from the person mask; otherwise "step back a little", "move left" or "move right".
- **Retakes by voice:** "retake front" (or any pose) redoes that one.
- **The photos are sent exactly as taken,** at full resolution, in his order: front, right side arms up, back, left side arms up. No collage, no cropping, no alignment, no last-week outline, no comparison screen (decided Oct 27 evening). `/photos/segment` is no longer called; SAM does not touch photos. The old collage, alignment and review code can stay in the tree for now.

### Check-in
**Cadence** (`PlanState.checkInSchedule`, from his email, confirmed by the athlete): **weekly** (`everyWeeks` 1), Thursday on waking, everything in by 9:00 AM Central. The check-in covers the period since the last sent check-in, so `WeekFacts` holds the days since then (7 on the weekly cadence) and every average spans them. Reminders and Check-in morning key off the due time.

1. Build `WeekFacts`, `TrainingSummary` and the week's `VoiceNote`s, then call `/checkin/draft`.
2. Show the coach's form in his order (DESIGN.md, Check-in).
3. **Wrap-up:** for each `.missing` or `.voice` field, speak the coach's label as a question. For example, "Energy levels, 1 to 10?". The three tape measurements are one question: "Waist, bicep and thigh?".
4. Record one utterance and call `/checkin/answer`.
5. Speak back a one-line confirmation: "Energy 6. Next: appetite." Support "skip", "go back" and "say that again".
6. **Send, in his order** (his email asks for two separate messages): first the plan message (the carried blocks: macros, cardio protocol, and the full supplement list marking which he's taking), then the questionnaire text with the four full photos, then the two flagged videos. `/checkin/render` returns both texts. Review and send runs three share sheets in a row: `[text1]`, `[text2, photo1…photo4]`, `[video1, video2]`. Gate G6 checks each lands as one WhatsApp message.
7. **Fallback:** if WhatsApp splits the text from the photos, send the photos first and the text right after, as two shares. Mark the draft `sentAt` when the last step completes.

### Check-in morning (conversational, hands-free)
The whole check-in as one conversation on check-in morning, in Setecho's own voice, with the coach's exact wording for his questions. **Never a synthetic copy of the coach's voice.**
- **Start:** "Hey Siri, start my Setecho check-in" (an App Shortcut; the phrase must contain the app's name), the check-in-day notification, or Today's check-in card.
- **Steps, fixed in code, in this order:**
  1. **Weight:** "Morning. Step on the scale, and tell me when you're off."
     - If today's weigh-in is already in, say it: "180.8, got it." It's in if Apple Health has it since 4 AM, or once Withings direct is built, from one fetch when the athlete says they're off.
     - Otherwise ask, "What did it say?"
  2. **Fasted glucose:** "Fasted glucose?"
  3. **Photos:** "Set up your tripod for photos, and tell me when you're ready." The Photo session runs as it is: four photos, hands-free, then back to the conversation.
  4. **The coach's questions:** every `.voice` or `.missing` field, in his order, with his label as the question and the measurements as one question. Drafted fields are read back for a yes: "Last refeed, Saturday the 24th?"
  5. **Review:** "That's everything. Want me to read it back, or open it to send?" Then Review and send. Sending to WhatsApp is the one tap.
- **Every utterance goes to `/checkin/turn`.** The phone applies the answers, speaks the reply, and picks the next question itself: the first pending field in the coach's order. Spark understands; code decides.
- **Pause:** on `pause` ("give me a couple of minutes"), speak the reply ("No worries, just tell me whenever you're ready"), stop asking, and keep listening.
  - Any speech resumes; an answer resumes and counts.
  - After 10 minutes of silence, stop listening and send one notification: "Your check-in is waiting. Say 'I'm back' or open Setecho."
- **Echo:** read every number back as it's stored ("Weight, 180.8"), with `VoiceEcho` on screen. "Undo" or a correction fixes it.
- **Resume anywhere:** the draft is saved after every answer. Reopening picks up at the next pending step and field.
- **Turn-taking:** listen only after Setecho finishes speaking, so it never hears itself. Interrupting mid-reply can come later.
- **Voice:** `AVSpeechSynthesizer` with the best installed voice, premium first, then enhanced. Settings has a voice picker, and first run suggests downloading a premium voice in iOS's Spoken Content settings.
- **Fallback:** the separate Photo session and Wrap-up screens stay. If Check-in morning isn't solid by Wednesday 9 PM, Thursday uses them.

### Coach reply
- **The first `PlanState`** comes from the imports: the program, plus the macro targets and cardio protocol read out of the form's carried blocks (part of `/import/form`'s structured output), confirmed on the Form review screen.

1. **Getting the reply in.** Build the in-app path first: Today or More → "Add coach reply" → paste text, or pick an audio file (`.fileImporter` allowing `.audio` and `.opus`). Then the `SetechoShare` share extension: it accepts text or one audio file, writes it to the app group's `inbox/`, and tells the athlete "Sent to Setecho." The app checks the inbox at launch and when it comes to the foreground.
2. **Read it.** Call `/coach/reply` with the reply and the current `PlanState`. Show the Coach reply screen (DESIGN.md).
3. **Apply.** Approving builds a new `PlanState` version from the approved changes, in Swift, deterministically. A macro or supplement change also edits the carried block's text: replace the old value on the matching line when it appears there exactly once; otherwise open the block for a manual edit. Keep every version. History → Plan changes can revert the latest one.
4. **Everything downstream reads the new version:** Today's session, the Session targets, `WeekFacts.targets`, the cardio protocol, and the check-in's carried blocks.
5. **MacroFactor:** Setecho can't change MacroFactor's targets, and Apple Health doesn't carry them. After a macro change is applied, Today shows "Update MacroFactor: training-day carbs 250 → 225 g" until the athlete marks it done.

### Two videos for your coach
His instructions: each check-in carries videos of two different movements the athlete feels unsteady on or wants sharper, cropped to just the reps, with no setup and no rest. The athlete picks; Setecho crops and attaches. **No model judges or ranks anything.**
- **Flag it:** "flag that" or "send that one to coach" during rest (`flagSet`) marks the last set: "Flagged for Thursday." Any set from the check-in period can also be picked on Review and send.
- **Each clip:** the set's MOV cropped from 0.5 s before the first rep to 0.5 s after the last, using SAM's `repTimes` (with no SAM result, the set's own start and end); H.264 720p, 20 MB or less; captioned with the exercise and set ("Incline DB press · top set").
- **UI:** a "Videos for your coach" card on Review and send: the flagged sets, two at most, from two different movements. If more were flagged, the athlete keeps two; if none, "Pick two" lists the period's sets by exercise.
- **Message:** the clips are the third share, after the questionnaire (§7, Check-in). No verdicts, and no numbers he didn't ask for.

---

## 8. Model prompts

Keep the prompts in `backend/app/prompts.py` and the schemas in `backend/app/schemas.py`, versioned. These are the starting texts.

**Import program** (`/import/program`, structured output, schema = `Program` minus `importedAt`):

> You convert a strength coach's training spreadsheet into JSON. Copy exercise names, set counts, reps, rep ranges, loads, RPE/RIR and rest times exactly as written. Never invent a value. If a cell is ambiguous, keep your best reading and add an entry to `flags` explaining what is unclear. Weeks and days follow the sheet's own order and names. Set each exercise's `equipment` from its name (barbell, dumbbell, machine, cable or bodyweight); if the name doesn't make it clear, pick the likeliest and add a flag. Tag each exercise with its movement family from this list: {families}, or none; its main and secondary muscles from {muscles}; and heavy (a compound lift) or light (an isolation lift). If the coach wrote an alternate ("or leg press"), copy it into `alternates` with his words. Never add an alternate he didn't write. Each sheet may be a training day, a rest day, or a block the coach adds on top of days. The training and rest days form the cycle, in the sheet's order. A block with a frequency ("4x per week", "2x per week") goes in `addOns` with `perWeek`, its timing ("upon waking" is onWaking, otherwise withSession) and his sentence in `quote`; it is never a day, even when its tab comes first. A rest day has no exercises; copy its cardio line into `cardio`. A time ("20 seconds", "5 minutes") is `seconds`, with reps null. "1 top set. 1 back down set" makes the first set top and the second backOff; a rest-pause set is restPause, with "20 total reps" as totalReps. A day-level rest period applies to each exercise that day.

**Import form** (`/import/form`, structured output, schema = `CheckInTemplate`):

> You convert a coach's check-in form into a template. Keep every field label exactly as written, in order, including hint text in parentheses as `prompt`. Blocks that are the coach's instructions rather than questions (macro targets, supplement lists) become `carriedBlocks` with their text copied verbatim. For each field, choose `kind` and a `source` from this list of available data keys: {DataKey list with one-line meanings}. Use `voice` when no data key fits. Never answer the fields. Also copy the macro targets (training and rest day kcal, protein, carbs, fat) and the cardio protocol out of those blocks into `targets` and `cardioProtocol`; if a number isn't clearly written there, leave it null.

**Check-in agent** (`/checkin/draft`, Responses API with tools):
- **Tools:** `get_week_facts()`, `get_training_summary()`, `get_notes()` and `get_last_checkin()`. They return what the phone sent.
- **The agent writes only the text fields:**
  - "Notes on performance", drafted
  - "Biggest win", a suggestion, marked drafted
  - mid-week notes routed to their fields
- **Every data field comes from code** (§7 table), never from the model.
- **The validator checks every number in the agent's text** against `WeekFacts` and the training summary. Any number not found makes that answer `.drafted`, with a "Check this" provenance. Never hide a mismatch.

> You fill in an athlete's check-in for their coach, in the athlete's own voice. Here are examples of how they write: {styleExamples}. Use only facts returned by your tools. Do not give advice, judge form or suggest changes; the coach does that. Keep answers short and casual, like the examples.

**Voice command** (`/voice/command`, structured output = `VoiceIntent`):

> Classify one short spoken command from an athlete during a lifting session. Context: {state, exercise, set, planned load and reps}. Map to one intent. Numbers are pounds for loads and counts for reps; "felt like a 9" is rpe 9. Today's exercises: {ids and names}. "The bench is taken" is equipmentTaken, with the exercise it's about or null; "doing dumbbells instead" is swapTo; "it's free" is equipmentFree. Mark a note urgent only when it's about pain or an injury. If unsure, return intent "unknown" with low confidence.

**Wrap-up answer** (`/checkin/answer`, structured output = `{text, number?, measurements?: {waistIn, bicepIn, thighIn}, confidence}`):

> Turn the athlete's spoken answer to "{label}" into the text they'd type. Keep their words and tone; fix only filler and false starts. Extract the number for scale or measurement fields. "Twenty-four and three quarters" is 24.75.

**Rules from the sheet** (part of `/import/program`, structured output = `{rules: [...]}` without `id` or `confirmed`):

> List only the load-adjustment rules the coach actually wrote in this sheet, such as "if RPE is over 9, drop 5%" or "when you hit 8 reps on every set, add 5 lb next week". Copy his words into `quote`. If the sheet has targets but no rule, return none. Never invent a rule, and never suggest one.

**Rules from his instructions** (`/import/rules`, structured output = `{rules, roleTargets, restRules, warmups, checkInSchedule, quietDays, flags}`):

> You read a strength coach's written instructions to his athlete, such as an onboarding email, and list only the rules he states about: how hard each kind of set should be, the weight of back-off sets, rest after each kind of set, warm-up sets, when to add weight, how often check-ins are due and by when, and days he doesn't want to be messaged. Copy his exact words into `quote` for each. Never invent a rule, never fill a gap with common practice, and never include names, phone numbers, links, discount codes, macros or supplement doses.

**Spotter line** (`/spotter/line`, structured output = `{text}`):

> You're the voice of a training partner spotting an athlete between sets. You are not his coach: never give advice about form, food or programming, and never suggest a weight other than the one in the facts. Facts: {facts}. Lines you said recently: {recent}. Say one or two short, natural sentences, at most 30 words, the way a friend at the gym would. Use only the numbers in the facts. Don't start the way any recent line started.

**Check-in turn** (`/checkin/turn`, structured output = `{intent, answers: [{fieldId, text, number?, measurements?}], reply, confidence}`, `fieldId` as a per-request enum):

> You are the voice of a check-in app, talking with an athlete on check-in morning. You are not their coach: never give advice about training, food, weight, recovery or posing. The question just asked: "{label}". Fields still to answer: {pending fields with their labels}. From what the athlete said, return the intent, any answers (the field id plus the number or words they used), and a reply of one short, friendly, casual sentence. Use only numbers the athlete said. If they ask for advice, say it's one for their coach and offer to add it to their notes. If they need a minute, tell them to take their time. Never move to another question yourself.

**Coach reply** (`/coach/reply`, structured output = `{changes: [...], unclear: [String]}`, with `path` as a per-request enum):

> You read a strength coach's reply to his athlete's check-in and list every change he makes to the athlete's plan. The plan's items are listed with a path, a label and the current value: {items}. For each change, pick the item's path, the operation, and the number he said, and copy his exact words into `quote`. List only changes he actually makes; a question, praise or "let's see how it goes" is not a change. If he changes something that isn't in the list, or you can't tell which item he means, put his sentence in `unclear`. Never work out a new value and never suggest one.

**Cue labels** (`/coach/reply`, structured output = `{segments: [{index, exerciseId, isCue}]}`, `exerciseId` as a per-request enum):

> Each numbered segment is one sentence or phrase from a coach's reply. For each, give the exercise it's about, from this list: {exercises}, or "none". Mark `isCue` true only when it tells the athlete how to perform that exercise (tempo, form, setup, effort). A change to sets, reps, load, macros, cardio or supplements is not a cue. Never rewrite his words.

---

## 9. Build order (Oct 27 – Nov 4)

Each phase ends with its checks passing, a commit, and a TestFlight build the human can take to the gym. Report after each phase: what passed, what didn't, what you need from the human.

**Stretch items** happen only when P1–P5 are green, in this order: Machine taken, the Garmin watch (G8 first), Withings direct, WhatsApp history import. Machine taken is about a day; plan on it being the only one that fits. Posing practice, content clips and any bar-speed or bar-path display are out of this build.

### Status (Oct 27 evening)
- **Built Oct 26:** everything in §2.
- **Built Oct 27:**
  - P1 rep counting: the phone count, continuous recording split at set ends, `/sets/count` with SAM, and G7 fixtures from a real Smith-machine bench set (hand count 7).
  - The P2 backend: `/coach/reply` with the validator and cues, and `/import/form` returning targets and cardio.
  - **P1b:** SAM as the count of record, the silent phone fallback at 60 s, `repSpeeds` and `velocityLossPct` (§5 steps 8–9), 15 fps clips, `setRole`. The G7 window through Fly at 15 fps: 33 s from upload to count (SAM runs at about 0.07 s per frame, so a 40 s set lands near 50 s). The real-session median shows on the Session-over line; it is still owed.
  - **P1c:** the cycle, rest days, add-ons, timed and role sets, day-level rest and alternates in `/import/program`; `/import/rules` with its validator; `PlanState.cycle` and the add-on planner on the phone; warm-up mode (only with his confirmed warm-up rule), holds, rest-pause sets held open; the Import review for the cycle, add-on days and his rules. Live runs on the hand-made sheet and email matched the fixtures.
  - **Check-in morning:** `/checkin/turn` with its validator, the two-message render, the free-meal draft; the conversation screen, the App Shortcuts, his cadence and the check-in period, the three-step send, the voice picker, the reminders. On TestFlight as build 202610271428.
  - **P4:** the effort map with per-exercise calibration, `RuleEngine` (every trigger, rounding to the load steps, one step per set, 10% from the plan, the back-off at the step nearest 22.5% lighter, next-session rules never mid-session), the rest-time line with "go with it" / "keep it" and the `LoadSuggestion` log, `/spotter/line` with its validator (template fallback on the phone), the logbook line, his 3–4 minutes after a top set, loads from the log on a sheet with none ("Weight for the top set?"), rules drafted from the sheet, flagged videos cropped to the reps with the "Pick two" picker and the third share, and the adjustments line. Untested in a real session.
- **Decided Oct 27:**
  - SAM is the count of record, and the phone is the silent fallback.
  - Measured effort with the coach's rules, next-set suggestions, two weekly videos for the coach, and the spotter voice.
  - The watch moves to stretch. Content clips and bar-speed displays are out.
  - The tagline is "The prep that logs itself."
  - Machine taken (swaps and reorders in the coach's order, reported in the check-in) is the first stretch item, ahead of the watch.
  - The athlete's real sheet needs the cycle, rest days, add-ons, timed sets and set roles (P1c), before his gym tests.
- **Decided Oct 26** (§13): the spreadsheet arrives as a Google Sheets link; the check-in is due **Thursday morning**; the backend is on Fly.
- **Untested:** every phone flow, in a real gym or at home.

### Sessions, Oct 28 afternoon (the between-set conversation and add-ons)
- [x] **P0 before Friday's Day 5 gym test:** voice during a set (rules only), pocket sets and count routing, the classifier fixes (each with a test), the end-session yes, one open ask, silent chatter and the ask-back as the action, the utterance queue and 8 s timeout, `/voice/command/text` with the realtime stream and the session VAD, rest lines as templates only, the logbook line on "top set" and Last time entry (§7, The between-set conversation).
- [x] **P0 add-ons:** vacuums said and shown once, holds that run themselves, the screen kept awake, no camera for an all-timed session, no warm-ups on add-ons or bodyweight lifts, "Weight for these?", abs by voice and never to SAM, "12 reps" with no load, the slash read as "or" (§7, Add-ons in a session).
- [x] **P1:** questions and notes; "next exercise" with sets left; `swapTo` / `equipmentTaken` / `equipmentFree` logged as `PlanDeviation` (the minimal Machine taken above).
- [x] **P2:** `backend/tests/fixtures/conversations/` (scenarios A–L), read through the real rules by `test_voice.py` and driven end to end by `ConversationTests`; Developer → Rehearse a session.
- [x] **Machine taken (P1 §13 a–f, Oct 28 evening):** his order asked once and confirmed, the catalog, his alternates and the same lift on other equipment, the spoken offer and the `TakenCard`, "go with it" / "the other one" / "I'll wait" / "it's free", the swap's own load, the off switch, and adjustments and gym changes in his notes field with untick on Review and send. Scenario D now runs on the offer.
- **Still to build:** moving a later lift up when a machine's taken (the fatigue check needs the exercise tags confirmed on Import); the tempo line (P1 §14: `tempo` at import, `repPhases` from `/sets/count`); SAM speed (the counting clip written during recording).
- **Waiting on the human:** one morning of vacuums run hands-free; the phone locked in a pocket during a session (mic, voice and clock keep running); Friday's Day 5 session with the debug JSON exported (nothing lost, nothing misfiled, nothing said to chatter). The backend on Fly needs a deploy for `/voice/command/text` and the new intents.

### After the first gym test (Oct 28 evening)
Three problems from the busy gym block Friday's Day 5 test and the demo, so they come before any remaining P1 or P2 item. He sends the session debug JSON tonight; tune the numbers from it.
- [x] **First, by Friday: hearing** (§7, Hearing him in a gym): the AirPods mic by default, an external mic first, the live input on the HUD, the session VAD (8 dB, 150 ms, 0.15 s, 0.8 s), the stream at 6 dB with Voice Transcribe's final words ending the turn, near misses heard and logged, the floor rising after a maximum-length noise, barge-in with a head-worn mic, Apple voice processing behind a Developer switch. *Untested on a device; the 20-phrase test is his.*
- [x] **First, by Friday: arming and lock-on** (§7, Sets start on his word): "go" arms, his movement starts the set, 20 s lapse, the camera follows only the body picked when he armed, SAM sees his station only, the reminder for his first three sessions. *Untested on a device.*
- [x] **Next: the conversation** (§7, Talk to it like a person): `/session/turn/text` and `/session/turn` with the validator, the phone's turn with facts and the last 8 exchanges, several actions per turn, the first-session intro, the on-screen hints. *Fly needs a deploy for `/session/turn` and the crop; until then the phone uses the old command path.*
- [ ] **Waiting on the human:** tonight's session JSON (does it confirm the phone mic and the 13 dB VAD?); the 20 phrases with music, AirPods mic against phone mic (target 18 of 20); voice processing on against off on the same phrases; a deploy to Fly; Friday's Day 5 session with the camera on the tripod in a busy gym.
- [ ] **Then:** whatever is left from the P1 list above (moving a later lift up, the tempo line, SAM speed).

### The session flow and screen (Oct 28 night)
- [x] **§1 He drives, Setecho follows** (§7): rest's up moves nothing and counts overtime, holds wait for "go", a finished exercise names the next and nothing of it starts until he moves, automatic decisions said and undoable, `goTo` / `addSet` / `endExercise` / "where am I?", late SAM counts silent unless they change what he heard. *Untested on a device.*
- [x] **§2 Built for not looking** (§7): the four tones and three haptics; the front camera behind Settings → "Camera faces you". *Untested on a device.*
- [ ] **§2, the human:** SAM's count front against back on a few clips, then turn "Camera faces you" on by default (or not); a whole Day 5 session without looking at the phone.
- [x] **§3 The session screen:** reviewed twice and rebuilt in the app's own style with his camera in the middle (light only), approved, and wired in: the live mapping, the camera preview with the lock-on, the replay during rest, the voice card, the open question on its card; the old layout is gone; DESIGN.md (Session) describes it. *Untested on a device.*
- [ ] **§3, the human:** a session on the tripod with the front camera ("Camera faces you" on) to see the picture, the brackets and the replay; then decide whether "Camera faces you" becomes the default (after SAM front against back).
- [ ] **His debug JSON:** every point where the plan moved without his word, each as a test.
- [ ] **Gym test, AirPods mic plus music:** Developer → Hearing → "Test music with each mic setting" with music playing (send the lines it shows); then a whole session on the AirPods mic with music: no errors, the music never stops or stays down, every line heard. The session JSON's `audio` list says what iOS applied at each step.
- [ ] **A Fly deploy** for the new intents (`goTo`, `addSet`, `endExercise`, `whereAmI`) and the front-camera crop.

### What's left (Oct 28)
Everything ticked below is built; "untested" still applies to every phone flow until it has run in the gym or at home.
- **Waiting on the human:** Thursday's first real check-in (P3); his real coach reply as the loop's first test; a real session's debug JSON (Settings → Developer → Session data → Share, saved to `backend/private/sessions/`) for the P1b median and P5 tuning; the gates G1, G2/G3/G6, G5 and G7 below; the App Group in Xcode so the share extension can be embedded.
- **Block 2 (Thursday):** camera speed (the second writer during recording, the tighter clip window, stage timings, 30 s to the measured line); `PlanItem` replacing add-ons; default filming (the tripod only for the top sets of the 1–2 main lifts, named on Today).
- **Block 3 (Friday):** P4 in a real session: warm-ups, the measured line on every top set, the back-off load from his rule, nothing suggested without a confirmed rule; the two flagged videos in the check-in.
- **Block 4 (Saturday):** P5 tuning from the sessions' debug JSON; the day's plan in time order on Today; cardio and steps checked against Apple Health; the PlanItem notifications.
- **After that:** fixes only (Sunday freeze), then P7–P9. Stretch (Machine taken, the watch, Withings, WhatsApp history) only if all of the above is green.

### Plan and priorities, Oct 27 evening (replaces the order above where they differ)
Report after each numbered block: what passed, what didn't, the measured latencies, and what the human owes.

**Block 1, Wednesday: Thursday's check-in, ready and rehearsed.** Check-in morning on TestFlight by Wed 6 PM; the human rehearses at 7 PM; fixes only from what he reports; final build by 10 PM. Targets: 1 s or less from end of speech to first audio on number answers, 2 s or less otherwise; report the measured numbers.
- **Built Oct 27 night** (all of the items below except the iOS 26 AirPods recording trial): measured through Fly from the Mac, file-mode Transcribe took 2.3–3.0 s per turn and Spark 1.9–2.3 s on a sentence, so the realtime stream carries the words: the final transcript lands 0.1–0.6 s after the end of speech (the socket opens during the speech, in 0.9 s). A number turn then needs only the fast path (no Spark); a sentence still pays Spark's ~2 s. The phone's own first-audio numbers show on the Probes screen after the rehearsal.
- **From the Oct 27 rehearsal (built that night, builds 202610272026–2044 and after):** the wrap-up on the Check-in tab shares `NaturalVoiceSpeaker`; cached lines play on a file node of the same `AVAudioEngine` as the live PCM (a separate `AVAudioPlayer` was dropped as the input engine started, which silenced the opening); a line whose cache fetch is landing waits ≤700 ms for it; the status check retries once; the Probes card shows the voice state (provider, cached/live/system counts, last fallback reason). Check-in morning opens with an **introduction from code** (`CheckInMorningFlow.intro`: first name from Settings, the due weekday, "a rehearsal of" on any other day, then weight, glucose, four photos, the coach's questions), pre-generated and warmed before it is due. **It starts itself** (`MorningStart`): the first time the app is in front on the due morning before the 8:40 guard with nothing sent that day, the flow opens with no tap, once per day; a notification at `Settings.checkInWakeTime` (default 06:30) opens the app into it, and a Shortcuts time automation running "Start my Setecho check-in" makes it fully hands-free. Today shows "Rehearse the morning" on the other days.
- **From the second rehearsal (Oct 27 night):** the photo session speaks through the natural voice (pose cues and framing lines pre-generated); framing guidance is paced like a person at the camera (4 s to get into position after the pose cue, a cue only after the framing has held 1 s, the same cue no sooner than 8 s later and at most twice, a different cue after 2.5 s, silence once framed); the screen stays awake in Check-in morning, the photo session and the wrap-up (`isIdleTimerDisabled`), and leaving the front pauses the morning (`enterBackground`/`enterForeground`) and cancels the photo session instead of cueing an empty frame on repeat. The voice detector needs 13 dB over the room for 350 ms, and an utterance whose transcript has no letters or digits is ignored in silence (no "say that again"). "Rehearse the morning" starts fresh (`AppRouter.morningFresh`: the unsent draft is discarded and rebuilt, today's photos set aside until a new set is taken). The Probes card shows the open-to-stage times (voice, intro, draft, first question). **Changing an answer:** by voice, `change` is a new turn intent (`changeFieldId`, picked by code from the template): the field goes back to missing and is asked again ("let me change my biggest win"); a `correction` with the value still works; on Review and send a "Change an answer" card opens each answered field in the edit sheet and rewrites the message.
- **From the third rehearsal (Oct 27 night):** the slow part between steps was `refreshWeightToday` rebuilding the whole draft (the week from Apple Health, then Spark) on every resume while the weight was "filled" rather than "confirmed"; it now reads today's weigh-in with one query (`HealthService.weighInLb`) and never rebuilds, and the week's eight Health queries run at the same time (`async let` + a task group). The weight step **offers** Apple Health's number ("Apple Health has 180.8. Use that, or tell me the number."): yes confirms it with provenance, a number replaces it by voice, no asks for the reading. "Rehearse the morning" no longer discards the draft: `resetSpokenAnswers` puts the spoken fields and the weight back to unanswered and keeps the data-filled fields and Spark's drafts, so a rehearsal starts in seconds. A turn ends after 1.2 s of quiet (was 0.7 s; he felt cut off) and may run 25 s. **Videos from the camera roll:** the picker has a "From your camera roll" card (PhotosPicker, videos only); the file is copied into the media folder (`VideoPick.sourceFile`), counts as one of the two, and is sent whole at 720p through the same export.
- **From the fourth rehearsal (Oct 28 morning):** the send was refused ("draft.adjustments: extra inputs are not permitted") because the backend's `CheckInDraft` forbade the phone's `videoPicks` and `adjustments`; it now carries both through (`VideoPick`), which also keeps next week's draft request (it sends last week's check-in) from failing. The cardio field is the coach's protocol word for word; what was logged stays in the provenance, and with no protocol the field is asked. Re-asks: the phone kept only the latest final segment from Meta's realtime stream, so an answer with a pause reached the backend cut in half; `RealtimeTranscriber` now keeps every segment. Cut-offs: a finished line's completion or safety timer could end the next line; each line in `PCMStreamPlayer` now has its own generation. The live first-byte deadline is 1.5 s (700 ms let lines drop to the system voice). Unclear turns carry `unclearReason` (noWords, model, reply, field, number, empty), counted on the Probes card without the words. Data-filled fields he never heard (steps, consistency, weeks out) are read back before review **one at a time, like the questions** (Oct 28: all in one line was too much): "From your data: average daily steps, 9.4k. Sound right?", then "Training consistency, 100%. Sound right?"; yes confirms it, no asks it as a question, a new value replaces it, skip moves on. Each line is pre-generated in the natural voice. Camera-roll videos go out exactly as chosen, no re-encode; set clips are cropped when Review and send opens, not at the third send. **Network:** on Oct 28 this Mac's network answered every DNS query for setecho-api.fly.dev (and api.meta.ai) with a Cisco Umbrella block page (146.112.61.110), even via 1.1.1.1; a phone on that Wi-Fi cannot reach the backend either. Live checks go through `fly ssh console`.
- **From the fifth rehearsal (Oct 28):** answers went unheard the first time with no unclear turn logged. Two causes in code: speech that arrived while a turn was in flight (often a noise turn) was dropped, and a turn with no words got no reply at all; and the noise floor was the median of the first 2 s of listening, so an answer started inside that window became the floor. Now the latest utterance during a turn in flight is kept and read when that turn comes to nothing, a long utterance with no words gets "Sorry, I didn't catch that", the floor is the quietest fifth of the window and follows the room while quiet, and "use that" / "sounds good" count as yes. The Probes card shows a "Heard" row (turns, queued, tooShort, noWords). Photos: the side cues say which side faces the camera ("Right side to the camera, arms up"); stillness is IoU ≥ 0.93 for 1 s with two shaky frames forgiven (was 0.97 for 1.2 s, any shaky frame reset it); once framed it says "Hold it there", after 4 s framed "Hold still for a second", after 7 s framed it takes the photo anyway, and after 15 s without a capture it repeats the pose cue; a larger hold bar shows on the HUD.
- **AirPods mic (Oct 28, optional, built, untested on a device):** Settings → Voice → "Use AirPods mic", off by default. On: `.playAndRecord`, mode `.default`, options HFP + `.bluetoothHighQualityRecording` + A2DP (plus duck or mix), all through `AirPodsMic.options`, the one place every activation takes its options from. Off: A2DP output with the DJI receiver or the iPhone mic, as before. After each activation and on every route change, `AirPodsMic.check` falls back for the rest of the run when the output is HFP and the input port's `bluetoothMicrophoneExtension.highQualityRecording.isEnabled` is false (iOS dropped to call quality), when there is no output, or when the options are refused; it then says "AirPods mic unavailable, using the DJI mic" (or "iPhone mic") on Check-in morning, Settings and Probes. Probes has the iOS 26 input picker (`AVInputPickerInteraction`) beside the live route readout and the AirPods state.
- **From the sixth rehearsal (Oct 28):** a pause before the mic heard him after each line: every natural-voice line ducked the music before it and restored mixing after it, two session category changes per line, and the mic stayed closed until the second one finished. Check-in morning, the photo session and the wrap-up now hold the ducking for their whole run (`AudioService.holdsDucking`), so the mic reopens the moment a line ends; sessions still duck per line. The indicator is a larger ring with "Your turn" in cobalt, shown only while the mic is actually open, and it follows his voice ("Hearing you"). The system voice: a live line now waits 2.5 s for its first audio, then retries once as a whole MP3 (4 s) before the system voice, and a voice status that failed at start is asked again on the next line (at most every 10 s).
- [x] **Timing:** log every stage of a check-in turn (end of speech, upload, transcribe, Spark, validator, first audio) to the debug JSON; live stage timings and medians on the Probes screen.
- [x] **Warm backend:** Fly `min_machines_running = 1`, auto-stop off, the region nearest Wichita (dfw or ord); one keep-alive HTTP client for Meta; the app pings `/health` when Check-in morning or a session starts.
- [x] **Realtime transcription:** check-in turns stream mic audio through the backend to Voice Transcribe's realtime WebSocket, with Meta's endpointing deciding when a turn ends. File mode stays as the fallback. *Built with the phone's voice detector ending the turn; Meta's endpointing mode is unverified.*
- [x] **Number fast path:** a transcript that is only a number (or the three tape measurements) for the field just asked is parsed by code and answered from a template, with no Spark call. Spark handles everything else.
- [x] **Spark at its lowest reasoning effort** with small max tokens for `/checkin/turn`, `/voice/command` and `/spotter/line`. *Built without the token cap: a cap cut the JSON off.*
- [x] **A soft sound** the moment a turn ends.
- [x] **The voice, on the device** (replaces the natural voice, Oct 28). *Removed:* ElevenLabs/Cartesia, `/voice/speak`, `NaturalVoiceSpeaker` and the backend's numbers-to-words (now `SpokenText` on the phone): every runtime model must be Meta's. `SystemSpeaker` with Ava (Premium), numbers as words, lines written to be heard, no line twice in a row, the fixed lines pre-rendered with `AVSpeechSynthesizer.write` when the flow starts (§7, The spotter voice). The rehearsal notes above that mention the natural voice describe builds before Oct 28.
- [ ] **Audio route:** AirPods out at full quality (A2DP, never call-quality Bluetooth); in from the DJI receiver when plugged in, else the iPhone mic; iOS 26 high-quality AirPods recording may be tried, falling back to the DJI/iPhone mic. The live route shows on the Probes screen. Check-in morning and sessions use the same route. *The AirPods mic switch is built and untested on a device.*
- [x] **Filming mode** (Settings, off by default): every line Setecho speaks saved as audio exactly as played (the voice service's stream, or `AVSpeechSynthesizer.write`), every utterance saved as its WAV, every file stamped from one clock; one SRT captions file per check-in or session; a slate on start (a white flash and a short beep, with its time logged); export by AirDrop from History; never uploaded, never committed; no change to timing or behaviour.
- [x] **Photos** as in §7: hands-free capture with the head-to-toe framing check and "retake front"; the collage, alignment and outline out of the flow; `/photos/segment` no longer called.
- [x] **Check-in morning** (§7 and P2) plus the three-step send `[plan message]`, `[questionnaire text + four photos]`, `[two videos]`, the weekly period, the free-meal draft, and "Current Goal(s)".
- [x] **Readiness, before the 6 PM build:** a scripted run in tests (a pause, a two-field answer, a correction, a question for the coach, every number from the transcript); a format check against a real past check-in in `backend/private/` (labels, order, carried blocks, the plan message as its own message), differences reported; a Facts screen (debug) with every data field and the raw values behind it; Rehearsal mode on Review and send (off by default) that sends all three steps to the athlete's own chat; a deadline guard: not sent by 8:40 AM Central, Review and send opens with what's ready and the missing fields can be typed.
- [x] **Today:** the cycle follows the day of the week when it is seven days long (Day 1 on Monday), with "Change day" as the override; a clean loading indicator wherever data is being read (Import, the check-in draft, Review and send).
- Keep the current build working for the Wednesday workout (2–3 filmed sets for SAM data and timing).

**Block 2, Thursday** (the first real check-in that morning).
- [ ] P1b as above, plus **camera speed:** write the counting clip during recording (a second writer at 480p and 15 fps, cropped to the body-pose box) so nothing is exported at set end; clip window start − 1 s to end + 0.5 s; stage timings for export, upload, SAM and math; 30 s or less to the measured line.
- [ ] P1c as above, plus the add-on as a general **PlanItem**: what (lifts, holds, cardio, supplement, meal or habit), when (cycle days, N per week, daily or set weekdays, plus an anchor: on waking, before, during or after the session, with meals, a clock time, before bed), the coach's quote, and tracking (by session, Apple Health, voice, or none). The import builds PlanItems from the sheet, the form's carried blocks and the email; items anchored to the session are spoken when it starts ("Intra-workout: EAAs, sodium, creatine").
- [ ] **Default filming:** the tripod only for the top set of the day's 1–2 main lifts, everything else by voice; Today names which sets to film.
- [x] The coach reply loop (P2) on TestFlight by Thursday evening; his real reply is its first test. *In every build since 202610271428; his real reply is still its first test.*

**Block 3, Friday** (the first full camera test in the gym): P4 as above.

**Block 4, Saturday** (the rehearsal shoot): P5 tuning from Friday's and Saturday's debug data, plus:
- [ ] Today shows the whole day's plan in time order.
- [ ] Cardio and steps checked against Apple Health (workouts matched to cardio PlanItems, steps against their daily target); the check-in's cardio field uses these numbers.
- [ ] Local notifications: a morning summary at wake time; one per PlanItem with a time or anchor ("Vacuums, on waking" starts the morning session; rest-day LISS clears itself once Apple Health shows the workout); wake time and bedtime in Settings; no notification for "with meals" items (session items are spoken); nothing while a session runs; a switch per kind; a rolling 7 days within iOS's 64 pending; no logging of meals or supplements.

**Block 5, Sunday:** fixes only. **Feature freeze Sunday night.** Stretch items only if everything above is green before Sunday; realistically none, and that is accepted.

**Mon Nov 2:** the main shoot, no code changes. **Tue Nov 3:** fixes only for pickups. **Wed Nov 4:** README final, `design/` purged from history with the human's go-ahead, repo public, submitted by 6 PM CT.

### Gates still open
- [ ] **G1 organizers.** The human confirms in writing that the app isn't a "sports analyzer or coach": it counts reps from phone video and applies the coach's own rules to suggest the next set's weight, for a human coach. The next-set suggestions and the machine-taken swaps and reorders are asked about by name.
- [ ] **G2 audio, G3 Apple Health, G6 share.** The human runs the probes from TestFlight (More → Probes). G6 also covers exporting one of the coach's voice notes out of WhatsApp.
- [ ] **G5, extended.** Run `import_probe` on two other coaches' check-in forms the human brings, and `reply_probe` on two of his real past replies.
- [ ] **G7 SAM reps.** `scripts/sam_reps_probe.py <mov> --equipment barbell` (built in P1) downscales the clip to 720p at 15 fps, calls SAM with "weight plate", runs `reps.py`, and prints the count, the rep times and the seconds from upload to count. Raw output goes to `backend/private/`; `--fixture` saves only the per-frame centroid series. **Pass:** the count matches the human's count of a real set of 8, one plate is tracked on every frame, and it takes under 60 s.

### P1 — Rep counting (Tue Oct 27, built)
- [x] `scripts/sam_reps_probe.py` (G7: §6 SAM on video, §5 `/sets/count`).
- [x] `backend/app/reps.py` and `/sets/count`, with the synthetic series and tests.
- [x] `SetDetector`: continuous recording split at set ends, the real start and end, and the two exports (§7, Set detection). Today it starts `AVCaptureMovieFileOutput` at set start, which loses the first rep.
- [x] `RepCounter` on the pose frames, extending `WristSignal` to every joint.
- [x] `LoggedSet.repCount` with its migration; the measured-count rules and callouts; `SourceChip` on Session and History.
- **Done when:** G7 passes on the human's clip, and a simulated session in `SessionEngineTests` logs a phone count, then applies a measured correction with undo.

### P1b — SAM as the record (Wed Oct 28 morning, small)
- [x] The rep-counting rules in §7: SAM as the record, the silent phone fallback at 60 s, and the set-end callout without the count.
- [x] 15 fps clip export, and `/sets/count` returning `repSpeeds` and `velocityLossPct` (§5, steps 8–9).
- [ ] Report the median SAM time from set end to result, on the G7 clips and one real session. *G7: 33 s through Fly. The real session is owed: Settings → Developer → Session data → Share exports its debug JSON with every SAM latency.*
- **Done when:** `SessionEngineTests` cover SAM on time, SAM late (the phone count spoken at 60 s, then replaced), SAM at low confidence, and "that was N".

### P1c — His real sheet (Wed Oct 28, before Check-in morning)
His sheet has an abs tab first, two rest days, timed holds, top and back-down sets and rest-pause sets (§7, Training cycle and add-ons). Today it would import with abs as Day 1, and Today would show it forever.
- [x] The import: the cycle, `kind`, `cardio`, `addOns`, `seconds`, `totalReps`, `role`, the day-level rest period, slash names; the prompt and schema changes; the Import review for the cycle and add-on days.
- [x] `PlanState.cycle` replacing `Store.nextDay`; "Change day"; the rest-day card; add-ons joining sessions, catch-up, "add abs" / "skip abs".
- [x] Warm-up sets: warm-up mode, the `topSet` and `warmup` intents, the phone classification, no SAM upload for warm-ups.
- [x] `/import/rules` with its validator, run on his onboarding email, and the Import review for each rule found.
- [x] Timed sets in `SessionEngine`; the morning add-on session with its App Shortcut; rest-pause sets held open in `SetDetector`; `setRole` sent to `/sets/count`.
- **Done when:** the human's sheet imports with 7 cycle days (5 training, 2 rest) and 2 add-ons, nothing flagged that's clearly written. A simulated week shows the right day each morning (a missed day waits, rest days pass with the calendar), abs join the two days he confirmed, and the vacuums session runs 4 × 20 s hands-free.
- **If it threatens Check-in morning's Wednesday-evening ship:** the import, the cycle and Today go first; timed sets and the morning session move to Thursday.

### P2 — Check-in morning, coach reply and voice cues (Wed Oct 28 – Thu Oct 29)
Order matters. **Check-in morning ships to TestFlight by Wednesday evening,** because Thursday morning is its first real use. The coach reply loop ships by Thursday evening, because his reply to that check-in is its first real test.
- [x] `PlanState` and its migration (§4). Every plan reader goes through `store.plan`.
- [x] `/coach/reply` with changes, unclear items and cues; the validator; prompts; tests on synthetic replies.
- [x] The Coach reply screen, the Today card, the MacroFactor reminder, and revert under History → Plan changes.
- [ ] Getting replies in: paste and audio file import first, then the `SetechoShare` share extension. *Paste and audio import are built; the share extension is built but not embedded until the App Group is registered in Xcode (`ios/SetechoShare/README.md`).*
- [x] Voice cues: cutting, review, playback rules, `replayCue`, and the Settings switch.
- [x] **First:** Check-in morning (§7) with `/checkin/turn`, the App Shortcut, pause and resume, and the voice picker.
- [x] **Also before Thursday:** the send in his order (the plan message, then the questionnaire with the four photos, then the videos), the check-in period since the last check-in, the free-meal draft, and "Current Goal(s)" drafted from the last check-in if his form has it (§7, Check-in).
- **Done when:** two of his past replies (one text, one voice note) produce the right changes and cues, and a simulated session plays the cue before the right exercise and never during a set. A scripted run of Check-in morning, with a pause, a two-field answer, a correction and a question for the coach, finishes with every number taken from the transcript.

### P3 — First real check-in (Thu Oct 29 morning)
- **The human:** Thursday morning, say "Hey Siri, start my Setecho check-in" and go through it hands-free, then send. Screen-record the whole run, and film it with a second camera.
- **The agent:** fixes only, from whatever broke.
- **When the coach replies,** the human shares it in and screen-records the Coach reply screen.

### P4 — Measured effort, the coach's rules and the spotter (Thu Oct 29 – Fri Oct 30)
- [x] The effort map and calibration; `RuleEngine` with rounding and limits; rules drafted at import and confirmed; the one-time question when there's no rule; set roles and the role-targets question (§7, Measured effort).
- [x] The rest-time line (measured count, effort, suggestion); the "go with it" / "keep it" intents; the `LoadSuggestion` log; the Settings switch.
- [x] `/spotter/line` with its validator; the set-end callout variants; session memory for PRs and streaks.
- [x] Videos for your coach: `flagSet`, the crop to the reps from `repTimes`, the Review and send card; the adjustments line in `/checkin/render`.
- [x] His rules in the engine: the back-off load, rest after a top set, the logbook line, and the next-session steps (§7, Measured effort).
- [x] The `Speaker` protocol with `SystemSpeaker`, the only voice.
- **Done when:**
  - In a real session, warm-ups log as warm-ups, every top set gets its measured line against his failure target and a back-off load from his 20–25% rule, and nothing is suggested without a confirmed rule.
  - The check-in carries the two flagged videos cropped to the reps, and the adjustments line.

### P5 — Tune (Fri Oct 30 – Sat Oct 31)
- [ ] Thresholds for `SetDetector`, `RepCounter` and the effort map, from the debug JSON of real sessions with spoken RPEs.
- [ ] Fixes from P3 and P4.
- **Done when:**
  - Three real sessions in a row where every set's reps are right or were fixed by voice.
  - On barbell sets, the estimated reps in reserve are within one rep of the athlete's spoken RPE most of the time.

### P6 — Stretch (Sat Oct 31 – Sun Nov 1), only if P1–P5 are green
In the order above. Specs:
- **Machine taken** (§7, Machine taken). About a day.
  - [ ] `ExerciseFamilies.json`; tags and alternates from `/import/program` with the prompt change; the Exercise tags review and the "When a machine's taken" question on Import.
  - [ ] `TakenEngine` and its tests; the new voice intents; the templated lines; `PlanDeviation` logging with `doneAs`; loads from the variant's own history.
  - [ ] The Gym changes card on Review and send, the line in `/checkin/render`, the urgent-note message, and the Settings switch.
  - **Done when:** in a real session, "the bench is taken" offers his first choice and a second, "go with it" logs it, the swapped lift's load comes from its own history or the athlete, and the check-in shows the change. On a scripted chest day, flyes or pushdowns are never offered ahead of a press.
- **Garmin watch.**
  - **First, G8:** a minimal watch app sends `setEnd` with a wrist count after each set to a probe screen under More → Probes. **Pass:** messages arrive within 3 s, and counts match on 3 sets each of bench press, rows and curls. If it fails, drop the watch: no second attempt.
  - **Then:** the watch app (§7, Garmin watch), `WatchService`, the Connections screen, and the input rules (§7, Session inputs), with the `config` thresholds sent from the phone and watch summaries in the debug JSON.
  - **Done when:** a session with the tripod on some exercises and the phone in a pocket for the rest has zero taps after Start.
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
### P7 — Rehearsal and freeze (Mon Nov 2)
- [ ] A full end-to-end run: a session mixing tripod and pocket, photos, check-in, coach reply. Fix bugs only.
- [ ] Feature freeze tonight.

### P8 — Film (Tue Nov 3)
- [ ] The human films the gym and photo segments. The check-in and coach reply segments use the P3 recordings.

### P9 — Submit (Wed Nov 4)
- [ ] The README states what was built during Oct 26 – Nov 4 and which Meta model does what.
- [ ] `design/` purged from git history (§11), with the human's go-ahead, before the first push.
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
  - `/checkin/turn` handles a pause, a resume, a two-field answer, a correction and a question for the coach, and turns any number not in the transcript into `unclear`
  - `reps.py` returns rep speeds and velocity loss on a synthetic set that slows by a known amount, and on the G7 series
  - `/spotter/line` rejects a line with a number not in the facts, with advice, or with an opening it used recently
  - the rules prompt returns no rule for a sheet that has targets but no rule
  - the import tags every exercise with a family from the enum or none, and never adds an alternate the sheet doesn't contain
  - `/import/rules` on a hand-written email with the same kinds of rules returns each with a verbatim quote, moves a rule whose number isn't in its quote to `flags`, and returns no names, numbers or links
  - the render returns the plan message and the questionnaire as two messages, in that order
  - a hand-made sheet with the athlete's shape (an add-on tab first with a 4x-on-waking block and a 2x block, rest tabs with a cardio line, timed holds, top/back-down and rest-pause sets, a day-level rest period) imports with add-ons outside the cycle, rest days as `.rest`, and the right `seconds`, `role` and `totalReps`
- **iOS:** `make ios-test`. Unit-test the adherence and day-type rules, PR detection, the set logging rules, undo, the collage layout math, the HealthKit aggregation, `RepCounter` on the shared series, the measured-count rules, each change kind's apply logic and plan revert, the `PlanState` and `repCount` migrations, the input rules in §7 (every start/end/reps precedence case), watch message decoding and clock conversion, cue playback timing (Ready only, once per session, never during a set), Check-in morning's step order, pause and resume after a relaunch, the rep-counting rules (SAM on time, late, low confidence, the phone fallback at 60 s), the effort map and its calibration, `RuleEngine` (every trigger, rounding, the step and 10% limits, double progression to the next session), suggestion decisions, the two-video ranking, and `TakenEngine` (his order, the fatigue check on a chest day and a leg day, no reorder with unconfirmed tags, a second taken machine, no barbell-to-dumbbell load conversion) with the Gym changes line, the cycle cursor (a missed day waits, a rest day passes with the calendar, the wrap), add-on days and catch-up, timed sets, rest-pause sets held open, role-scoped suggestions, warm-up classification and its voice fixes, the back-off load (the step nearest 22.5% lighter), the next-session steps, crop windows from `repTimes`, the check-in period since the last sent check-in, the cycle following the weekday, and the quiet day, all with synthetic samples.
- **Never** hit the live API in tests.

## 11. Privacy and repo hygiene (the repo becomes public)
- **Never commit:**
  - the athlete's photos, set videos or audio
  - the coach's program sheet: the import fixture is a hand-made sheet with the same shape
  - the coach's onboarding email or any of his written instructions: the `/import/rules` fixture is a hand-written email with the same kinds of rules, naming no one
  - real Health values or real check-in answers
  - the coach's name, phone number, replies or voice notes (`/coach/reply` fixtures are synthetic replies written for the tests)
  - API keys, `.env` files or `Local.xcconfig`
- `.gitignore` already blocks clips, `.env` and `Local.xcconfig`. Add `*.wav`, `*.opus`, `*.ogg`, `*.m4a`, `*.jpg` outside `design/`, and `ios/Probes/output/`.
- **Fixtures use synthetic values.** The form fixture keeps the coach's field labels, with placeholder numbers for macro targets and supplement doses.
- **`design/` stays out of the repo (decided Oct 27).** It's local reference only.
  - **Now, in its own commit:** add `design/` to `.gitignore`, drop the `!design/**` exceptions, and run `git rm -r --cached design`. The files stay on disk for reference.
  - **The README and docs must not link anything under `design/`.** The repo goes public. If the README needs an image, use a screenshot of the real app taken after kickoff, kept in `docs/`.
  - **Why:** it holds working files and references, not product code, and only work from after the kickoff cutoff (12:24 PM ET, Oct 26) belongs in the submitted repo.
  - **History:** the folder is already in history from `6fc246f`. In P9, before the first push and only with the human's go-ahead, purge it with `git filter-repo --invert-paths --path design/`, which keeps commit dates.
  - **The app's logo, wordmark and icon** in `ios/Setecho/Assets.xcassets` stay.
- Photos never go to Meta (the framing check runs on the device); set clips go only through `/sets/count` (downscaled, no audio), and the coach's voice notes only through `/coach/reply`. Filming-mode exports stay on the phone and are never uploaded or committed. All Standard tier: gyms have bystanders. Cut cue clips of the coach's voice stay on the phone, under `media/cues/`. Withings tokens live in the Keychain, never on the backend or in the repo. Speech is synthesized on the phone; no text or audio goes to a voice service.

## 12. Things only the human can do
- Put `MODEL_API_KEY` in `~/.zshrc`, claim the $150 credits, and set a spend limit.
- Set the Apple team ID in `Local.xcconfig`, and test on the real iPhone, since HealthKit and the DJI mic need a device.
- Create the backend host account and deploy.
- Keep the GitHub repo private while building (run `git remote add origin https://github.com/Lyquifyy/setecho.git` when ready), and make it public before submitting.
- Ask the office-hours question, and get the coach's OK to appear in the demo.
- Tell the coach his voice notes are transcribed through Meta's API, and collect two of his past replies (one text, one voice note) for G5 and P2.
- Hand-count every set during the gym tests, and call out an RPE on every set so the effort map can be checked.
- Download Ava and Zoe (Premium) on the iPhone (Settings → Accessibility → Read & Speak → Voices → English) and tune the speed at the rehearsal (Settings → Voice).
- Tell the agent your coach's load-adjustment rule if it isn't in the sheet, and check it with him.
- Ask the organizers about the next-set suggestions and the machine-taken swaps in the same thread as G1.
- On Import, confirm which days abs join and which mornings the vacuums go on.
- Paste your coach's onboarding email into Import → His instructions and confirm each rule it finds. It already answers how hard top and back-off sets go (to failure) and the back-off load (20–25% lighter). Check-ins are weekly.
- Ask your coach what he wants when a machine's taken (the same lift on other equipment, move a later lift up, or wait), and whether his sheet's "or" options are the swaps he'd accept. During gym tests, say "it's taken" whenever it really happens.
- Garmin setup (about an hour, only when the watch stretch item starts): install the Connect IQ SDK Manager, the SDK and the Venu 4 device files; generate a developer key outside the repo; install OpenMTP if the watch mounts as MTP; sideload the G8 probe.
- Ask the coach whether his voice can play in your sessions, and appear in the demo.
- Bring two other coaches' check-in forms for G5.
- For Withings direct (stretch): register the Withings developer app and set its two Fly secrets.
- Do the physical tests: the gym sessions, photo rounds and WhatsApp send.

## 13. Defaults for open questions (change when the human answers)
| Question | Default |
|---|---|
| How the spreadsheet arrives | **Decided Oct 26: a Google Sheets link.** The backend fetches the sheet's CSV export (`/export?format=csv`); the sheet must be shared "anyone with the link". A `.csv`/`.xlsx` file, pasted text and a screenshot stay as fallbacks |
| Check-in day | **Decided Oct 26: Thursday morning**; reminder Wednesday 7 PM: "Tomorrow's check-in: say 'Hey Siri, start my Setecho check-in' when you're up" |
| G1 organizers | **Decided Oct 26: not a sports analyzer or coach.** Human confirms in writing on Oct 27 |
| Gates G2–G6 | **Decided Oct 26: build on the plan's defaults** and test on the phone from TestFlight, not from the Mac. The probe screens live under Settings → Developer until the P7 freeze (Mon Nov 2) |
| Photos | The four full photos as taken, in his order; no collage (decided Oct 27 evening) |
| "Current body weight" | Check-in morning weigh-in |
| Rest time when the sheet has none | 150 s |
| Macro tolerance | kcal ±5%; protein, carbs and fat ±10 g |
| Proposed changes on the review screen | Checked; the "Apply" tap is the approval |
| A change with no start date | Applies from the next session |
| Reps in the log | You said, then Measured, then Phone, then Watch, then Plan (§7, Session inputs) |
| Coach's voice in sessions | On; Settings switch, plus a checkbox per cue |
| Check-in morning voice | The best installed iOS voice, premium first. Never the coach's |
| Watch thresholds | `startStd` 120 mg, `endStd` 40 mg, sent from the phone; tune in P5 |
| Next-set suggestions | On; only with a confirmed coach's rule; the athlete decides each one |
| Effort map (velocity loss → reps left) | Under 10% → 4+, 10–20% → 3, 20–30% → 2, 30–40% → 1, over 40% → 0; calibrated per exercise from spoken RPE |
| Load steps | Barbell 5 lb, dumbbells 5 lb, machines from Settings |
| Spotter voice | Ava (Premium) on the device (then Zoe, then Evan), rate 0.49; else the best installed English voice. No voice service |
| Tagline | "The prep that logs itself." |
| When a machine's taken | Only Wait and the athlete's own swaps until the coach's order is confirmed; then his order |
| Exercise families | `ExerciseFamilies.json`, about 30, hand-written; the import tags against it |
| Add-on days | Proposed evenly (with-session over training days, on-waking over the whole cycle); the athlete confirms |
| Rest between timed holds | The sheet's, else 30 s |
| A rest-pause set ends after | Its third round, 75 s still, or "done" |
| A day-level rest range | The countdown runs to the top of it; a quiet cue at the bottom |
| Back-off load from a 20–25% rule | The load step nearest 22.5% lighter than the top set actually done |
| Rest after a top set | His rule (3–4 min) over the sheet's day range |
| Warm-up classification | 8 reps or fewer with under 20% slowdown, before the first working set |
| Check-in cadence | **Weekly** (decided Oct 27 evening): Thursday, by 9:00 AM Central, until the athlete changes it |
