import SwiftUI

/// Coach reply (DESIGN.md): see exactly what the coach changed before anything changes. The reply
/// card, the changes grouped by what they touch, the unclear sentences, the cues for sessions,
/// and "Apply N changes". Not hands-free: it's reviewed at home.
struct CoachReplyView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(Store.self) private var store
    let reply: CoachReply
    @State private var model: CoachReplyModel?
    @State private var showAll = false
    @State private var handEdit = false

    var body: some View {
        Group {
            if let model {
                content(model)
            } else {
                ProgressView().tint(Theme.cobalt).frame(maxWidth: .infinity, maxHeight: .infinity).background(Theme.page)
            }
        }
        .task { if model == nil { model = CoachReplyModel(store: store, reply: reply) } }
    }

    private func content(_ model: CoachReplyModel) -> some View {
        let reply = model.reply
        return ScreenScaffold {
            LinkButton(title: "Back", chevron: .leading) { dismiss() }
            TitleBlock(eyebrow: reply.map { Format.shortDate($0.receivedAt) }, title: "Coach reply",
                       subtitle: reply?.summary(duration: model.audioDuration))
            if let reply {
                replyCard(reply, model: model)
                if let summary = model.appliedSummary {
                    SectionCard("Applied") {
                        Text(summary).font(.subheadline).foregroundStyle(Theme.navy)
                        if !store.macroFactorReminders.isEmpty {
                            Text("MacroFactor can't be changed from here; Today reminds you until you mark it done.")
                                .font(.footnote).secondaryText()
                        }
                    }
                } else if reply.isApplied {
                    SectionCard("Applied") {
                        Text("Applied as plan version \(reply.appliedVersion ?? 0). Revert from History → Plan changes.")
                            .font(.subheadline).secondaryText()
                    }
                }
                if model.changes.isEmpty {
                    SectionCard("Changes") {
                        Text("No changes to the plan in this reply.").font(.subheadline).secondaryText()
                    }
                }
                ForEach(model.groupedChanges, id: \.group) { group in
                    SectionCard(group.group) {
                        ForEach(Array(group.changes.enumerated()), id: \.element.id) { index, change in
                            if index > 0 { CardDivider() }
                            ChangeRow(change: change, onToggle: reply.isApplied ? nil : { model.toggle(change) })
                        }
                    }
                }
                if !reply.unclear.isEmpty {
                    SectionCard("Not sure") {
                        Text("These sound like changes but match nothing in the plan.").font(.footnote).secondaryText()
                        ForEach(Array(reply.unclear.enumerated()), id: \.offset) { index, text in
                            if index > 0 { CardDivider() }
                            UnclearRow(text: text) { handEdit = true }
                        }
                    }
                }
                if model.cuesEnabled, !model.cues.isEmpty {
                    SectionCard("In your sessions") {
                        Text("Played once before the exercise, never during a set.").font(.footnote).secondaryText()
                        ForEach(Array(model.cues.enumerated()), id: \.element.id) { index, cue in
                            if index > 0 { CardDivider() }
                            CueRow(cue: cue, exerciseName: store.plan?.exerciseName(id: cue.exerciseId) ?? cue.exerciseId,
                                   onPlay: { model.play(cue: cue) }, onToggle: { model.toggle(cue: cue) })
                        }
                    }
                }
            }
        } footer: {
            if let reply, !reply.isApplied {
                Button(model.approvedCount == 1 ? "Apply 1 change" : "Apply \(model.approvedCount) changes") {
                    model.apply()
                }
                .buttonStyle(.setechoPrimary)
                .disabled(model.approvedCount == 0 && model.cues.isEmpty)
            } else {
                Button("Done") { dismiss() }.buttonStyle(.setechoPrimary)
            }
        }
        .sheet(isPresented: $handEdit) {
            SettingsView()
        }
    }

    private func replyCard(_ reply: CoachReply, model: CoachReplyModel) -> some View {
        SectionCard(reply.kind == .voiceNote ? "Voice note" : "His message", accessory: {
            if reply.kind == .voiceNote {
                PlayButton(accessibilityLabel: "Play the voice note") { model.playNote() }
            }
        }) {
            Text(reply.transcript)
                .font(.body)
                .foregroundStyle(Theme.navy)
                .lineLimit(showAll ? nil : 4)
                .textSelection(.enabled)
            if reply.transcript.count > 200 {
                LinkButton(title: showAll ? "Show less" : "Show all", chevron: .none) { showAll.toggle() }
            }
        }
    }
}
