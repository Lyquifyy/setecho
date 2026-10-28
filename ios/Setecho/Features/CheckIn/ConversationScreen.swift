import SwiftUI

/// The one layout a spoken check-in uses, for Check-in morning and the wrap-up (DESIGN.md):
/// the lockup and which check-in this is, the step track, the conversation filling the middle,
/// the voice bar saying whose turn it is, then the footer. Full-screen and hands-free: the footer
/// holds the hold-to-stop button, and only once it is done, the one tap of the morning.
struct ConversationScreen<Footer: View>: View {
    /// "Thursday check-in", "Practice run", "Wrap-up · 4 of 9".
    let eyebrow: String
    var steps: [StepTrack.Step] = []
    var currentStep = 0
    let entries: [ConversationEntry]
    let phase: VoicePhase
    var level: Double = 0
    /// A line under the voice bar: an error, an AirPods notice, "Open Withings once…".
    var notice: String?
    /// Which voice is speaking, so a fallback to a lesser voice is never a mystery.
    var voiceName: String?
    @ViewBuilder let footer: Footer

    var body: some View {
        VStack(spacing: Theme.Space.m) {
            HStack(alignment: .center) {
                Image("Lockup")
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
                    .frame(height: 26)
                    .foregroundStyle(Theme.cobalt)
                    .accessibilityLabel("Setecho")
                Spacer()
                Text(eyebrow).font(.hudLabel).monospacedDigit().secondaryText().lineLimit(1).minimumScaleFactor(0.8)
            }
            if !steps.isEmpty {
                StepTrack(steps: steps, current: currentStep)
            }
            ConversationTranscript(entries: entries)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if phase != .idle {
                VoiceBar(phase: phase, level: level)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            if let notice, !notice.isEmpty {
                Text(notice).font(.hudLabel).secondaryText().multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .transition(.opacity)
            }
            footer
            if let voiceName {
                Text("Voice · \(voiceName)").font(.caption).secondaryText().accessibilityLabel("Voice: \(voiceName)")
            }
        }
        .padding(Theme.gutter)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.page.ignoresSafeArea())
        .animation(.snappy(duration: 0.3), value: phase)
        .animation(.snappy(duration: 0.3), value: notice)
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
    }
}

#Preview {
    ConversationScreen(
        eyebrow: "Thursday check-in",
        steps: CheckInMorningStep.allCases.map { .init(id: $0.wire, title: $0.title) },
        currentStep: 1,
        entries: [
            .setecho("Morning, Zander. It's your Thursday check-in. We'll do your weight, glucose and photos, then your coach's questions."),
            .setecho("Apple Health has you at 180.8, down 0.4 from last week. Should I use that?"),
            .athlete("Yeah, go with that."),
            .answer(label: "Weight", value: "180.8", source: "Apple Health"),
            .setecho("Okay. And your fasted glucose?"),
        ],
        phase: .listening,
        level: 0.3,
        voiceName: "Ava (Premium)"
    ) {
        HoldButton(title: "Hold to stop") {}
    }
}
