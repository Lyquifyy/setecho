import Foundation

/// The spoken callouts, deterministic and template-only (HANDOFF.md §7). No model writes these.
/// "8 reps. Next, 225 for 8. Rest two thirty." With no count: "Set 3 done. Next, …".
enum Callout {
    static func setDone(setNumber: Int, reps: Int? = nil, shortBy: Int = 0, next: NextSet?, restSeconds: Int) -> String {
        var parts: [String]
        if let reps {
            // A count is stated as a fact, and so is falling short of the plan. Never a judgement.
            parts = [shortBy > 0 ? "\(reps) reps, \(shortBy) short of plan." : "\(reps) reps."]
        } else {
            parts = ["Set \(setNumber) done."]
        }
        switch next {
        case .sameExercise(let load, let reps):
            parts.append("Next, \(target(load: load, reps: reps)).")
            parts.append("Rest \(spoken(seconds: restSeconds)).")
        case .nextExercise(let name, let load, let reps):
            parts.append("Next exercise, \(name), \(target(load: load, reps: reps)).")
            parts.append("Rest \(spoken(seconds: restSeconds)).")
        case nil:
            parts.append("That's the session.")
        }
        return parts.joined(separator: " ")
    }

    enum NextSet: Equatable {
        case sameExercise(loadLb: Double?, reps: String)
        case nextExercise(name: String, loadLb: Double?, reps: String)
    }

    static func target(load: Double?, reps: String) -> String {
        if let load { return "\(Format.number(load)) for \(reps)" }
        return "\(reps) reps"
    }

    /// 150 -> "two thirty", 90 -> "one thirty", 120 -> "two minutes", 45 -> "forty five seconds".
    static func spoken(seconds: Int) -> String {
        let minutes = seconds / 60
        let rest = seconds % 60
        if minutes == 0 { return "\(word(seconds)) seconds" }
        if rest == 0 { return minutes == 1 ? "one minute" : "\(word(minutes)) minutes" }
        return "\(word(minutes)) \(rest < 10 ? "oh \(word(rest))" : word(rest))"
    }

    /// Number words 0–99, so the synthesizer never reads "2:30" as a time of day.
    static func word(_ n: Int) -> String {
        let units = ["zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten",
                     "eleven", "twelve", "thirteen", "fourteen", "fifteen", "sixteen", "seventeen", "eighteen", "nineteen"]
        let tens = ["", "", "twenty", "thirty", "forty", "fifty", "sixty", "seventy", "eighty", "ninety"]
        if n < 20 { return units[n] }
        if n < 100 { return n % 10 == 0 ? tens[n / 10] : "\(tens[n / 10]) \(units[n % 10])" }
        return "\(n)"
    }

    static func rpeLogged(_ rpe: Double, setNumber: Int) -> String {
        "RPE \(Format.number(rpe)) on set \(setNumber)."
    }

    static func repsLogged(_ reps: Int, setNumber: Int) -> String {
        "Set \(setNumber), \(reps) reps."
    }

    static func loadChanged(to load: Double) -> String {
        "Load \(Format.number(load))."
    }

    static func askBack(_ transcript: String) -> String {
        "Did you say \(transcript)?"
    }

    /// SAM disagreed and is confident: "Set 3: 7, not 8."
    static func measuredCorrection(setNumber: Int, measured: Int, was: Int) -> String {
        "Set \(setNumber): \(measured), not \(was)."
    }

    /// SAM disagreed and is unsure: "Set 3, was that 7 or 8?"
    static func whichCount(setNumber: Int, measured: Int, current: Int) -> String {
        "Set \(setNumber), was that \(measured) or \(current)?"
    }
}
