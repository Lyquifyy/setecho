import Foundation
import Testing
@testable import Setecho

/// Content that sounds like a person: one fact from the log, acknowledgments in turn. Every number from code.

private func field(_ kind: FieldKind, key: DataKey? = nil) throws -> FieldSpec {
    let source = key.map { #"{"type":"data","key":"\#($0.rawValue)"}"# } ?? #"{"type":"voice"}"#
    let json = #"{"id":"f","label":"F","kind":"\#(kind.rawValue)","source":\#(source),"order":0}"#
    return try JSONCoding.decoder.decode(FieldSpec.self, from: Data(json.utf8))
}

@Test func oneFactFromTheLastCheckIn() throws {
    let cal = Calendar(identifier: .gregorian)
    let today = cal.date(from: DateComponents(year: 2026, month: 10, day: 29))!
    let lastWeek = cal.date(byAdding: .day, value: -7, to: today)
    let weight = try field(.measurement, key: .currentWeight)
    #expect(SpokenFacts.comparison(weight, now: "180.8", last: "181.2", lastSentAt: lastWeek, today: today, calendar: cal) == "down 0.4 from last week")
    #expect(SpokenFacts.comparison(weight, now: "182", last: "181.2", lastSentAt: lastWeek, today: today, calendar: cal) == "up 0.8 from last week")
    #expect(SpokenFacts.comparison(weight, now: "180.8", last: "180.8", lastSentAt: lastWeek, today: today, calendar: cal) == "same as last week")
    let steps = try field(.number, key: .avgDailySteps)
    #expect(SpokenFacts.comparison(steps, now: "9.4k", last: "8.9k", lastSentAt: lastWeek, today: today, calendar: cal) == "up 500 from last week")
    let percent = try field(.percent, key: .trainingConsistency)
    let twoWeeks = cal.date(byAdding: .day, value: -14, to: today)
    #expect(SpokenFacts.comparison(percent, now: "100%, 5 of 5 sessions", last: "80%, 4 of 5", lastSentAt: twoWeeks, today: today, calendar: cal)
            == "up 20 points since your last check-in")
    #expect(SpokenFacts.comparison(try field(.scale10), now: "6/10", last: "7/10", lastSentAt: lastWeek, today: today, calendar: cal) == "down 1 from last week")
    // Nothing to compare, or nothing that means anything aloud: no fact.
    #expect(SpokenFacts.comparison(weight, now: "180.8", last: nil, lastSentAt: nil, today: today) == nil)
    #expect(SpokenFacts.comparison(try field(.text), now: "Felt strong", last: "Tired", lastSentAt: lastWeek, today: today) == nil)
    #expect(SpokenFacts.comparison(try field(.number, key: .weeksToShow), now: "6", last: "7", lastSentAt: lastWeek, today: today) == nil)
    // Spoken the way people say it.
    #expect(SpokenText.spoken("180.8, down 0.4 from last week") == "one eighty point eight, down point four from last week")
}

@Test func theFactJoinsTheLineItBelongsTo() {
    #expect(CheckInMorningModel.weightOffer("180.8", fact: "down 0.4 from last week")
            == "Apple Health has you at 180.8, down 0.4 from last week. Should I use that?")
    #expect(CheckInMorningModel.weightOffer("180.8") == "Apple Health has you at 180.8. Should I use that?")
    #expect(SpokenFacts.joined("Okay, 180.8.", fact: "down 0.4 from last week") == "Okay, 180.8, down 0.4 from last week.")
    #expect(SpokenFacts.joined("Okay, 180.8.", fact: nil) == "Okay, 180.8.")
}

@Test func acknowledgmentsTakeTurnsAndNeverPraiseAChange() {
    var last: String?
    var said: [String] = []
    for _ in 0..<9 {
        let ack = SpokenFacts.next(after: last, beforeAFact: false)
        said.append(ack)
        last = ack
    }
    #expect(zip(said, said.dropFirst()).allSatisfy { $0 != $1 })
    #expect(Set(said) == ["Got it", "Okay", "Nice"])
    for prior in [nil, "Got it", "Okay", "Nice"] as [String?] {
        let ack = SpokenFacts.next(after: prior, beforeAFact: true)
        #expect(ack != "Nice" && ack != prior)
    }
    #expect(SpokenFacts.reacknowledged("180.8, got it.", with: "Okay") == "Okay, 180.8.")
    #expect(SpokenFacts.reacknowledged("Weight 180.8 and glucose 91, got it.", with: "Nice") == "Nice, weight 180.8 and glucose 91.")
    #expect(SpokenFacts.reacknowledged("Got it.", with: "Okay") == "Okay.")
    #expect(SpokenFacts.reacknowledged("Changed to 180.6.", with: "Okay") == nil) // kept as the reply wrote it
}

@Test func theChimeIsSoftAndShort() {
    let chime = VoiceOutput.makeChime()
    let samples = UnsafeBufferPointer(start: chime.floatChannelData![0], count: Int(chime.frameLength))
    #expect(Double(chime.frameLength) / chime.format.sampleRate < 0.4)
    #expect(samples.map(abs).max()! < 0.15)
    #expect(abs(samples.last!) < 0.002) // fades out, no click
}
