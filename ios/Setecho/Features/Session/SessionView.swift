import SwiftUI

/// Session (DESIGN.md): full-screen and hands-free. The phone sits on the tripod 2–3 m away, facing
/// him. `SessionHUD` draws it from the live session (`SessionHUDModel(engine:live:)`): the lifts
/// across the top, the audio connection, his own camera with the set up now (or the replay of the
/// set he just did, during rest), the voice card. The only tap target is the long-press end.
struct SessionView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var coordinator: SessionCoordinator
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
        // A quarter-second clock for the elapsed time and the word-by-word fill; everything else
        // updates as the engine, the mic and the camera change.
        TimelineView(.periodic(from: .now, by: 0.25)) { context in
            SessionHUD(model: SessionHUDModel(engine: engine, live: live(at: context.date)),
                       onEnd: endSession,
                       footer: coordinator.rehearsal ? AnyView(rehearsalField) : nil)
        }
        .environment(\.sessionCameraFeed, cameraFeed)
        .environment(\.sessionReplayFeed, replayFeed)
        .overlay { if coordinator.showSlate { Color.white.ignoresSafeArea() } } // the filming slate
        .overlay {
            if coordinator.permissionsDenied {
                Text("Microphone access is needed for a hands-free session.")
                    .font(.hudLabel).foregroundStyle(Theme.navy).multilineTextAlignment(.center)
                    .padding(Theme.cardPadding)
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
                    .padding(Theme.gutter)
            }
        }
        .task { await coordinator.start() }
        // A tripod rest is 3–4 minutes: the screen must not lock and stop the camera, and the countdown stays in view.
        .keepsScreenAwake()
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
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
    }

    /// The mic, the camera and the conversation right now, for the screen's model.
    private func live(at date: Date) -> SessionHUDModel.Live {
        let audio = coordinator.audio
        let talk = coordinator.conversation
        return SessionHUDModel.Live(
            micLabel: audio.inputLabel, micOnHim: audio.isHeadWornMic, micLevel: audio.inputLevel,
            cameraRunning: coordinator.cameraRunning, cameraOnDuty: coordinator.detector.isOnDuty, cameraDark: coordinator.detector.isDark,
            frontCamera: coordinator.detector.front, trackedBox: coordinator.detector.trackedBox,
            hearing: audio.isHearing, liveWords: coordinator.liveWords, reading: talk.reading,
            speakingLine: talk.speakingLine, speakingSince: talk.speakingSince, lastLine: talk.lastLine, now: date)
    }

    /// His live image, from the set detector's own capture session.
    private var cameraFeed: AnyView? {
        guard coordinator.cameraRunning else { return nil }
        return AnyView(SessionCameraPreview(session: coordinator.detector.captureSession, mirrored: coordinator.detector.front))
    }

    /// During rest, the set he just did, from the clip kept for his coach (once it's exported).
    private var replayFeed: AnyView? {
        guard coordinator.cameraRunning, let file = engine.session.sets.last?.clipFile else { return nil }
        return AnyView(ReplayView(url: store.mediaDirectory.appendingPathComponent(file), front: coordinator.detector.front))
    }

    private func endSession() {
        if engine.state != .ended { coordinator.end() }
        dismiss()
    }

    private var rehearsalField: some View {
        HStack(spacing: Theme.Space.s) {
            SettingsField(placeholder: "Say something, e.g. done, 12", text: $typed)
                .submitLabel(.send)
                .onSubmit(sendTyped)
            LinkButton(title: "Say", chevron: .none, action: sendTyped)
        }
    }

    private var engine: SessionEngine { coordinator.engine }

    private func sendTyped() {
        let line = typed.trimmingCharacters(in: .whitespaces)
        guard !line.isEmpty else { return }
        typed = ""
        Task { await coordinator.rehearse(line) }
    }

    /// "Abs · Plank", but "Stomach Vacuums" once when the add-on and its exercise share the name.
    static func nameLine(section: String?, name: String) -> String {
        guard let section, !SessionEngine.sameName(section, name) else { return name }
        return "\(section) · \(name)"
    }
}
