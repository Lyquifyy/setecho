import CoreGraphics
import Foundation

/// The live session as the session screen shows it (DESIGN.md Session): every value from the engine,
/// the conversation, the mic and the camera, so `SessionHUD` itself stays a plain view of a model.
extension SessionHUDModel {
    /// What the services know right now, beside the engine.
    struct Live {
        var micLabel = "Phone mic"
        var micOnHim = false
        var micLevel = 0.0
        /// The camera is running (not a rehearsal or a morning of holds), and sees him.
        var cameraRunning = false
        var cameraOnDuty = false
        /// The camera's picture is dark: the phone is in a pocket.
        var cameraDark = false
        /// The front camera faces him; its picture is shown mirrored, like a mirror.
        var frontCamera = false
        /// His box in the camera's upright, unmirrored frame (`SetDetector.trackedBox`).
        var trackedBox: CGRect?
        /// Someone is talking into the mic, with the stream's words so far.
        var hearing = false
        var liveWords: String?
        /// His words while the turn is read; the line being said and when it started; the last line.
        var reading: String?
        var speakingLine: String?
        var speakingSince: Date?
        var lastLine: String?
        var now = Date.now
    }

    /// Setecho's speech rate for the word-by-word fill: about 2.6 words a second at his default rate.
    static let wordsPerSecond = 2.6

    @MainActor
    init(engine: SessionEngine, live: Live) {
        let ex = engine.currentExercise
        let planned = engine.currentPlannedSet
        let phase = Self.phase(engine, now: live.now)
        self.init(
            phase: phase,
            // A pocket is a dark picture. Off duty alone isn't one: on the tripod before the tracker
            // finds him, he needs his picture to frame himself (Oct 29).
            pocket: live.cameraRunning && live.cameraDark,
            progress: Self.progress(engine),
            micLabel: live.micLabel,
            micOnHim: live.micOnHim,
            exercise: ex?.name ?? "",
            role: engine.state == .paused ? "Paused" : engine.warmupMode ? "Warm-up \(engine.warmupCount + 1)" : planned?.role?.label,
            setLabel: engine.isComplete ? "" : "set \(engine.setNumber) of \(engine.setCount)",
            load: engine.targetLoadLb.flatMap { $0 > 0 ? $0 : nil },
            reps: engine.isComplete ? "" : engine.targetRepsText,
            lastTime: ex.flatMap { e in
                engine.lastSets[SessionEngine.loadKey(e.id, planned?.role)].map { "Last time \(Format.number($0.loadLb)) × \($0.reps)" }
            },
            voice: Self.voice(engine, live: live, phase: phase),
            result: Self.result(engine),
            loggedLoadLb: engine.session.sets.last?.loadLb,
            next: Self.next(engine),
            nextAsk: engine.pendingAskText,
            summary: phase == .done ? Self.summary(engine) : nil,
            camera: live.cameraRunning && !live.cameraDark,
            lockBox: live.trackedBox.map { box in
                live.frontCamera ? CGRect(x: 1 - box.maxX, y: box.minY, width: box.width, height: box.height) : box
            }
        )
    }

    @MainActor
    static func phase(_ engine: SessionEngine, now: Date) -> Phase {
        switch engine.state {
        case .ready, .saved, .listening, .paused:
            return engine.isArmed ? .armed : .ready
        case .leadIn:
            return .armed
        case .recording:
            return .recording(elapsed: max(0, Int(now.timeIntervalSince(engine.recordingStartedAt ?? now))))
        case .rest(let remaining):
            return engine.isArmed ? .armed : .rest(remaining: remaining, total: max(1, engine.restTotal))
        case .hold(let remaining):
            return .hold(remaining: remaining, total: engine.currentPlannedSet?.seconds ?? max(1, remaining),
                         index: engine.setNumber, count: engine.setCount)
        case .ended:
            return .done
        }
    }

    /// Today's lifts as short names with a dot per set; an add-on is one entry, its sets together.
    @MainActor
    static func progress(_ engine: SessionEngine) -> [ExerciseDots] {
        let entries = engine.exercises
        let names = shortNames(entries.filter { $0.addOnId == nil }.map(\.exercise.name))
        var dayIndex = 0
        var out: [ExerciseDots] = []
        for (i, entry) in entries.enumerated() {
            let ex = entry.exercise
            let logged = engine.session.sets.filter { $0.exerciseId == ex.id && !$0.isWarmup }.count
            let ended = engine.endedExerciseIds.contains(ex.id) || (i < engine.exerciseIndex && logged < ex.sets.count)
            let dots: [ExerciseDots.Dot] = ex.sets.indices.map { k in
                if i == engine.exerciseIndex, k == engine.setIndex, !engine.isComplete, engine.state != .ended { return .current }
                if k < logged { return .done }
                return ended ? .skipped : .upcoming
            }
            if let section = entry.section, entry.addOnId != nil {
                if let last = out.last, last.isAddOn, last.name == section {
                    out[out.count - 1].dots += dots
                } else {
                    out.append(ExerciseDots(name: section, dots: dots, isAddOn: true))
                }
            } else {
                out.append(ExerciseDots(name: names[dayIndex], dots: dots))
                dayIndex += 1
            }
        }
        return out
    }

    /// "Incline DB press" → "Incline", "Smith close-grip press" → "Close-grip": the first word that
    /// isn't equipment or a posture; two words when the day has two of the same.
    static func shortNames(_ names: [String]) -> [String] {
        let skip: Set<String> = ["barbell", "dumbbell", "db", "bb", "cable", "machine", "smith", "seated", "standing", "lying",
                                 "hanging", "ez", "bar", "the", "single", "arm", "one"]
        func words(_ name: String) -> [String] {
            let all = name.split(separator: " ").map(String.init)
            let kept = all.filter { !skip.contains($0.lowercased()) }
            return kept.isEmpty ? all : kept
        }
        let first = names.map { words($0).first.map { $0.prefix(1).uppercased() + $0.dropFirst() } ?? $0 }
        return names.indices.map { i in
            guard first.filter({ $0 == first[i] }).count > 1 else { return first[i] }
            let w = words(names[i])
            return w.count > 1 ? "\(first[i]) \(w.last!)" : first[i]
        }
    }

    @MainActor
    static func voice(_ engine: SessionEngine, live: Live, phase: Phase) -> Voice {
        if live.hearing { return .hearing(live.liveWords ?? "…", level: max(0.3, live.micLevel)) }
        if let reading = live.reading, !reading.isEmpty { return .thinking(reading) }
        if let line = live.speakingLine {
            let elapsed = live.now.timeIntervalSince(live.speakingSince ?? live.now)
            return .speaking(line, spoken: Int(elapsed * wordsPerSecond) + 1)
        }
        if let last = live.lastLine { return .speaking(last, spoken: Int.max) }
        if phase == .done { return .idle(hints: []) }
        return .idle(hints: VoiceGuide.hints(for: engine))
    }

    /// The last set as Results shows it: its count and where it came from, then the effort.
    @MainActor
    static func result(_ engine: SessionEngine) -> [Fact] {
        guard let set = engine.session.sets.last else { return [] }
        if set.repCount.isCounting { return [Fact(text: set.isWarmup ? "Warm-up" : "Counting")] }
        if let seconds = set.seconds { return [Fact(text: "\(Format.duration(TimeInterval(seconds))) held")] }
        var facts = [Fact(text: set.isWarmup ? "Warm-up · \(set.reps) reps" : "\(set.reps) reps"),
                     Fact(text: set.repCount.source.chipText, source: true)]
        if let loss = set.repCount.velocityLossPct { facts.append(Fact(text: "slowed \(Int(loss.rounded()))%")) }
        if let rpe = set.rpe {
            facts.append(Fact(text: "RPE \(Format.number(rpe))"))
        } else if let rir = set.repCount.estimatedRIR {
            facts.append(Fact(text: rir < 0.5 ? "failure" : "about \(Int(rir.rounded())) left"))
        }
        return facts
    }

    /// What's next, as the yellow tag: "Back-off 65 × 8–10", or the next exercise by name.
    @MainActor
    static func next(_ engine: SessionEngine) -> String? {
        guard let ex = engine.currentExercise else { return nil }
        let load = engine.targetLoadLb.flatMap { $0 > 0 ? Format.number($0) + " × " : nil } ?? ""
        let target = load + engine.targetRepsText
        if engine.session.sets.last?.exerciseId != ex.id { return "\(ex.name) · \(target)" }
        let label = engine.currentPlannedSet?.role?.label ?? "Set \(engine.setNumber)"
        return "\(label) \(target)"
    }

    /// Session end: each exercise's top set, a logbook beaten, flags, notes and gym changes.
    @MainActor
    static func summary(_ engine: SessionEngine) -> Summary {
        var lines: [Summary.Line] = []
        for entry in engine.exercises {
            let sets = engine.session.sets.filter { $0.exerciseId == entry.exercise.id && !$0.isWarmup }
            guard let top = sets.max(by: { ($0.loadLb, $0.reps, $0.seconds ?? 0) < ($1.loadLb, $1.reps, $1.seconds ?? 0) }) else { continue }
            let text = top.seconds.map { "\(Format.duration(TimeInterval($0)))" }
                ?? (top.loadLb > 0 ? "\(Format.number(top.loadLb)) × \(top.reps)" : "\(top.reps) reps")
            let last = engine.lastSets[SessionEngine.loadKey(top.exerciseId, top.role)]
            let beat = last.map { top.loadLb > $0.loadLb || (top.loadLb == $0.loadLb && top.reps > $0.reps) } ?? false
            lines.append(.init(exercise: entry.exercise.name, top: text, beat: beat ? "Beat the logbook" : nil))
        }
        var notes: [String] = []
        for set in engine.session.sets where set.flaggedForCoach {
            let name = engine.exercises.first { $0.exercise.id == set.exerciseId }?.exercise.name ?? set.exerciseId
            notes.append("Flagged: \(name.lowercased()), set \(set.setIndex + 1)")
        }
        notes += engine.session.notes.map { "Noted: \($0.transcript)" }
        for d in engine.session.deviations {
            switch d.kind {
            case .skip: notes.append("Skipped: \(d.exerciseName.lowercased())")
            case .swap: notes.append("Swapped: \(d.exerciseName.lowercased()) → \((d.doneAs ?? "").lowercased())")
            case .reorder: notes.append("\(d.exerciseName) \(d.reason ?? "moved ahead")")
            }
        }
        // The P1b latency report he reads off the screen: SAM's median from set end to count.
        if let median = engine.medianCountLatency { notes.append("Counted in \(Int(median.rounded())) s on average") }
        return Summary(lines: lines, notes: notes)
    }
}
