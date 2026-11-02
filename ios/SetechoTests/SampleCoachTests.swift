import Foundation
import Testing
@testable import Setecho

// Sample coach mode (HANDOFF.md §7, Sample coach): the seed, the store swap, and the synthetic Health week.

private func temporaryRoot(_ name: String) -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
}

@MainActor
@Test func theSeedIsAWholeWeekOnATrainingDay() throws {
    let root = temporaryRoot("sample-seed")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = Store(root: root)
    // A Sunday afternoon: a rest day in the cycle, and the judge still gets "Start session".
    let now = try #require(Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: 8, hour: 15)))
    try SampleCoach.seed(into: store, now: now)

    let today = try #require(store.todayDay)
    #expect(!today.day.isRest)
    #expect(store.currentTemplate != nil)
    #expect(store.plan?.rules.isEmpty == false)
    let twoWeeksAgo = Calendar.current.date(byAdding: .day, value: -14, to: now)!
    #expect(store.sessions.count >= 8)
    #expect(store.sessions.allSatisfy { $0.startedAt > twoWeeksAgo && $0.startedAt < now && !$0.sets.isEmpty })
    #expect(store.checkIns.filter { !$0.isSent }.count == 1)
    #expect(store.checkIns.filter(\.isSent).count == 1)
    #expect(store.lastSentCheckIn.map { Calendar.current.dateComponents([.day], from: $0.sentAt!, to: now).day! } == 7)
    #expect(store.pendingReply?.changes.count == 3)
    #expect(store.photoSets.count == 2)
    for set in store.photoSets {
        for photo in set.poses { #expect(FileManager.default.fileExists(atPath: store.mediaDirectory.appendingPathComponent(photo.file).path)) }
    }
    // It all survives a relaunch of the same folder.
    let reopened = Store(root: root)
    #expect(reopened.pendingReply != nil && reopened.sessions.count == store.sessions.count)
}

@MainActor
@Test func enteringAndLeavingTheSampleNeverTouchesTheRealStore() throws {
    let realRoot = temporaryRoot("sample-real"), sampleRoot = temporaryRoot("sample-sample")
    defer { try? FileManager.default.removeItem(at: realRoot); try? FileManager.default.removeItem(at: sampleRoot) }
    let suite = "sample-settings-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let settings = Settings(defaults: defaults)
    settings.athleteFirstName = "Zander"
    settings.cardioProtocol = "his cardio"
    settings.trainingWeekdays = [2, 4, 6]
    settings.showDate = ""
    settings.rehearsalMode = false

    // His own store has one session in it.
    let real = Store(root: realRoot)
    let at = Date(timeIntervalSince1970: 1_800_000_000)
    real.upsert(session: Session(id: UUID(), programDayId: nil, startedAt: at, endedAt: at.addingTimeInterval(60), sets: [], notes: [], addOnIds: []))
    let before = try FileManager.default.contentsOfDirectory(atPath: realRoot.path).sorted()
    let bytesBefore = try Data(contentsOf: realRoot.appendingPathComponent("sessions.json"))

    let holder = StoreHolder(realRoot: realRoot, sampleRoot: sampleRoot, settings: settings)
    #expect(holder.store.root == realRoot)
    try holder.enterSample()
    #expect(settings.sampleMode && holder.isSample)
    #expect(holder.store.root == sampleRoot)
    #expect(holder.store.pendingReply != nil)
    #expect(settings.athleteFirstName == "Alex" && settings.rehearsalMode && settings.trainingWeekdays == [2, 3, 4, 6, 7])
    #expect(!settings.showDate.isEmpty)
    // Something happens in the sample.
    holder.store.clearMacroFactorReminders()
    holder.store.upsert(session: Session(id: UUID(), programDayId: nil, startedAt: .now, endedAt: nil, sets: [], notes: [], addOnIds: []))

    holder.leaveSample()
    #expect(!settings.sampleMode)
    #expect(holder.store.root == realRoot)
    #expect(holder.store.sessions.count == 1)
    #expect(try FileManager.default.contentsOfDirectory(atPath: realRoot.path).sorted() == before)
    #expect(try Data(contentsOf: realRoot.appendingPathComponent("sessions.json")) == bytesBefore)
    #expect(settings.athleteFirstName == "Zander" && settings.cardioProtocol == "his cardio" && settings.trainingWeekdays == [2, 4, 6])
    #expect(settings.showDate.isEmpty && !settings.rehearsalMode && settings.settingsBeforeSample == nil)
    #expect(!FileManager.default.fileExists(atPath: sampleRoot.path))

    // A relaunch while the sample is on opens the sample's folder.
    try holder.enterSample()
    let relaunched = StoreHolder(realRoot: realRoot, sampleRoot: sampleRoot, settings: Settings(defaults: defaults))
    #expect(relaunched.store.root == sampleRoot)
    relaunched.leaveSample()
}

/// The seed writes the sample's cardio protocol into `Settings.shared` (through `Store.saveTemplate`), so
/// the backup has to be taken first, or leaving the sample hands his cardio back as the sample's.
@MainActor
@Test func hisCardioProtocolComesBackAfterTheSample() throws {
    let realRoot = temporaryRoot("sample-real-shared"), sampleRoot = temporaryRoot("sample-sample-shared")
    defer { try? FileManager.default.removeItem(at: realRoot); try? FileManager.default.removeItem(at: sampleRoot) }
    let shared = Settings.shared
    let before = (shared.cardioProtocol, shared.athleteFirstName, shared.sampleMode, shared.settingsBeforeSample)
    defer {
        shared.cardioProtocol = before.0; shared.athleteFirstName = before.1
        shared.sampleMode = before.2; shared.settingsBeforeSample = before.3
    }
    shared.cardioProtocol = "25 min LISS × 2 on rest days, his words"
    shared.settingsBeforeSample = nil

    let holder = StoreHolder(realRoot: realRoot, sampleRoot: sampleRoot, settings: shared)
    try holder.enterSample()
    #expect(shared.cardioProtocol == SampleCoach.cardioProtocol)
    holder.leaveSample()
    #expect(shared.cardioProtocol == "25 min LISS × 2 on rest days, his words")
}

@MainActor
@Test func theSyntheticHealthWeekFillsTheFacts() throws {
    let calendar = Calendar.current
    let end = try #require(calendar.date(from: DateComponents(year: 2026, month: 11, day: 5, hour: 8)))
    let start = calendar.date(byAdding: .day, value: -7, to: calendar.startOfDay(for: end))!
    let week = SampleCoach.healthWeek(from: start, to: end)
    #expect(week.days.count == 8)
    #expect(week.sources["weight"] == "Withings" && week.sources["steps"] == "iPhone")

    let targets = MacroTargets(training: Macros(kcal: 2400, proteinG: 200, carbsG: 250, fatG: 65), rest: Macros(kcal: 2100, proteinG: 200, carbsG: 175, fatG: 65))
    let facts = WeekFacts.build(week: week, weekStart: start, weekEnd: end, targets: targets, sessions: [],
                                scheduledWeekdays: SampleCoach.trainingWeekdays, showDate: "2027-03-20", lastCheckInWeightLb: 181.6, now: end)
    let completed = facts.daily.dropLast()
    #expect(completed.allSatisfy { $0.weighInLb != nil && $0.kcal != nil && $0.steps != nil && $0.sleepHours != nil })
    let meanSteps = completed.compactMap(\.steps).reduce(0, +) / Double(completed.count)
    #expect(abs(meanSteps - 9842) < 1)
    let meanWeight = completed.compactMap(\.weighInLb).reduce(0, +) / Double(completed.count)
    #expect(abs(meanWeight - 180.8) < 0.01)
    #expect(completed.contains { $0.liss.contains { $0.type == "walking" && $0.minutes == 25 } })
    #expect(facts.lastCheckInWeightLb == 181.6)
}

@MainActor
@Test func theExampleReplyIsOneLoadChangeAndOneSwap() {
    #expect(SampleCoach.exampleReply.contains("hack squat") && SampleCoach.exampleReply.contains("Swap"))
}

@MainActor
@Test func aBudgetAnswerIsOverBudgetAndTheNoticeComesOnce() {
    #expect(APIError(status: 429, message: "budget").isOverBudget)
    #expect(!APIError(status: 429, message: "transcribe failed").isOverBudget)
    #expect(!APIError(status: 422, message: "budget").isOverBudget)
    #expect(DemoBudget.noticeOnce() == DemoBudget.line)
    #expect(DemoBudget.noticeOnce() == nil)
}
