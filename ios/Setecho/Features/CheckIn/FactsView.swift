import SwiftUI

/// Facts (debug, HANDOFF.md §9, block 1): every data field for the period with the raw values
/// behind it: each weigh-in, each day's macros, steps, sleep and cardio, and which app wrote them.
struct FactsView: View {
    @Environment(\.dismiss) private var dismiss
    let facts: WeekFacts?
    let draft: CheckInDraft?
    let template: CheckInTemplate?

    var body: some View {
        ScreenScaffold {
            LinkButton(title: "Back", chevron: .leading) { dismiss() }
            TitleBlock(eyebrow: "Debug", title: "Facts", subtitle: "What the check-in was built from. Numbers only, from Apple Health and the log.")
            if let facts {
                SectionCard("Period · \(facts.weekStart) to \(facts.weekEnd)") {
                    LabeledValue("Training target", "\(Format.number(facts.targets.training.kcal)) kcal · \(Format.number(facts.targets.training.proteinG))P \(Format.number(facts.targets.training.carbsG))C \(Format.number(facts.targets.training.fatG))F")
                    CardDivider()
                    LabeledValue("Rest target", "\(Format.number(facts.targets.rest.kcal)) kcal · \(Format.number(facts.targets.rest.proteinG))P \(Format.number(facts.targets.rest.carbsG))C \(Format.number(facts.targets.rest.fatG))F")
                    CardDivider()
                    LabeledValue("Last check-in weight", facts.lastCheckInWeightLb.map(Format.number) ?? "—")
                    CardDivider()
                    LabeledValue("Cardio protocol", facts.cardioProtocol ?? "—")
                    CardDivider()
                    LabeledValue("Sources", facts.sources.map { "\($0.key): \($0.value)" }.sorted().joined(separator: ", "))
                }
                ForEach(facts.daily, id: \.date) { day in
                    SectionCard("\(day.date) · \(day.isTrainingDay ? "training" : "rest")") {
                        LabeledValue("Weigh-in", day.weighInLb.map { "\(Format.number($0)) lb" } ?? "—")
                        CardDivider()
                        LabeledValue("Macros", day.kcal.map { "\(Format.number($0)) kcal · \(day.proteinG.map(Format.number) ?? "–")P \(day.carbsG.map(Format.number) ?? "–")C \(day.fatG.map(Format.number) ?? "–")F" } ?? "—")
                        CardDivider()
                        LabeledValue("Steps", day.steps.map(Format.number) ?? "—")
                        CardDivider()
                        LabeledValue("Sleep", day.sleepHours.map { "\(Format.number($0)) h" } ?? "—")
                        CardDivider()
                        LabeledValue("Cardio", day.liss.isEmpty ? "—" : day.liss.map { "\($0.type) \($0.minutes) min" }.joined(separator: ", "))
                    }
                }
            } else {
                SectionCard { Text("No facts yet. Open the check-in once to build them.").font(.subheadline).secondaryText() }
            }
            if let draft, let template {
                SectionCard("Fields") {
                    ForEach(Array(template.orderedFields.enumerated()), id: \.element.id) { index, field in
                        if index > 0 { CardDivider() }
                        let answer = draft.answers.first { $0.fieldId == field.id }
                        VStack(alignment: .leading, spacing: Theme.Space.xxs) {
                            Text(field.label).font(.subheadline.weight(.semibold)).foregroundStyle(Theme.navy)
                            Text("\(answer?.state.rawValue ?? "missing") · \(answer?.text ?? "")").font(.footnote).monospacedDigit().secondaryText()
                            ForEach(Array((answer?.provenance ?? []).enumerated()), id: \.offset) { _, p in
                                Text("\(p.source): \(p.detail)").font(.footnote).secondaryText()
                            }
                        }
                    }
                }
            }
        }
    }
}
