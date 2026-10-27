import Foundation
import Testing
@testable import Setecho

/// The models decode exactly what the backend sends (fixtures saved from real Spark output on
/// synthetic inputs) and round-trip through the Store's files.
private final class FixtureAnchor {}

private func fixture(_ name: String) throws -> Data {
    let url = try #require(Bundle(for: FixtureAnchor.self).url(forResource: name, withExtension: "json"))
    return try Data(contentsOf: url)
}

@Test func programDecodesFromTheBackendFixture() throws {
    let program = try JSONCoding.decoder.decode(Program.self, from: fixture("program"))
    #expect(program.name.hasPrefix("Prep Block 2"))
    #expect(program.weeks.count == 2)
    let upper = program.weeks[0].days[0]
    #expect(upper.id == "w1_upper_a" && upper.name == "Upper A")
    let bench = upper.exercises[0]
    #expect(bench.summary == "4 × 8 · 185 lb · RPE 8")
    #expect(bench.restText == "Rest 2:30")
    #expect(upper.exercises[1].summary == "4 × 8–10 · 165 lb · RPE 8")
    #expect(program.flags.count == 4)
    #expect(Calendar.current.component(.year, from: program.importedAt) == 2026)
}

@Test func templateDecodesFromTheBackendFixture() throws {
    let template = try JSONCoding.decoder.decode(CheckInTemplate.self, from: fixture("template"))
    #expect(template.fields.count == 23)
    let first = template.orderedFields[0]
    #expect(first.id == "weeks_away_from_target_date")
    #expect(first.source == FieldSource(type: .calculated, key: .weeksToShow))
    #expect(first.source.howAnswered == "Data" && first.source.sourceName == "Settings")
    #expect(template.carriedBlocks.map(\.title) == ["Macro targets (until I change them):", "Supplements:"])
    #expect(template.voiceFieldCount == 11 && template.dataFieldCount == 11)
}

@Test func fieldSourceEncodesAsTypeAndKey() throws {
    let data = try JSONCoding.encoder.encode(FieldSource(type: .data, key: .avgDailySteps))
    #expect(String(decoding: data, as: UTF8.self).contains("\"key\" : \"avgDailySteps\""))
    let voice = try JSONCoding.decoder.decode(FieldSource.self, from: Data("{\"type\":\"voice\",\"key\":null}".utf8))
    #expect(voice == FieldSource(type: .voice, key: nil))
}

@Test @MainActor func storeRoundTripsThroughFiles() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("store-\(UUID().uuidString)")
    // The backend writes microseconds; files keep milliseconds. Normalize once so equality is exact.
    let fromBackend = try JSONCoding.decoder.decode(Program.self, from: fixture("program"))
    let program = try JSONCoding.decoder.decode(Program.self, from: JSONCoding.encoder.encode(fromBackend))
    #expect(abs(program.importedAt.timeIntervalSince(fromBackend.importedAt)) < 0.001)
    let template = try JSONCoding.decoder.decode(CheckInTemplate.self, from: fixture("template"))

    let store = Store(root: root)
    #expect(store.program == nil)
    store.saveProgram(program)
    store.saveTemplate(template)

    let reopened = Store(root: root)
    #expect(reopened.program == program)
    #expect(reopened.template == template)
    #expect(reopened.todayDay?.day.id == "w1_upper_a")
    #expect(reopened.loadError == nil)
}

@Test func dayKeyRoundTrip() {
    let cal = Calendar(identifier: .gregorian)
    let date = cal.date(from: DateComponents(year: 2026, month: 10, day: 5))!
    #expect(DayKey.string(date, calendar: cal) == "2026-10-05")
    #expect(DayKey.date("2026-10-05", calendar: cal) == date)
    #expect(DayKey.date("nope", calendar: cal) == nil)
}

@Test func weekFactsBuildRoundsAndDates() {
    let cal = Calendar(identifier: .gregorian)
    let start = cal.date(from: DateComponents(year: 2026, month: 10, day: 23))!
    let end = cal.date(from: DateComponents(year: 2026, month: 10, day: 24))!
    let week = HealthService.Week(
        days: [
            HealthService.DayReading(date: start, kcal: 2410.4, proteinG: 211.6, steps: 10412.0, sleepHours: 7.44, weighInLb: 181.23),
            HealthService.DayReading(date: end),
        ],
        sources: ["weight": "Withings"]
    )
    let targets = MacroTargets(training: Macros(kcal: 1, proteinG: 1, carbsG: 1, fatG: 1),
                               rest: Macros(kcal: 1, proteinG: 1, carbsG: 1, fatG: 1))
    let facts = WeekFacts.build(week: week, weekStart: start, weekEnd: end, targets: targets, sessions: [],
                                scheduledWeekdays: [6], showDate: "2027-01-23", lastCheckInWeightLb: 182, calendar: cal)
    #expect(facts.weekStart == "2026-10-23" && facts.weekEnd == "2026-10-24")
    #expect(facts.daily[0].kcal == 2410 && facts.daily[0].proteinG == 212 && facts.daily[0].sleepHours == 7.4)
    #expect(facts.daily[0].weighInLb == 181.2 && facts.daily[0].isTrainingDay) // Oct 23 2026 is a Friday (6)
    #expect(facts.daily[1].kcal == nil && !facts.daily[1].isTrainingDay)
    #expect(facts.sources["weight"] == "Withings")
}

@Test func loggedSetWithoutRepCountDecodesAsPlan() throws {
    let json = """
    {"id":"8E2B2C0E-5C4C-4C3B-9B1D-0D7B5B3D1A11","exerciseId":"bench","setIndex":0,"loadLb":225,"reps":8,"rpe":null,
     "startedAt":"2026-10-26T18:00:00.000Z","endedAt":"2026-10-26T18:00:30.000Z","clipFile":null,"edits":[]}
    """
    let set = try JSONCoding.decoder.decode(LoggedSet.self, from: Data(json.utf8))
    #expect(set.repCount == RepCount(source: .plan))
    #expect(set.repCount.status == .done && set.reps == 8)
    let data = try JSONCoding.encoder.encode(set)
    let back = try JSONCoding.decoder.decode(LoggedSet.self, from: data)
    #expect(back == set)
    #expect(String(decoding: data, as: UTF8.self).contains("\"source\" : \"plan\""))
}

@Test func plannedExerciseWithoutEquipmentInfersItFromTheName() throws {
    let program = try JSONCoding.decoder.decode(Program.self, from: fixture("program"))
    let upper = program.weeks[0].days[0]
    #expect(upper.exercises[0].equipment == .barbell)   // Bench press
    #expect(Equipment.infer(from: "Incline DB press") == .dumbbell)
    #expect(Equipment.infer(from: "Cable fly") == .cable)
    #expect(Equipment.infer(from: "Leg press") == .machine)
    #expect(Equipment.infer(from: "Weighted pull-up") == .bodyweight)
    #expect(Equipment.infer(from: "Lat pulldown") == .cable)
    let json = """
    {"id":"x","name":"Hack squat","sets":[],"equipment":"machine","restSeconds":null,"notes":null}
    """
    let ex = try JSONCoding.decoder.decode(PlannedExercise.self, from: Data(json.utf8))
    #expect(ex.equipment == .machine)
}
