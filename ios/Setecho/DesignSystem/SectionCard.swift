import SwiftUI

/// One white card per semantic group, with its title inside.
///
/// Never nest a SectionCard in another, and never use one per metric: related rows go in the same card,
/// separated by `CardDivider`.
struct SectionCard<Content: View, Accessory: View>: View {
    private let title: String?
    private let accessory: Accessory
    private let content: Content

    init(_ title: String? = nil, @ViewBuilder accessory: () -> Accessory, @ViewBuilder content: () -> Content) {
        self.title = title
        self.accessory = accessory()
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            if title != nil {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .firstTextBaseline) {
                        heading
                        Spacer(minLength: Theme.Space.xs)
                        accessory
                    }
                    VStack(alignment: .leading, spacing: Theme.Space.xs) {
                        heading
                        accessory
                    }
                }
            }
            content
        }
        .padding(Theme.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .setechoSurface()
    }

    private var heading: some View {
        Text(title ?? "")
            .font(.sectionTitle)
            .foregroundStyle(Theme.navy)
            .accessibilityAddTraits(.isHeader)
    }
}

extension SectionCard where Accessory == EmptyView {
    init(_ title: String? = nil, @ViewBuilder content: () -> Content) {
        self.init(title, accessory: { EmptyView() }, content: content)
    }
}

/// Hairline divider between rows inside a card.
struct CardDivider: View {
    @Environment(\.displayScale) private var scale
    var body: some View {
        Rectangle().fill(Theme.border).frame(height: 1 / scale)
    }
}

/// Vertical hairline, e.g. between "225 lb" and "8 reps".
struct VerticalCardDivider: View {
    @Environment(\.displayScale) private var scale
    var body: some View {
        Rectangle().fill(Theme.border).frame(width: 1 / scale)
    }
}

#Preview {
    ScrollView {
        VStack(spacing: Theme.gutter) {
            SectionCard("Next set") {
                Text("220 lb × 8").font(.metricXL)
            }
            SectionCard("Completed sets", accessory: { Text("3").secondaryText() }) {
                Text("Row one")
                CardDivider()
                Text("Row two")
            }
        }
        .padding(Theme.gutter)
    }
    .background(Theme.page)
}


/// One clean loading state wherever data is being read (DESIGN.md Today, Loading): a card with
/// the cobalt spinner and a short line saying what is happening. Never a bare spinner.
struct LoadingCard: View {
    let title: String
    var detail: String?

    var body: some View {
        SectionCard { LoadingRow(title: title, detail: detail) }
    }
}

/// The same line inside a card that already exists: cards never nest (DESIGN.md rule 5).
struct LoadingRow: View {
    let title: String
    var detail: String?

    var body: some View {
        HStack(spacing: Theme.Space.m) {
            ProgressView().tint(Theme.cobalt).controlSize(.large)
            VStack(alignment: .leading, spacing: Theme.Space.xxs) {
                Text(title).font(.body.weight(.semibold)).foregroundStyle(Theme.navy)
                if let detail { Text(detail).font(.subheadline).secondaryText() }
            }
            Spacer()
        }
        .frame(minHeight: 56)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title). \(detail ?? "")")
    }
}
