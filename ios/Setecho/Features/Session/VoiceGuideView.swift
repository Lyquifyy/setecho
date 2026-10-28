import SwiftUI

/// What you can say (DESIGN.md): every line a session understands, one tab per kind of session
/// (Working out, Abs, Vacuums), grouped by when you'd say it. From Today's session card, Settings →
/// Sessions and the session intro. Out loud, the same help is "what can I say?" between sets.
struct VoiceGuideView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var guide = VoiceGuide.guides.first?.title ?? ""

    var body: some View {
        ScreenScaffold(onClose: { dismiss() }) {
            TitleBlock(title: "What you can say",
                       subtitle: "Between sets, say it your way: these are examples, not passwords. Talk to anyone else freely; what isn't for Setecho is ignored.")
            SegmentTabs(items: VoiceGuide.guides.map { .init(value: $0.title, title: $0.title) }, selection: $guide)
            ForEach(VoiceGuide.guides.first { $0.title == guide }?.sections ?? [], id: \.title) { section in
                SectionCard(section.title) {
                    Text(section.detail).font(.footnote).secondaryText()
                    ForEach(section.phrases, id: \.say) { phrase in
                        CardDivider()
                        PhraseRow(phrase: phrase)
                    }
                }
            }
        }
    }
}

/// One line you can say, then what it does.
private struct PhraseRow: View {
    let phrase: VoiceGuide.Phrase

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xxs) {
            Text("\u{201C}\(phrase.say)\u{201D}").font(.body.weight(.semibold)).monospacedDigit().foregroundStyle(Theme.navy)
            Text(phrase.does).font(.subheadline).monospacedDigit().secondaryText()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

/// How a session works (DESIGN.md): shown once, before the first session, and from Settings →
/// Sessions after that. With `onStart` its footer starts the session; without, it closes.
struct SessionIntroView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(Store.self) private var store
    var onStart: (() -> Void)?
    @State private var showGuide = false
    @State private var practicing = false

    var body: some View {
        ScreenScaffold(onClose: { dismiss() }) {
            TitleBlock(eyebrow: onStart == nil ? nil : "Before your first session", title: "How a session works")
            step("Set the phone down",
                 "On the tripod, 2 to 3 m away and facing you, so the camera sees each set. Or in your pocket: then your voice runs it.")
            step("Lift",
                 "The camera starts each set, ends it and counts it. Without the camera, say \u{201C}starting\u{201D}, then \u{201C}done, 8\u{201D} when you rack it.")
            step("Talk between sets",
                 "Ask what's next, change the weight, fix a count or leave your coach a note, in your own words. Every action is said back, and \u{201C}undo\u{201D} takes back anything.")
            step("Not sure? Ask",
                 "Say \u{201C}what can I say?\u{201D} between sets and Setecho tells you what works right then.")
            SectionCard {
                LinkButton(title: "Everything you can say") { showGuide = true }
                if store.todayDay.map({ !$0.day.isRest }) ?? false {
                    CardDivider()
                    LinkButton(title: "Practice first") { practicing = true }
                    Text("Today's session with the camera and mic off: type what you'd say and hear the answer. Nothing is logged.")
                        .font(.footnote).secondaryText()
                }
            }
        } footer: {
            Button(onStart == nil ? "Done" : "Start session") {
                Settings.shared.hasSeenSessionIntro = true
                onStart?()
                dismiss()
            }
            .buttonStyle(.setechoPrimary)
        }
        .sheet(isPresented: $showGuide) { VoiceGuideView() }
        .fullScreenCover(isPresented: $practicing) {
            let today = store.todayDay
            SessionView(day: today?.day, addOns: today.map { store.addOnsDue(on: $0.day.id).map(\.addOn) } ?? [],
                        weekNumber: today?.week.number ?? 1, store: store, rehearsal: true)
        }
    }

    private func step(_ title: String, _ text: String) -> some View {
        SectionCard(title) {
            Text(text).font(.subheadline).foregroundStyle(Theme.navy)
        }
    }
}

#Preview("What you can say") {
    VoiceGuideView()
}
