import SwiftUI

/// The one-time question on the rules review (HANDOFF.md §7, Machine taken): "When a machine's
/// taken, what does your coach want?" He puts the options in his coach's order and confirms it's
/// what his coach wants. Until then a taken machine gets only Wait, plus whatever he names himself.
/// Moving a later lift up waits for the exercise tags; waiting is always the last choice.
struct TakenRuleCard: View {
    @Environment(Store.self) private var store
    @State private var rule = TakenRule.suggested

    var body: some View {
        SectionCard("When a machine's taken", accessory: { if !rule.confirmed { TargetTag(text: "Confirm") } }) {
            Text("What does your coach want? Put his choices in his order; waiting is always last. Setecho offers them in that order and tells him each swap in the check-in.")
                .font(.footnote).secondaryText()
            ForEach(Array(rule.order.enumerated()), id: \.element) { index, option in
                CardDivider()
                HStack(spacing: Theme.Space.s) {
                    Text("\(index + 1). \(option.label)").font(.body).monospacedDigit().foregroundStyle(Theme.navy)
                    Spacer()
                    if index > 0 { LinkButton(title: "Move up", chevron: .none) { moveUp(index) } }
                }
            }
            CardDivider()
            Text("\(rule.order.count + 1). Wait for it").font(.body).monospacedDigit().secondaryText()
            CardDivider()
            RuleRow(text: rule.confirmed ? "That's his order" : "Is this what he wants?", quote: nil, confirmed: rule.confirmed) {
                rule.confirmed.toggle()
                store.setTakenRule(rule)
            }
        }
        .onAppear { rule = store.plan?.takenRule ?? .suggested }
    }

    private func moveUp(_ index: Int) {
        rule.order.swapAt(index, index - 1)
        rule.confirmed = false // a new order is confirmed again
        store.setTakenRule(rule)
    }
}
