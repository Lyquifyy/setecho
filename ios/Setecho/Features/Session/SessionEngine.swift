import Foundation
import Observation

/// The hands-free session state machine (DESIGN.md Session, HANDOFF.md §7). Pure logic: the camera,
/// microphone and speech live in services that feed it events, so every rule is unit-tested.
///
/// Logging rule: load comes from the plan, or the last spoken override for that exercise. Reps
/// follow the rep-counting rules: what the athlete said, else the phone's instant count, else the
/// plan; SAM's measured count arrives during rest and corrects the log when it is confident. RPE
/// is spoken. Every voice action is echoed and can be undone.
@MainActor
@Observable
final class SessionEngine {
    enum State: Equatable {
        case ready
        case recording
        case saved
        case rest(remaining: Int)
        case listening
        case paused
        case ended

        var isListeningAllowed: Bool {
            switch self {
            case .ready, .rest, .saved, .listening, .paused: true
            case .recording, .ended: false
            }
        }
    }

    /// What the services should do after an event: say something, show an echo, ask back.
    struct Outcome: Equatable {
        var speech: String?
        var echo: String?
        var askBack: String?
        static let none = Outcome()
    }

    /// "Set 3, was that 7 or 8?" waiting for a spoken number.
    struct PendingQuestion: Equatable {
        var setId: UUID
        var measured: Int
        var current: Int
    }

    let day: ProgramDay
    let weekNumber: Int
    let defaultRestSeconds: Int

    private(set) var session: Session
    private(set) var state: State = .ready
    private(set) var exerciseIndex = 0
    private(set) var setIndex = 0
    private(set) var loadOverrides: [String: Double] = [:]
    private(set) var lastEcho: String?
    private(set) var lastCallout: String?
    private(set) var pendingAskBack: String?
    private(set) var pendingQuestion: PendingQuestion?
    private(set) var undoStack: [UndoEntry] = []
    /// Measured counts that arrived during a set, applied at the next rest. Never spoken mid-set.
    private(set) var heldMeasurements: [(setId: UUID, response: CountResponse)] = []
    private var recordingStartedAt: Date?
    private var stateBeforePause: State = .ready
    private var repsOverrideForCurrentSet: Int?

    init(day: ProgramDay, weekNumber: Int, defaultRestSeconds: Int = 150, now: Date = .now) {
        self.day = day
        self.weekNumber = weekNumber
        self.defaultRestSeconds = defaultRestSeconds
        self.session = Session(id: UUID(), programDayId: day.id, startedAt: now, endedAt: nil, sets: [], notes: [])
    }

    // MARK: Current target

    var currentExercise: PlannedExercise? { day.exercises.indices.contains(exerciseIndex) ? day.exercises[exerciseIndex] : nil }
    var currentPlannedSet: PlannedSet? {
        guard let ex = currentExercise, ex.sets.indices.contains(setIndex) else { return nil }
        return ex.sets[setIndex]
    }
    var targetLoadLb: Double? {
        guard let ex = currentExercise else { return nil }
        return loadOverrides[ex.id] ?? currentPlannedSet?.loadLb
    }
    var targetRepsText: String { currentPlannedSet?.repsText ?? "?" }
    var setNumber: Int { setIndex + 1 }
    var setCount: Int { currentExercise?.sets.count ?? 0 }
    var isComplete: Bool { currentExercise == nil }
    var restSeconds: Int { currentExercise?.restSeconds ?? defaultRestSeconds }
    var lastLoggedSetId: UUID? { session.sets.last?.id }

    var context: SessionContext {
        SessionContext(
            state: stateName,
            exerciseName: currentExercise?.name,
            setIndex: isComplete ? nil : setNumber,
            setCount: isComplete ? nil : setCount,
            plannedLoadLb: targetLoadLb,
            plannedReps: currentPlannedSet?.reps
        )
    }

    private var stateName: String {
        switch state {
        case .ready: "ready"
        case .recording: "recording"
        case .saved: "saved"
        case .rest: "rest"
        case .listening: "listening"
        case .paused: "paused"
        case .ended: "ended"
        }
    }

    // MARK: Set detection events

    /// The bar started moving (or the athlete said "starting").
    @discardableResult
    func setStarted(at now: Date = .now) -> Outcome {
        guard !isComplete, state != .recording, state != .ended, state != .paused else { return .none }
        recordingStartedAt = now
        state = .recording
        return Outcome(echo: "Set \(setNumber) recording")
    }

    /// The bar stopped (or the athlete said "done"). Logs the set: what was said, else the phone's
    /// count, else the plan. `willMeasure` marks the count as pending SAM's answer.
    @discardableResult
    func setEnded(at now: Date = .now, phone: RepCounter.Result? = nil, willMeasure: Bool = false) -> Outcome {
        guard state == .recording, let exercise = currentExercise, let planned = currentPlannedSet else { return .none }
        let planReps = planned.reps ?? planned.repsMin ?? 0
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
        let logged = LoggedSet(
            id: UUID(),
            exerciseId: exercise.id,
            setIndex: setIndex,
            loadLb: targetLoadLb ?? 0,
            reps: reps,
            rpe: nil,
            repCount: RepCount(source: source, phone: phoneReps, status: willMeasure ? .counting : .done),
            startedAt: recordingStartedAt ?? now,
            endedAt: now,
            clipFile: nil,
            edits: []
        )
        session.sets.append(logged)
        undoStack.append(UndoEntry(action: .loggedSet(logged.id), description: "set \(setNumber)"))
        let doneNumber = setNumber
        // The rest belongs to the set just finished, even when the next set is another exercise.
        let rest = exercise.restSeconds ?? defaultRestSeconds
        let shortBy = source == .plan ? 0 : max(0, (planned.repsMin ?? planned.reps ?? 0) - reps)
        repsOverrideForCurrentSet = nil
        recordingStartedAt = nil

        advance()
        let callout = Callout.setDone(setNumber: doneNumber, reps: source == .plan ? nil : reps, shortBy: shortBy,
                                      next: nextTarget, restSeconds: rest)
        lastCallout = callout
        state = isComplete ? .ended : .rest(remaining: rest)
        if isComplete { session.endedAt = now }
        var outcome = Outcome(speech: callout, echo: "Set \(doneNumber) saved: \(Format.number(logged.loadLb)) × \(reps)")
        // Measured counts that arrived mid-set are spoken now, during rest.
        for held in heldMeasurements {
            let late = applyMeasured(setId: held.setId, held.response, now: now)
            if let speech = late.speech { outcome.speech = [outcome.speech, speech].compactMap { $0 }.joined(separator: " ") }
            if let echo = late.echo { outcome.echo = echo }
            if let ask = late.askBack { outcome.askBack = ask }
        }
        heldMeasurements.removeAll()
        return outcome
    }

    /// The set's trimmed clip finished exporting after the set was logged.
    func attachClip(setId: UUID, file: String) {
        if let i = session.sets.firstIndex(where: { $0.id == setId }) { session.sets[i].clipFile = file }
    }

    // MARK: Measured counts (HANDOFF.md §7, Rep counting)

    /// SAM's count came back. During a set it is held; otherwise: same number, the chip changes
    /// and nothing is said; different and confident, the log changes (undoable) and it is said;
    /// different and unsure, the athlete is asked. "That was N" always wins.
    @discardableResult
    func measured(setId: UUID, _ response: CountResponse, now: Date = .now) -> Outcome {
        if state == .recording {
            heldMeasurements.append((setId, response))
            return .none
        }
        return applyMeasured(setId: setId, response, now: now)
    }

    private func applyMeasured(setId: UUID, _ response: CountResponse, now: Date) -> Outcome {
        guard let i = session.sets.firstIndex(where: { $0.id == setId }) else { return .none }
        var set = session.sets[i]
        set.repCount.measured = response.reps
        set.repCount.confidence = response.confidence
        set.repCount.repTimes = response.repTimes
        guard response.trackFound, let measured = response.reps else {
            set.repCount.status = .failed
            session.sets[i] = set
            return .none
        }
        set.repCount.status = .done
        let number = set.setIndex + 1
        if set.repCount.source == .spoken {
            session.sets[i] = set
            return .none
        }
        if measured == set.reps {
            set.repCount.source = .measured
            session.sets[i] = set
            return .none
        }
        if response.confidence >= RepCount.confidentThreshold {
            let old = set.reps
            let oldSource = set.repCount.source
            set.reps = measured
            set.repCount.source = .measured
            set.edits.append(SetEdit(at: now, field: "reps", from: "\(old)", to: "\(measured)", transcript: "measured"))
            session.sets[i] = set
            undoStack.append(UndoEntry(action: .measured(setId: setId, oldReps: old, oldSource: oldSource), description: "measured count"))
            lastEcho = "Set \(number) → \(measured) reps (measured)"
            return Outcome(speech: Callout.measuredCorrection(setNumber: number, measured: measured, was: old),
                           echo: "Set \(number) → \(measured) reps (measured). Say undo to revert.")
        }
        session.sets[i] = set
        pendingQuestion = PendingQuestion(setId: setId, measured: measured, current: set.reps)
        let ask = Callout.whichCount(setNumber: number, measured: measured, current: set.reps)
        return Outcome(speech: ask, askBack: ask)
    }

    /// The clip never reached the backend: the phone count stands.
    func countFailed(setId: UUID) {
        if let i = session.sets.firstIndex(where: { $0.id == setId }) { session.sets[i].repCount.status = .failed }
    }

    private var nextTarget: Callout.NextSet? {
        guard let ex = currentExercise else { return nil }
        if setIndex == 0, exerciseIndex > 0 || session.sets.isEmpty == false, session.sets.last?.exerciseId != ex.id {
            return .nextExercise(name: ex.name, loadLb: targetLoadLb, reps: targetRepsText)
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
        }
    }

    /// One second of rest passed. Returns the callout for "rest over" when it ends.
    @discardableResult
    func tickRest() -> Outcome {
        guard case .rest(let remaining) = state else { return .none }
        if remaining <= 1 {
            state = .ready
            return Outcome(speech: "Go.", echo: "Ready")
        }
        state = .rest(remaining: remaining - 1)
        return .none
    }

    func skipRest() {
        if case .rest = state { state = .ready }
    }

    // MARK: Voice

    func listeningStarted() {
        if state.isListeningAllowed, state != .paused { state = .listening }
    }

    func listeningEnded(resumeRest remaining: Int?) {
        guard state == .listening else { return }
        state = remaining.map { .rest(remaining: $0) } ?? .ready
    }

    /// Apply a classified command. Low confidence or unknown asks back and changes nothing.
    @discardableResult
    func apply(_ response: VoiceCommandResponse, now: Date = .now) -> Outcome {
        let intent = response.intent
        // A number answers "was that 7 or 8?"; any other command lets the question lapse.
        if let question = pendingQuestion {
            if let n = intent.number, intent.intent == .answer || intent.intent == .reps, intent.confidence >= VoiceIntent.actThreshold {
                pendingQuestion = nil
                return answerQuestion(question, with: Int(n), transcript: response.transcript, now: now)
            }
            if intent.isActionable { pendingQuestion = nil }
        }
        guard intent.isActionable else {
            let ask = Callout.askBack(response.transcript.isEmpty ? "that" : response.transcript)
            pendingAskBack = response.transcript
            return Outcome(speech: ask, askBack: ask)
        }
        pendingAskBack = nil
        switch intent.intent {
        case .rpe:
            guard let n = intent.number, let last = session.sets.indices.last else { return say("No set to rate yet.") }
            let old = session.sets[last].rpe
            session.sets[last].rpe = n
            session.sets[last].edits.append(SetEdit(at: now, field: "rpe", from: old.map(Format.number) ?? "", to: Format.number(n), transcript: response.transcript))
            undoStack.append(UndoEntry(action: .rpe(setId: session.sets[last].id, old: old), description: "RPE \(Format.number(n))"))
            return echo("Set \(session.sets[last].setIndex + 1) → RPE \(Format.number(n))", speech: Callout.rpeLogged(n, setNumber: session.sets[last].setIndex + 1))
        case .reps:
            guard let n = intent.number else { return say("How many reps?") }
            if state == .recording {
                repsOverrideForCurrentSet = Int(n)
                return echo("This set → \(Int(n)) reps")
            }
            guard let last = session.sets.indices.last else { return say("No set to correct yet.") }
            return spokenReps(at: last, Int(n), transcript: response.transcript, now: now)
        case .setLoad:
            guard let n = intent.number, let ex = currentExercise else { return say("Which load?") }
            let old = loadOverrides[ex.id]
            loadOverrides[ex.id] = n
            undoStack.append(UndoEntry(action: .load(exerciseId: ex.id, old: old), description: "load \(Format.number(n))"))
            return echo("\(ex.name) → \(Format.number(n)) lb", speech: Callout.loadChanged(to: n))
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
            let from = (exerciseIndex, setIndex)
            exerciseIndex += 1
            setIndex = 0
            undoStack.append(UndoEntry(action: .skip(exercise: from.0, set: from.1), description: "next exercise"))
            state = isComplete ? .ended : .ready
            return echo(isComplete ? "No more exercises" : "Next: \(currentExercise?.name ?? "")", speech: isComplete ? "That's the session." : "Next exercise, \(currentExercise?.name ?? ""), \(Callout.target(load: targetLoadLb, reps: targetRepsText)).")
        case .note:
            let note = VoiceNote(id: UUID(), at: now, transcript: intent.text ?? response.transcript, targetFieldId: intent.fieldId)
            session.notes.append(note)
            undoStack.append(UndoEntry(action: .note(id: note.id), description: "note"))
            return echo("Noted for check-in: \(note.transcript)", speech: "Noted.")
        case .undo:
            return undo()
        case .pause:
            guard state != .paused, state != .ended else { return .none }
            stateBeforePause = state
            state = .paused
            return echo("Paused", speech: "Paused.")
        case .resume:
            guard state == .paused else { return .none }
            state = stateBeforePause == .recording ? .ready : stateBeforePause
            return echo("Resumed", speech: "Resumed.")
        case .endSession:
            endSession(at: now)
            return echo("Session ended", speech: "Session ended. \(session.sets.count) sets logged.")
        case .starting:
            let outcome = setStarted(at: now)
            return outcome.echo == nil ? .none : outcome
        case .endSet:
            return setEnded(at: now)
        case .answer, .unknown:
            return .none
        }
    }

    /// "That was N" on a logged set: the athlete's number wins over every count.
    private func spokenReps(at index: Int, _ n: Int, transcript: String, now: Date) -> Outcome {
        let old = session.sets[index].reps
        let oldSource = session.sets[index].repCount.source
        session.sets[index].reps = n
        session.sets[index].repCount.source = .spoken
        session.sets[index].edits.append(SetEdit(at: now, field: "reps", from: "\(old)", to: "\(n)", transcript: transcript))
        undoStack.append(UndoEntry(action: .reps(setId: session.sets[index].id, old: old, oldSource: oldSource), description: "\(n) reps"))
        return echo("Set \(session.sets[index].setIndex + 1) → \(n) reps", speech: Callout.repsLogged(n, setNumber: session.sets[index].setIndex + 1))
    }

    private func answerQuestion(_ question: PendingQuestion, with n: Int, transcript: String, now: Date) -> Outcome {
        guard let i = session.sets.firstIndex(where: { $0.id == question.setId }) else { return .none }
        return spokenReps(at: i, n, transcript: transcript, now: now)
    }

    /// Revert the last action and say what was reverted.
    @discardableResult
    func undo() -> Outcome {
        guard let entry = undoStack.popLast() else { return say("Nothing to undo.") }
        switch entry.action {
        case .loggedSet(let id):
            if let i = session.sets.firstIndex(where: { $0.id == id }) {
                let set = session.sets.remove(at: i)
                if let exIndex = day.exercises.firstIndex(where: { $0.id == set.exerciseId }) {
                    exerciseIndex = exIndex
                    setIndex = set.setIndex
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
        }
        return echo("Undid \(entry.description)", speech: "Undid \(entry.description).")
    }

    func endSession(at now: Date = .now) {
        if state == .recording { _ = setEnded(at: now) }
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
        }

        var action: Action
        var description: String
    }
}
