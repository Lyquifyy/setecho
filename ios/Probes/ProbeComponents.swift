import SwiftUI

/// Label on the left, value on the right, inside a card.
struct LabeledRow: View {
    let label: String
    let value: String

    init(_ label: String, _ value: String) {
        self.label = label
        self.value = value
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
            Text(label).font(.subheadline).secondaryText()
            Spacer(minLength: Theme.Space.xs)
            Text(value)
                .font(.subheadline)
                .monospacedDigit()
                .foregroundStyle(Theme.navy)
                .multilineTextAlignment(.trailing)
        }
        .frame(minHeight: 28)
    }
}

/// What the human checks by hand for this gate.
struct PassChecksCard: View {
    let items: [String]

    var body: some View {
        SectionCard("Pass checks") {
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                if index > 0 { CardDivider() }
                HStack(alignment: .firstTextBaseline, spacing: Theme.Space.xs) {
                    Image(systemName: "checkmark.circle")
                        .font(.subheadline)
                        .foregroundStyle(Theme.cobalt)
                        .accessibilityHidden(true)
                    Text(item).font(.subheadline).foregroundStyle(Theme.navy)
                }
            }
        }
    }
}

/// Newest line first, so the latest status is at the top of the card.
struct ProbeLog: View {
    let lines: [String]

    var body: some View {
        SectionCard("Log", accessory: { Text("\(lines.count)").font(.subheadline).monospacedDigit().secondaryText() }) {
            if lines.isEmpty {
                Text("Nothing yet.").font(.footnote).secondaryText()
            } else {
                ForEach(Array(lines.reversed().enumerated()), id: \.offset) { index, line in
                    if index > 0 { CardDivider() }
                    Text(line)
                        .font(.footnote)
                        .monospacedDigit()
                        .foregroundStyle(index == 0 ? Theme.navy : Theme.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }
}

extension Date {
    /// "20:14:05" for the probe logs.
    var probeStamp: String {
        formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).second(.twoDigits))
    }
}
