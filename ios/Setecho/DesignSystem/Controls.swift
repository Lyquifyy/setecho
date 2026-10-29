import SwiftUI

// MARK: - Buttons

/// Full-width cobalt action. One per screen, in the footer.
struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .labelStyle(.titleAndIcon)
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, minHeight: 52)
            .background(
                configuration.isPressed ? Theme.cobaltPressed : Theme.cobalt,
                in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
            )
            .opacity(isEnabled ? 1 : 0.45)
            .contentShape(Rectangle())
    }
}

/// Quiet secondary action inside a card ("Edit load").
struct OutlineButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(Theme.cobalt)
            .padding(.horizontal, 14)
            .frame(minHeight: 44)
            .background(
                configuration.isPressed ? Theme.cobaltTint : Theme.surface,
                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
            )
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.cobalt, lineWidth: 1))
    }
}

/// The in-card action: a cobalt-tint button with an optional icon ("Open check-in", "Take photos").
/// Use it where a card offers something to do, so the action reads as a button rather than a line of text.
struct TonalButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    var fullWidth = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .labelStyle(.titleAndIcon)
            .foregroundStyle(Theme.cobalt)
            .lineLimit(1)
            // Two wide ones share a row with an icon button (Today): shrink a little, never truncate.
            .minimumScaleFactor(0.85)
            .padding(.horizontal, Theme.Space.s)
            .frame(maxWidth: fullWidth ? .infinity : nil, minHeight: 44)
            .background(
                configuration.isPressed ? Theme.cobaltPressedTint : Theme.cobaltTint,
                in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
            )
            .opacity(isEnabled ? 1 : 0.45)
            .contentShape(Rectangle())
    }
}

extension ButtonStyle where Self == TonalButtonStyle {
    static var setechoTonal: TonalButtonStyle { TonalButtonStyle() }
    static var setechoTonalWide: TonalButtonStyle { TonalButtonStyle(fullWidth: true) }
}

/// A 44 pt round icon button for secondary card actions ("Refresh"). Always pass an accessibility label.
struct IconButton: View {
    let systemImage: String
    let accessibilityLabel: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.cobalt)
                .frame(width: 44, height: 44)
                .background(Theme.cobaltTint, in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
    }
}

extension ButtonStyle where Self == PrimaryButtonStyle {
    static var setechoPrimary: PrimaryButtonStyle { PrimaryButtonStyle() }
}

extension ButtonStyle where Self == OutlineButtonStyle {
    static var setechoOutline: OutlineButtonStyle { OutlineButtonStyle() }
}

/// Cobalt text link with an optional chevron: "Why this load? ›", "View set details ›", "‹ Back to workout".
struct LinkButton: View {
    enum Chevron { case none, trailing, leading }

    let title: String
    var chevron: Chevron = .trailing
    var underline = false
    /// At hands-free size (`.hudLabel`), for the links a hands-free screen offers once it's done.
    var hud = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if chevron == .leading {
                    Image(systemName: "chevron.left").font(.footnote.weight(.semibold))
                }
                Text(title).underline(underline)
                if chevron == .trailing {
                    Image(systemName: "chevron.right").font(.footnote.weight(.semibold))
                }
            }
            .font(hud ? .hudLabel.weight(.medium) : .subheadline.weight(.medium))
            .lineLimit(1)
            .minimumScaleFactor(hud ? 0.8 : 1)
            .foregroundStyle(Theme.cobalt)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Small play control for a set's video. 44 pt hit target around a 34 pt disc.
struct PlayButton: View {
    let accessibilityLabel: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "play.fill")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(Theme.cobalt)
                .frame(width: 34, height: 34)
                .background(Theme.cobaltTint, in: Circle())
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
    }
}

// MARK: - Tag

/// Yellow marker for the next target only ("Next set", "Set 4 of 4").
struct TargetTag: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(Theme.navy)
            .multilineTextAlignment(.center)
            .fixedSize()
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Theme.yellow, in: RoundedRectangle(cornerRadius: Theme.Radius.tag, style: .continuous))
    }
}

// MARK: - Metrics

/// "220 lb × 8" with tabular digits and smaller units.
struct LoadRepsText: View {
    enum Size { case xl, l }

    let loadLb: Double
    let reps: Int
    var size: Size = .xl

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(Format.number(loadLb)).font(number)
                Text("lb").font(unit)
            }
            Text("×").font(unit).foregroundStyle(Theme.textSecondary)
            Text("\(reps)").font(number)
        }
        .foregroundStyle(Theme.navy)
        .lineLimit(1)
        .minimumScaleFactor(0.7)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(Format.number(loadLb)) pounds for \(reps) reps")
    }

    private var number: Font { size == .xl ? .metricXL : .metricL }
    private var unit: Font { size == .xl ? .metricUnitXL : .metricUnitL }
}

/// A single big number with a unit, e.g. "225 lb" or "8 reps".
struct MetricText: View {
    let value: String
    let unit: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(value).font(.metricXL)
            Text(unit).font(.metricUnitXL)
        }
        .foregroundStyle(Theme.navy)
        .lineLimit(1)
        .minimumScaleFactor(0.7)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Video thumbnail

/// Placeholder for a set's video frame. Swap the fill for an AVAssetImageGenerator thumbnail when real clips exist.
struct SetThumbnail: View {
    var width: CGFloat = 120
    var height: CGFloat = 72

    var body: some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(Theme.cameraFill)
            .frame(width: width, height: height)
            .overlay {
                Image(systemName: "play.fill")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Theme.navy)
                    .frame(width: 32, height: 32)
                    .background(.white, in: Circle())
            }
            .accessibilityHidden(true)
    }
}
