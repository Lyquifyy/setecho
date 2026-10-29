import SwiftUI

/// Check-in morning (DESIGN.md): the whole check-in as one conversation. The step track across the
/// top, the conversation filling the middle (every line said, every answer stored with its check),
/// the voice bar saying whose turn it is. Full-screen and hands-free; the photo session runs
/// inside it, and it ends on Review and send, the one tap of the morning.
struct CheckInMorningView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(Store.self) private var store
    @State private var model: CheckInMorningModel
    let coordinator: CheckInCoordinator

    init(coordinator: CheckInCoordinator, store: Store, fresh: Bool = false) {
        self.coordinator = coordinator
        _model = State(initialValue: CheckInMorningModel(coordinator: coordinator, store: store, fresh: fresh))
    }

    var body: some View {
        ConversationScreen(
            eyebrow: model.title,
            steps: CheckInMorningStep.allCases.map { .init(id: $0.wire, title: $0.title) },
            currentStep: model.isDone ? CheckInMorningStep.allCases.count : model.stepIndex,
            entries: model.transcript,
            phase: model.phase,
            level: model.audio.inputLevel,
            notice: model.status ?? AirPodsMic.shared.notice,
            voiceName: AudioService.voiceDescription,
            // Once it's done, every line of the summary opens to change it.
            onSummaryTap: model.isDone ? { model.edit($0) } : nil
        ) {
            if model.isDone {
                Button("Open to send") { model.showReview = true }.buttonStyle(.setechoPrimary)
                HStack {
                    LinkButton(title: "Read it back", chevron: .none, hud: true) { Task { await model.readBack() } }
                    Spacer()
                    LinkButton(title: "Start over", chevron: .none, hud: true) { Task { await model.startOver() } }
                    Spacer()
                    // The way out once it's done: the answers are saved, the tab can send later.
                    LinkButton(title: "Done for now", chevron: .none, hud: true) { Task { await model.leave() } }
                }
            } else {
                HoldButton(title: "Hold to stop",
                           accessibilityHint: "Press and hold. Your answers are saved; reopening picks up where you left off.") {
                    model.stop()
                    dismiss()
                }
            }
        }
        .overlay { if model.showSlate { Color.white.ignoresSafeArea() } } // the filming slate
        .task { await model.start() }
        // Hands-free means the screen must not lock mid-conversation, photos and review included.
        .keepsScreenAwake()
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)) { _ in model.enterBackground() }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in Task { await model.enterForeground() } }
        .fullScreenCover(isPresented: $model.showPhotos, onDismiss: {
            Task { await model.photosFinished() }
        }) {
            PhotoSessionView(store: store, existing: model.photosToReview).environment(store)
        }
        .sheet(item: $model.editingField, onDismiss: { model.editFinished() }) { field in
            FieldEditSheet(field: field, coordinator: coordinator)
        }
        .fullScreenCover(isPresented: $model.showReview, onDismiss: { Task { await model.reviewClosed() } }) {
            NavigationStack { ReviewSendView(coordinator: coordinator) }.environment(store)
        }
        // Sent, or "done for now": the morning closes itself once its last line is said.
        .onChange(of: model.finished) { _, finished in if finished { dismiss() } }
        .animation(.snappy(duration: 0.3), value: model.isDone)
    }
}
