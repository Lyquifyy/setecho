import SwiftUI

/// Tabs inside a screen ("Sessions · Check-ins · Photos · Plan"): a pill track with the selected tab in cobalt.
/// A badge counts what's in a tab; `highlight` puts it on yellow when that count is waiting on the athlete.
struct SegmentTabs<Value: Hashable>: View {
    struct Item {
        let value: Value
        let title: String
        var badge: Int?
        var highlight = false
    }

    let items: [Item]
    @Binding var selection: Value
    @Namespace private var namespace

    var body: some View {
        HStack(spacing: Theme.Space.xxs) {
            ForEach(items, id: \.value) { item in
                let selected = item.value == selection
                Button {
                    withAnimation(.snappy(duration: 0.25)) { selection = item.value }
                } label: {
                    HStack(spacing: 6) {
                        Text(item.title).lineLimit(1).minimumScaleFactor(0.8)
                        if let badge = item.badge, badge > 0 {
                            Text("\(badge)")
                                .font(.caption.weight(.bold)).monospacedDigit()
                                .foregroundStyle(Theme.navy)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(item.highlight ? Theme.yellow : Theme.surface, in: Capsule())
                        }
                    }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(selected ? Theme.surface : Theme.navy)
                    .padding(.horizontal, Theme.Space.xs)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .background {
                        if selected {
                            RoundedRectangle(cornerRadius: Theme.Radius.tag + 2, style: .continuous)
                                .fill(Theme.cobalt)
                                .matchedGeometryEffect(id: "selected", in: namespace)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(item.badge.map { "\(item.title), \($0)" } ?? item.title)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(Theme.Space.xxs)
        .background(Theme.fieldFill, in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
    }
}

/// A half-width card that is one tappable thing: an icon and title, a glance of its state, and a chevron.
/// Two sit side by side for things checked at a glance (Today's check-in and photos). Never nest one in a card.
struct TileCard<Content: View>: View {
    let title: String
    let systemImage: String
    let action: () -> Void
    @ViewBuilder let content: Content

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                HStack(spacing: Theme.Space.xs) {
                    Image(systemName: systemImage)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.cobalt)
                        .frame(width: 30, height: 30)
                        .background(Theme.cobaltTint, in: RoundedRectangle(cornerRadius: Theme.Radius.tag, style: .continuous))
                    Text(title).font(.sectionTitle).foregroundStyle(Theme.navy).lineLimit(1)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(Theme.cobalt)
                }
                content
                Spacer(minLength: 0)
            }
            .padding(Theme.cardPadding)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                    .strokeBorder(Theme.border, lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

/// How far along something is ("3 of 7 ready"): a thin cobalt bar on the field fill.
struct MeterBar: View {
    let value: Int
    let total: Int

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.fieldFill)
                Capsule().fill(Theme.cobalt)
                    .frame(width: total > 0 ? geometry.size.width * CGFloat(min(value, total)) / CGFloat(total) : 0)
            }
        }
        .frame(height: 6)
        .accessibilityElement()
        .accessibilityLabel("\(value) of \(total)")
    }
}

/// The chevron on a row that opens and closes: down when closed, up when open.
struct DisclosureChevron: View {
    let expanded: Bool

    var body: some View {
        Image(systemName: "chevron.down")
            .font(.footnote.weight(.semibold))
            .foregroundStyle(Theme.cobalt)
            .rotationEffect(.degrees(expanded ? 180 : 0))
            .frame(width: 24, height: 24)
            .accessibilityHidden(true)
    }
}

#Preview {
    @Previewable @State var tab = 0
    VStack(spacing: Theme.gutter) {
        SegmentTabs(items: [.init(value: 0, title: "All"), .init(value: 1, title: "To answer", badge: 4, highlight: true),
                            .init(value: 2, title: "Ready", badge: 3)], selection: $tab)
        HStack(spacing: Theme.gutter) {
            TileCard(title: "Check-in", systemImage: "checklist", action: {}) {
                Text("3 of 7 ready").font(.subheadline).foregroundStyle(Theme.navy)
                MeterBar(value: 3, total: 7)
            }
            TileCard(title: "Photos", systemImage: "camera", action: {}) {
                Text("Next Thu").font(.subheadline).secondaryText()
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        HStack {
            Button("Open check-in", systemImage: "checklist") {}.buttonStyle(.setechoTonal)
            IconButton(systemImage: "arrow.clockwise", accessibilityLabel: "Refresh") {}
        }
    }
    .padding(Theme.gutter)
    .background(Theme.page)
}
