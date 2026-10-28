import SwiftUI

/// One coach's rule in plain words, its source (his quote, or "you confirmed"), and a yellow
/// "Confirm" tag until confirmed (DESIGN.md Components, `RuleRow`). Tapping confirms.
struct RuleRow: View {
    let text: String
    let quote: String?
    let confirmed: Bool
    let onConfirm: () -> Void

    var body: some View {
        Button(action: onConfirm) {
            HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
                VStack(alignment: .leading, spacing: Theme.Space.xxs) {
                    Text(text).font(.body).foregroundStyle(Theme.navy).multilineTextAlignment(.leading)
                    Text(confirmed ? (quote.map { "“\($0)”" } ?? "You confirmed") : (quote.map { "“\($0)”" } ?? "Not in his words"))
                        .font(.footnote).secondaryText().multilineTextAlignment(.leading)
                }
                Spacer(minLength: Theme.Space.xs)
                if confirmed {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.cobalt).accessibilityLabel("Confirmed")
                } else {
                    TargetTag(text: "Confirm")
                }
            }
            .padding(.vertical, Theme.Space.xxs)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint(confirmed ? "" : "Confirms this is what your coach wants")
    }
}

/// On Import: an add-on's name, his words, "2× a week", and the cycle days it joins as chips
/// (cobalt when chosen) (DESIGN.md Components, `AddOnRow`).
struct AddOnRow: View {
    let addOn: AddOn
    let days: [ProgramDay]
    @Binding var chosen: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            HStack(alignment: .firstTextBaseline) {
                Text(addOn.name).font(.body.weight(.semibold)).foregroundStyle(Theme.navy)
                Spacer()
                Text("\(addOn.perWeek)× a week · \(addOn.timing == .onWaking ? "on waking" : "with the session")")
                    .font(.subheadline).monospacedDigit().secondaryText()
            }
            Text("“\(addOn.quote)”").font(.footnote).secondaryText()
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Theme.Space.xs) {
                    ForEach(days) { day in
                        let on = chosen.contains(day.id)
                        Button(day.name) {
                            if on { chosen.removeAll { $0 == day.id } } else { chosen.append(day.id) }
                        }
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(on ? Theme.surface : Theme.cobalt)
                        .padding(.horizontal, Theme.Space.s)
                        .frame(minHeight: 44)
                        .background(on ? Theme.cobalt : Theme.surface, in: Capsule())
                        .overlay(Capsule().strokeBorder(Theme.cobalt, lineWidth: 1))
                        .accessibilityLabel("\(day.name)\(on ? ", chosen" : "")")
                    }
                }
            }
        }
        .padding(.vertical, Theme.Space.xxs)
    }
}

#Preview {
    let day = ProgramDay(id: "d1", name: "Day 1", exercises: [])
    VStack {
        SectionCard("His rules") {
            RuleRow(text: "Back-off sets 20–25% lighter than the top set", quote: "Back down sets are 20-25% lighter than your top set.", confirmed: false) {}
            CardDivider()
            RuleRow(text: "Top sets to failure", quote: "every working set goes to muscle failure", confirmed: true) {}
        }
        SectionCard("Add-ons") {
            AddOnRow(addOn: AddOn(id: "abs", name: "Abs", exercises: [], perWeek: 2, timing: .withSession, quote: "Complete this 2x per week:"),
                     days: [day, ProgramDay(id: "d2", name: "Day 2", exercises: [])], chosen: .constant(["d2"]))
        }
    }
    .padding(Theme.gutter)
    .background(Theme.page)
}

/// One exercise of today's session as a single line ("Bench press · 4 × 8") that opens to the sheet's details:
/// load and intensity, equipment and rest, his "or" options and notes. Keeps a long day readable without scrolling.
struct ExerciseDisclosureRow: View {
    let number: Int
    let exercise: PlannedExercise
    let expanded: Bool
    let onToggle: () -> Void

    var body: some View {
        Button(action: onToggle) {
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                HStack(alignment: .center, spacing: Theme.Space.s) {
                    Text("\(number)")
                        .font(.footnote.weight(.semibold)).monospacedDigit()
                        .secondaryText()
                        .frame(width: 18, alignment: .leading)
                    Text(exercise.name)
                        .font(.body.weight(.semibold)).foregroundStyle(Theme.navy)
                        .multilineTextAlignment(.leading)
                    Spacer(minLength: Theme.Space.xs)
                    Text(exercise.setsText).font(.subheadline.weight(.medium)).monospacedDigit().foregroundStyle(Theme.navy)
                    DisclosureChevron(expanded: expanded)
                }
                if expanded {
                    VStack(alignment: .leading, spacing: Theme.Space.xxs) {
                        if !exercise.summaryDetails.isEmpty {
                            Text(exercise.summaryDetails.joined(separator: " · "))
                                .font(.subheadline).monospacedDigit().foregroundStyle(Theme.navy)
                        }
                        Text([exercise.equipment.label, exercise.restText].compactMap { $0 }.joined(separator: " · "))
                            .font(.footnote).monospacedDigit().secondaryText()
                        ForEach(exercise.alternates, id: \.name) { alternate in
                            Text("or \(alternate.name) · “\(alternate.quote)”").font(.footnote).secondaryText()
                        }
                        if let notes = exercise.notes, !notes.isEmpty {
                            Text(notes).font(.footnote).secondaryText()
                        }
                    }
                    .padding(.leading, 18 + Theme.Space.s)
                    .multilineTextAlignment(.leading)
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(exercise.name), \(exercise.summary)")
        .accessibilityHint(expanded ? "Hides the details" : "Shows the details")
    }
}
