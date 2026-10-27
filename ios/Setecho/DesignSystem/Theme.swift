import SwiftUI

/// Setecho design tokens. Source of truth: design/cobalt-cards/design-tokens.json and DESIGN.md.
///
/// Rules:
/// - Cobalt marks actions, active controls and data sources. Nothing decorative is cobalt.
/// - Yellow marks only the one next thing waiting on the athlete (next set, selected plate, a field to confirm).
///   It is always a fill behind navy text, never text.
/// - Navy is the reading color. Secondary text uses `textSecondary`, never opacity on navy.
enum Theme {
    // MARK: Palette
    static let cobalt = Color(hex: 0x2541D8)
    static let cobaltPressed = Color(hex: 0x1A2FA0)
    /// Light cobalt fill for play buttons and the user's chat bubble.
    static let cobaltTint = Color(hex: 0xE6ECFD)
    static let page = Color(hex: 0xEEF2F9)
    static let surface = Color.white
    static let nearWhite = Color(hex: 0xFAFCFF)
    static let navy = Color(hex: 0x171D36)
    /// 7.3:1 on white. Use for labels, metadata and placeholders.
    static let textSecondary = Color(hex: 0x4C5573)
    static let yellow = Color(hex: 0xF0CD50)
    static let border = Color(hex: 0xD1D9EC)
    static let fieldFill = Color(hex: 0xE4E9F4)
    static let recording = Color(hex: 0xE5484D)
    static let cameraFill = Color(hex: 0x10142A)

    // MARK: Spacing (pt)
    enum Space {
        static let xxs: CGFloat = 4
        static let xs: CGFloat = 8
        static let s: CGFloat = 12
        static let m: CGFloat = 16
        static let l: CGFloat = 24
        static let xl: CGFloat = 32
    }

    // MARK: Corner radii (pt)
    enum Radius {
        static let card: CGFloat = 16
        static let control: CGFloat = 12
        static let tag: CGFloat = 8
        static let bubble: CGFloat = 14
    }

    /// Internal padding of a section card: 16 pt top, 18 pt sides and bottom.
    static let cardPadding = EdgeInsets(top: 16, leading: 18, bottom: 18, trailing: 18)
    /// Gap between cards and the page's side gutter.
    static let gutter: CGFloat = 16
}

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: opacity
        )
    }
}
