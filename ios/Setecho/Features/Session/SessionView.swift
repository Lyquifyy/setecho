import SwiftUI

/// Session (DESIGN.md): full-screen and hands-free. The phone sits on the tripod 2–3 m away.
/// Top to bottom: exercise name, the target with the set counter, the state line, the last set's
/// result, the voice echo, up next. The only tap target is End session, which needs a long press.
struct SessionView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var coordinator: SessionCoordinator
    @State private var endProgress = false

    init(day: ProgramDay, weekNumber: Int, store: Store) {
        _coordinator = State(initialValue: SessionCoordinator(day: day, weekNumber: weekNumber, store: store))
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
                Text("\(engine.day.name) · Week \(engine.weekNumber)").font(.hudLabel).secondaryText()
            }

            Spacer(minLength: 0)

            if let exercise = engine.currentExercise {
                Text(exercise.name).font(.hudLabel).secondaryText()
                Text(targetText(engine))
                    .font(.hudTarget)
                    .foregroundStyle(Theme.navy)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                TargetTag(text: "Set \(engine.setNumber) of \(engine.setCount)")
                    .scaleEffect(1.4)
                    .padding(.vertical, Theme.Space.xs)
            } else {
                Text("Session over").font(.hudTarget).foregroundStyle(Theme.navy).minimumScaleFactor(0.5)
                Text("\(engine.session.sets.count) sets logged").font(.hudLabel).secondaryText()
            }

            HUDState(state: coordinator.hudState)

            if let last = engine.session.sets.last {
                Text(lastSetText(last)).font(.hudLabel).foregroundStyle(Theme.navy)
            }

            if let echo = coordinator.echo {
                VoiceEcho(text: echo)
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

            endButton
        }
        .padding(Theme.gutter)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.page.ignoresSafeArea())
        .task { await coordinator.start() }
        .onChange(of: engine.state) { _, state in
            if state == .ended {
                Task {
                    try? await Task.sleep(for: .seconds(4))
                    dismiss()
                }
            }
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

    private func targetText(_ engine: SessionEngine) -> String {
        if let load = engine.targetLoadLb { return "\(Format.number(load)) × \(engine.targetRepsText)" }
        return "× \(engine.targetRepsText)"
    }

    private func lastSetText(_ set: LoggedSet) -> String {
        var s = "Last: set \(set.setIndex + 1), \(Format.number(set.loadLb)) × \(set.reps)"
        if let rpe = set.rpe { s += " · RPE \(Format.number(rpe))" }
        return s
    }

    private func upNext(_ engine: SessionEngine) -> String? {
        guard let exercise = engine.currentExercise else { return nil }
        if engine.setIndex + 1 < exercise.sets.count {
            return "Up next: set \(engine.setNumber + 1) of \(exercise.sets.count)"
        }
        let nextIndex = engine.exerciseIndex + 1
        guard engine.day.exercises.indices.contains(nextIndex) else { return "Up next: last set of the session" }
        return "Up next: \(engine.day.exercises[nextIndex].name)"
    }
}
