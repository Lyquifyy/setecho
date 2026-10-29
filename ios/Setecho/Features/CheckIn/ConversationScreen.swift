import SwiftUI

/// The one layout a spoken check-in uses, for Check-in morning and the wrap-up (DESIGN.md), on the
/// hands-free `StageSheet`: the navy stage holds the mark, which check-in this is, the step track
/// and the one line being asked now, in white; the white sheet holds what was just heard and
/// stored, the voice bar saying whose turn it is, and the footer. Earlier lines leave the screen:
/// the voice said them, and the check-in keeps the answers.
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
    /// A summary line tapped, to change it.
    var onSummaryTap: ((SummaryRow) -> Void)?
    @ViewBuilder let footer: Footer
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        StageSheet {
            Theme.stage
        } overlay: {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                HStack(alignment: .center) {
                    StageMark()
                    Spacer()
                    Text(eyebrow).font(.hudLabel).monospacedDigit().foregroundStyle(Theme.onStageSecondary)
                        .lineLimit(1).minimumScaleFactor(0.8)
                }
                if !steps.isEmpty {
                    StepTrack(steps: steps, current: currentStep, onStage: true)
                }
                Spacer(minLength: 0)
                if let asked {
                    Text(asked.text)
                        .font(asked.text.count > 70 ? .hudQuestion : .hudState)
                        .foregroundStyle(Theme.onStage)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .id(asked.id)
                        .transition(reduceMotion ? .opacity : .asymmetric(insertion: .move(edge: .bottom).combined(with: .opacity), removal: .opacity))
                        .accessibilityLabel("Setecho: \(asked.text)")
                }
            }
        } sheet: {
            VStack(spacing: Theme.Space.m) {
                if let summary {
                    ScrollView {
                        SummaryCard(sections: summary, onTap: onSummaryTap, framed: false)
                    }
                    .scrollIndicators(.hidden)
                    .frame(height: 260)
                } else {
                    ForEach(recent) { entry in
                        row(entry).transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
                    }
                }
                if phase != .idle {
                    VoiceBar(phase: phase, level: level, voiceName: voiceName, framed: false)
                        .transition(.opacity)
                }
                if let notice, !notice.isEmpty {
                    Text(notice).font(.hudLabel).secondaryText().multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .transition(.opacity)
                }
                footer
            }
        }
        .animation(reduceMotion ? .easeInOut(duration: 0.25) : .spring(duration: 0.45, bounce: 0.12), value: entries.count)
        .animation(.snappy(duration: 0.3), value: phase)
        .animation(.snappy(duration: 0.3), value: notice)
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
    }

    /// The line being asked now: the last thing Setecho said.
    private var asked: ConversationEntry? { entries.last { $0.kind == .setecho } }

    /// What just happened, under the question: what he said and what was stored since the line
    /// before it (two at most), so the sheet answers "did it hear me, and what went in?".
    private var recent: [ConversationEntry] {
        guard let now = entries.lastIndex(where: { $0.kind == .setecho }) else { return Array(entries.suffix(2)) }
        let before = entries[..<now].lastIndex { $0.kind == .setecho } ?? -1
        return Array(entries[(before + 1)...].filter { $0.kind != .setecho }.suffix(2))
    }

    private var summary: [SummarySection]? {
        for entry in entries.reversed() { if case .summary(let sections) = entry.kind { return sections } }
        return nil
    }

    @ViewBuilder private func row(_ entry: ConversationEntry) -> some View {
        switch entry.kind {
        case .athlete: AthleteLine(text: entry.text)
        case .answer(let label, let value, let source): AnswerCard(label: label, value: value, source: source)
        case .note: Text(entry.text).font(.hudLabel).secondaryText().frame(maxWidth: .infinity, alignment: .center)
        case .setecho, .summary: EmptyView()
        }
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
