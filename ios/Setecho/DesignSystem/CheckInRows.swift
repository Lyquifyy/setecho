import SwiftUI

/// Small cobalt-tint capsule naming where an answer came from: "Withings", "Training log", "You said · Wed".
struct SourceChip: View {
    let source: String

    var body: some View {
        Text(source)
            .font(.caption.weight(.semibold))
            .foregroundStyle(Theme.cobalt)
            .lineLimit(1)
            .padding(.horizontal, Theme.Space.xs)
            .padding(.vertical, Theme.Space.xxs)
            .background(Theme.cobaltTint, in: Capsule())
            .accessibilityLabel("Source: \(source)")
    }
}

/// One check-in field: the coach's label, the answer, its source, and its state.
/// Filled shows the chip; drafted adds a yellow "Confirm"; missing shows "Ask in wrap-up".
struct FieldRow: View {
    let field: FieldSpec
    let answer: FieldAnswer?

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Space.s) {
            VStack(alignment: .leading, spacing: Theme.Space.xxs) {
                Text(field.label).font(.subheadline).secondaryText()
                if let answer, !answer.text.isEmpty {
                    Text(answer.text).font(.body).monospacedDigit().foregroundStyle(Theme.navy)
                } else {
                    Text(field.source.type == .photo ? "From the photo session" : "Not answered yet")
                        .font(.body).secondaryText()
                }
                HStack(spacing: Theme.Space.xs) {
                    if let source = answer?.provenance.first?.source ?? field.source.sourceName {
                        SourceChip(source: source)
                    }
                    if answer?.provenance.contains(where: { $0.source == "Check this" }) == true {
                        SourceChip(source: "Check this")
                    }
                }
            }
            Spacer(minLength: Theme.Space.xs)
            stateTag
        }
        .padding(.vertical, Theme.Space.xxs)
        .contentShape(Rectangle())
    }

    @ViewBuilder private var stateTag: some View {
        switch answer?.state {
        case .drafted:
            TargetTag(text: "Confirm")
        case .missing, nil:
            if field.source.type != .photo {
                Text("Ask in wrap-up").font(.caption.weight(.semibold)).secondaryText()
            }
        case .filled, .confirmed:
            EmptyView()
        }
    }
}

#Preview {
    let field = FieldSpec(id: "current_body_weight", label: "Current Body Weight", prompt: nil, kind: .measurement,
                          source: FieldSource(type: .data, key: .currentWeight), order: 0)
    VStack(spacing: Theme.gutter) {
        SectionCard("Fields") {
            FieldRow(field: field, answer: FieldAnswer(fieldId: "current_body_weight", text: "180.8", state: .filled,
                                                        provenance: [Provenance(source: "Withings via Apple Health", detail: "")]))
            CardDivider()
            FieldRow(field: field, answer: FieldAnswer(fieldId: "x", text: "Avg 7.4 h/night", state: .drafted,
                                                        provenance: [Provenance(source: "Garmin via Apple Health", detail: "")]))
            CardDivider()
            FieldRow(field: field, answer: nil)
        }
    }
    .padding(Theme.gutter)
    .background(Theme.page)
}
