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
    #expect(SpokenFacts.comparison(steps, now: "5890.0", last: nil, lastSentAt: lastWeek, today: today, calendar: cal) == nil)   // Oct 30: "up 5890.0"
    #expect(SpokenFacts.comparison(steps, now: "5,890", last: "", lastSentAt: lastWeek, today: today, calendar: cal) == nil)
    #expect(SpokenFacts.comparison(steps, now: "5,890", last: "—", lastSentAt: lastWeek, today: today, calendar: cal) == nil)
    // Steps are whole hundreds, never a decimal, whichever way the numbers were written.
    #expect(SpokenFacts.value("10,200") == 10200 && SpokenFacts.value("5,890 steps") == 5890)
    #expect(SpokenFacts.comparison(steps, now: "5,890", last: "9.4k", lastSentAt: lastWeek, today: today, calendar: cal) == "down 3500 from last week")
    #expect(SpokenFacts.comparison(steps, now: "5890.0", last: "3210.5", lastSentAt: lastWeek, today: today, calendar: cal) == "up 2700 from last week")
    #expect(SpokenFacts.comparison(steps, now: "1,050", last: "950", lastSentAt: lastWeek, today: today, calendar: cal) == "up 100 from last week")
    #expect(SpokenFacts.comparison(try field(.text), now: "Felt strong", last: "Tired", lastSentAt: lastWeek, today: today) == nil)
    #expect(SpokenFacts.comparison(try field(.number, key: .weeksToShow), now: "6", last: "7", lastSentAt: lastWeek, today: today) == nil)
    // Spoken the way people say it.
    #expect(SpokenText.spoken("180.8, down 0.4 from last week") == "one eighty point eight, down point four from last week")
}

@Test func theFactJoinsTheLineItBelongsTo() {
    #expect(SpokenFacts.joined("Okay, 180.8.", fact: "down 0.4 from last week") == "Okay, 180.8, down 0.4 from last week.")
    #expect(SpokenFacts.joined("Okay, 180.8.", fact: nil) == "Okay, 180.8.")
}

/// Oct 30: no spoken line carries a delta. The weight offer is the number alone.
@Test func theWeightOfferCarriesNoDelta() {
    #expect(CheckInMorningModel.weightOffer("180.8") == "Apple Health has you at 180.8. Should I use that?")
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

// MARK: Measured top sets in the check-in (HANDOFF.md §7, Measured effort, In the check-in)

private func measuredSet(_ exercise: String, _ load: Double, _ reps: Int, loss: Double?, rir: Double? = nil, role: SetRole? = .top,
                         measured: Int? = 9, at: Date, doneAs: String? = nil) -> LoggedSet {
    LoggedSet(id: UUID(), exerciseId: exercise, setIndex: 0, loadLb: load, reps: reps, rpe: nil, role: role,
              repCount: RepCount(source: measured == nil ? .phone : .measured, phone: reps, measured: measured, confidence: 0.8,
                                 velocityLossPct: loss, estimatedRIR: rir),
              startedAt: at, endedAt: at.addingTimeInterval(30), clipFile: nil, edits: [], doneAs: doneAs)
}

private func session(_ sets: [LoggedSet], at: Date) -> Session {
    Session(id: UUID(), programDayId: "d", startedAt: at, endedAt: at.addingTimeInterval(3600), sets: sets, notes: [])
}

@Test func theMeasuredTopSetLineHasOnlyTheLogsNumbersAndTheSpottersWords() {
    #expect(Effort.topSetLine(name: "Smith close-grip press", loadLb: 225, reps: 9, velocityLossPct: 46.4, rir: 0)
            == "Smith close-grip press 225 × 9, slowed 46%, failure")
    #expect(Effort.topSetLine(name: "Incline DB press", loadLb: 80, reps: 10, velocityLossPct: 31, rir: 1)
            == "Incline DB press 80 × 10, slowed 31%, about 1 left")
    // Loads through Format: a half-pound load keeps its decimal, a whole one has none.
    #expect(Effort.topSetLine(name: "Curl", loadLb: 32.5, reps: 12, velocityLossPct: 8.2, rir: 4) == "Curl 32.5 × 12, slowed 8%, 4+ left")
    #expect(Effort.written(rir: 0) == "failure" && Effort.written(rir: 0.5) == "about 1 left" && Effort.written(rir: 2) == "about 2 left")
    #expect(Effort.written(rir: 4) == "4+ left" && Effort.written(rir: -1) == "failure")
    for rir in [0.0, 1, 2, 3, 4] {
        let line = Effort.topSetLine(name: "Bench", loadLb: 200, reps: 8, velocityLossPct: 20, rir: rir)
        #expect(!line.contains("good") && !line.contains("strong") && !line.contains("estimated"))
    }
}

@Test func eachLiftsBestMeasuredTopSetOfThePeriodInTheOrderFirstDone() {
    let cal = Calendar(identifier: .gregorian)
    let tue = cal.date(from: DateComponents(year: 2026, month: 10, day: 27, hour: 7))!
    let thu = cal.date(byAdding: .day, value: 2, to: tue)!
    let sat = cal.date(byAdding: .day, value: 4, to: tue)!
    let names: (String) -> String = { ["cgp": "Smith close-grip press", "inc": "Incline DB press", "hack": "Hack squat", "fly": "Pec deck"][$0] ?? $0 }
    let sessions = [
        session([
            // A warm-up and a back-off never count, measured or not.
            measuredSet("cgp", 135, 10, loss: 12, role: .warmup, at: tue),
            measuredSet("cgp", 225, 9, loss: 46.4, rir: 0, at: tue.addingTimeInterval(600)),
            measuredSet("cgp", 180, 12, loss: 44, rir: 0, role: .backOff, at: tue.addingTimeInterval(900)),
            // A top set with no slowdown measured, and one counted on the phone only: not measured.
            measuredSet("inc", 80, 10, loss: nil, at: tue.addingTimeInterval(1200)),
            measuredSet("fly", 120, 12, loss: 20, measured: nil, at: tue.addingTimeInterval(1500)),
        ], at: tue),
        session([
            // The same lift later in the period: heavier wins; at the same load, more reps win.
            measuredSet("hack", 270, 7, loss: 44, rir: 0, at: thu),
            measuredSet("inc", 80, 10, loss: 31, rir: 1, at: thu.addingTimeInterval(600)),
        ], at: thu),
        session([
            measuredSet("cgp", 225, 8, loss: 48, rir: 0, at: sat),
            measuredSet("hack", 270, 8, loss: 39, rir: 1, at: sat.addingTimeInterval(600)),
        ], at: sat),
    ]
    let notes = Effort.measuredTopSets(in: sessions, names: names)
    #expect(notes.map(\.line) == [
        "Smith close-grip press 225 × 9, slowed 46%, failure",
        "Hack squat 270 × 8, slowed 39%, about 1 left",
        "Incline DB press 80 × 10, slowed 31%, about 1 left",
    ])
    #expect(notes.map(\.exerciseName) == ["Smith close-grip press", "Hack squat", "Incline DB press"])
    #expect(notes[0].at == tue.addingTimeInterval(600) && notes[1].at == sat.addingTimeInterval(600))
    // Each note keys on its set, so an untick on Review and send leaves exactly that line out.
    #expect(notes[0].id == sessions[0].sets[1].id && notes[1].id == sessions[2].sets[1].id)
    // Nothing measured, nothing to say.
    #expect(Effort.measuredTopSets(in: [sessions[0]].map { session($0.sets.filter { $0.role != .top }, at: tue) }, names: names).isEmpty)
    #expect(Effort.measuredTopSets(in: [], names: names).isEmpty)
}

@Test func aMeasuredTopSetWithoutAStoredEstimateUsesTheEffortMapAndASwapIsNamedAsDone() {
    let at = Date(timeIntervalSince1970: 1_793_000_000)
    // No estimatedRIR stored: §13's map, 31% → 1 left; the fitted map once the lift has five spoken RPEs.
    let set = measuredSet("inc", 70, 7, loss: 31, at: at, doneAs: "Incline dumbbell press")
    let plain = Effort.measuredTopSets(in: [session([set], at: at)], names: { _ in "Incline barbell press" })
    #expect(plain.map(\.line) == ["Incline dumbbell press 70 × 7, slowed 31%, about 1 left"])
    var cal = Effort.Calibration()
    for (loss, rpe) in [(10.0, 10.0), (20, 10), (30, 10), (40, 10), (50, 10)] { cal.add(exerciseId: "inc", velocityLossPct: loss, rpe: rpe) }
    let fitted = Effort.measuredTopSets(in: [session([set], at: at)], names: { _ in "Incline barbell press" }, calibration: cal)
    #expect(fitted.map(\.line) == ["Incline dumbbell press 70 × 7, slowed 31%, failure"])
    // The logged reps, not SAM's, when he corrected the count aloud.
    let corrected = measuredSet("inc", 70, 8, loss: 31, rir: 1, measured: 7, at: at)
    #expect(Effort.measuredTopSets(in: [session([corrected], at: at)], names: { _ in "Incline press" }).map(\.line)
            == ["Incline press 70 × 8, slowed 31%, about 1 left"])
}
