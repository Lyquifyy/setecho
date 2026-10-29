import Foundation
import Testing
@testable import Setecho

/// Talkative spotter (Oct 29): the engine's lines said like a training partner, with every number
/// kept, and a reaction from Muse Spark after a set only while nothing else is going on.

private let numberWords: Set<String> = [
    "zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten", "eleven", "twelve", "thirteen",
    "fourteen", "fifteen", "sixteen", "seventeen", "eighteen", "nineteen", "twenty", "thirty", "forty", "fifty", "sixty",
    "seventy", "eighty", "ninety", "oh",
]

/// Every number in a line, as digits or words, in order.
private func numbers(_ line: String) -> [String] {
    line.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "." && $0 != "–" })
        .map { String($0).trimmingCharacters(in: CharacterSet(charactersIn: ".")) }
        .filter { $0.first?.isNumber == true || numberWords.contains($0) }
}

/// The engine's own lines, as the tests and the session say them.
private let lines = [
    "Day 1. Pec Deck, 175 for 12–15. Last time 175 for 12. Lift when ready, or say starting.",
    "Set 1 done. Rest three minutes.",
    "8 reps. Next, 225 for 8. Rest two thirty.",
    "11 reps, measured. Next, 90 for 6–8.",
    "22 total, measured.",
    "Warm-up two, logged. Rest one thirty, then your top set: 27.5 for 12–15. Last time 27.5 for 12.",
    "Incline press done. Cable flyes next.",
    "Next exercise, Cable flyes, 30 for 12 reps. Last time 30 for 12. Warm-ups first.",
    "Rest's up.",
    "Got it. Next, 90 for 6–8.",
    "That's the session.",
    "Seven. Was that your top set?",
    "Set 2 is next.",
    "Back-off at 170, his rule: 20 to 25 percent lighter. Say 'go with it' or a weight.",
]

@Test func everyPhrasingKeepsEveryNumber() {
    for line in lines {
        for turn in 0..<12 {
            let said = Talk.rephrase(line, turn: turn, name: "Sam")
            #expect(numbers(said) == numbers(line), "\(line) → \(said)")
        }
    }
}

@Test func linesAreSaidDifferentlyAndNeverTwiceInARow() {
    let line = "Set 1 done. Rest three minutes."
    let said = (0..<6).map { Talk.rephrase(line, turn: $0, name: nil) }
    #expect(Set(said).count > 2)
    for turn in 0..<6 {
        let first = Talk.rephrase(line, turn: turn, name: nil)
        #expect(Talk.rephrase(line, turn: turn, name: nil, previous: first) != first)
    }
}

@Test func unknownSentencesDecimalsAndQuestionsAreLeftAlone() {
    #expect(Talk.sentences("Rest one thirty, then your top set: 27.5 for 12. Last time 27.5 for 12.") ==
        ["Rest one thirty, then your top set: 27.5 for 12.", "Last time 27.5 for 12."])
    for turn in 0..<6 {
        #expect(Talk.rephrase("Set 2 is next.", turn: turn, name: nil) == "Set 2 is next.")
        #expect(Talk.rephrase("Seven. Was that your top set?", turn: turn, name: nil) == "Seven. Was that your top set?")
        #expect(Talk.rephrase("Keeping 225.", turn: turn, name: nil) == "Keeping 225.")
    }
}

@Test func hisNameOnlyWhenItIsSet() {
    let named = (0..<8).map { Talk.rephrase("Day 1.", turn: $0, name: "Sam") }
    #expect(named.contains("Alright Sam, Day 1."))
    let unnamed = (0..<8).map { Talk.rephrase("Day 1.", turn: $0, name: nil) }
    #expect(unnamed.allSatisfy { !$0.contains("{name}") && !$0.contains(",,") && !$0.contains("Alright ,") })
}

// MARK: The reaction after a set

private func plannedSet(_ reps: Int, _ load: Double, role: SetRole? = nil) -> PlannedSet {
    PlannedSet(reps: reps, repsMin: nil, repsMax: nil, loadLb: load, rpe: nil, rir: nil, role: role)
}

private let day = ProgramDay(id: "d1", name: "Day 1", exercises: [
    PlannedExercise(id: "cg", name: "Smith close-grip", sets: [plannedSet(9, 225, role: .top), plannedSet(10, 185, role: .backOff)], restSeconds: 180, notes: nil),
])

@MainActor
private func talk(_ engine: SessionEngine, react: @escaping @MainActor (SpotterFacts, [String]) async -> String?) -> SessionConversation {
    let talk = SessionConversation(engine: engine)
    talk.classify = { heard, _ in
        let n = Double((heard.transcript ?? "").filter(\.isNumber)) ?? 0
        return SessionTurnResponse(transcript: heard.transcript ?? "", actions: [VoiceIntent(intent: .endSet, number: n, confidence: 0.95)], classifiedBy: "rules")
    }
    talk.rephrase = { line, turn, previous in Talk.rephrase(line, turn: turn, name: nil, previous: previous) }
    talk.react = react
    return talk
}

@Test @MainActor func aReactionFollowsTheFactsDuringTheRest() async throws {
    let engine = SessionEngine(day: day, weekNumber: 1, lastSets: ["cg|top": LastSet(loadLb: 225, reps: 9)])
    var asked: SpotterFacts?
    let t = talk(engine) { facts, _ in
        asked = facts
        return "One more than last time at 225."
    }
    await t.hear(.init(transcript: "done, 10", wav: nil, seconds: 1, speechEndedAt: .now))
    try await Task.sleep(for: .milliseconds(100))
    #expect(asked?.reps == 10 && asked?.lastTimeReps == 9 && asked?.lastTimeLoadLb == 225)
    #expect(t.said.last == "One more than last time at 225.")
    #expect(t.said.count == 2)
}

@Test @MainActor func noReactionWhenHeTalksFirstOrAQuestionIsWaiting() async throws {
    // He speaks again before the reaction is back: the reaction is dropped.
    let engine = SessionEngine(day: day, weekNumber: 1)
    var release: CheckedContinuation<Void, Never>?
    let t = talk(engine) { _, _ in
        await withCheckedContinuation { release = $0 }
        return "Strong one."
    }
    await t.hear(.init(transcript: "done, 9", wav: nil, seconds: 1, speechEndedAt: .now))
    t.say("Rest's up.")
    release?.resume()
    try await Task.sleep(for: .milliseconds(100))
    #expect(!t.said.contains("Strong one."))
    // A set that leaves a question open ("Seven. Was that your top set?") gets no reaction either.
    let warm = SessionEngine(day: day, weekNumber: 1, warmups: WarmupRule(minSets: 1, maxSets: 3, maxReps: 8, quote: nil, confirmed: true))
    let t2 = talk(warm) { _, _ in "Strong one." }
    await t2.hear(.init(transcript: "done, 8", wav: nil, seconds: 1, speechEndedAt: .now))
    try await Task.sleep(for: .milliseconds(100))
    #expect(warm.pendingAsk != nil && !t2.said.contains("Strong one."))
}
