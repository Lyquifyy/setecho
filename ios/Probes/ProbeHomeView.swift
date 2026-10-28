import AVKit
import SwiftUI

struct ProbeHomeView: View {
    var body: some View {
        ScreenScaffold {
            if ProbesPresenter.shared.isShown {
                LinkButton(title: "Close probes", chevron: .leading) { ProbesPresenter.shared.isShown = false }
            }
            TitleBlock(
                eyebrow: "M0 · Tuesday's gates",
                title: "Probes",
                subtitle: "Run each on the real iPhone, then report what you saw."
            )
            SectionCard("On the phone") {
                ProbeRow(gate: "G2", title: "Audio", detail: "DJI mic in, AirPods out, a ducked callout") {
                    AudioProbeView()
                }
                CardDivider()
                ProbeRow(gate: "G3", title: "Apple Health", detail: "Last 7 days of every check-in type, with sources") {
                    HealthProbeView()
                }
                CardDivider()
                ProbeRow(gate: "G6", title: "WhatsApp share", detail: "One image plus text: do both arrive together?") {
                    ShareProbeView()
                }
                CardDivider()
                ProbeRow(gate: "G8", title: "Watch", detail: "Venu 4 sets and wrist counts, with each message's delay") {
                    WatchProbeView()
                }
            }
            #if SETECHO_APP
            SectionCard("Check-in turns") {
                TurnTimingsCard()
            }
            #endif
            SectionCard("Elsewhere") {
                Text("G1 is a question for office hours. G4 (SAM), G5 (import) and the voice smoke run from backend/scripts on the Mac.")
                    .font(.subheadline)
                    .secondaryText()
            }
        }
    }
}

private struct ProbeRow<Destination: View>: View {
    let gate: String
    let title: String
    let detail: String
    @ViewBuilder let destination: () -> Destination

    var body: some View {
        NavigationLink {
            destination()
        } label: {
            HStack(spacing: Theme.Space.s) {
                Text(gate)
                    .font(.columnLabel)
                    .foregroundStyle(Theme.cobalt)
                    .frame(width: Theme.Space.xl, alignment: .leading)
                VStack(alignment: .leading, spacing: Theme.Space.xxs) {
                    Text(title).font(.body.weight(.semibold)).foregroundStyle(Theme.navy)
                    Text(detail).font(.subheadline).secondaryText()
                }
                Spacer(minLength: Theme.Space.xs)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Theme.cobalt)
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(gate), \(title)")
    }
}

#Preview {
    NavigationStack { ProbeHomeView() }
}


#if SETECHO_APP
/// Live stage timings and medians for the check-in turns (HANDOFF.md §9, block 1).
private struct TurnTimingsCard: View {
    @State private var timings = TurnTimings.shared
    @State private var route = "—"

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            Text("Targets: 1 s to first audio on a number, 2 s otherwise.").font(.footnote).secondaryText()
            LabeledRow("Turns", "\(timings.turns.count)")
            LabeledRow("First audio, numbers", seconds(timings.medianFirstAudio(fastPath: true)))
            LabeledRow("First audio, the rest", seconds(timings.medianFirstAudio(fastPath: false)))
            LabeledRow("Round trip (median)", seconds(timings.median(\.roundTrip)))
            LabeledRow("Upload", seconds(timings.median(\.upload)))
            LabeledRow("Transcribe", seconds(timings.median(\.transcribe)))
            LabeledRow("Spark", seconds(timings.median(\.spark, fastPath: false)))
            if let last = timings.turns.last {
                CardDivider()
                Text("Last turn · \(last.intent)\(last.fastPath ? " · fast path" : "")").font(.subheadline.weight(.semibold)).foregroundStyle(Theme.navy)
                LabeledRow("Upload / transcribe / Spark", "\(seconds(last.upload)) / \(seconds(last.transcribe)) / \(seconds(last.spark))")
                LabeledRow("Round trip → first audio", "\(seconds(last.roundTrip)) → \(seconds(last.firstAudio))")
            }
            CardDivider()
            if !timings.openStages.isEmpty {
                LabeledRow("Open → stages", timings.openStages.map { "\($0.name) \(seconds($0.seconds))" }.joined(separator: " · "))
            }
            LabeledRow("Heard", timings.heardCounts.isEmpty ? "—" : timings.heardCounts.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", "))
            LabeledRow("Unclear turns", timings.unclearCount == 0 ? "0" : "\(timings.unclearCount) · " + timings.unclearReasons.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", "))
            LabeledRow("Natural voice", voiceState)
            LabeledRow("Lines cached / live / system", "\(timings.voiceCached) / \(timings.voiceLive) / \(timings.voiceFallbacks)")
            if let reason = timings.voiceLastFallback {
                Text("Last fallback: \(reason)").font(.footnote).secondaryText()
            }
            CardDivider()
            LabeledRow("Audio route", route)
            LabeledRow("AirPods mic", AirPodsMic.shared.state)
            if let notice = AirPodsMic.shared.notice { Text(notice).font(.footnote).secondaryText() }
            HStack {
                LinkButton(title: "Refresh route", chevron: .none) { route = AudioService().routeDescription }
                Spacer()
                InputPickerButton { route = AudioService().routeDescription }
                    .frame(width: 120, height: 44)
            }
        }
        .onAppear { route = AudioService().routeDescription }
    }

    private var voiceState: String {
        if let failure = timings.voiceStatusFailure { return "status failed: \(failure)" }
        guard let configured = timings.voiceConfigured else { return "not asked yet" }
        return configured ? (timings.voiceProvider ?? "configured") : "none configured, system voice"
    }

    private func seconds(_ value: Double?) -> String {
        guard let value else { return "—" }
        return String(format: "%.2f s", value)
    }
}
#endif

#if SETECHO_APP
/// iOS 26's input picker (AVInputPickerInteraction) on a button: the session is set up for recording
/// first, as the picker lists inputs only for a recording session.
private struct InputPickerButton: UIViewRepresentable {
    var onPicked: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onPicked: onPicked) }

    func makeUIView(context: Context) -> UIButton {
        let button = UIButton(type: .system)
        button.setTitle("Pick input", for: .normal)
        button.titleLabel?.font = .preferredFont(forTextStyle: .subheadline)
        button.tintColor = UIColor(Theme.cobalt)
        button.contentHorizontalAlignment = .trailing
        let interaction = AVInputPickerInteraction()
        interaction.delegate = context.coordinator
        button.addInteraction(interaction)
        button.addAction(UIAction { _ in
            AudioService().configure()
            interaction.present()
        }, for: .touchUpInside)
        button.accessibilityLabel = "Pick the audio input"
        return button
    }

    func updateUIView(_ uiView: UIButton, context: Context) {}

    @MainActor
    final class Coordinator: NSObject, @preconcurrency AVInputPickerInteraction.Delegate {
        let onPicked: () -> Void
        init(onPicked: @escaping () -> Void) { self.onPicked = onPicked }
        func inputPickerInteractionDidEndDismissing(_ inputPickerInteraction: AVInputPickerInteraction) {
            onPicked()
        }
    }
}
#endif
