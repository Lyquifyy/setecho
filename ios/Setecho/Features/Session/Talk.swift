import Foundation

/// Settings → Sessions → "Talkative spotter" (Oct 29): the engine's lines, said like a training
/// partner instead of a readout, and never the same way twice in a row. Each known sentence has a
/// few phrasings that keep its own words for every number, so what's said is still what the code
/// computed (rule 13; `TalkTests` checks every rule keeps every number). A sentence it doesn't know
/// is said as written. Off, every line is the engine's exact template.
enum Talk {
    struct Rule {
        let pattern: NSRegularExpression
        let variants: [String]
    }

    private static func rule(_ pattern: String, _ variants: [String]) -> Rule {
        Rule(pattern: try! NSRegularExpression(pattern: "^" + pattern + "$"), variants: variants)
    }

    /// Sentence by sentence, first match wins. `$1` is the template's own words (a number, a load, a name).
    /// `{name}` variants are used only when his first name is set.
    static let rules: [Rule] = [
        rule(#"Day (\d+)"#, ["Day $1", "Alright, Day $1", "Day $1, let's get after it", "Alright {name}, Day $1"]),
        rule(#"Set (\d+) done"#, ["Set $1 done", "That's set $1", "Nice, set $1's in", "Set $1, done"]),
        rule(#"(\d+) reps, measured"#, ["$1 reps, measured", "Camera says $1", "That's $1, by the camera"]),
        rule(#"(\d+) reps"#, ["$1 reps", "$1, got it", "$1 it is"]),
        rule(#"(\d+) total, measured"#, ["$1 total, measured", "Camera says $1 total"]),
        rule(#"Warm-up (\w+), logged"#, ["Warm-up $1, logged", "That's warm-up $1", "Warm-up $1 in"]),
        rule(#"Rest (.+)"#, ["Rest $1", "Take $1", "Catch your breath, $1"]),
        rule(#"Next, (.+)"#, ["Next, $1", "Next up, $1", "Then $1"]),
        rule(#"Next exercise, (.+)"#, ["Next exercise, $1", "On to the next exercise: $1", "Moving on, $1"]),
        rule(#"(?!.*\b(is|are|was)\b)([^,:]+) done"#, ["$2 done", "That's $2 done", "$2, all done"]),
        rule(#"(?!.*\b(is|are|was)\b)([^,:]+) next"#, ["$2 next", "Up next, $2", "On to $2"]),
        rule(#"Rest's up"#, ["Rest's up", "That's your rest. Go when you're ready", "Rest's done, whenever you're ready"]),
        rule(#"Lift when ready, or say starting"#, ["Lift when ready, or say starting", "Whenever you're ready", "Go when you're ready"]),
        rule(#"Warm-ups first"#, ["Warm-ups first", "Warm up first", "Get your warm-ups in first"]),
        rule(#"Got it"#, ["Got it", "Okay", "Cool"]),
        rule(#"That's the session"#, ["That's the session", "That's the session. Good work today", "And that's the session. Nice work, {name}"]),
    ]

    /// The line said his way. `turn` moves the phrasing along; `previous` (the last line said) is never repeated.
    static func rephrase(_ line: String, turn: Int, name: String?, previous: String? = nil) -> String {
        for shift in 0..<4 {
            let out = sentences(line).map { say($0, turn: turn + shift, name: name) }.joined(separator: " ")
            if out != previous { return out }
        }
        return line
    }

    /// "Set 1 done. Rest three minutes." → ["Set 1 done.", "Rest three minutes."]. A decimal load
    /// ("27.5 for 12") is never split: only a period followed by a space ends a sentence.
    static func sentences(_ line: String) -> [String] {
        var out: [String] = []
        var current = ""
        let chars = Array(line)
        for (i, c) in chars.enumerated() {
            current.append(c)
            let ends = (c == "." || c == "?" || c == "!") && (i + 1 == chars.count || chars[i + 1] == " ")
            if ends {
                out.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            }
        }
        let rest = current.trimmingCharacters(in: .whitespaces)
        if !rest.isEmpty { out.append(rest) }
        return out
    }

    private static func say(_ sentence: String, turn: Int, name: String?) -> String {
        guard let end = sentence.last, ".?!".contains(end) else { return sentence }
        let body = String(sentence.dropLast())
        let range = NSRange(body.startIndex..., in: body)
        for (index, rule) in rules.enumerated() {
            guard let match = rule.pattern.firstMatch(in: body, range: range) else { continue }
            let usable = rule.variants.filter { name?.isEmpty == false || !$0.contains("{name}") }
            let template = usable[(turn + index) % usable.count].replacingOccurrences(of: "{name}", with: name ?? "")
            let out = rule.pattern.replacementString(for: match, in: body, offset: 0, template: template)
            return out + String(end)
        }
        return sentence
    }
}
