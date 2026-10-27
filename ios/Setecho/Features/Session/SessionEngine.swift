import Foundation
import Observation

/// The hands-free session state machine (DESIGN.md Session, HANDOFF.md §7). Pure logic: the camera,
/// microphone and speech live in services that feed it events, so every rule is unit-tested.
///
/// Logging rule: load comes from the plan, or the last spoken override for that exercise. Reps come
/// from the plan unless the athlete says "that was N". RPE is spoken. Every voice action is echoed
/// and can be undone.
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
    private(set) var undoStack: [UndoEntry] = []
    private var recordingStartedAt: Date?
    private var stateBeforePause: State = .ready
    private var repsOverrideForCurrentSet: Int?
    private var clipForCurrentSet: String?

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

    func attachClip(_ file: String) {
        clipForCurrentSet = file
    }

    /// The bar stopped (or the athlete said "done"). Logs the set from the plan plus anything said.
    @discardableResult
    func setEnded(at now: Date = .now) -> Outcome {
        guard state == .recording, let exercise = currentExercise, let planned = currentPlannedSet else { return .none }
        let reps = repsOverrideForCurrentSet ?? planned.reps ?? planned.repsMin ?? 0
        let logged = LoggedSet(
            id: UUID(),
            exerciseId: exercise.id,
            setIndex: setIndex,
            loadLb: targetLoadLb ?? 0,
            reps: reps,
            rpe: nil,
            startedAt: recordingStartedAt ?? now,
            endedAt: now,
            clipFile: clipForCurrentSet,
            edits: []
        )
        session.sets.append(logged)
        undoStack.append(UndoEntry(action: .loggedSet(logged.id), description: "set \(setNumber)"))
        let doneNumber = setNumber
        // The rest belongs to the set just finished, even when the next set is another exercise.
        let rest = exercise.restSeconds ?? defaultRestSeconds
        repsOverrideForCurrentSet = nil
        clipForCurrentSet = nil
        recordingStartedAt = nil

        advance()
        let callout = Callout.setDone(setNumber: doneNumber, next: nextTarget, restSeconds: rest)
        lastCallout = callout
        state = isComplete ? .ended : .rest(remaining: rest)
        if isComplete { session.endedAt = now }
        return Outcome(speech: callout, echo: "Set \(doneNumber) saved: \(Format.number(logged.loadLb)) × \(reps)")
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
        if let pending = pendingAskBack, intent.intent == .answer || intent.intent == .unknown {
            _ = pending
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
            let old = session.sets[last].reps
            session.sets[last].reps = Int(n)
            session.sets[last].edits.append(SetEdit(at: now, field: "reps", from: "\(old)", to: "\(Int(n))", transcript: response.transcript))
            undoStack.append(UndoEntry(action: .reps(setId: session.sets[last].id, old: old), description: "\(Int(n)) reps"))
            return echo("Set \(session.sets[last].setIndex + 1) → \(Int(n)) reps", speech: Callout.repsLogged(Int(n), setNumber: session.sets[last].setIndex + 1))
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
        case .reps(let id, let old):
            if let i = session.sets.firstIndex(where: { $0.id == id }) { session.sets[i].reps = old }
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
            case reps(setId: UUID, old: Int)
            case load(exerciseId: String, old: Double?)
            case skip(exercise: Int, set: Int)
            case note(id: UUID)
        }

        var action: Action
        var description: String
    }
}
