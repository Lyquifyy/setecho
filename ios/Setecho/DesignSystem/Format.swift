import Foundation

/// The only place numbers become strings. Loads are in pounds.
enum Format {
    /// "09:00" (as the schedule stores it) -> "9:00 AM", in the phone's own clock style.
    static func clock(_ hhmm: String) -> String {
        let parts = hhmm.split(separator: ":").compactMap { Int($0) }
        guard let hour = parts.first,
              let date = Calendar.current.date(bySettingHour: hour, minute: parts.count > 1 ? parts[1] : 0, second: 0, of: .now)
        else { return hhmm }
        return date.formatted(date: .omitted, time: .shortened)
    }

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

    /// Storage on the phone: 0 -> "Zero KB", 412_000_000 -> "412 MB"
    static func bytes(_ count: Int64) -> String {
        count.formatted(.byteCount(style: .file))
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
