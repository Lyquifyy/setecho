import Foundation

/// The spoken callouts, deterministic and template-only (HANDOFF.md §7). No model writes these.
/// On a tripod set the set-end line carries no count ("Set 3 done. Rest two thirty."): SAM is the
/// count of record, and its number comes during rest ("8 reps, measured. Next, 225 for 8."). A set
/// nothing will measure keeps the full line: "8 reps. Next, 225 for 8. Rest two thirty."
enum Callout {
    /// The instant set-end line while SAM counts: no number yet.
    static func setDone(setNumber: Int, restSeconds: Int, sessionOver: Bool) -> String {
        sessionOver ? "Set \(setNumber) done. That's the session." : "Set \(setNumber) done. Rest \(spoken(seconds: restSeconds))."
    }

    /// The count, once it is known, with the next target: "8 reps, measured. Next, 225 for 8."
    /// A rest-pause set's number is its total: "22 total, measured." Falling short of the plan is
    /// stated as a fact, never a judgement.
    static func counted(reps: Int, measured: Bool, total: Bool = false, shortBy: Int = 0, next: NextSet?) -> String {
        var line = total ? "\(reps) total" : "\(reps) reps"
        if measured { line += ", measured" }
        if shortBy > 0 { line += ", \(shortBy) short of plan" }
        var parts = [line + "."]
        if let next { parts.append(nextLine(next)) }
        return parts.joined(separator: " ")
    }

    /// SAM answered after another set had started, and nothing had been said about this one yet.
    static func lateCount(setNumber: Int, reps: Int, measured: Bool) -> String {
        "Set \(setNumber): \(reps)\(measured ? ", measured" : "")."
    }

    /// SAM's count replaced a number already spoken: "Set 3 updated: 7, measured."
    static func updated(setNumber: Int, reps: Int) -> String {
        "Set \(setNumber) updated: \(reps), measured."
    }

    /// SAM is unsure: "Set 3, was that 8?" A yes logs it as Measured, a number as You said.
    static func confirmCount(setNumber: Int, reps: Int) -> String {
        "Set \(setNumber), was that \(reps)?"
    }

    /// No count to say (the plan's reps stand): just the next target. A new exercise names its
    /// add-on ("Abs"), says "Warm-ups first" when it starts in warm-up mode, and "Say go" for a hold.
    static func nextLine(_ next: NextSet) -> String {
        switch next {
        case .sameExercise(let load, let reps):
            return "Next, \(target(load: load, reps: reps))."
        case .nextExercise(let name, let load, let reps, let section, let warmups, let timed):
            var line = section.map { "Next, \($0). \(name), " } ?? "Next exercise, \(name), "
            line += timed ? "\(reps). Say go." : "\(target(load: load, reps: reps))."
            if warmups { line += " Warm-ups first." }
            return line
        }
    }

    static func setDone(setNumber: Int, reps: Int? = nil, total: Bool = false, shortBy: Int = 0, next: NextSet?, restSeconds: Int) -> String {
        var parts: [String]
        if let reps {
            // A count is stated as a fact, and so is falling short of the plan. Never a judgement.
            let unit = total ? "total" : "reps"
            parts = [shortBy > 0 ? "\(reps) \(unit), \(shortBy) short of plan." : "\(reps) \(unit)."]
        } else {
            parts = ["Set \(setNumber) done."]
        }
        if let next {
            parts.append(nextLine(next))
            parts.append("Rest \(spoken(seconds: restSeconds)).")
        } else {
            parts.append("That's the session.")
        }
        return parts.joined(separator: " ")
    }

    /// A warm-up never gets a count spoken as a result: "Warm-up 2. Rest one thirty."
    static func warmupDone(number: Int, restSeconds: Int) -> String {
        "Warm-up \(number). Rest \(spoken(seconds: restSeconds))."
    }

    /// A hold ended: "Time. Next, 60 s. Rest thirty seconds." or, cut short, "Forty seconds logged."
    static func holdDone(setNumber: Int, seconds: Int, planned: Int, next: NextSet?, restSeconds: Int, sessionOver: Bool) -> String {
        let ran = spoken(seconds: seconds)
        var parts = [seconds >= planned ? "Time." : "\(ran.prefix(1).uppercased() + ran.dropFirst()) logged."]
        if sessionOver || next == nil {
            parts.append("That's the session.")
        } else if let next {
            parts.append(nextLine(next))
            parts.append("Rest \(spoken(seconds: restSeconds)).")
        }
        return parts.joined(separator: " ")
    }

    enum NextSet: Equatable {
        case sameExercise(loadLb: Double?, reps: String)
        case nextExercise(name: String, loadLb: Double?, reps: String, section: String? = nil, warmups: Bool = false, timed: Bool = false)
    }

    static func target(load: Double?, reps: String) -> String {
        if let load { return "\(Format.number(load)) for \(reps)" }
        return reps.hasSuffix(" s") || reps.hasSuffix(" min") || reps.hasSuffix(" total") ? reps : "\(reps) reps"
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
}
