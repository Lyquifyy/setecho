import Foundation

/// The short replies of a conversation, read by code the way people actually say them (Oct 28: "let's
/// keep that" and "sounds good to me" weren't heard as a yes). The same reading as the backend's
/// `checkin_turn.conversational`, so a keep, a no or a wait is acted on whichever side reads it.
/// Anything with a number, a "but", a yes and a no together, or more than eight words is left to Spark.
enum SpokenReply: Equatable {
    /// Agreeing with what was offered: "let's keep that", "sounds good to me", "yeah, go with it".
    case keep
    /// A no with no new value: "nah, that's off", "that's not right", "change it".
    case decline
    /// Asking for time: "hang on", "one sec", "let me check", "give me two minutes".
    case hold
    /// Only thinking out loud: "um", "hmm, let me see". Nothing to answer and nothing to say.
    case thinking

    /// Coming back from a wait: "I'm back", "ready", "okay, go ahead", "let's keep going". No
    /// number in it, so a value said after a wait is still an answer.
    static func isBack(_ transcript: String) -> Bool {
        let text = transcript.lowercased().replacingOccurrences(of: "’", with: "'")
        guard !text.contains(where: { $0.isNumber }) else { return false }
        return matches(backPattern, text)
    }

    nonisolated(unsafe) private static let backPattern = pattern(
        #"\b(i'?m back|back now|ready|let'?s go|go ahead|continue|carry on|keep going|where were we|next question|go on)\b"#)

    /// Leaving once everything is done: "I'm done", "that's all", "done for now", "close it".
    static func isFinished(_ transcript: String) -> Bool {
        matches(finishedPattern, transcript.lowercased().replacingOccurrences(of: "’", with: "'"))
    }

    nonisolated(unsafe) private static let finishedPattern = pattern(
        #"\b(i'?m done|that'?s (?:all|it|everything)|all done|done for now|we'?re done|close(?: it| this)?|finish(?:ed)?|that'?ll do|"#
        + #"(?:good)?bye|all set|see you|i'?m good|i'?m finished|exit|quit)\b"#)

    /// The whole check-in again: "start over", "let's start again", "from the top", "restart". Short
    /// and with no number in it, so an answer that mentions starting is still an answer.
    static func isStartOver(_ transcript: String) -> Bool {
        let text = transcript.lowercased().replacingOccurrences(of: "’", with: "'")
            .replacing(/[^\w' ]/, with: " ")
            .split(separator: " ").joined(separator: " ")
        guard !text.contains(where: { $0.isNumber }), text.split(separator: " ").count <= 9 else { return false }
        return matches(startOverPattern, text)
    }

    nonisolated(unsafe) private static let startOverPattern = pattern(
        #"\b(start (?:it |this |that |the (?:whole )?(?:thing|check ?in) |everything )?(?:all )?(?:over|again|from (?:the )?(?:top|beginning|scratch))|"#
        + #"restart|re start|from the (?:top|beginning)|begin again|start from scratch|"#
        + #"redo (?:it all|everything|the whole (?:thing|check ?in))|do (?:the whole thing|everything|it all) (?:over|again))\b"#)

    static func read(_ transcript: String, offered: Bool) -> SpokenReply? {
        let text = transcript.lowercased().replacingOccurrences(of: "’", with: "'")
            .replacing(/[^\w' ]/, with: " ")
            .split(separator: " ").joined(separator: " ")
        let words = text.split(separator: " ").map(String.init)
        guard !words.isEmpty else { return nil }
        if words.allSatisfy(thinkingWords.contains) { return .thinking }
        // The wait's own words ("one sec", "two minutes") are not a number he's answering with.
        let rest = holdPattern.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: " ")
        let restWords = rest.split(separator: " ").map(String.init)
        if rest.contains(where: { $0.isNumber }) || restWords.contains(where: numberWords.contains)
            || words.count > 8 || words.contains("but") || matches(unsurePattern, text) {
            return nil
        }
        let holding = matches(holdPattern, text), declining = matches(declinePattern, text)
        // "not right" is a no, not a "right": the no's words are taken out before looking for a yes.
        let withoutNo = declinePattern.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: " ")
        let keeping = matches(keepPattern, withoutNo)
        if holding { return declining ? nil : .hold }   // "okay, hang on" waits; "wait, no" is Spark's
        guard offered, keeping != declining else { return nil }
        return keeping ? .keep : .decline
    }

    private static func matches(_ regex: NSRegularExpression, _ text: String) -> Bool {
        regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    private static func pattern(_ p: String) -> NSRegularExpression {
        try! NSRegularExpression(pattern: p)   // fixed patterns, checked by the tests
    }

    nonisolated(unsafe) private static let keepPattern = pattern(
        #"\b(yes|yeah|yea|yep|yup|ya|sure|ok|okay|alright|all right|correct|right|exactly|perfect|good|great|fine|"#
        + #"keep|use (?:that|it|this)|go with|sounds? (?:good|right|fine|great)|looks? (?:good|right|fine)|that works|"#
        + #"works for me|spot on|that'?s it|leave it|all good|agreed|for sure|definitely|absolutely|bang on)\b"#)
    nonisolated(unsafe) private static let declinePattern = pattern(
        #"\b(no|nope|nah|wrong|incorrect|not (?:right|quite|correct|it|that|good)|"#
        + #"(?:that'?s|that is|it'?s|it is) (?:off|wrong|not(?: right| it| correct| quite)?)|change (?:it|that)|don'?t (?:use|keep))\b"#)
    nonisolated(unsafe) private static let holdPattern = pattern(
        #"\b(hang on|hold on|one sec(?:ond)?|just a (?:sec(?:ond)?|minute|moment)|(?:a|one|two|a few|a couple of?) minutes?|"#
        + #"give me (?:a|one|two|a few|a couple)|gimme|wait|a minute|let me (?:think|check|look|grab|find)|"#
        + #"not yet|not ready|bear with me|in a (?:sec(?:ond)?|minute|bit))\b"#)
    /// Not knowing is not a no: "no idea" goes to Spark.
    nonisolated(unsafe) private static let unsurePattern = pattern(#"\b(no idea|not sure|dunno|don'?t know|no clue)\b"#)
    private static let thinkingWords: Set<String> = ["um", "umm", "uh", "uhh", "hmm", "hm", "mm", "erm", "er", "so", "well", "let", "me", "see"]
    /// Spoken numbers left after the wait's words: any of them makes this a value, not a yes or a no.
    private static let numberWords: Set<String> = [
        "zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten", "eleven", "twelve",
        "thirteen", "fourteen", "fifteen", "sixteen", "seventeen", "eighteen", "nineteen", "twenty", "thirty", "forty",
        "fifty", "sixty", "seventy", "eighty", "ninety", "hundred", "point", "half",
    ]
}
