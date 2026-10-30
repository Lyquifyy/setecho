import SwiftUI

/// Shared surface treatment; dividers belong between rows, not under every heading.
private struct CardSurface: ViewModifier {
    @Environment(\.colorSchemeContrast) private var contrast
    func body(content: Content) -> some View {
        content
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.card))
            .overlay {
                RoundedRectangle(cornerRadius: Theme.Radius.card)
                    .strokeBorder(contrast == .increased ? Theme.border : Theme.Surface.stroke, lineWidth: 1)
            }
            .shadow(color: Theme.Surface.shadow, radius: Theme.Surface.shadowRadius, y: Theme.Surface.shadowY)
    }
}

extension View {
    func setechoSurface() -> some View { modifier(CardSurface()) }
}

/// Small, interruptible touch feedback. Reduced motion keeps the color feedback alone.
struct QuietPressStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.8 : 1)
            .scaleEffect(configuration.isPressed && !reduceMotion ? Theme.Control.pressedScale : 1)
            .animation(reduceMotion ? nil : Theme.Motion.press, value: configuration.isPressed)
    }
}

/// Useful empty states explain what will appear and how to get there.
struct EmptyState: View {
    let symbol: String
    let title: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            Image(systemName: symbol)
                .font(.title2.weight(.medium))
                .foregroundStyle(Theme.textSecondary)
                .padding(.bottom, Theme.Space.xxs)
                .accessibilityHidden(true)
            Text(title).font(.title3.weight(.semibold)).foregroundStyle(Theme.navy)
            Text(detail).font(.subheadline).secondaryText().fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, Theme.Space.s)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A setup sequence, with completed steps named as well as colored.
struct SetupProgress: View {
    let current: Int
    private let labels = ["Program", "Check-in", "Rules"]
    var body: some View {
        HStack(spacing: Theme.Space.xs) {
            ForEach(Array(labels.enumerated()), id: \.element) { index, label in
                VStack(alignment: .leading, spacing: Theme.Space.xs) {
                    Capsule().fill(index + 1 <= current ? Theme.cobalt : Theme.border).frame(height: 4)
                    Label(label, systemImage: index + 1 < current ? "checkmark.circle.fill" : "circle")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(index + 1 == current ? Theme.cobalt : Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityLabel("\(labels[index]), \(index + 1 < current ? "complete" : index + 1 == current ? "current step" : "upcoming")")
            }
        }
        .padding(.bottom, Theme.Space.xs)
    }
}
