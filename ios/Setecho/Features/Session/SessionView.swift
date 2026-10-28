import SwiftUI

/// Session (DESIGN.md): full-screen and hands-free. The phone sits on the tripod 2–3 m away.
/// Top to bottom: exercise name, the target with the set counter, the state line, the last set's
/// result, the voice echo, up next. The only tap target is End session, which needs a long press.
struct SessionView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var coordinator: SessionCoordinator
    @State private var endProgress = false
    @State private var typed = ""
    private let store: Store

    /// The day's session with the add-ons joining it, or a morning session of one add-on (day nil).
    /// A rehearsal (Developer → Session rehearsal) has no camera and no mic: lines are typed and go
    /// through the real backend, and nothing is saved to the log.
    init(day: ProgramDay?, addOns: [AddOn] = [], weekNumber: Int, store: Store, rehearsal: Bool = false) {
        self.store = store
        _coordinator = State(initialValue: SessionCoordinator(day: day, addOns: addOns, weekNumber: weekNumber, store: store, rehearsal: rehearsal))
    }

    var body: some View {
        let engine = coordinator.engine
        VStack(spacing: Theme.Space.l) {
            HStack {
                Image("Lockup")
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
                    .frame(height: 26)
                    .foregroundStyle(Theme.cobalt)
                    .accessibilityHidden(true)
                Spacer()
                Text(engine.day == nil ? engine.title : "\(engine.title) · Week \(engine.weekNumber)").font(.hudLabel).secondaryText()
            }

            Spacer(minLength: 0)

            if let exercise = engine.currentExercise {
                Text(Self.nameLine(section: engine.currentEntry?.section, name: exercise.name)).font(.hudLabel).secondaryText()
                Text(targetText(engine))
                    .font(.hudTarget)
                    .foregroundStyle(Theme.navy)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                TargetTag(text: engine.currentPlannedSet?.role.map { "\($0.label) · set \(engine.setNumber) of \(engine.setCount)" } ?? "Set \(engine.setNumber) of \(engine.setCount)")
                    .scaleEffect(1.4)
                    .padding(.vertical, Theme.Space.xs)
            } else {
                Text("Session over").font(.hudTarget).foregroundStyle(Theme.navy).minimumScaleFactor(0.5)
                Text(sessionOverText(engine)).font(.hudLabel).secondaryText()
            }

            HStack(spacing: Theme.Space.m) {
                HUDState(state: coordinator.hudState)
                InputStatus(camera: coordinator.detector.isOnDuty)
            }

            if let last = engine.session.sets.last {
                HStack(spacing: Theme.Space.s) {
                    Text(lastSetText(last)).font(.hudLabel).foregroundStyle(Theme.navy)
                    // "Measured" from SAM; "Phone" only as the fallback; "Counting" while SAM works.
                    SourceChip(source: last.repCount.isCounting ? "Counting" : last.repCount.source.chipText)
                        .scaleEffect(1.3)
                        .padding(.horizontal, Theme.Space.xs)
                }
                if !last.isWarmup { EffortLine(set: last) }
            }
            if let suggestion = engine.pendingSuggestion {
                SuggestionTag(suggestion: suggestion, reps: engine.targetRepsText)
            }
            if case .rest = engine.state, let line = coordinator.spokenLine {
                Text(line).font(.hudLabel).secondaryText().multilineTextAlignment(.center)
            }

            if let echo = coordinator.echo {
                VoiceEcho(text: echo)
            } else if let heard = coordinator.heard {
                // Chatter: shown, never answered.
                Text(heard).font(.hudLabel).secondaryText().lineLimit(2)
            }
            if let ask = coordinator.askBack {
                Text(ask).font(.hudLabel).foregroundStyle(Theme.navy)
            }

            Spacer(minLength: 0)

            if let next = upNext(engine) {
                Text(next).font(.hudLabel).secondaryText()
            }
            if let error = coordinator.audio.lastError ?? coordinator.detector.lastError {
                Text(error).font(.hudLabel).secondaryText()
            }
            if coordinator.permissionsDenied {
                Text("Microphone access is needed for a hands-free session.").font(.hudLabel).foregroundStyle(Theme.navy)
            }

            if coordinator.rehearsal {
                HStack(spacing: Theme.Space.s) {
                    SettingsField(placeholder: "Say something, e.g. done, 12", text: $typed)
                        .submitLabel(.send)
                        .onSubmit(sendTyped)
                    LinkButton(title: "Say", chevron: .none, action: sendTyped)
                }
            }

            endButton
        }
        .padding(Theme.gutter)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.page.ignoresSafeArea())
        .overlay { if coordinator.showSlate { Color.white.ignoresSafeArea() } } // the filming slate
        .task { await coordinator.start() }
        // A tripod rest is 3–4 minutes: the screen must not lock and stop the camera, and the countdown stays in view.
        .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
        .onChange(of: engine.state) { _, state in
            if state == .ended {
                Task {
                    try? await Task.sleep(for: .seconds(4))
                    dismiss()
                }
            }
        }
        .onChange(of: coordinator.requestedDayNumber) { _, number in
            // "I'm doing Day 5 today": the cursor moves and the session restarts on that day.
            guard let number, let program = store.currentProgram,
                  let found = program.days.first(where: { $0.day.name.lowercased() == "day \(number)" })
            else { return }
            store.changeDay(to: found.day.id)
            coordinator.end()
            coordinator = SessionCoordinator(day: found.day, addOns: store.addOnsDue(on: found.day.id).map(\.addOn), weekNumber: found.week.number, store: store)
            Task { await coordinator.start() }
        }
        .animation(.default, value: coordinator.echo)
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
    }

    /// Long press only, so a brush against the phone never ends the session.
    private var endButton: some View {
        Text(engine.state == .ended ? "Done" : "Hold to end session")
            .font(.headline)
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, minHeight: 60)
            .background(endProgress ? Theme.cobaltPressed : Theme.cobalt,
                        in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
            .contentShape(Rectangle())
            .onLongPressGesture(minimumDuration: 1.2, pressing: { endProgress = $0 }) {
                if engine.state == .ended {
                    dismiss()
                } else {
                    coordinator.end()
                    dismiss()
                }
            }
            .accessibilityLabel("End session")
            .accessibilityHint("Press and hold for one second, or say end session")
    }

    private var engine: SessionEngine { coordinator.engine }

    private func sendTyped() {
        let line = typed.trimmingCharacters(in: .whitespaces)
        guard !line.isEmpty else { return }
        typed = ""
        Task { await coordinator.rehearse(line) }
    }

    private func targetText(_ engine: SessionEngine) -> String {
        if case .hold(let remaining) = engine.state { return Format.duration(TimeInterval(remaining)) }
        if case .leadIn(let remaining) = engine.state { return "\(remaining)" }
        if engine.currentSetIsTimed { return engine.targetRepsText }
        if let load = engine.targetLoadLb { return "\(Format.number(load)) × \(engine.targetRepsText)" }
        return "× \(engine.targetRepsText)"
    }

    /// The count shows once it is settled: while SAM works, the set is the load alone. A warm-up
    /// says so, and a hold shows its seconds.
    private func lastSetText(_ set: LoggedSet) -> String {
        let name = set.isWarmup ? "warm-up" : "set \(set.setIndex + 1)"
        var s: String
        if let seconds = set.seconds {
            s = "Last: \(name), \(Format.duration(TimeInterval(seconds)))"
        } else if set.repCount.isCounting {
            s = "Last: \(name), \(Format.load(set.loadLb))"
        } else if set.loadLb > 0 {
            s = "Last: \(name), \(Format.number(set.loadLb)) × \(set.reps)"
        } else {
            s = "Last: \(name), \(set.reps) reps"
        }
        if let rpe = set.rpe { s += " · RPE \(Format.number(rpe))" }
        return s
    }

    /// "12 sets logged · SAM median 24 s": the latency report the human reads off the screen (P1b).
    private func sessionOverText(_ engine: SessionEngine) -> String {
        var s = "\(engine.session.workingSets.count) sets logged"
        if let median = coordinator.medianCountLatency { s += " · SAM median \(Int(median.rounded())) s" }
        return s
    }

    private func upNext(_ engine: SessionEngine) -> String? {
        guard let exercise = engine.currentExercise else { return nil }
        if engine.setIndex + 1 < exercise.sets.count {
            return "Up next: set \(engine.setNumber + 1) of \(exercise.sets.count)"
        }
        let nextIndex = engine.exerciseIndex + 1
        guard engine.exercises.indices.contains(nextIndex) else { return "Up next: last set of the session" }
        let next = engine.exercises[nextIndex]
        return "Up next: \(Self.nameLine(section: next.section, name: next.exercise.name))"
    }

    /// "Abs · Plank", but "Stomach Vacuums" once when the add-on and its exercise share the name.
    static func nameLine(section: String?, name: String) -> String {
        guard let section, !SessionEngine.sameName(section, name) else { return name }
        return "\(section) · \(name)"
    }
}
