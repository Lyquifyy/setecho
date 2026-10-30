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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ViewThatFits(in: .horizontal) {
            tabRow
            ScrollView(.horizontal, showsIndicators: false) { tabRow.fixedSize(horizontal: true, vertical: false) }
        }
        .sensoryFeedback(.selection, trigger: selection)
    }

    private var tabRow: some View {
        HStack(spacing: Theme.Space.xxs) {
            ForEach(items, id: \.value) { item in
                let selected = item.value == selection
                Button {
                    withAnimation(reduceMotion ? nil : Theme.Motion.change) { selection = item.value }
                } label: {
                    HStack(spacing: 6) {
                        Text(item.title).lineLimit(1).fixedSize(horizontal: true, vertical: false)
                        if let badge = item.badge, badge > 0 {
                            Text("\(badge)")
                                .font(.caption.weight(.bold)).monospacedDigit()
                                .lineLimit(1).fixedSize()
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
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(Theme.cobalt)
                }
                Text(title).font(.sectionTitle).foregroundStyle(Theme.navy)
                content
                Spacer(minLength: 0)
            }
            .padding(Theme.cardPadding)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .setechoSurface()
            .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        }
        .buttonStyle(QuietPressStyle())
    }
}

/// How far along something is ("3 of 7 ready", or a fraction of a job): a thin cobalt bar on the
/// field fill, which moves smoothly as the value changes.
struct MeterBar: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let fraction: Double
    let label: String

    init(value: Int, total: Int) {
        fraction = total > 0 ? Double(min(value, total)) / Double(total) : 0
        label = "\(value) of \(total)"
    }

    /// 0…1 of a job under way (a video export).
    init(fraction: Double) {
        self.fraction = min(max(fraction, 0), 1)
        label = "\(Int((self.fraction * 100).rounded())) percent"
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.fieldFill)
                Capsule().fill(Theme.cobalt)
                    .frame(width: geometry.size.width * CGFloat(fraction))
                    .animation(reduceMotion ? nil : Theme.Motion.change, value: fraction)
            }
        }
        .frame(height: 6)
        .accessibilityElement()
        .accessibilityLabel(label)
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
