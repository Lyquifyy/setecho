import Foundation

/// What he says to the photo session, read by code (Oct 29: "say retake and a pose" was spoken, but
/// nothing was listening). "Retake the front", "do the right side again", "redo them all", "wait",
/// "we're done".
enum PhotoCommand: Equatable {
    /// One pose again.
    case retake(Pose)
    /// "Retake" with no pose he named: ask which.
    case retakeWhich
    /// All four again, from the front.
    case retakeAll
    /// "Wait", "hang on", "not yet": more time before the photo.
    case wait
    /// "We're done", "looks good", "keep them".
    case done

    static func read(_ transcript: String) -> PhotoCommand? {
        let text = transcript.lowercased().replacingOccurrences(of: "’", with: "'")
            .replacing(/[^\w' ]/, with: " ")
            .split(separator: " ").joined(separator: " ")
        guard !text.isEmpty else { return nil }
        if matches(allPattern, text) { return .retakeAll }
        if matches(retakePattern, text) {
            return pose(in: text).map(PhotoCommand.retake) ?? .retakeWhich
        }
        if matches(waitPattern, text) { return .wait }
        if SpokenReply.isFinished(text) || matches(donePattern, text) { return .done }
        return nil
    }

    /// The one pose named: front, back, right side, left side. Both sides named is no pose.
    static func pose(in text: String) -> Pose? {
        var found: [Pose] = []
        if matches(pattern(#"\bfront\b"#), text) { found.append(.front) }
        if matches(pattern(#"\bright\b"#), text) { found.append(.rightArmsUp) }
        // "back" as the pose, not "I'm back" or "go back".
        if matches(pattern(#"\bback\b"#), text), !matches(pattern(#"\b(i'?m|go|come|be|step) back\b"#), text) { found.append(.back) }
        if matches(pattern(#"\bleft\b"#), text) { found.append(.leftArmsUp) }
        return found.count == 1 ? found[0] : nil
    }

    private static func matches(_ regex: NSRegularExpression, _ text: String) -> Bool {
        regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    private static func pattern(_ p: String) -> NSRegularExpression {
        try! NSRegularExpression(pattern: p)   // fixed patterns, checked by the tests
    }

    nonisolated(unsafe) private static let allPattern = pattern(
        #"\b((?:retake|redo|re do|reshoot) (?:them |it )?all|(?:retake|redo|re do|reshoot) (?:all|every|the whole)|"#
        + #"all (?:four |of them )?again|start (?:the photos )?over|from the (?:top|front|beginning)|do them all again)\b"#)
    nonisolated(unsafe) private static let retakePattern = pattern(
        #"\b(retake|re take|redo|re do|reshoot|re shoot|again|another one|one more|take (?:it|that|the \w+(?: \w+)?) again)\b"#)
    nonisolated(unsafe) private static let waitPattern = pattern(
        #"\b(wait|hang on|hold on|one sec(?:ond)?|just a (?:sec(?:ond)?|moment)|not yet|not ready|give me a (?:sec(?:ond)?|moment))\b"#)
    nonisolated(unsafe) private static let donePattern = pattern(
        #"\b(done|looks? good|they'?re good|those are good|keep (?:them|those|it)|move on|we'?re good|perfect|that'?s good)\b"#)
}
