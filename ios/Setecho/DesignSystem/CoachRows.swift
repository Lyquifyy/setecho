import SwiftUI

/// One proposed plan change (DESIGN.md Components): what it touches, before → after with the old
/// value struck through, when it starts, the coach's exact words beneath, and a checkbox. An
/// unclear item uses the same row with no checkbox and an "Add by hand" link.
struct ChangeRow: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let change: PlanChange
    var onToggle: (() -> Void)?
    var applied = false

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Space.s) {
            VStack(alignment: .leading, spacing: Theme.Space.xxs) {
                Text(change.label).font(.body.weight(.semibold)).foregroundStyle(Theme.navy)
                HStack(spacing: Theme.Space.xs) {
                    if let before = change.before {
                        Text(before).font(.body).monospacedDigit().strikethrough().secondaryText()
                        Text("→").font(.body).secondaryText()
                    }
                    Text(change.after ?? "").font(.body.weight(.semibold)).monospacedDigit().foregroundStyle(Theme.navy)
                        .contentTransition(reduceMotion ? .opacity : .numericText())
                }
                if let from = change.appliesFromDate {
                    Text("From \(from.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()))")
                        .font(.footnote).secondaryText()
                }
                Text("“\(change.quote)”").font(.footnote).secondaryText()
            }
            Spacer(minLength: Theme.Space.xs)
            if let onToggle {
                Checkbox(isOn: change.approved, action: onToggle)
                    .accessibilityLabel("\(change.label), \(change.approved ? "approved" : "not approved")")
            } else if applied && change.approved {
                VStack(spacing: Theme.Space.xxs) {
                    AnimatedCheck(size: 24)
                    Text("Applied").font(.caption).foregroundStyle(Theme.cobalt)
                }
                .transition(.opacity)
            } else if applied {
                Text("Not applied").font(.caption).secondaryText()
            }
        }
        .padding(.vertical, Theme.Space.xxs)
        .animation(reduceMotion ? .easeOut(duration: 0.15) : .snappy(duration: 0.35), value: applied)
    }
}

/// His sentence that sounds like a change but matches nothing in the plan.
struct UnclearRow: View {
    let text: String
    var onAddByHand: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Space.s) {
            Text("“\(text)”").font(.footnote).foregroundStyle(Theme.navy)
            Spacer(minLength: Theme.Space.xs)
            LinkButton(title: "Add by hand", chevron: .none, action: onAddByHand)
        }
        .padding(.vertical, Theme.Space.xxs)
    }
}

/// One coach voice cue: the exercise it plays before, his words, a play button and a checkbox.
struct CueRow: View {
    let cue: VoiceCue
    let exerciseName: String
    var onPlay: () -> Void
    var onToggle: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Space.s) {
            PlayButton(accessibilityLabel: "Play cue for \(exerciseName)", action: onPlay)
            VStack(alignment: .leading, spacing: Theme.Space.xxs) {
                Text(exerciseName).font(.body.weight(.semibold)).foregroundStyle(Theme.navy)
                Text("“\(cue.text)”").font(.footnote).secondaryText()
                if cue.audioFile == nil {
                    Text("Read aloud by the phone").font(.caption).secondaryText()
                }
            }
            Spacer(minLength: Theme.Space.xs)
            Checkbox(isOn: cue.approved, action: onToggle)
                .accessibilityLabel("Cue for \(exerciseName), \(cue.approved ? "on" : "off")")
        }
        .padding(.vertical, Theme.Space.xxs)
    }
}

/// A square checkbox, cobalt when on.
struct Checkbox: View {
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: isOn ? "checkmark.square.fill" : "square")
                .font(.title2)
                .foregroundStyle(isOn ? Theme.cobalt : Theme.textSecondary)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    VStack(spacing: Theme.gutter) {
        SectionCard("Targets") {
            ChangeRow(change: PlanChange(id: "c1", kind: .macroTarget, path: "targets.training.carbsG", label: "Training-day carbs",
                                         op: .decrease, amount: 25, before: "250 g", after: "225 g",
                                         quote: "drop training day carbs by 25", appliesFrom: "2026-11-02", approved: true)) {}
            CardDivider()
            UnclearRow(text: "and let's add some sauna") {}
        }
        SectionCard("In your sessions") {
            CueRow(cue: VoiceCue(id: "cue1", replyId: UUID(), exerciseId: "bench", text: "Pause a full second at the bottom.",
                                 audioFile: nil, startSec: nil, endSec: nil, approved: true, lastPlayedAt: nil),
                   exerciseName: "Bench press", onPlay: {}, onToggle: {})
        }
    }
    .padding(Theme.gutter)
    .background(Theme.page)
}
