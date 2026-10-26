import SwiftUI

/// Iron and chalk, one signal color. Orange is reserved for the bar path, actions and warnings.
enum Theme {
    static let iron = Color(red: 0x11 / 255, green: 0x13 / 255, blue: 0x12 / 255)
    static let ironRaised = Color(red: 0x1B / 255, green: 0x1E / 255, blue: 0x1D / 255)
    static let line = Color(red: 0x2C / 255, green: 0x30 / 255, blue: 0x2E / 255)
    static let chalk = Color(red: 0xF3 / 255, green: 0xF1 / 255, blue: 0xEA / 255)
    static let chalkMuted = Color(red: 0xA7 / 255, green: 0xAA / 255, blue: 0xA4 / 255)
    static let signal = Color(red: 0xFF / 255, green: 0x6A / 255, blue: 0x2B / 255)
}
