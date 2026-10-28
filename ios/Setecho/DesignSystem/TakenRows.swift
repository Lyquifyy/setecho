import SwiftUI

/// In the HUD when a machine's taken (DESIGN.md, `TakenCard`): what's taken, up to two options in
/// his order with the first marked as his, and what to say.
struct TakenCard: View {
    let what: String
    let options: [String]

    var body: some View {
        VStack(spacing: Theme.Space.xxs) {
            Text("\(what) taken").font(.hudState).foregroundStyle(Theme.navy)
            ForEach(Array(options.prefix(2).enumerated()), id: \.offset) { index, option in
                Text(index == 0 ? "His first choice: \(option)" : "Or: \(option)").font(.hudLabel).foregroundStyle(Theme.navy)
            }
            Text(options.count > 1 ? "Say 'go with it', 'the other one' or 'I'll wait'" : "Say 'go with it' or 'I'll wait'")
                .font(.hudLabel).secondaryText()
        }
        .multilineTextAlignment(.center)
        .accessibilityElement(children: .combine)
    }
}

/// One gym change on Review and send (DESIGN.md, `DeviationRow`): planned → done, the reason and
/// the day, and a checkbox for whether it goes in his notes.
struct DeviationRow: View {
    let planned: String
    let done: String?
    let detail: String
    let included: Bool
    let onToggle: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Space.s) {
            VStack(alignment: .leading, spacing: Theme.Space.xxs) {
                Text(done.map { "\(planned) → \($0)" } ?? "\(planned) skipped").font(.subheadline).foregroundStyle(Theme.navy)
                Text(detail).font(.footnote).secondaryText()
            }
            Spacer(minLength: Theme.Space.xs)
            Checkbox(isOn: included, action: onToggle)
                .accessibilityLabel("\(planned), \(included ? "in the notes" : "left out")")
        }
    }
}

#Preview {
    VStack(spacing: Theme.Space.l) {
        TakenCard(what: "Smith", options: ["Incline dumbbell press", "Incline barbell press"])
        DeviationRow(planned: "Smith close-grip press", done: "Close-grip bench press", detail: "Smith taken · Tue", included: true) {}
    }
    .padding(Theme.gutter)
    .background(Theme.page)
}
