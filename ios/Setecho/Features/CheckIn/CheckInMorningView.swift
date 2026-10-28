import SwiftUI

/// Check-in morning (DESIGN.md): the whole check-in as one conversation. Five step dots, the
/// current question in the HUD, the athlete's last words and Setecho's reply, the listening pulse,
/// and an echo for each stored answer. Full-screen and hands-free; the photo session runs inside
/// it, and it ends on Review and send.
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
        VStack(spacing: Theme.Space.l) {
            HStack {
                Image("Lockup").renderingMode(.template).resizable().scaledToFit().frame(height: 26).foregroundStyle(Theme.cobalt)
                    .accessibilityHidden(true)
                Spacer()
                Text("Check-in morning").font(.hudLabel).secondaryText()
            }
            stepDots
            Spacer(minLength: 0)
            Text(model.question).font(.hudState).foregroundStyle(Theme.navy).multilineTextAlignment(.center)
            if let words = model.lastWords {
                Text("“\(words)”").font(.hudLabel).foregroundStyle(Theme.navy).multilineTextAlignment(.center)
            }
            if let reply = model.reply, reply != model.question {
                Text(reply).font(.hudLabel).secondaryText().multilineTextAlignment(.center)
            }
            if model.isPaused {
                Text("Take your time. Just talk when you're ready.").font(.hudLabel).secondaryText()
                ListeningIndicator().opacity(0.5)
            } else if model.isListening, !model.audio.isSpeaking {
                // The mic is open: say so plainly, and let the ring move with his voice.
                ListeningIndicator(level: model.audio.inputLevel, label: model.audio.inputLevel > 0.25 ? "Hearing you" : "Your turn")
            }
            if let echo = model.echo {
                VoiceEcho(text: echo)
            }
            if let status = model.status {
                Text(status).font(.hudLabel).secondaryText()
            }
            if let notice = AirPodsMic.shared.notice {
                Text(notice).font(.hudLabel).secondaryText().multilineTextAlignment(.center)
            }
            Spacer(minLength: 0)
            if model.isDone {
                Button("Open to send") { model.showReview = true }.buttonStyle(.setechoPrimary)
                LinkButton(title: "Read it back", chevron: .none) { Task { await model.readBack() } }
            }
            Text("Hold to stop")
                .font(.headline)
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, minHeight: 60)
                .background(Theme.cobalt, in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
                .contentShape(Rectangle())
                .onLongPressGesture(minimumDuration: 1.0) {
                    model.stop()
                    dismiss()
                }
                .accessibilityLabel("Stop the check-in")
                .accessibilityHint("Press and hold. Your answers are saved; reopening picks up where you left off.")
        }
        .padding(Theme.gutter)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.page.ignoresSafeArea())
        .overlay { if model.showSlate { Color.white.ignoresSafeArea() } } // the filming slate
        .task { await model.start() }
        // Hands-free means the screen must not lock mid-conversation.
        .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)) { _ in model.enterBackground() }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in Task { await model.enterForeground() } }
        .fullScreenCover(isPresented: $model.showPhotos, onDismiss: {
            UIApplication.shared.isIdleTimerDisabled = true
            Task { await model.photosFinished() }
        }) {
            PhotoSessionView(store: store).environment(store)
        }
        .fullScreenCover(isPresented: $model.showReview) {
            NavigationStack { ReviewSendView(coordinator: coordinator) }.environment(store)
        }
        .animation(.default, value: model.echo)
        .statusBarHidden()
    }

    /// Weight · Glucose · Photos · Questions · Review
    private var stepDots: some View {
        HStack(spacing: Theme.Space.s) {
            ForEach(CheckInMorningStep.allCases, id: \.rawValue) { step in
                let state: DotState = step.rawValue < model.stepIndex ? .done : step == model.step ? .current : .pending
                HStack(spacing: Theme.Space.xxs) {
                    Circle()
                        .fill(state == .pending ? Theme.border : Theme.cobalt)
                        .frame(width: 10, height: 10)
                        .overlay(Circle().strokeBorder(Theme.yellow, lineWidth: state == .current ? 3 : 0).frame(width: 16, height: 16))
                    Text(step.title).font(.footnote.weight(state == .current ? .semibold : .regular))
                        .foregroundStyle(state == .pending ? Theme.textSecondary : Theme.navy)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(step.title), \(state == .done ? "done" : state == .current ? "current" : "pending")")
            }
        }
        .frame(maxWidth: .infinity)
    }

    private enum DotState { case done, current, pending }
}
