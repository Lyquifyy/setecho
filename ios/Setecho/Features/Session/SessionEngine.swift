import Foundation
import Observation

/// The hands-free session state machine (DESIGN.md Session, HANDOFF.md §7). Pure logic: the camera,
/// microphone and speech live in services that feed it events, so every rule is unit-tested.
///
/// Logging rule: load comes from the plan, or the last spoken override for that exercise. Reps
/// follow the rep-counting rules (HANDOFF.md §7): SAM is the count of record on a tripod set, so
/// the set-end line carries no number and the count is said during rest when SAM answers. The
/// phone's own count is a silent fallback, spoken only if SAM fails or has not answered 60 s after
/// the set ended, and replaced when SAM lands. What the athlete said ("that was 7") beats both.
/// RPE is spoken. Every voice action is echoed and can be undone.
///
/// The session's exercises are the cycle day's lifts, then any add-on that joins it, under its
/// own name (Two workouts in one day). With his warm-up rule, each lift starts in warm-up mode and
/// a short, easy set is logged as a warm-up that never counts (Warm-up sets). A timed set is a
/// countdown, not a camera set; a rest-pause set's count is its total across the rounds.
@MainActor
@Observable
final class SessionEngine {
    enum State: Equatable {
        case ready
        case recording
        case saved
        case rest(remaining: Int)
        /// "Three, two, one. Hold.": the seconds before a timed set starts itself.
        case leadIn(remaining: Int)
        /// A timed set running: seconds left.
        case hold(remaining: Int)
        case listening
        case paused
        case ended

        var isListeningAllowed: Bool {
            switch self {
            case .ready, .rest, .saved, .listening, .paused, .hold, .leadIn: true
            case .recording, .ended: false
            }
        }
    }

    /// What the services should do after an event: say something, show an echo, ask back, or show
    /// what was heard and say nothing (chatter). The rest line's facts stay for the debug record.
    struct Outcome: Equatable {
        var speech: String?
        var echo: String?
        var askBack: String?
        var spotterFacts: SpotterFacts?
        var spotterReplaceable: String?
        /// "Heard: …" on the HUD for 3 seconds, nothing spoken.
        var heard: String?
        static let none = Outcome()

        /// Two outcomes in one breath: the speeches in order, the later echo and ask-back.
        func merged(with other: Outcome) -> Outcome {
            let speeches = [speech, other.speech].compactMap { $0 }
            return Outcome(speech: speeches.isEmpty ? nil : speeches.joined(separator: " "),
                           echo: other.echo ?? echo, askBack: other.askBack ?? askBack,
                           spotterFacts: other.spotterFacts ?? spotterFacts, spotterReplaceable: other.spotterReplaceable ?? spotterReplaceable,
                           heard: other.heard ?? heard)
        }
    }

    /// The one question open (HANDOFF.md §7, The between-set conversation). The latest ask owns
    /// yes, no, numbers and the choices; opening another lets the older one lapse with its
    /// default: a suggestion is kept, a count stays as it is.
    enum Ask: Equatable {
        /// "Set 3, was that 8?"
        case countConfirm(PendingQuestion)
        /// His rule's next load: "go with it" or "keep it".
        case suggestion(LoadSuggestion)
        /// A voice-only set logged with the plan's reps: "How many?" No answer by the end of rest keeps the plan's.
        case howMany(setId: UUID)
        /// "End the session? Six sets logged." Only a yes ends it.
        case endSession
        /// A count in Ready the camera may have missed: "Twelve for set 2 of flyes?" Yes logs a new set.
        case countFor(reps: Int)
        /// A command heard at 0.4–0.7 confidence, asked as the action: "Twelve reps on set 2?" Yes applies it.
        case clarify(VoiceCommandResponse)
        /// "That's one for your coach. Want me to note it for Thursday?"
        case noteOffer(String)
        /// "Next exercise" with sets left: "Log the other 2 sets of flyes from the plan?"
        case logPlanSets(count: Int)
        /// "Smith's taken. His first choice is …": his options in his order, then Wait.
        case takenOffer(TakenOffer)
    }

    /// What was offered when a machine was taken, for the HUD's TakenCard and the choices.
    struct TakenOffer: Equatable {
        var exerciseId: String
        /// What he said was taken ("Smith"), or nil when he only asked for another machine.
        var what: String?
        var options: [TakenOption]
    }

    /// "Set 3, was that 7?" waiting for a yes, a no or a number.
    struct PendingQuestion: Equatable {
        var setId: UUID
        var measured: Int
        var current: Int
    }

    /// A set SAM is still counting: when it ended, and whether a number has been said for it yet.
    struct PendingCount: Equatable {
        var setId: UUID
        var endedAt: Date
        var spoken: Bool
    }

    /// One exercise of the session, with the add-on it belongs to (nil for the day's own lifts).
    struct Entry: Equatable {
        var exercise: PlannedExercise
        var addOnId: String?
        var section: String?
    }

    /// SAM silent for this long after a set ends: the phone's count is spoken (HANDOFF.md §7).
    static let fallbackSeconds: TimeInterval = 60
    /// A warm-up is 8 reps or fewer with under 20% slowdown, before the first working set (§13).
    static let warmupMaxSlowdownPct = 20.0
    static let defaultWarmupMaxReps = 8
    /// Rest between timed holds when the sheet gives none (§13).
    static let defaultHoldRestSeconds = 30
    /// The lead-in before a hold, and the longer one to get into position for a new timed exercise.
    static let leadInSeconds = 3
    static let firstLeadInSeconds = 5
    /// An end-session or ask-back yes counts only this long after the question.
    static let askExpirySeconds: TimeInterval = 30
    /// "Done, 12" this soon after the camera ended a set is about that set, not a new one.
    static let sameSetSeconds: TimeInterval = 20
    /// In Ready with the camera on duty, "that was 8" corrects the last set only this soon after it.
    static let correctionWindowSeconds: TimeInterval = 180

    let day: ProgramDay?
    let weekNumber: Int
    let defaultRestSeconds: Int
    /// His warm-up rule, once confirmed: turns warm-up mode on for every lift.
    let warmups: WarmupRule?
    /// Add-ons the athlete can add by voice ("add abs").
    let availableAddOns: [AddOn]
    /// His rules (only the confirmed ones apply), his effort targets per set role, his rest rules.
    let rules: [ProgressionRule]
    let roleTargets: [RoleTarget]
    let restRules: [RestRule]
    let loadSteps: RuleEngine.LoadSteps
    /// Last time's set per "exerciseId|role" (the log, beneath it his paper logbook), and the
    /// next-session steps the athlete accepted. "Last time I did 145 for 9" adds to it.
    private(set) var lastSets: [String: LastSet]
    let nextSessionLoads: [String: Double]
    /// Settings → "Next-set suggestions". Off: effort is still measured and still reaches the coach.
    let suggestionsEnabled: Bool
    let calibration: Effort.Calibration
    let athleteName: String?
    /// Settings → "Start holds automatically": a timed set starts itself after its lead-in.
    let autoHolds: Bool
    /// When a machine's taken: his confirmed options (nil or unconfirmed: only Wait), Settings →
    /// "Machine-taken help", each swapped variant's last load and the variants done most recently.
    let takenRule: TakenRule?
    let takenHelp: Bool
    let variantLoads: [String: Double]
    let recentVariants: [String]
    /// The camera sees him (SetDetector.isOnDuty), set by the coordinator. A voice-only set ignores it.
    var cameraOnDuty = false
    /// The app's last line, for the backend's context.
    var lastSpoken: String?

    private(set) var exercises: [Entry]
    private(set) var session: Session
    private(set) var state: State = .ready
    private(set) var exerciseIndex = 0
    private(set) var setIndex = 0
    private(set) var loadOverrides: [String: Double] = [:]
    private(set) var lastEcho: String?
    private(set) var lastCallout: String?
    private(set) var pendingAsk: Ask?
    /// The open ask as it was said, for the HUD and the backend's context.
    private(set) var pendingAskText: String?
    private var askedAt: Date?
    /// "Last time I did 145 for 9", for the store's logbook.
    private(set) var logbookEntries: [LogbookEntry] = []
    private(set) var undoStack: [UndoEntry] = []
    /// Measured counts that arrived during a set, applied at the next rest. Never spoken mid-set.
    private(set) var heldMeasurements: [(setId: UUID, response: CountResponse)] = []
    /// Sets whose SAM count is pending, oldest first.
    private(set) var pendingCounts: [PendingCount] = []
    /// Seconds from each set's end to SAM's result, for the latency report (HANDOFF.md §9, P1b).
    private(set) var countLatencies: [TimeInterval] = []
    /// The current lift is still warming up: an easy set logs as a warm-up and the counter stays.
    private(set) var warmupMode = false
    /// Warm-ups logged for the current lift so far.
    private(set) var warmupCount = 0
    /// "I'm doing Day 5 today" before any set: the day number asked for, for the coordinator.
    private(set) var requestedDayNumber: Int?
    /// His rule's suggestion for the next set, waiting for "go with it" or "keep it".
    var pendingSuggestion: LoadSuggestion? {
        if case .suggestion(let s) = pendingAsk { return s }
        return nil
    }
    /// "Set 3, was that 8?" waiting for a yes, a no or a number.
    var pendingQuestion: PendingQuestion? {
        if case .countConfirm(let q) = pendingAsk { return q }
        return nil
    }
    /// (exercise, velocity loss, RPE) pairs from this session, for the athlete's own effort map.
    private(set) var calibrationSamples: [(exerciseId: String, velocityLossPct: Double, rpe: Double)] = []
    /// The last five lines spoken at rest, so the spotter never repeats an opening.
    private(set) var recentLines: [String] = []
    /// Where the quiet "ready when you are" falls in the current rest, as seconds remaining.
    private var restCueAtRemaining: Int?
    private var recordingStartedAt: Date?
    private var stateBeforePause: State = .ready
    private var repsOverrideForCurrentSet: Int?
    /// "Top set" said during the set: it is a working set whatever the count says.
    private var forceWorkingForCurrentSet = false
    private var holdStartedAt: Date?
    /// Approved coach cues by exercise id (HANDOFF.md §7, Coach voice cues).
    var cues: [String: VoiceCue] = [:]
    private(set) var playedCueExerciseIds: Set<String> = []
    private(set) var lastCuePlayed: VoiceCue?

    init(day: ProgramDay?, addOns: [AddOn] = [], availableAddOns: [AddOn] = [], weekNumber: Int, defaultRestSeconds: Int = 150,
         warmups: WarmupRule? = nil, rules: [ProgressionRule] = [], roleTargets: [RoleTarget] = [], restRules: [RestRule] = [],
         loadSteps: RuleEngine.LoadSteps = RuleEngine.LoadSteps(), lastSets: [String: LastSet] = [:], nextSessionLoads: [String: Double] = [:],
         suggestionsEnabled: Bool = true, calibration: Effort.Calibration = Effort.Calibration(), athleteName: String? = nil,
         autoHolds: Bool = true, takenRule: TakenRule? = nil, takenHelp: Bool = true, variantLoads: [String: Double] = [:],
         recentVariants: [String] = [], now: Date = .now) {
        self.day = day
        self.weekNumber = weekNumber
        self.defaultRestSeconds = defaultRestSeconds
        self.warmups = warmups?.confirmed == true ? warmups : nil
        self.availableAddOns = availableAddOns
        self.rules = rules
        self.roleTargets = roleTargets.filter(\.confirmed)
        self.restRules = restRules.filter(\.confirmed)
        self.loadSteps = loadSteps
        self.lastSets = lastSets
        self.nextSessionLoads = nextSessionLoads
        self.suggestionsEnabled = suggestionsEnabled
        self.calibration = calibration
        self.athleteName = athleteName
        self.autoHolds = autoHolds
        self.takenRule = takenRule
        self.takenHelp = takenHelp
        self.variantLoads = variantLoads
        self.recentVariants = recentVariants
        var entries = (day?.exercises ?? []).map { Entry(exercise: $0, addOnId: nil, section: nil) }
        for addOn in addOns { entries += addOn.exercises.map { Entry(exercise: $0, addOnId: addOn.id, section: addOn.name) } }
        self.exercises = entries
        self.session = Session(id: UUID(), programDayId: day?.id, startedAt: now, endedAt: nil, sets: [], notes: [], addOnIds: addOns.map(\.id))
        enterExercise()
    }

    // MARK: Current target

    /// The session's name on the HUD: the day, or the add-on it is made of.
    var title: String { day?.name ?? exercises.first?.section ?? "Session" }
    var currentEntry: Entry? { exercises.indices.contains(exerciseIndex) ? exercises[exerciseIndex] : nil }
    var currentExercise: PlannedExercise? { currentEntry?.exercise }
    var currentPlannedSet: PlannedSet? {
        guard let ex = currentExercise, ex.sets.indices.contains(setIndex) else { return nil }
        return ex.sets[setIndex]
    }
    /// The plan's load, else the athlete's override, else last time's for the same exercise and
    /// role plus any accepted next-session step (HANDOFF.md §7, No planned loads). Nil means ask.
    var targetLoadLb: Double? {
        guard let ex = currentExercise else { return nil }
        if let override = loadOverrides[ex.id] { return override }
        // Swapped for another variant: its load is his to say, never converted from the plan's.
        if let variant = doneAs[ex.id] { return variantLoads["\(ex.id)|\(variant.lowercased())"] }
        if let planned = currentPlannedSet?.loadLb { return planned }
        let key = Self.loadKey(ex.id, currentPlannedSet?.role)
        return nextSessionLoads[key] ?? lastSets[key]?.loadLb
    }

    static func loadKey(_ exerciseId: String, _ role: SetRole?) -> String { "\(exerciseId)|\(role?.rawValue ?? "")" }

    /// A lift with no load from anywhere: the athlete is asked "Weight for the top set?" (never for bodyweight).
    var needsLoad: Bool { currentExercise != nil && currentExercise?.equipment != .bodyweight && !currentSetIsTimed && targetLoadLb == nil }

    /// "Weight for the top set?", "Weight for the back-off?", or for a set with no such role, "Weight for these?"
    var loadAsk: String {
        switch currentPlannedSet?.role {
        case .top: "Weight for the top set?"
        case .backOff: "Weight for the back-off?"
        default: "Weight for these?"
        }
    }

    /// The opening line. A morning session of one add-on whose exercise has its name says it once:
    /// "Stomach vacuums: four holds of twenty seconds." A timed first set starts itself after.
    var intro: String {
        guard let ex = currentExercise else { return "Nothing planned for today." }
        if Self.sameName(title, ex.name), currentSetIsTimed, let seconds = currentPlannedSet?.seconds {
            let count = ex.sets.count
            return "\(Self.sentenceCase(ex.name)): \(Callout.word(count)) \(count == 1 ? "hold" : "holds") of \(Callout.holdLength(seconds))."
        }
        let name = Self.sameName(title, ex.name) ? Self.sentenceCase(ex.name) : "\(title). \(ex.name)"
        if currentSetIsTimed { return autoHolds ? "\(name), \(targetRepsText)." : "\(name), \(targetRepsText). Say go." }
        var line = "\(name), \(Callout.target(load: targetLoadLb, reps: targetRepsText))."
        if let logbook = logbookLine(for: ex) { line += " \(logbook)" }
        line += warmupMode ? " Warm-ups first." : " Lift when ready, or say starting."
        if needsLoad { line += " \(loadAsk)" }
        return line
    }

    static func sameName(_ a: String?, _ b: String?) -> Bool {
        guard let a, let b else { return false }
        return a.lowercased() == b.lowercased()
    }

    /// "Stomach Vacuums" -> "Stomach vacuums".
    static func sentenceCase(_ s: String) -> String { s.prefix(1).uppercased() + s.dropFirst().lowercased() }

    /// "Last time 80 for 9. Beat the logbook." at an exercise's top set (HANDOFF.md §7, The logbook line).
    func logbookLine(for exercise: PlannedExercise) -> String? {
        guard let first = exercise.sets.first, first.role == .top || (first.role == nil && !first.isTimed),
              let last = lastSets[Self.loadKey(exercise.id, first.role)] else { return nil }
        var line = "Last time \(Format.number(last.loadLb)) for \(last.reps)."
        if rules.contains(where: { $0.confirmed && ($0.quote ?? "").lowercased().contains("logbook") }) { line += " Beat the logbook." }
        return line
    }
    var targetRepsText: String { currentPlannedSet?.repsText ?? "?" }
    var setNumber: Int { setIndex + 1 }
    var setCount: Int { currentExercise?.sets.count ?? 0 }
    var isComplete: Bool { currentExercise == nil }
    var restSeconds: Int { currentExercise?.restSeconds ?? defaultRestSeconds }
    var lastLoggedSetId: UUID? { session.sets.last?.id }
    var lastLoggedSet: LoggedSet? { session.sets.last }
    /// The current set is a hold or a duration: no camera set, no clip, no SAM.
    var currentSetIsTimed: Bool { currentPlannedSet?.isTimed == true }
    var currentSetIsRestPause: Bool { currentPlannedSet?.isRestPause == true }
    var warmupMaxReps: Int { warmups?.maxReps ?? Self.defaultWarmupMaxReps }
    /// Holds and add-on sets go by voice (HANDOFF.md §7, Add-ons): the camera neither starts nor
    /// ends them, and SAM never counts them. The wrists don't move on a hanging leg raise.
    var currentSetIsVoiceOnly: Bool { currentSetIsTimed || currentEntry?.addOnId != nil }
    /// The camera can see this set: on duty, and not a voice-only set.
    var cameraSees: Bool { cameraOnDuty && !currentSetIsVoiceOnly }
    /// Every exercise is a hold or a duration: no camera at all (no 6 AM permission prompt).
    var isAllTimed: Bool { !exercises.isEmpty && exercises.allSatisfy { $0.exercise.sets.allSatisfy(\.isTimed) } }

    var context: SessionContext {
        SessionContext(
            state: stateName,
            exerciseName: currentExercise?.name,
            setIndex: isComplete ? nil : setNumber,
            setCount: isComplete ? nil : setCount,
            plannedLoadLb: targetLoadLb,
            plannedReps: currentPlannedSet?.reps,
            pendingAsk: pendingAskText,
            lastSpoken: lastSpoken,
            exercisesAhead: exercises.indices.filter { $0 >= exerciseIndex }.map { exercises[$0].exercise.name },
            addOnNames: Array(Set(availableAddOns.map(\.name) + exercises.compactMap(\.section))).sorted()
        )
    }

    private var stateName: String {
        switch state {
        case .ready: "ready"
        case .recording: "recording"
        case .saved: "saved"
        case .rest: "rest"
        case .leadIn: "leadIn"
        case .hold: "hold"
        case .listening: "listening"
        case .paused: "paused"
        case .ended: "ended"
        }
    }

    /// Entering a lift: warm-up mode when his rule is confirmed and the lift takes warm-ups. Warm-ups
    /// belong to the day's own lifts: never an add-on's exercises, never bodyweight ones.
    private func enterExercise() {
        warmupCount = 0
        warmupMode = warmups != nil && currentExercise?.hasWarmups == true && currentEntry?.addOnId == nil
            && currentExercise?.equipment != .bodyweight
    }

    // MARK: Coach cues

    /// The cue to play now: the current exercise's, in Ready, before its first set of the session,
    /// once. Never during a set. Nil when there is nothing to play.
    func cueDue() -> VoiceCue? {
        guard state == .ready, let ex = currentExercise, let cue = cues[ex.id], cue.approved,
              !playedCueExerciseIds.contains(ex.id), !session.sets.contains(where: { $0.exerciseId == ex.id })
        else { return nil }
        return cue
    }

    func cuePlayed(_ cue: VoiceCue) {
        playedCueExerciseIds.insert(cue.exerciseId)
        lastCuePlayed = cue
        lastEcho = "Coach · \(currentExercise?.name ?? "")"
    }

    /// "Say that again": the last cue, if any and not mid-set.
    func cueToReplay() -> VoiceCue? {
        guard state != .recording, let cue = lastCuePlayed else { return nil }
        return cue
    }

    // MARK: Set detection events

    /// The bar started moving (or the athlete said "starting"). On a timed set, "go" starts the hold.
    @discardableResult
    func setStarted(at now: Date = .now) -> Outcome {
        guard !isComplete, state != .recording, state != .ended, state != .paused else { return .none }
        if case .hold = state { return .none }
        lapseAsk()
        if let planned = currentPlannedSet, planned.isTimed, let seconds = planned.seconds {
            holdStartedAt = now
            state = .hold(remaining: seconds)
            return Outcome(echo: "\(currentExercise?.name ?? "Hold") · \(Callout.spoken(seconds: seconds))")
        }
        recordingStartedAt = now
        state = .recording
        return Outcome(echo: warmupMode ? "Warm-up \(warmupCount + 1) recording" : "Set \(setNumber) recording")
    }

    /// The bar stopped (or the athlete said "done"). Logs the set: what was said, else the phone's
    /// count, else the plan. `willMeasure` means a clip is on its way to SAM: the count is then
    /// pending, the set-end line says no number, and SAM's answer is spoken during rest. In warm-up
    /// mode a short, easy set logs as a warm-up instead: no SAM, no counter move.
    @discardableResult
    func setEnded(at now: Date = .now, phone: RepCounter.Result? = nil, willMeasure: Bool = false, askHowMany: Bool = false) -> Outcome {
        if case .hold = state { return holdEnded(at: now) }
        guard state == .recording, let exercise = currentExercise, let planned = currentPlannedSet else { return .none }
        let planReps = planned.minimumReps ?? planned.totalReps ?? 0
        let phoneReps = phone?.reps
        let reps: Int
        let source: RepSource
        if let spoken = repsOverrideForCurrentSet {
            reps = spoken
            source = .spoken
        } else if let phoneReps {
            reps = phoneReps
            source = .phone
        } else {
            reps = planReps
            source = .plan
        }
        let isWarmup = warmupMode && !forceWorkingForCurrentSet && Self.looksLikeWarmup(reps: reps, source: source, phone: phone, maxReps: warmupMaxReps)
        let logged = LoggedSet(
            id: UUID(),
            exerciseId: exercise.id,
            setIndex: setIndex,
            loadLb: targetLoadLb ?? 0,
            reps: reps,
            rpe: nil,
            role: isWarmup ? .warmup : planned.role,
            repCount: RepCount(source: source, phone: phoneReps, velocityLossPct: phone?.velocityLossPct,
                               status: willMeasure && !isWarmup ? .counting : .done),
            startedAt: recordingStartedAt ?? now,
            endedAt: now,
            clipFile: nil,
            edits: [],
            doneAs: doneAs[exercise.id]
        )
        session.sets.append(logged)
        var rest = exercise.restSeconds ?? defaultRestSeconds
        // Nothing counted it and nobody said a number: never the plan's reps in silence.
        let howMany = askHowMany && source == .plan && !willMeasure
        repsOverrideForCurrentSet = nil
        forceWorkingForCurrentSet = false
        recordingStartedAt = nil

        if isWarmup {
            restCueAtRemaining = nil
            warmupCount += 1
            undoStack.append(UndoEntry(action: .loggedSet(logged.id), description: "warm-up \(warmupCount)"))
            let callout = Callout.warmupDone(number: warmupCount, restSeconds: rest)
            lastCallout = callout
            state = .rest(remaining: rest)
            return Outcome(speech: callout, echo: "Warm-up \(warmupCount) saved: \(Format.number(logged.loadLb)) × \(reps)")
        }

        undoStack.append(UndoEntry(action: .loggedSet(logged.id), description: "set \(setNumber)"))
        warmupMode = false
        let doneNumber = setNumber
        // The rest belongs to the set just finished, even when the next set is another exercise. His
        // rest after a top set (3–4 min) overrides the sheet's day range: the countdown runs to the top,
        // with a quiet "ready when you are" at the bottom.
        restCueAtRemaining = nil
        if let his = restRules.first(where: { $0.after == .top }), planned.role == .top {
            rest = his.maxSeconds
            restCueAtRemaining = his.minSeconds < his.maxSeconds ? his.maxSeconds - his.minSeconds : nil
        } else if let minimum = exercise.restMinSeconds, let top = exercise.restSeconds, minimum < top {
            restCueAtRemaining = top - minimum
        }
        lapseAsk() // no answer keeps the plan's load and the count as it is
        let shortBy = source == .plan || planned.isRestPause ? 0 : max(0, planReps - reps)
        advance()
        let callout: String
        if howMany {
            callout = Callout.setDone(setNumber: doneNumber, restSeconds: rest, sessionOver: isComplete)
        } else if willMeasure, source != .spoken {
            // SAM is the count of record: no number until it answers, or 60 s pass.
            pendingCounts.append(PendingCount(setId: logged.id, endedAt: now, spoken: false))
            callout = Callout.setDone(setNumber: doneNumber, restSeconds: rest, sessionOver: isComplete)
        } else {
            callout = Callout.setDone(setNumber: doneNumber, reps: source == .plan ? nil : reps, total: planned.isRestPause,
                                      shortBy: shortBy, next: nextTarget, restSeconds: rest)
        }
        lastCallout = callout
        state = isComplete ? .ended : .rest(remaining: rest)
        if isComplete { session.endedAt = now }
        let saved = willMeasure && source != .spoken ? "Set \(doneNumber) saved: \(Format.number(logged.loadLb)) lb, counting"
                                                    : "Set \(doneNumber) saved: \(Format.number(logged.loadLb)) × \(reps)"
        var outcome = Outcome(speech: callout, echo: howMany ? "Set \(doneNumber) saved: \(Format.number(logged.loadLb)) lb, how many?" : saved)
        if howMany, !isComplete {
            outcome = outcome.merged(with: ask(.howMany(setId: logged.id), "How many?", now: now))
        } else if !(willMeasure && source != .spoken), let i = session.sets.firstIndex(where: { $0.id == logged.id }) {
            // Nothing to wait for: the effort and his rule's suggestion come now, after the set-end line.
            outcome = outcome.merged(with: settle(at: i, mode: .askOnly))
        }
        // Measured counts that arrived mid-set land now, during rest, and are mentioned only if they matter.
        for held in heldMeasurements {
            outcome = outcome.merged(with: applyMeasured(setId: held.setId, held.response, now: now, late: true))
        }
        heldMeasurements.removeAll()
        return outcome
    }

    /// 8 reps or fewer with under 20% slowdown is a warm-up (§13). The athlete's own number counts
    /// as reps; with no reading of the slowdown, a short set is still a warm-up.
    static func looksLikeWarmup(reps: Int, source: RepSource, phone: RepCounter.Result?, maxReps: Int) -> Bool {
        guard source != .plan else { return false }
        guard reps <= maxReps else { return false }
        return (phone?.velocityLossPct ?? 0) < warmupMaxSlowdownPct
    }

    /// The set's trimmed clip finished exporting after the set was logged.
    func attachClip(setId: UUID, file: String) {
        if let i = session.sets.firstIndex(where: { $0.id == setId }) { session.sets[i].clipFile = file }
    }

    // MARK: Timed sets (HANDOFF.md §7, Timed sets in a session)

    /// The clock ticked during a hold. The time left comes from the wall clock since the hold
    /// started, so a stalled tick never stretches it. The last three seconds are counted aloud
    /// ("10 seconds" first on a long hold), then "Time." and the set logs.
    @discardableResult
    func tickHold(at now: Date = .now) -> Outcome {
        guard case .hold(let shown) = state, let seconds = currentPlannedSet?.seconds else { return .none }
        let elapsed = Int(now.timeIntervalSince(holdStartedAt ?? now))
        let remaining = max(0, seconds - elapsed)
        guard remaining != shown else { return .none }
        if remaining == 0 {
            state = .hold(remaining: 0) // the hold ran its course
            return holdEnded(at: now)
        }
        state = .hold(remaining: remaining)
        if (1...3).contains(remaining) { return Outcome(speech: "\(Callout.word(remaining).capitalized).") }
        return remaining == 10 && seconds >= 30 ? Outcome(speech: "10 seconds.") : .none
    }

    /// A timed set starts itself (HANDOFF.md §7, Add-ons): "Three." now, then "Two.", "One." and
    /// "Hold." on the next ticks. A new timed exercise after another gets five seconds to get into
    /// position: "Plank, sixty seconds. Starting in five." Nothing when holds wait for "go".
    @discardableResult
    func beginLeadIn(seconds: Int? = nil) -> Outcome {
        guard autoHolds, currentSetIsTimed, !isComplete, let ex = currentExercise, let hold = currentPlannedSet?.seconds else { return .none }
        switch state {
        case .ready, .rest, .paused: break
        default: return .none
        }
        lapseAsk()
        let fresh = setIndex == 0 && session.sets.contains { $0.exerciseId != ex.id }
        let lead = seconds ?? (fresh ? Self.firstLeadInSeconds : Self.leadInSeconds)
        state = .leadIn(remaining: lead)
        let echo = "\(ex.name) · \(Callout.spoken(seconds: hold))"
        if lead > 3 {
            return Outcome(speech: "\(ex.name), \(Callout.holdLength(hold)). Starting in \(Callout.word(lead)).", echo: echo)
        }
        return Outcome(speech: "\(Callout.word(lead).capitalized).", echo: echo)
    }

    /// After the intro, or when the session lands on a hold in Ready: start its lead-in.
    @discardableResult
    func beginLeadInIfDue() -> Outcome {
        state == .ready ? beginLeadIn() : .none
    }

    /// One second of a lead-in: the count, then "Hold." and the hold starts.
    @discardableResult
    func tickLeadIn(at now: Date = .now) -> Outcome {
        guard case .leadIn(let remaining) = state else { return .none }
        let next = remaining - 1
        guard next > 0 else {
            state = .ready
            let started = setStarted(at: now)
            return Outcome(speech: "Hold.", echo: started.echo)
        }
        state = .leadIn(remaining: next)
        return next <= 3 ? Outcome(speech: "\(Callout.word(next).capitalized).") : .none
    }

    /// "Time." (or "done" early): the hold logs how long it ran, then rests the sheet's time, else 30 s.
    private func holdEnded(at now: Date) -> Outcome {
        guard case .hold(let remaining) = state, let exercise = currentExercise, let planned = currentPlannedSet,
              let seconds = planned.seconds else { return .none }
        let ran = holdStartedAt.map { min(seconds, max(1, Int(now.timeIntervalSince($0).rounded()))) } ?? max(1, seconds - remaining)
        let logged = LoggedSet(
            id: UUID(), exerciseId: exercise.id, setIndex: setIndex, loadLb: targetLoadLb ?? 0, reps: 0, rpe: nil,
            seconds: ran, role: planned.role, repCount: RepCount(source: .plan, status: .done),
            startedAt: holdStartedAt ?? now, endedAt: now, clipFile: nil, edits: []
        )
        session.sets.append(logged)
        undoStack.append(UndoEntry(action: .loggedSet(logged.id), description: "set \(setNumber)"))
        let doneNumber = setNumber
        holdStartedAt = nil
        let rest = exercise.restSeconds ?? Self.defaultHoldRestSeconds
        advance()
        let callout = Callout.holdDone(setNumber: doneNumber, seconds: ran, planned: seconds, next: nextTarget, restSeconds: rest,
                                       sessionOver: isComplete)
        lastCallout = callout
        state = isComplete ? .ended : .rest(remaining: rest)
        if isComplete { session.endedAt = now }
        return Outcome(speech: callout, echo: "Set \(doneNumber) saved: \(Callout.spoken(seconds: ran))")
    }

    // MARK: Measured counts (HANDOFF.md §7, Rep counting)

    /// SAM's count came back. During a set it is held and lands at the next rest. Otherwise, with
    /// confidence 0.6 or more it is logged as Measured and said with the next target; under 0.6 the
    /// athlete is asked "Set 3, was that 8?"; a count already spoken (the 60 s fallback) is replaced
    /// and mentioned only if it changed. "That was N" always wins and SAM's number is just recorded.
    @discardableResult
    func measured(setId: UUID, _ response: CountResponse, now: Date = .now) -> Outcome {
        if let set = session.sets.first(where: { $0.id == setId }) {
            countLatencies.append(max(0, now.timeIntervalSince(set.endedAt)))
        }
        if state == .recording {
            heldMeasurements.append((setId, response))
            return .none
        }
        return applyMeasured(setId: setId, response, now: now, late: false)
    }

    private func applyMeasured(setId: UUID, _ response: CountResponse, now: Date, late: Bool) -> Outcome {
        guard let i = session.sets.firstIndex(where: { $0.id == setId }) else { return .none }
        let late = late || session.sets.last?.id != setId
        var set = session.sets[i]
        set.repCount.measured = response.reps
        set.repCount.confidence = response.confidence
        set.repCount.repTimes = response.repTimes
        if let loss = response.velocityLossPct { set.repCount.velocityLossPct = loss }
        let pending = pendingCounts.first { $0.setId == setId }
        pendingCounts.removeAll { $0.setId == setId }
        let unspoken = pending.map { !$0.spoken } ?? false
        let number = set.setIndex + 1
        guard response.trackFound, let measured = response.reps else {
            // No track: the phone's count stands, and it is said now if nothing has been.
            set.repCount.status = .failed
            session.sets[i] = set
            return unspoken ? speakFallback(at: i) : .none
        }
        set.repCount.status = .done
        if set.repCount.source == .spoken {
            session.sets[i] = set
            return .none
        }
        let current = set.reps
        if measured == current {
            set.repCount.source = .measured
            session.sets[i] = set
            return unspoken ? speakCount(at: i, late: late) : .none
        }
        if response.confidence >= RepCount.confidentThreshold {
            let oldSource = set.repCount.source
            set.reps = measured
            set.repCount.source = .measured
            set.edits.append(SetEdit(at: now, field: "reps", from: "\(current)", to: "\(measured)", transcript: "measured"))
            session.sets[i] = set
            undoStack.append(UndoEntry(action: .measured(setId: setId, oldReps: current, oldSource: oldSource), description: "measured count"))
            if unspoken { return speakCount(at: i, late: late) }
            lastEcho = "Set \(number) updated: \(measured) reps (measured)"
            return Outcome(speech: Callout.updated(setNumber: number, reps: measured),
                           echo: "Set \(number) updated: \(measured) reps (measured). Say undo to revert.")
        }
        // Unsure: ask. A yes logs it as Measured, a number as You said, and no answer keeps the current count.
        session.sets[i] = set
        return ask(.countConfirm(PendingQuestion(setId: setId, measured: measured, current: current)),
                   Callout.confirmCount(setNumber: number, reps: measured))
    }

    /// The clip never reached the backend: the phone count stands, and is said now if nothing has
    /// been said about the set (or at the next rest, if a set is under way).
    @discardableResult
    func countFailed(setId: UUID) -> Outcome {
        guard let i = session.sets.firstIndex(where: { $0.id == setId }) else { return .none }
        session.sets[i].repCount.status = .failed
        guard let k = pendingCounts.firstIndex(where: { $0.setId == setId }), state != .recording else { return .none }
        let unspoken = !pendingCounts[k].spoken
        pendingCounts.remove(at: k)
        return unspoken ? speakFallback(at: i) : .none
    }

    /// One second passed. A set SAM has not answered within 60 s of its end, or whose upload
    /// failed during the next set, gets the phone's count spoken now. Never during a set.
    @discardableResult
    func tick(now: Date) -> Outcome {
        guard state != .recording else { return .none }
        var outcome = Outcome.none
        for k in pendingCounts.indices where !pendingCounts[k].spoken {
            let p = pendingCounts[k]
            let failed = session.sets.first { $0.id == p.setId }?.repCount.status == .failed
            guard failed || now.timeIntervalSince(p.endedAt) >= Self.fallbackSeconds else { continue }
            pendingCounts[k].spoken = true
            if let i = session.sets.firstIndex(where: { $0.id == p.setId }) {
                outcome = outcome.merged(with: speakFallback(at: i))
            }
        }
        pendingCounts.removeAll { p in session.sets.first { $0.id == p.setId }?.repCount.status == .failed }
        return outcome
    }

    /// The count in the log, said once it is settled: with the effort, his rule's suggestion and
    /// the next target when the set is the last one logged, else as a late mention. A rest-pause
    /// set's number is its total.
    private func speakCount(at i: Int, late: Bool) -> Outcome {
        let set = session.sets[i]
        let number = set.setIndex + 1
        let measured = set.repCount.source == .measured
        let chip = set.repCount.source.chipText
        if late {
            _ = settle(at: i, mode: .quiet)
            lastEcho = "Set \(number): \(set.reps) reps (\(chip))"
            return Outcome(speech: Callout.lateCount(setNumber: number, reps: set.reps, measured: measured), echo: lastEcho)
        }
        _ = measured
        lastEcho = "Set \(number): \(set.reps) reps (\(chip))"
        return Outcome(echo: lastEcho).merged(with: settle(at: i, mode: .restLine))
    }

    /// What `settle` says: the whole rest line, only the effort and the ask (the set-end line already
    /// carried the count and the next target), or nothing (a late count).
    enum SettleMode { case restLine, askOnly, quiet }

    // MARK: Measured effort and his rules (HANDOFF.md §7)

    /// His target for a set, in reps in reserve: the sheet's RPE or RIR, else his role target.
    func targetRIR(for planned: PlannedSet?) -> Double? {
        if let rir = planned?.rir { return Double(rir) }
        if let rpe = planned?.rpe { return 10 - rpe }
        let role: RoleName = switch planned?.role {
        case .top: .top
        case .backOff: .backOff
        case .restPause: .restPause
        default: .straight
        }
        return roleTargets.first { $0.role == role }?.rir
    }

    /// The set's effort: the spoken RPE wins, else the measured slowdown through the effort map.
    private func effort(for set: LoggedSet) -> (rir: Double, measured: Bool)? {
        if let rpe = set.rpe { return (max(0, 10 - rpe), false) }
        if set.role == .restPause { return nil }
        guard let loss = set.repCount.velocityLossPct else { return nil }
        return (Effort.estimatedRIR(velocityLossPct: loss, exerciseId: set.exerciseId, calibration: calibration), true)
    }

    /// Once a set's count is settled: record its estimated effort, ask his rule for the next load,
    /// and build the rest-time line (the facts for the spotter, and the template that stands in).
    private func settle(at i: Int, mode: SettleMode) -> Outcome {
        var set = session.sets[i]
        let planned = plannedSet(for: set)
        let effort = effort(for: set)
        if let effort, effort.measured { set.repCount.estimatedRIR = effort.rir }
        session.sets[i] = set
        guard mode != .quiet, session.sets.last?.id == set.id else { return .none }
        guard let entry = exercises.first(where: { $0.exercise.id == set.exerciseId }) else { return .none }
        let exercise = entry.exercise
        let target = targetRIR(for: planned)
        var suggestion: LoadSuggestion?
        if suggestionsEnabled, set.role != .restPause || true {
            let allAtTop = planned?.repsMax.map { top in session.workingSets.filter { $0.exerciseId == set.exerciseId }.allSatisfy { $0.reps >= top } } ?? false
            let facts = RuleEngine.SetFacts(
                exerciseId: set.exerciseId, exerciseName: exercise.name, equipment: exercise.equipment, setIndex: set.setIndex,
                role: set.role, loadLb: set.loadLb, reps: set.reps, repsMin: planned?.repsMin, repsMax: planned?.repsMax,
                totalReps: planned?.totalReps, effortRIR: effort?.rir, effortIsMeasured: effort?.measured ?? false,
                targetRIR: target, plannedLoadLb: planned?.loadLb, allSetsAtTopOfRange: allAtTop
            )
            suggestion = RuleEngine.suggestion(for: facts, rules: rules, steps: loadSteps, setId: set.id)
        }
        if let suggestion {
            session.suggestions.append(suggestion)
            open(.suggestion(suggestion), Callout.suggestionAsk(suggestion))
        }
        let rule = suggestion.flatMap { s in rules.first { $0.id == s.ruleId } }
        let shortBy = planned?.isRestPause == true ? 0 : max(0, (planned?.minimumReps ?? 0) - set.reps)
        let line = Callout.restLine(set: set, role: planned?.role, shortBy: shortBy, effort: effort, targetRIR: target, suggestion: suggestion, rule: rule)
        let facts = SpotterFacts(
            exercise: exercise.name, setNumber: set.setIndex + 1, setCount: exercise.sets.count, reps: set.reps,
            repSource: set.repCount.source.rawValue, loadLb: set.loadLb > 0 ? set.loadLb : nil,
            velocityLossPct: set.repCount.velocityLossPct, estimatedRIR: effort?.measured == true ? effort?.rir : nil,
            target: target.map { $0 <= 0 ? "failure" : "RPE \(Format.number(10 - $0))" } ?? planned.map { $0.repsText + " reps" },
            suggestionLb: suggestion?.toLb, suggestionRule: rule.map(RuleEngine.ruleWords),
            isPR: isPR(set), streak: streak(for: set, planned: planned), lastTimeLoadLb: lastSets[Self.loadKey(set.exerciseId, set.role)]?.loadLb,
            lastTimeReps: lastSets[Self.loadKey(set.exerciseId, set.role)]?.reps, sessionSets: session.workingSets.count,
            role: set.role?.rawValue
        )
        let ask = suggestion.map { Callout.suggestionAsk($0) }
        // The ask names the next set's load itself; otherwise the next target follows.
        let next = suggestion?.scope == .nextSet ? nil : nextTarget.map { Callout.nextLine($0) }
        let parts = mode == .restLine ? [line.facts, line.effort, ask, next] : [line.effort, ask]
        let speech = parts.compactMap { $0 }.joined(separator: " ")
        recentLines.append(line.facts)
        if recentLines.count > 5 { recentLines.removeFirst() }
        lastEcho = suggestion.map { "Next: \(Format.number($0.toLb)) × \(targetRepsText) · his rule" } ?? lastEcho
        guard !speech.isEmpty else { return .none }
        let replaceable = mode == .restLine ? [line.facts, line.effort].compactMap { $0 }.joined(separator: " ") : line.effort
        return Outcome(speech: speech, echo: lastEcho, spotterFacts: mode == .restLine ? facts : nil, spotterReplaceable: replaceable)
    }

    /// Heavier, or the same load for more reps, than last time's set for this exercise and role.
    private func isPR(_ set: LoggedSet) -> Bool {
        guard set.loadLb > 0, let last = lastSets[Self.loadKey(set.exerciseId, set.role)] else { return false }
        return set.loadLb > last.loadLb || (set.loadLb == last.loadLb && set.reps > last.reps)
    }

    /// Sets in a row of this exercise at the top of the range, this session.
    private func streak(for set: LoggedSet, planned: PlannedSet?) -> Int? {
        guard let top = planned?.repsMax else { return nil }
        var count = 0
        for s in session.workingSets.reversed() where s.exerciseId == set.exerciseId {
            if s.reps >= top { count += 1 } else { break }
        }
        return count >= 2 ? count : nil
    }

    /// "Go with it" / "keep it", or no answer at the next set: every decision is logged.
    @discardableResult
    func decideSuggestion(_ decision: SuggestionDecision, spoken: Bool, load: Double? = nil) -> Outcome {
        guard let suggestion = pendingSuggestion else { return spoken ? say("Nothing to decide.") : .none }
        clearAsk()
        if let i = session.suggestions.firstIndex(where: { $0.id == suggestion.id }) { session.suggestions[i].decision = decision }
        if decision == .accepted, suggestion.scope == .nextSet {
            let old = loadOverrides[suggestion.exerciseId]
            loadOverrides[suggestion.exerciseId] = suggestion.toLb
            undoStack.append(UndoEntry(action: .load(exerciseId: suggestion.exerciseId, old: old), description: "going with \(Format.number(suggestion.toLb))"))
            return echo("Next: \(Format.number(suggestion.toLb)) lb, his rule", speech: "\(Format.number(suggestion.toLb)) it is.")
        }
        if decision == .accepted {
            return echo("Next session: \(Format.number(suggestion.toLb)) lb, his rule", speech: "Noted for next session.")
        }
        guard spoken else { return .none }
        if let load { return echo("Keeping your \(Format.number(load)) lb", speech: "Keeping \(Format.number(load)).") }
        if targetLoadLb == nil, suggestion.scope == .nextSet { loadOverrides[suggestion.exerciseId] = suggestion.fromLb } // no plan load: the set's own
        return echo("Keeping \(Format.number(suggestion.fromLb)) lb", speech: "Keeping \(Format.number(suggestion.fromLb)).")
    }

    /// SAM is late or failed: the phone's count, if there is one, else just the next target.
    private func speakFallback(at i: Int) -> Outcome {
        let set = session.sets[i]
        let late = session.sets.last?.id != set.id
        if set.repCount.source == .phone { return speakCount(at: i, late: late) }
        guard !late, let next = nextTarget else { return .none }
        lastEcho = "Set \(set.setIndex + 1): \(set.reps) reps (Plan)"
        return Outcome(speech: Callout.nextLine(next), echo: lastEcho)
    }

    private func plannedSet(for set: LoggedSet) -> PlannedSet? {
        guard let ex = exercises.first(where: { $0.exercise.id == set.exerciseId })?.exercise, ex.sets.indices.contains(set.setIndex) else { return nil }
        return ex.sets[set.setIndex]
    }

    /// The median seconds from set end to SAM's result this session, for the latency report.
    var medianCountLatency: TimeInterval? {
        guard !countLatencies.isEmpty else { return nil }
        let sorted = countLatencies.sorted()
        let n = sorted.count
        return n % 2 == 1 ? sorted[n / 2] : (sorted[n / 2 - 1] + sorted[n / 2]) / 2
    }

    private var nextTarget: Callout.NextSet? {
        guard let entry = currentEntry else { return nil }
        let ex = entry.exercise
        if setIndex == 0, session.sets.last?.exerciseId != ex.id {
            return .nextExercise(name: ex.name, loadLb: targetLoadLb, reps: targetRepsText, section: entry.section,
                                 warmups: warmupMode, timed: ex.sets.first?.isTimed == true && !autoHolds, logbook: logbookLine(for: ex),
                                 askLoad: needsLoad ? loadAsk : nil)
        }
        return .sameExercise(loadLb: targetLoadLb, reps: targetRepsText)
    }

    private func advance() {
        guard let ex = currentExercise else { return }
        if setIndex + 1 < ex.sets.count {
            setIndex += 1
        } else {
            exerciseIndex += 1
            setIndex = 0
            enterExercise()
        }
    }

    /// One second of rest passed. Returns the callout for "rest over" when it ends, and a quiet
    /// "ready when you are" at the bottom of a day-level rest range.
    @discardableResult
    func tickRest() -> Outcome {
        guard case .rest(let remaining) = state else { return .none }
        if remaining <= 1 {
            // "How many?" unanswered by the end of rest: the plan's reps stand, chip Plan.
            if case .howMany = pendingAsk { lapseAsk() }
            state = .ready
            // A hold starts itself; "Go." is for rep sets.
            if autoHolds, currentSetIsTimed { return beginLeadIn() }
            return Outcome(speech: "Go.", echo: "Ready")
        }
        state = .rest(remaining: remaining - 1)
        if let cue = restCueAtRemaining, remaining - 1 == cue {
            return Outcome(speech: "Ready when you are.")
        }
        return .none
    }

    func skipRest() {
        if case .rest = state { state = .ready }
    }

    // MARK: Add-ons (HANDOFF.md §7, Two workouts in one day)

    /// "Add abs": the add-on's exercises join after the last lift, for today only.
    @discardableResult
    func addAddOn(named name: String) -> Outcome {
        let wanted = name.lowercased()
        guard let addOn = availableAddOns.first(where: { $0.name.lowercased().contains(wanted) || wanted.contains($0.name.lowercased()) })
        else { return say("No add-on called \(name).") }
        guard !session.addOnIds.contains(addOn.id) else { return say("\(addOn.name) is already in today's session.") }
        exercises += addOn.exercises.map { Entry(exercise: $0, addOnId: addOn.id, section: addOn.name) }
        session.addOnIds.append(addOn.id)
        if isComplete || state == .ended {
            exerciseIndex = exercises.count - addOn.exercises.count
            setIndex = 0
            session.endedAt = nil
            state = .ready
            enterExercise()
        } else if currentEntry == nil {
            enterExercise()
        }
        undoStack.append(UndoEntry(action: .addOn(id: addOn.id, count: addOn.exercises.count), description: "adding \(addOn.name.lowercased())"))
        return echo("Added \(addOn.name) after the last lift", speech: "Adding \(addOn.name.lowercased()) today.")
    }

    /// "Skip abs": the add-on leaves today's session, unless a set of it is already logged.
    @discardableResult
    func skipAddOn(named name: String) -> Outcome {
        let wanted = name.lowercased()
        guard let addOnId = session.addOnIds.first(where: { id in
            let entryName = exercises.first { $0.addOnId == id }?.section?.lowercased() ?? ""
            return entryName.contains(wanted) || wanted.contains(entryName)
        }) else { return say("\(name) isn't in today's session.") }
        let ids = Set(exercises.filter { $0.addOnId == addOnId }.map(\.exercise.id))
        guard !session.sets.contains(where: { ids.contains($0.exerciseId) }) else { return say("You've already started it.") }
        let removed = exercises.filter { $0.addOnId == addOnId }
        let sectionName = removed.first?.section ?? name
        exercises.removeAll { $0.addOnId == addOnId }
        session.addOnIds.removeAll { $0 == addOnId }
        if exerciseIndex >= exercises.count {
            exerciseIndex = exercises.count
            setIndex = 0
            state = .ended
            session.endedAt = .now
        }
        undoStack.append(UndoEntry(action: .skippedAddOn(entries: removed, ids: [addOnId]), description: "skipping \(sectionName.lowercased())"))
        return echo("Skipped \(sectionName) today", speech: isComplete ? "That's the session." : "Skipping \(sectionName.lowercased()) today.")
    }

    // MARK: Voice (HANDOFF.md §7, The between-set conversation)

    func listeningStarted() {
        if state.isListeningAllowed, state != .paused { state = .listening }
    }

    func listeningEnded(resumeRest remaining: Int?) {
        guard state == .listening else { return }
        state = remaining.map { .rest(remaining: $0) } ?? .ready
    }

    /// Apply a classified command. Chatter, unknown and anything heard under 0.4 are silent ("Heard: …"
    /// on the HUD). A command heard at 0.4–0.7 is asked back as the action, and a yes applies it.
    /// The open ask takes its answers first. `phone` and `willMeasure` come from the camera when a
    /// spoken "done" ends a set it was filming.
    @discardableResult
    func apply(_ response: VoiceCommandResponse, now: Date = .now, phone: RepCounter.Result? = nil, willMeasure: Bool = false) -> Outcome {
        let intent = response.intent
        if let pendingAsk, let askedAt, Self.expires(pendingAsk), now.timeIntervalSince(askedAt) > Self.askExpirySeconds { clearAsk() }
        if intent.intent == .chatter || intent.intent == .unknown || intent.confidence < VoiceIntent.askThreshold {
            return heard(response.transcript)
        }
        if intent.confidence < VoiceIntent.actThreshold {
            if intent.intent == .endSession { return askEndSession(now: now) }
            guard let text = clarifyText(intent) else { return heard(response.transcript) }
            return ask(.clarify(response), text, now: now)
        }
        if let pendingAsk, let answered = answer(pendingAsk, response, now: now) { return answered }
        if Self.lapsesAsk(intent.intent) { lapseAsk() }
        return act(response, now: now, phone: phone, willMeasure: willMeasure)
    }

    /// The command itself, once any ask has had its say.
    private func act(_ response: VoiceCommandResponse, now: Date, phone: RepCounter.Result? = nil, willMeasure: Bool = false) -> Outcome {
        let intent = response.intent
        switch intent.intent {
        case .rpe:
            guard let n = intent.number, let last = session.sets.indices.last else { return say("No set to rate yet.") }
            let old = session.sets[last].rpe
            session.sets[last].rpe = n
            if let loss = session.sets[last].repCount.velocityLossPct, !session.sets[last].isWarmup {
                calibrationSamples.append((session.sets[last].exerciseId, loss, n))
            }
            session.sets[last].edits.append(SetEdit(at: now, field: "rpe", from: old.map(Format.number) ?? "", to: Format.number(n), transcript: response.transcript))
            undoStack.append(UndoEntry(action: .rpe(setId: session.sets[last].id, old: old), description: "RPE \(Format.number(n))"))
            return echo("Set \(session.sets[last].setIndex + 1) → RPE \(Format.number(n))", speech: Callout.rpeLogged(n, setNumber: session.sets[last].setIndex + 1))
        case .reps, .answer:
            guard let n = intent.number else { return intent.intent == .reps ? say("How many reps?") : .none }
            // "Weight for the top set?" answered with a bare number: his load for this lift.
            if intent.intent == .answer, state != .recording, needsLoad { return setLoad(n) }
            return routeCount(Int(n), done: false, named: intent.setNumber, exercise: intent.text, transcript: response.transcript,
                              now: now, phone: phone, willMeasure: willMeasure)
        case .endSet:
            if let n = intent.number {
                return routeCount(Int(n), done: true, named: nil, exercise: nil, transcript: response.transcript, now: now, phone: phone, willMeasure: willMeasure)
            }
            return done(now: now, phone: phone, willMeasure: willMeasure)
        case .setLoad:
            guard let n = intent.number else { return say("Which load?") }
            return setLoad(n)
        case .acceptSuggestion:
            return decideSuggestion(.accepted, spoken: true)
        case .keepLoad:
            return decideSuggestion(.kept, spoken: true)
        case .loadDelta:
            guard let n = intent.number, let ex = currentExercise, let base = targetLoadLb else { return say("Which load?") }
            let old = loadOverrides[ex.id]
            let new = max(0, base + n)
            loadOverrides[ex.id] = new
            undoStack.append(UndoEntry(action: .load(exerciseId: ex.id, old: old), description: "load \(Format.number(new))"))
            return echo("\(ex.name) → \(Format.number(new)) lb", speech: Callout.loadChanged(to: new))
        case .skipSet:
            guard !isComplete, state != .recording else { return .none }
            let skipped = (exerciseIndex, setIndex)
            advance()
            undoStack.append(UndoEntry(action: .skip(exercise: skipped.0, set: skipped.1), description: "skip"))
            state = isComplete ? .ended : .ready
            return echo("Skipped set \(skipped.1 + 1)", speech: isComplete ? "That's the session." : "Next, \(Callout.target(load: targetLoadLb, reps: targetRepsText)).")
        case .nextExercise:
            guard !isComplete, state != .recording else { return .none }
            let left = setCount - setIndex
            if let ex = currentExercise, left > 0, session.sets.contains(where: { $0.exerciseId == ex.id && !$0.isWarmup }) {
                return ask(.logPlanSets(count: left), "Log the other \(left) \(left == 1 ? "set" : "sets") of \(ex.name.lowercased()) from the plan?", now: now)
            }
            return moveToNextExercise()
        case .skipExercise:
            return skipExercise(named: intent.text ?? response.transcript, transcript: response.transcript, now: now)
        case .note:
            return addNote(intent.text ?? response.transcript, fieldId: intent.fieldId, now: now)
        case .undo:
            return undo()
        case .pause:
            guard state != .paused, state != .ended else { return .none }
            stateBeforePause = state
            state = .paused
            return echo("Paused", speech: "Paused.")
        case .resume:
            guard state == .paused else { return .none }
            if case .leadIn = stateBeforePause {
                state = .ready
                return echo("Resumed", speech: "Resumed.").merged(with: beginLeadIn(seconds: Self.leadInSeconds))
            }
            state = stateBeforePause == .recording ? .ready : stateBeforePause
            return echo("Resumed", speech: "Resumed.")
        case .endSession:
            return askEndSession(now: now)
        case .starting:
            // "Go", "ready", "start" before a hold: its lead-in now, without waiting out the rest.
            if autoHolds, currentSetIsTimed {
                if case .rest = state { state = .ready }
                return beginLeadIn(seconds: Self.leadInSeconds)
            }
            let outcome = setStarted(at: now)
            return outcome.echo == nil ? .none : outcome
        case .replayCue:
            return cueToReplay() == nil ? say("No cue to replay.") : Outcome(echo: "Replaying the coach's cue")
        case .topSet:
            return topSet(transcript: response.transcript, now: now)
        case .warmup:
            return markLastAsWarmup(now: now)
        case .addAddOn:
            return addAddOn(named: intent.text ?? response.transcript)
        case .skipAddOn:
            return skipAddOn(named: intent.text ?? response.transcript)
        case .changeDay:
            guard let n = intent.number, session.sets.isEmpty, state != .recording else { return say("Too late to change the day.") }
            requestedDayNumber = Int(n)
            return echo("Switching to Day \(Int(n))")
        case .flagSet:
            guard let last = session.sets.indices.last else { return say("No set to flag yet.") }
            session.sets[last].flaggedForCoach = true
            undoStack.append(UndoEntry(action: .flag(setId: session.sets[last].id), description: "the flag"))
            return echo("Set \(session.sets[last].setIndex + 1) flagged for your coach", speech: "Flagged for Thursday.")
        case .question:
            return answerQuestion(intent.topic, transcript: response.transcript, now: now)
        case .logbook:
            return logbook(load: intent.number, reps: intent.reps, now: now)
        case .equipmentTaken:
            return equipmentTaken(named: intent.text, now: now)
        case .swapTo:
            return swap(to: intent.text ?? response.transcript, transcript: response.transcript, now: now)
        case .equipmentFree:
            return equipmentFree()
        case .yes, .no, .choose:
            // Nothing is waiting on an answer.
            return heard(response.transcript)
        case .unknown, .chatter:
            return heard(response.transcript)
        }
    }

    // MARK: The open ask

    /// The open ask's answer, or nil when the command isn't one (it then lapses or stands, by kind).
    private func answer(_ open: Ask, _ response: VoiceCommandResponse, now: Date) -> Outcome? {
        let intent = response.intent
        let kind = intent.intent
        let yes = kind == .yes || kind == .acceptSuggestion || (kind == .choose && intent.number == 1)
        let no = kind == .no || kind == .keepLoad
        // A bare count, or "that was N" about no named set.
        let count = kind == .answer || (kind == .reps && intent.setNumber == nil) ? intent.number.map { Int($0) } : nil
        switch open {
        case .countConfirm(let question):
            if let count { clearAsk(); return answerCount(question, with: count, transcript: response.transcript, now: now) }
            if yes { clearAsk(); return acceptMeasured(question, transcript: response.transcript, now: now) }
            if no {
                clearAsk()
                lastEcho = "Set \(setNumber(of: question.setId)) stays at \(question.current) reps"
                return Outcome(speech: "Keeping \(question.current).", echo: lastEcho)
            }
        case .suggestion:
            if yes { return decideSuggestion(.accepted, spoken: true) }
            if no { return decideSuggestion(.kept, spoken: true) }
            if kind == .answer, let n = intent.number { return setLoad(n) }
        case .howMany(let setId):
            if let count, let i = session.sets.firstIndex(where: { $0.id == setId }) {
                clearAsk()
                var outcome = spokenReps(at: i, count, transcript: response.transcript, now: now)
                outcome = outcome.merged(with: settle(at: i, mode: .askOnly))
                if pendingSuggestion == nil, let next = nextTarget { outcome = outcome.merged(with: Outcome(speech: Callout.nextLine(next))) }
                return outcome
            }
        case .endSession:
            if yes {
                clearAsk()
                endSession(at: now)
                return echo("Session ended", speech: "Session ended. \(session.workingSets.count) sets logged.")
            }
            if no { clearAsk(); return Outcome(speech: "Carrying on.", echo: "Carrying on") }
        case .countFor(let reps):
            if yes || count != nil { clearAsk(); return logVoiceSet(reps: count ?? reps, now: now) }
            if no { clearAsk(); return Outcome(speech: "Okay.", echo: "Not logged") }
        case .clarify(let stored):
            if yes {
                clearAsk()
                var confirmed = stored
                confirmed.intent.confidence = 0.95
                return act(confirmed, now: now)
            }
            if no { clearAsk(); return Outcome(speech: "Okay.", echo: "Ignored: \(stored.transcript)") }
        case .noteOffer(let text):
            if yes { clearAsk(); return addNote(text, fieldId: nil, now: now) }
            if no { clearAsk(); return Outcome(speech: "Okay.") }
        case .logPlanSets(let count):
            if yes {
                clearAsk()
                let logged = logPlanSets(now: now)
                return echo("Logged \(logged) from the plan", speech: "Logged \(logged) from the plan.").merged(with: moveToNextExercise())
            }
            if no { clearAsk(); return moveToNextExercise(skipped: count) }
        case .takenOffer(let offer):
            let first = yes || kind == .choose && intent.number == 1
            let other = kind == .choose && intent.number == 2
            let wait = no || kind == .choose && intent.text == "wait"
            let swaps = offer.options.filter { $0.kind != .wait }
            if first || other {
                clearAsk()
                let index = other ? 1 : 0
                guard swaps.indices.contains(index) else { return waitFor(offer.exerciseId) }
                return swap(to: swaps[index].name, exerciseId: offer.exerciseId, reason: offer.what.map { "\($0) taken" } ?? "machine taken",
                            transcript: response.transcript, now: now)
            }
            if wait { clearAsk(); return waitFor(offer.exerciseId) }
        }
        return nil
    }

    /// Open an ask (the older one lapses with its default) and say it.
    private func ask(_ open: Ask, _ text: String, now: Date = .now) -> Outcome {
        self.open(open, text, now: now)
        return Outcome(speech: text, askBack: text)
    }

    private func open(_ open: Ask, _ text: String, now: Date = .now) {
        lapseAsk()
        pendingAsk = open
        pendingAskText = text
        askedAt = now
    }

    /// The open ask lapses with its default: a suggestion is kept, a count stays as it is.
    private func lapseAsk() {
        if let suggestion = pendingSuggestion, let i = session.suggestions.firstIndex(where: { $0.id == suggestion.id }) {
            session.suggestions[i].decision = .kept
        }
        clearAsk()
    }

    private func clearAsk() {
        pendingAsk = nil
        pendingAskText = nil
        askedAt = nil
    }

    /// A yes long after these is not an answer to them.
    private static func expires(_ ask: Ask) -> Bool {
        switch ask {
        case .endSession, .clarify, .countFor, .noteOffer, .takenOffer: true
        default: false
        }
    }

    /// A question, a note or an RPE leaves the open ask standing ("what's the back-off?", then "go with it").
    private static func lapsesAsk(_ kind: VoiceIntent.Kind) -> Bool {
        switch kind {
        case .question, .note, .rpe, .flagSet, .replayCue, .pause, .resume, .logbook, .chatter, .unknown, .yes, .no, .choose: false
        default: true
        }
    }

    /// "End the session? Six sets logged." Only a yes ends it; the long-press End stays immediate.
    private func askEndSession(now: Date) -> Outcome {
        guard state != .ended else { return .none }
        let n = session.workingSets.count
        return ask(.endSession, "End the session? \(Callout.word(n).capitalized) \(n == 1 ? "set" : "sets") logged.", now: now)
    }

    /// The ask-back, worded as the action. Nil when there's no sensible way to ask: then it's chatter.
    private func clarifyText(_ intent: VoiceIntent) -> String? {
        let n = intent.number
        switch intent.intent {
        case .reps, .answer, .endSet:
            guard let n else { return intent.intent == .endSet ? "Set done?" : nil }
            let target = isResting ? (session.sets.last.map { $0.setIndex + 1 } ?? setNumber) : setNumber
            return "\(Callout.word(Int(n)).capitalized) reps on set \(target)?"
        case .setLoad: return n.map { "Load \(Format.number($0))?" }
        case .loadDelta: return n.map { $0 >= 0 ? "Add \(Format.number($0))?" : "Take off \(Format.number(-$0))?" }
        case .rpe: return n.map { "RPE \(Format.number($0)) on set \((session.sets.last?.setIndex ?? 0) + 1)?" }
        case .skipSet: return "Skip this set?"
        case .nextExercise: return "Next exercise?"
        case .starting: return "Starting?"
        case .note: return "Note that for Thursday?"
        case .undo: return "Undo \(undoStack.last?.description ?? "that")?"
        default: return nil
        }
    }

    private var isResting: Bool {
        if case .rest = state { return true }
        return state == .paused
    }

    // MARK: Counts (HANDOFF.md §7, Pocket sets)

    /// A spoken count, routed by where the session is. During a set it is the set's. In rest it
    /// corrects the set just done (a "done, 12" well after it is a new set: the rest was cut
    /// short). In Ready it logs a new set, unless the camera is on duty and filmed this lift
    /// moments ago; then a bare count corrects that set, and anything else is asked. A count never
    /// edits a set of another exercise unless that set is named.
    private func routeCount(_ n: Int, done: Bool, named setNumber: Int?, exercise name: String?, transcript: String, now: Date,
                            phone: RepCounter.Result?, willMeasure: Bool) -> Outcome {
        if let setNumber { return correctNamedSet(setNumber, exercise: name, reps: n, transcript: transcript, now: now) }
        switch state {
        case .recording:
            repsOverrideForCurrentSet = n
            guard done else { return echo("This set → \(n) reps") }
            return setEnded(at: now, phone: phone, willMeasure: willMeasure)
        case .hold:
            return done ? holdEnded(at: now) : .none
        case .rest, .paused:
            guard let last = session.sets.indices.last, session.sets[last].seconds == nil else { return .none }
            if done, now.timeIntervalSince(session.sets[last].endedAt) > Self.sameSetSeconds, !currentSetIsTimed {
                return logVoiceSet(reps: n, now: now)
            }
            return spokenReps(at: last, n, transcript: transcript, now: now)
        case .ready, .listening, .saved, .leadIn:
            if done || !cameraSees { return logVoiceSet(reps: n, now: now) }
            if let last = session.sets.indices.last, session.sets[last].exerciseId == currentExercise?.id,
               session.sets[last].seconds == nil, now.timeIntervalSince(session.sets[last].endedAt) < Self.correctionWindowSeconds {
                return spokenReps(at: last, n, transcript: transcript, now: now)
            }
            guard let ex = currentExercise, !currentSetIsTimed else { return .none }
            return ask(.countFor(reps: n), "\(Callout.word(n).capitalized) for set \(setNumber) of \(ex.name.lowercased())?", now: now)
        case .ended:
            return .none
        }
    }

    /// "Done" with no number. During a set it ends it: with the camera's count when it filmed it,
    /// else logged with the plan's reps and "How many?". In Ready (or well into a rest) the set
    /// happened without being seen: logged the same way.
    private func done(now: Date, phone: RepCounter.Result?, willMeasure: Bool) -> Outcome {
        switch state {
        case .recording:
            return setEnded(at: now, phone: phone, willMeasure: willMeasure, askHowMany: true)
        case .hold:
            return holdEnded(at: now)
        case .ready, .listening, .saved:
            return logVoiceSet(reps: nil, now: now)
        case .rest:
            guard let last = session.sets.last, now.timeIntervalSince(last.endedAt) > Self.sameSetSeconds else { return .none }
            return logVoiceSet(reps: nil, now: now)
        case .leadIn, .paused, .ended:
            return .none
        }
    }

    /// A set nobody saw start: logged now for the current target. With a count it is You said and
    /// gets the usual set-end line; without one it is the plan's reps and "How many?".
    private func logVoiceSet(reps n: Int?, now: Date) -> Outcome {
        guard !isComplete, !currentSetIsTimed, state != .ended else { return .none }
        lapseAsk()
        recordingStartedAt = now
        state = .recording
        repsOverrideForCurrentSet = n
        return setEnded(at: now, askHowMany: n == nil)
    }

    /// "Set 3 of incline was 7": the one way a count reaches a set of another exercise.
    private func correctNamedSet(_ number: Int, exercise name: String?, reps: Int, transcript: String, now: Date) -> Outcome {
        let exerciseId: String? = if let name {
            exercises.first { Self.nameMatches(name, $0.exercise.name) }?.exercise.id
        } else {
            session.sets.last?.exerciseId ?? currentExercise?.id
        }
        guard let exerciseId, let i = session.sets.lastIndex(where: { $0.exerciseId == exerciseId && $0.setIndex == number - 1 && !$0.isWarmup })
        else { return say("No set \(number)\(name.map { " of \($0)" } ?? "") yet.") }
        return spokenReps(at: i, reps, transcript: transcript, now: now)
    }

    /// "Flyes" matches "Cable incline flyes": every word said starts a word of the name (four letters
    /// is enough, so "flies" finds "flyes"). The same test as the backend's `name_matches`.
    static func nameMatches(_ said: String, _ name: String) -> Bool {
        let skip: Set<String> = ["the", "a", "my", "of", "on", "with"]
        func words(_ s: String) -> [String] { s.lowercased().split { !$0.isLetter }.map(String.init).filter { !skip.contains($0) } }
        let saidWords = words(said), nameWords = words(name)
        guard !saidWords.isEmpty, !nameWords.isEmpty else { return false }
        return saidWords.allSatisfy { w in nameWords.contains { n in n.hasPrefix(w.prefix(4)) || w.hasPrefix(n.prefix(4)) } }
    }

    private func setLoad(_ n: Double) -> Outcome {
        guard let ex = currentExercise else { return say("Which load?") }
        if pendingSuggestion != nil { _ = decideSuggestion(.kept, spoken: false, load: n) } // his own weight beats the rule's
        let old = loadOverrides[ex.id]
        loadOverrides[ex.id] = n
        undoStack.append(UndoEntry(action: .load(exerciseId: ex.id, old: old), description: "load \(Format.number(n))"))
        return echo("\(ex.name) → \(Format.number(n)) lb", speech: Callout.loadChanged(to: n))
    }

    // MARK: Moving through the plan

    private func moveToNextExercise(skipped: Int = 0) -> Outcome {
        guard !isComplete else { return .none }
        let from = (exerciseIndex, setIndex)
        exerciseIndex += 1
        setIndex = 0
        enterExercise()
        undoStack.append(UndoEntry(action: .skip(exercise: from.0, set: from.1), description: "next exercise"))
        state = isComplete ? .ended : .ready
        if isComplete { return echo("No more exercises", speech: "That's the session.") }
        let ex = currentExercise
        var line = "Next exercise, \(ex?.name ?? ""), \(Callout.target(load: targetLoadLb, reps: targetRepsText))."
        if needsLoad { line += " \(loadAsk)" }
        return echo("Next: \(ex?.name ?? "")", speech: skipped > 0 ? "Skipped. \(line)" : line)
    }

    /// "Yes" to "Log the other 2 sets from the plan?": each one logged with source Plan.
    private func logPlanSets(now: Date) -> Int {
        guard let ex = currentExercise else { return 0 }
        var count = 0
        while setIndex < ex.sets.count {
            let planned = ex.sets[setIndex]
            let set = LoggedSet(id: UUID(), exerciseId: ex.id, setIndex: setIndex, loadLb: targetLoadLb ?? 0,
                                reps: planned.minimumReps ?? planned.totalReps ?? 0, rpe: nil, seconds: planned.seconds, role: planned.role,
                                repCount: RepCount(source: .plan, status: .done), startedAt: now, endedAt: now, clipFile: nil, edits: [],
                                doneAs: doneAs[ex.id])
            session.sets.append(set)
            undoStack.append(UndoEntry(action: .loggedSet(set.id), description: "set \(setIndex + 1)"))
            setIndex += 1
            count += 1
        }
        setIndex = max(0, ex.sets.count - 1)
        return count
    }

    /// "Skip the flyes": that exercise leaves today's session. The plan doesn't change, and the coach sees it.
    private func skipExercise(named name: String, transcript: String, now: Date) -> Outcome {
        guard let index = exercises.indices.first(where: { $0 >= exerciseIndex && Self.nameMatches(name, exercises[$0].exercise.name) })
        else { return say("\(name.capitalized) isn't left today.") }
        let entry = exercises[index]
        session.deviations.append(PlanDeviation(id: UUID(), at: now, kind: .skip, exerciseId: entry.exercise.id,
                                                exerciseName: entry.exercise.name, doneAs: nil, transcript: transcript))
        if index == exerciseIndex {
            let moved = moveToNextExercise()
            return Outcome(speech: "Skipping \(entry.exercise.name.lowercased()) today.").merged(with: moved)
        }
        exercises.remove(at: index)
        undoStack.append(UndoEntry(action: .removedExercise(entry: entry, index: index), description: "skipping \(entry.exercise.name.lowercased())"))
        return echo("Skipped \(entry.exercise.name) today", speech: "Skipping \(entry.exercise.name.lowercased()) today.")
    }

    // MARK: Machine taken (HANDOFF.md §7; with no confirmed rule: wait, or what he names)

    /// What he's doing instead of each exercise today. Its load comes from that variant's own
    /// history, or he says it: never converted from the planned lift's.
    private(set) var doneAs: [String: String] = [:]
    private var swapOldLoads: [String: Double?] = [:]
    /// Equipment taken this session ("smith", "barbell"): never offered again today.
    private(set) var takenEquipment: Set<String> = []
    /// The exercise he's waiting on: "it's free" brings it back. The rest timer keeps running.
    private(set) var waitingFor: String?

    var takenOffer: TakenOffer? {
        if case .takenOffer(let offer) = pendingAsk { return offer }
        return nil
    }

    /// "The bench is taken": the exercise he names if it's still to do today, else the one up now.
    /// His options in his order, said at once as a template (he's standing there waiting).
    private func equipmentTaken(named name: String?, now: Date) -> Outcome {
        let generic: Set<String> = ["bench", "machine", "rack", "station", "one", "this", "it"]
        let specific = name.map { $0.lowercased().split { !$0.isLetter }.map(String.init).filter { !generic.contains($0) }.joined(separator: " ") } ?? ""
        let named = specific.isEmpty ? nil : exercises.indices.first { $0 >= exerciseIndex && Self.nameMatches(specific, exercises[$0].exercise.name) }
        guard let ex = named.map({ exercises[$0].exercise }) ?? currentExercise else { return .none }
        takenEquipment.insert(ExerciseFamily.equipment(of: doneAs[ex.id] ?? ex.name, fallback: ex.equipment))
        let options = takenHelp ? TakenEngine.options(for: ex, rule: takenRule, takenEquipment: takenEquipment, recentVariants: recentVariants) : [.wait]
        let what = name.map { $0.prefix(1).uppercased() + $0.dropFirst() }
        let swaps = options.filter { $0.kind != .wait }
        guard let first = swaps.first else {
            return echo("\(ex.name): taken", speech: "\(what ?? "That")'s taken. The rest keeps running. Say what you'll do instead, or wait.")
        }
        var line = what.map { "\($0)'s taken. His first choice is \(Self.inSentence(first.name))." }
            ?? "For \(ex.name.lowercased()), his first choice is \(Self.inSentence(first.name))."
        if swaps.count > 1 {
            line += " Or \(Self.inSentence(swaps[1].name)). Say 'go with it', 'the other one', or 'I'll wait'."
        } else {
            line += " Say 'go with it' or 'I'll wait'."
        }
        return ask(.takenOffer(TakenOffer(exerciseId: ex.id, what: what, options: options)), line, now: now)
    }

    /// "Incline dumbbell press" mid-sentence, but "Smith squat" keeps its capital.
    private static func inSentence(_ name: String) -> String {
        name.hasPrefix("Smith") ? name : name.prefix(1).lowercased() + name.dropFirst()
    }

    /// "Doing dumbbells instead", or the option he picked: logged as a gym change for the coach,
    /// the plan untouched, the load from that variant's history or his to say.
    private func swap(to what: String, exerciseId: String? = nil, reason: String? = nil, transcript: String, now: Date) -> Outcome {
        guard let ex = exerciseId.flatMap({ id in exercises.first { $0.exercise.id == id }?.exercise }) ?? currentExercise else { return .none }
        doneAs[ex.id] = what
        if waitingFor == ex.id { waitingFor = nil }
        swapOldLoads[ex.id] = loadOverrides[ex.id]
        loadOverrides[ex.id] = nil
        session.deviations.append(PlanDeviation(id: UUID(), at: now, kind: .swap, exerciseId: ex.id, exerciseName: ex.name,
                                                doneAs: what, reason: reason, transcript: transcript))
        // An option he picked is named back; his own words need no echo.
        var speech = reason == nil ? "Noted for Thursday." : "\(what). Noted for Thursday."
        if ex.id == currentExercise?.id {
            if let load = targetLoadLb { speech += " \(Callout.target(load: load, reps: targetRepsText))." } else if needsLoad { speech += " \(loadAsk)" }
        }
        return echo("\(ex.name) → \(what)", speech: speech)
    }

    /// "I'll wait": the rest keeps running, and "it's free" brings the lift back.
    private func waitFor(_ exerciseId: String) -> Outcome {
        waitingFor = exerciseId
        return echo("Waiting for \(exercises.first { $0.exercise.id == exerciseId }?.exercise.name ?? "it")", speech: "Waiting for it. Say 'it's free' when it is.")
    }

    /// "It's free": back to the planned lift.
    private func equipmentFree() -> Outcome {
        if let id = waitingFor, doneAs[id] == nil {
            waitingFor = nil
            let name = exercises.first { $0.exercise.id == id }?.exercise.name ?? "it"
            return echo("Back to \(name)", speech: "Back to \(name.lowercased()).")
        }
        guard let ex = currentExercise, doneAs[ex.id] != nil else { return say("Okay.") }
        doneAs[ex.id] = nil
        loadOverrides[ex.id] = swapOldLoads.removeValue(forKey: ex.id) ?? nil
        return echo("Back to \(ex.name)", speech: "Back to \(ex.name.lowercased()). \(Callout.target(load: targetLoadLb, reps: targetRepsText)).")
    }

    // MARK: Notes and the logbook

    private func addNote(_ text: String, fieldId: String?, now: Date) -> Outcome {
        let note = VoiceNote(id: UUID(), at: now, transcript: text, targetFieldId: fieldId)
        session.notes.append(note)
        undoStack.append(UndoEntry(action: .note(id: note.id), description: "note"))
        return echo("Noted for check-in: \(note.transcript)", speech: "Noted for Thursday.")
    }

    /// "Last time I did 145 for 9": the current lift's logbook entry, and its logbook line from now on.
    private func logbook(load: Double?, reps: Int?, now: Date) -> Outcome {
        guard let ex = currentExercise, let load, let reps, state != .recording else { return say("Say it as: last time I did 145 for 9.") }
        let role = ex.sets.first?.role
        logbookEntries.append(LogbookEntry(id: UUID(), exerciseId: ex.id, role: role, loadLb: load, reps: reps, date: now))
        lastSets[Self.loadKey(ex.id, role)] = LastSet(loadLb: load, reps: reps)
        return echo("Last time: \(ex.name) \(Format.number(load)) × \(reps)", speech: "Got it. Last time \(Format.number(load)) for \(reps).")
    }

    // MARK: Questions (HANDOFF.md §7): every answer a template, every number from the log

    private func answerQuestion(_ topic: VoiceIntent.Topic?, transcript: String, now: Date) -> Outcome {
        switch topic {
        case .next:
            guard let next = nextTarget else { return say("That's the session.") }
            return say(Callout.nextLine(next))
        case .restLeft:
            guard case .rest(let remaining) = state else { return say("No rest running.") }
            let left = Callout.spoken(seconds: remaining)
            return say("\(left.prefix(1).uppercased() + left.dropFirst()) left.")
        case .lastSet:
            guard let last = session.sets.last else { return say("No set yet.") }
            if let seconds = last.seconds { return say("\(Callout.holdLength(seconds).capitalized) logged.") }
            if last.repCount.isCounting { return say("Still counting.") }
            let source = switch last.repCount.source {
            case .measured: "measured"
            case .spoken: "as you said"
            case .phone: "phone count"
            case .watch: "watch count"
            case .plan: "from the plan"
            }
            return say("\(last.isWarmup ? "Warm-up" : "Set \(last.setIndex + 1)"): \(last.reps) reps, \(source).")
        case .lastTime:
            guard let ex = currentExercise, let line = logbookLine(for: ex) else { return say("Nothing in the logbook for these yet.") }
            return say(line)
        case .load:
            if let s = pendingSuggestion {
                return say(s.role == .backOff ? "Back-off at \(Format.number(s.toLb)), his rule." : "\(Format.number(s.toLb)) next, his rule.")
            }
            guard let load = targetLoadLb else { return say("No weight set for these yet.") }
            return say("\(Callout.target(load: load, reps: targetRepsText)).")
        case .setsLeft:
            guard let ex = currentExercise else { return say("That's the session.") }
            let left = ex.sets.count - setIndex
            let then = exercises.indices.contains(exerciseIndex + 1) ? "then \(exercises[exerciseIndex + 1].exercise.name.lowercased())" : "then that's the session"
            return say("\(Callout.word(left).capitalized) more of these, \(then).")
        case .effort:
            guard let last = session.workingSets.last else { return say("No set yet.") }
            if let rpe = last.rpe { return say("You said RPE \(Format.number(rpe)).") }
            guard let effort = effort(for: last), effort.measured else { return say("No measure on that one.") }
            let line = Callout.restLine(set: last, role: plannedSet(for: last)?.role, effort: effort, targetRIR: targetRIR(for: plannedSet(for: last)),
                                        suggestion: nil, rule: nil)
            return say(line.effort ?? "No measure on that one.")
        case .coachNotes:
            guard let notes = currentExercise?.notes?.trimmingCharacters(in: .whitespacesAndNewlines), !notes.isEmpty
            else { return say("No note from him on these.") }
            return say("His note: \(notes)")
        case .outOfScope:
            return ask(.noteOffer(transcript), "That's one for your coach. Want me to note it for Thursday?", now: now)
        case .help:
            return say(VoiceGuide.spokenHelp(state: state, firstSet: session.sets.isEmpty, suggestion: pendingSuggestion != nil,
                                             timed: currentSetIsTimed))
        case nil:
            return heard(transcript)
        }
    }

    /// Nothing spoken: "Heard: …" on the HUD.
    private func heard(_ transcript: String) -> Outcome {
        Outcome(heard: transcript.isEmpty ? nil : transcript)
    }

    // MARK: Warm-ups (HANDOFF.md §7, Warm-up sets)

    /// "Top set" before a set: the next set is the top set. During a set: this one is. "That was
    /// my top set" after a warm-up: the last warm-up becomes the working set it should have been.
    private func topSet(transcript: String, now: Date) -> Outcome {
        let aboutTheLast = transcript.lowercased().contains("was")
        if state == .recording {
            forceWorkingForCurrentSet = true
            return echo("This set → top set")
        }
        if aboutTheLast, let last = session.sets.indices.last, session.sets[last].isWarmup, session.sets[last].exerciseId == currentExercise?.id {
            return reclassify(at: last, toWarmup: false, transcript: transcript, now: now)
        }
        // "Top set. Last time 145 for 9. Beat the logbook." (the cold open)
        guard warmupMode || currentPlannedSet?.role == .top else { return say("Set \(setNumber) is next.") }
        if warmupMode {
            warmupMode = false
            undoStack.append(UndoEntry(action: .warmupMode(wasOn: true), description: "top set"))
        }
        var speech = "Top set."
        if let ex = currentExercise, let logbook = logbookLine(for: ex) { speech += " \(logbook)" }
        if needsLoad { speech += " \(loadAsk)" }
        return echo("Next: set \(setNumber), the top set", speech: speech)
    }

    /// "That was a warm-up": the last working set of this lift becomes a warm-up, the counter moves back.
    private func markLastAsWarmup(now: Date) -> Outcome {
        guard let last = session.sets.indices.last, !session.sets[last].isWarmup,
              session.sets[last].exerciseId == (currentExercise?.id ?? session.sets[last].exerciseId)
        else { return say("Nothing to mark as a warm-up.") }
        return reclassify(at: last, toWarmup: true, transcript: "that was a warm-up", now: now)
    }

    private func reclassify(at i: Int, toWarmup: Bool, transcript: String, now: Date) -> Outcome {
        var set = session.sets[i]
        let oldRole = set.role
        let oldStatus = set.repCount.status
        let planned = plannedSet(for: set)
        if toWarmup {
            set.role = .warmup
            set.repCount.status = .done
            pendingCounts.removeAll { $0.setId == set.id }
            warmupCount += 1
            warmupMode = true
            if exerciseIndex < exercises.count, exercises[exerciseIndex].exercise.id == set.exerciseId {
                setIndex = set.setIndex
            } else if let index = exercises.firstIndex(where: { $0.exercise.id == set.exerciseId }) {
                exerciseIndex = index
                setIndex = set.setIndex
                session.endedAt = nil
                if state == .ended { state = .ready }
            }
        } else {
            set.role = planned?.role
            if set.repCount.status != .failed, set.repCount.measured == nil, set.repCount.source != .spoken {
                // A warm-up reclassified by voice uploads now; its clip is still on the phone.
                set.repCount.status = .counting
                pendingCounts.append(PendingCount(setId: set.id, endedAt: set.endedAt, spoken: true))
            }
            warmupCount = max(0, warmupCount - 1)
            warmupMode = false
            if setIndex == set.setIndex { advance() }
        }
        set.edits.append(SetEdit(at: now, field: "role", from: oldRole?.rawValue ?? "", to: set.role?.rawValue ?? "", transcript: transcript))
        session.sets[i] = set
        undoStack.append(UndoEntry(action: .role(setId: set.id, oldRole: oldRole, oldStatus: oldStatus), description: toWarmup ? "warm-up" : "top set"))
        let number = set.setIndex + 1
        return toWarmup ? echo("Set \(number) → warm-up", speech: "Warm-up. Set \(number) is next.")
                        : echo("Warm-up → set \(number)", speech: "Set \(number) logged.")
    }

    /// A set that needs a SAM upload once its clip is ready: never a warm-up or a timed set.
    func shouldUpload(setId: UUID) -> Bool {
        guard let set = session.sets.first(where: { $0.id == setId }) else { return false }
        let addOn = exercises.first { $0.exercise.id == set.exerciseId }?.addOnId != nil
        return !set.isWarmup && set.seconds == nil && !addOn
    }

    /// Sets whose reclassification by voice means their clip should go to SAM now.
    func setsNeedingUpload() -> [UUID] {
        pendingCounts.filter { p in session.sets.first { $0.id == p.setId }?.repCount.measured == nil }.map(\.setId)
    }

    /// "That was N" on a logged set: the athlete's number wins over every count.
    private func spokenReps(at index: Int, _ n: Int, transcript: String, now: Date) -> Outcome {
        let old = session.sets[index].reps
        let oldSource = session.sets[index].repCount.source
        pendingCounts.removeAll { $0.setId == session.sets[index].id }
        session.sets[index].reps = n
        session.sets[index].repCount.source = .spoken
        session.sets[index].edits.append(SetEdit(at: now, field: "reps", from: "\(old)", to: "\(n)", transcript: transcript))
        undoStack.append(UndoEntry(action: .reps(setId: session.sets[index].id, old: old, oldSource: oldSource), description: "\(n) reps"))
        return echo("Set \(session.sets[index].setIndex + 1) → \(n) reps", speech: Callout.repsLogged(n, setNumber: session.sets[index].setIndex + 1))
    }

    private func answerCount(_ question: PendingQuestion, with n: Int, transcript: String, now: Date) -> Outcome {
        guard let i = session.sets.firstIndex(where: { $0.id == question.setId }) else { return .none }
        return spokenReps(at: i, n, transcript: transcript, now: now)
    }

    /// "Yes" to "was that 7?": SAM's count goes in the log as Measured.
    private func acceptMeasured(_ question: PendingQuestion, transcript: String, now: Date) -> Outcome {
        guard let i = session.sets.firstIndex(where: { $0.id == question.setId }) else { return .none }
        let old = session.sets[i].reps
        let oldSource = session.sets[i].repCount.source
        session.sets[i].reps = question.measured
        session.sets[i].repCount.source = .measured
        session.sets[i].edits.append(SetEdit(at: now, field: "reps", from: "\(old)", to: "\(question.measured)", transcript: transcript))
        undoStack.append(UndoEntry(action: .measured(setId: question.setId, oldReps: old, oldSource: oldSource), description: "measured count"))
        let number = session.sets[i].setIndex + 1
        return echo("Set \(number) → \(question.measured) reps (measured)", speech: Callout.repsLogged(question.measured, setNumber: number))
    }

    private func setNumber(of setId: UUID) -> Int {
        (session.sets.first { $0.id == setId }?.setIndex ?? 0) + 1
    }

    /// Revert the last action and say what was reverted.
    @discardableResult
    func undo() -> Outcome {
        guard let entry = undoStack.popLast() else { return say("Nothing to undo.") }
        switch entry.action {
        case .loggedSet(let id):
            pendingCounts.removeAll { $0.setId == id }
            if let i = session.sets.firstIndex(where: { $0.id == id }) {
                let set = session.sets.remove(at: i)
                if let exIndex = exercises.firstIndex(where: { $0.exercise.id == set.exerciseId }) {
                    exerciseIndex = exIndex
                    setIndex = set.setIndex
                }
                if set.isWarmup {
                    warmupCount = max(0, warmupCount - 1)
                    warmupMode = true
                }
                session.endedAt = nil
                state = .ready
            }
        case .rpe(let id, let old):
            if let i = session.sets.firstIndex(where: { $0.id == id }) { session.sets[i].rpe = old }
        case .reps(let id, let old, let oldSource), .measured(let id, let old, let oldSource):
            if let i = session.sets.firstIndex(where: { $0.id == id }) {
                session.sets[i].reps = old
                session.sets[i].repCount.source = oldSource
            }
        case .load(let exerciseId, let old):
            loadOverrides[exerciseId] = old
        case .skip(let exercise, let set):
            exerciseIndex = exercise
            setIndex = set
            session.endedAt = nil
            state = .ready
        case .note(let id):
            session.notes.removeAll { $0.id == id }
        case .flag(let id):
            if let i = session.sets.firstIndex(where: { $0.id == id }) { session.sets[i].flaggedForCoach = false }
        case .warmupMode(let wasOn):
            warmupMode = wasOn
        case .role(let id, let oldRole, let oldStatus):
            if let i = session.sets.firstIndex(where: { $0.id == id }) {
                let wasWarmup = session.sets[i].isWarmup
                session.sets[i].role = oldRole
                session.sets[i].repCount.status = oldStatus
                pendingCounts.removeAll { $0.setId == id }
                if wasWarmup {
                    warmupCount = max(0, warmupCount - 1)
                    warmupMode = false
                    if setIndex == session.sets[i].setIndex { advance() }
                } else {
                    warmupCount += 1
                    warmupMode = true
                    if let exIndex = exercises.firstIndex(where: { $0.exercise.id == session.sets[i].exerciseId }) {
                        exerciseIndex = exIndex
                        setIndex = session.sets[i].setIndex
                        session.endedAt = nil
                        if state == .ended { state = .ready }
                    }
                }
            }
        case .addOn(let id, let count):
            exercises.removeLast(count)
            session.addOnIds.removeAll { $0 == id }
            if exerciseIndex >= exercises.count {
                exerciseIndex = exercises.count
                setIndex = 0
                state = .ended
                session.endedAt = .now
            }
        case .removedExercise(let entry, let index):
            exercises.insert(entry, at: min(index, exercises.count))
            session.deviations.removeAll { $0.exerciseId == entry.exercise.id && $0.kind == .skip }
        case .skippedAddOn(let entries, let ids):
            exercises += entries
            session.addOnIds += ids
            if state == .ended {
                exerciseIndex = exercises.count - entries.count
                setIndex = 0
                session.endedAt = nil
                state = .ready
                enterExercise()
            }
        }
        return echo("Undid \(entry.description)", speech: "Undid \(entry.description).")
    }

    func endSession(at now: Date = .now) {
        if state == .recording { _ = setEnded(at: now) }
        if case .hold = state { _ = holdEnded(at: now) }
        session.endedAt = now
        state = .ended
    }

    // MARK: Helpers

    private func echo(_ text: String, speech: String? = nil) -> Outcome {
        lastEcho = text
        return Outcome(speech: speech, echo: "\(text). Say undo to revert.")
    }

    private func say(_ text: String) -> Outcome {
        Outcome(speech: text, echo: text)
    }

    struct UndoEntry: Equatable {
        enum Action: Equatable {
            case loggedSet(UUID)
            case rpe(setId: UUID, old: Double?)
            case reps(setId: UUID, old: Int, oldSource: RepSource)
            case measured(setId: UUID, oldReps: Int, oldSource: RepSource)
            case load(exerciseId: String, old: Double?)
            case skip(exercise: Int, set: Int)
            case note(id: UUID)
            case flag(setId: UUID)
            case warmupMode(wasOn: Bool)
            case role(setId: UUID, oldRole: SetRole?, oldStatus: CountStatus)
            case addOn(id: String, count: Int)
            case skippedAddOn(entries: [Entry], ids: [String])
            case removedExercise(entry: Entry, index: Int)
        }

        var action: Action
        var description: String
    }
}
