import Foundation

/// The only place numbers become strings. Loads are in pounds.
enum Format {
    /// 220 -> "220", 222.5 -> "222.5"
    static func number(_ value: Double) -> String {
        value.rounded() == value ? String(Int(value)) : String(format: "%.1f", value)
    }

    /// 220 -> "220 lb"
    static func load(_ lb: Double) -> String { "\(number(lb)) lb" }

    /// 31.2 -> "31%"
    static func percent(_ value: Double) -> String { "\(Int(value.rounded()))%" }

    /// 29 -> "0:29", 78 -> "1:18"
    static func duration(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds.rounded()))
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    /// Recording timer: 18 -> "00:18"
    static func timer(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds))
        return String(format: "%02d:%02d", s / 60, s % 60)
    }

    /// "Oct 19"
    static func shortDate(_ date: Date) -> String {
        date.formatted(.dateTime.month(.abbreviated).day())
    }

    /// History date column: ("19", "OCT")
    static func dayAndMonth(_ date: Date) -> (day: String, month: String) {
        (date.formatted(.dateTime.day()), date.formatted(.dateTime.month(.abbreviated)).uppercased())
    }
}
