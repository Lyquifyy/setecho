import Foundation

/// What makes a read-back sound like a person who knows him, from content alone (HANDOFF.md §7):
/// acknowledgments that never come twice in a row, and a change since the last check-in computed from
/// his own check-ins. Every number here is computed; the model writes none of it. The comparisons are
/// for the screen only: no spoken line carries one (Oct 30, the practice run read "up 5890.0" on steps
/// against a last value that wasn't there, "down 100 points", and a delta right after a correction).
enum SpokenFacts {
    // MARK: One fact from the log

    /// The leading number of an answer: "180.8" → 180.8, "9.4k" → 9400, "10,200" → 10200,
    /// "100%, 5 of 5 sessions" → 100, "31 in" → 31, "6/10" → 6. Nil when the answer doesn't start with
    /// a number.
    static func value(_ text: String) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespaces).replacing(/(\d),(\d{3})/, with: { "\($0.1)\($0.2)" })
        guard let match = trimmed.firstMatch(of: /^(\d+(?:\.\d+)?)(k)?/) else { return nil }
        guard let n = Double(match.1) else { return nil }
        return match.2 == nil ? n : n * 1000
    }

    /// Fields where a change since last time means something said aloud: weight and the tape, steps,
    /// glucose, the percentages, the 1–10 scales. Not dates, words, weeks out or last week's own weight.
    static func comparable(_ field: FieldSpec) -> Bool {
        guard [.measurement, .number, .percent, .scale10].contains(field.kind) else { return false }
        return field.source.key != .weeksToShow && field.source.key != .lastCheckInWeight
    }

    /// "down 0.4 from last week", "up 500 from last week", "up 5 points since your last check-in",
    /// "same as last week". Nil without a comparable value from a previous check-in: a missing, empty or
    /// wordy last value compares to nothing. Steps (either value in the thousands) are whole hundreds,
    /// never a decimal.
    static func comparison(_ field: FieldSpec, now: String, last: String?, lastSentAt: Date?, today: Date = .now,
                           calendar: Calendar = .current) -> String? {
        guard comparable(field), let last, let a = value(now), let b = value(last), a.isFinite, b.isFinite else { return nil }
        let days = lastSentAt.map { calendar.dateComponents([.day], from: calendar.startOfDay(for: $0), to: calendar.startOfDay(for: today)).day ?? 0 }
        let weekly = days.map { (5...9).contains($0) } ?? false
        let since = weekly ? "from last week" : "since your last check-in"
        let same = weekly ? "same as last week" : "same as your last check-in"

        let delta = a - b
        let text: String
        if field.kind == .percent {
            let points = Int(delta.rounded())
            guard points != 0 else { return same }
            text = "\(abs(points)) \(abs(points) == 1 ? "point" : "points")"
        } else if a >= 1000 || b >= 1000 {
            let hundreds = Int((delta / 100).rounded()) * 100 // steps: to the nearest hundred, no decimal
            guard hundreds != 0 else { return "about the \(same)" }
            text = "\(abs(hundreds))"
        } else if now.contains(".") || last.contains(".") {
            let tenths = (delta * 10).rounded() / 10
            guard tenths != 0 else { return same }
            text = String(format: "%.1f", abs(tenths))
        } else {
            let whole = Int(delta.rounded())
            guard whole != 0 else { return same }
            text = "\(abs(whole))"
        }
        return "\(delta > 0 ? "up" : "down") \(text) \(since)"
    }

    /// The fact joined to a line that already has the value: "Apple Health has you at 180.8" +
    /// "down 0.4 from last week" → "Apple Health has you at 180.8, down 0.4 from last week."
    static func joined(_ line: String, fact: String?) -> String {
        guard let fact else { return line }
        let base = line.trimmingCharacters(in: .whitespaces)
        if base.hasSuffix(".") { return String(base.dropLast()) + ", \(fact)." }
        if base.hasSuffix("?") || base.hasSuffix("!") { return base + " That's \(fact)." }
        return base + ", \(fact)."
    }

    // MARK: Acknowledgments

    static let acknowledgments = ["Got it", "Okay", "Nice"]

    /// The next acknowledgment after `last`, in turn, never the same twice in a row. "Nice" never sits in
    /// front of a change ("Nice, up two pounds" would be a judgment, and Setecho never coaches).
    static func next(after last: String?, beforeAFact: Bool) -> String {
        let choices = beforeAFact ? acknowledgments.filter { $0 != "Nice" } : acknowledgments
        let start = last.flatMap { choices.firstIndex(of: $0) }.map { $0 + 1 } ?? 0
        for offset in 0..<choices.count {
            let candidate = choices[(start + offset) % choices.count]
            if candidate != last { return candidate }
        }
        return choices[0]
    }

    /// A reply with its "got it" swapped for the acknowledgment in turn: "180.8, got it." → "Okay, 180.8.";
    /// "Got it, weight 180.8 and glucose 91." → "Nice, weight 180.8 and glucose 91." A reply that doesn't
    /// acknowledge ("Changed to 180.6.") is kept as written. Nil when there is nothing to swap.
    static func reacknowledged(_ reply: String, with ack: String) -> String? {
        let trimmed = reply.trimmingCharacters(in: .whitespaces)
        var rest: Substring
        if let m = trimmed.firstMatch(of: /(?i)^got it[,.!]?\s*/) {
            rest = trimmed[m.range.upperBound...]
        } else if let m = trimmed.firstMatch(of: /(?i),?\s*got it[.!]?$/) {
            rest = trimmed[..<m.range.lowerBound]
        } else {
            return nil
        }
        rest = rest.drop { $0 == " " || $0 == "," }
        guard let first = rest.first else { return "\(ack)." }
        let body = (first.isUppercase ? first.lowercased() + rest.dropFirst() : String(rest))
            .trimmingCharacters(in: CharacterSet(charactersIn: " .!"))
        return "\(ack), \(body)."
    }
}
