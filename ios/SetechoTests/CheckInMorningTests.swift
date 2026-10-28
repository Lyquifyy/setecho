import Foundation
import Testing
@testable import Setecho

/// Check-in morning (HANDOFF.md §7): the step order, resuming after a relaunch, a pause, a
/// two-field answer, a correction and a question for the coach, with every number taken from the
/// transcript by the backend's validator (tested there) and every answer saved after each turn.
private final class Anchor {}

private func template() throws -> CheckInTemplate {
    let url = try #require(Bundle(for: Anchor.self).url(forResource: "template", withExtension: "json"))
    return try JSONCoding.decoder.decode(CheckInTemplate.self, from: Data(contentsOf: url))
}

@MainActor private func makeStore() -> Store {
    Store(root: FileManager.default.temporaryDirectory.appendingPathComponent("morning-\(UUID().uuidString)"))
}

/// The current period's draft, as the coordinator finds it: ending the day before the next due day.
@MainActor private func currentDraft(answers: [FieldAnswer]) -> CheckInDraft {
    let schedule = CheckInSchedule()
    let week = schedule.week(endingBefore: schedule.nextDue(from: .now))
    return CheckInDraft(id: UUID(), weekStart: week.start, weekEnd: week.end, answers: answers, photoSetId: nil, sentAt: nil)
}

private func answer(_ id: String, _ text: String, state: AnswerState = .filled) -> FieldAnswer {
    FieldAnswer(fieldId: id, text: text, state: state, provenance: [Provenance(source: "You said · 2026-10-29", detail: text)])
}

private func turn(_ intent: TurnIntent, _ transcript: String, answers: [FieldAnswer] = [], reply: String = "") -> TurnResponse {
    TurnResponse(transcript: transcript, intent: intent, answers: answers, reply: reply, confidence: 0.9)
}

@Test func stepsRunWeightGlucosePhotosQuestionsReview() throws {
    let flow = CheckInMorningFlow(template: try template())
    let weight = try #require(flow.weightField)
    let glucose = try #require(flow.glucoseField)
    #expect(weight.id.contains("weight") && glucose.label.lowercased().contains("glucose"))
    var draft = CheckInDraft(id: UUID(), weekStart: .now, weekEnd: .now, answers: [], photoSetId: nil, sentAt: nil)
    #expect(flow.nextStep(draft: draft, photosTakenToday: false) == .weight)
    draft.answers.append(answer(weight.id, "180.8"))
    #expect(flow.nextStep(draft: draft, photosTakenToday: false) == .glucose)
    draft.answers.append(answer(glucose.id, "91"))
    #expect(flow.nextStep(draft: draft, photosTakenToday: false) == .photos)
    #expect(flow.nextStep(draft: draft, photosTakenToday: true) == .questions)
    // The coach's questions never include weight, glucose or the photos, and the tape measurements are one.
    let groups = flow.questionGroups(draft: draft)
    #expect(!groups.flatMap { $0 }.contains { $0.id == weight.id || $0.id == glucose.id || $0.source.type == .photo })
    #expect(groups.last?.count == 3 && groups.last?.allSatisfy { $0.kind == .measurement } == true)
    for group in groups { for field in group { draft.answers.append(answer(field.id, "x")) } }
    #expect(flow.nextStep(draft: draft, photosTakenToday: true) == .review)
}

@Test func aDraftedFieldIsReadBackAndADraftedWeightStillAsks() throws {
    let flow = CheckInMorningFlow(template: try template())
    let weight = try #require(flow.weightField)
    let refeed = try #require(flow.template.fields.first { $0.id.contains("refeed") })
    let draft = CheckInDraft(id: UUID(), weekStart: .now, weekEnd: .now, answers: [answer(refeed.id, "10/24/26", state: .drafted), answer(weight.id, "180.8", state: .drafted)], photoSetId: nil, sentAt: nil)
    #expect(flow.nextStep(draft: draft, photosTakenToday: true) == .weight)   // drafted is not answered
    #expect(flow.prompt(for: [refeed], draft: draft) == "Date of last refeed or cheat meal, 10/24/26?")
    #expect(CheckInMorningFlow.isYes("Yes.") && CheckInMorningFlow.isYes("yeah") && !CheckInMorningFlow.isYes("yes it was 180"))
    #expect(CheckInMorningFlow.isNo("Nope") && !CheckInMorningFlow.isNo("no idea"))
}

@Test func theMorningStartsItselfOnceOnTheDueMorningBeforeTheGuard() {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "America/Chicago")!
    let thursday = cal.date(from: DateComponents(year: 2026, month: 10, day: 29, hour: 6, minute: 45))!
    let weekly = CheckInSchedule(dueWeekday: 5, everyWeeks: 1, dueBy: "09:00", lastSentAt: nil)
    #expect(MorningStart.shouldStart(schedule: weekly, lastSentAt: nil, lastStartedDay: "", now: thursday, calendar: cal))
    #expect(!MorningStart.shouldStart(schedule: weekly, lastSentAt: nil, lastStartedDay: "2026-10-29", now: thursday, calendar: cal))
    #expect(!MorningStart.shouldStart(schedule: weekly, lastSentAt: thursday, lastStartedDay: "", now: thursday, calendar: cal))
    let wednesday = cal.date(byAdding: .day, value: -1, to: thursday)!
    #expect(!MorningStart.shouldStart(schedule: weekly, lastSentAt: nil, lastStartedDay: "", now: wednesday, calendar: cal))
    let late = cal.date(bySettingHour: 8, minute: 45, second: 0, of: thursday)!
    #expect(!MorningStart.shouldStart(schedule: weekly, lastSentAt: nil, lastStartedDay: "", now: late, calendar: cal))
}

@Test func theIntroductionNamesTheAthleteTheDayAndWhatIsComing() {
    #expect(CheckInMorningFlow.intro(firstName: "Zander", dueDay: "Thursday", isDueMorning: true)
            == "Morning, Zander. Your Thursday check-in: weight, glucose, four photos, then the coach's questions.")
    #expect(CheckInMorningFlow.intro(firstName: " ", dueDay: "Thursday", isDueMorning: false)
            == "Morning. A rehearsal of your Thursday check-in: weight, glucose, four photos, then the coach's questions.")
}

@Test @MainActor func aScriptedMorningSavesEveryAnswerAndPicksTheNextQuestionItself() async throws {
    let store = makeStore()
    store.saveTemplate(try template())
    let coordinator = CheckInCoordinator(store: store)
    var spoken: [String] = []
    let model = CheckInMorningModel(coordinator: coordinator, store: store, speak: { spoken.append($0) })
    let flow = model.flow
    let weight = try #require(flow.weightField)
    let glucose = try #require(flow.glucoseField)
    // A draft to fill, as the coordinator would build it.
    store.upsert(checkIn: currentDraft(answers: []))
    let fresh = CheckInCoordinator(store: store)
    let m = CheckInMorningModel(coordinator: fresh, store: store, speak: { spoken.append($0) })
    await m.resume(opening: true)
    #expect(m.step == .weight && spoken.last == "Step on the scale, and tell me when you're off.")
    // The introduction is spoken by start(), before the draft builds; its words come from the flow.
    #expect(m.intro.hasPrefix("Morning") && m.intro.contains("check-in"))
    // "Give me a couple of minutes": a pause keeps listening and asks nothing.
    await m.apply(turn(.pause, "give me a couple of minutes", reply: "No worries, just tell me whenever you're ready."))
    #expect(m.isPaused && m.isListening && spoken.last == "No worries, just tell me whenever you're ready.")
    // Any answer resumes and counts: one utterance answers two fields.
    await m.apply(turn(.answer, "180.8, and glucose was 91", answers: [answer(weight.id, "180.8"), answer(glucose.id, "91")], reply: "Weight 180.8 and glucose 91, got it."))
    #expect(!m.isPaused)
    #expect(fresh.answer(for: weight)?.text == "180.8" && fresh.answer(for: glucose)?.text == "91")
    #expect(store.checkIns.first?.answers.count == 2)   // saved after the answer
    #expect(m.step == .photos && m.question == "Set up your tripod for photos, and tell me when you're ready.")
    // A correction names a field already answered and stays on the current question.
    await m.apply(turn(.correction, "wait, it was 180.6", answers: [answer(weight.id, "180.6")], reply: "Changed to 180.6."))
    #expect(fresh.answer(for: weight)?.text == "180.6" && m.step == .photos && m.echo?.contains("180.6") == true)
    // "Ready" on the photos step opens the photo session.
    await m.apply(turn(.ready, "ready"))
    #expect(m.showPhotos)
    // Back from the photos with none taken today: the questions carry on anyway once asked again.
    m.showPhotos = false
    await m.photosFinished()
    #expect(m.step == .photos)   // nothing taken: still the photos step
}

@Test @MainActor func questionsForTheCoachLandInTheNotesOnAYes() async throws {
    let store = makeStore()
    store.saveTemplate(try template())
    let coordinator = CheckInCoordinator(store: store)
    let flow = CheckInMorningFlow(template: try template())
    let weight = try #require(flow.weightField)
    let glucose = try #require(flow.glucoseField)
    let notes = try #require(flow.notesField)
    let set = PhotoSet(id: UUID(), takenAt: .now, poses: [], collageFile: "c.jpg")
    store.upsert(photoSet: set)
    store.upsert(checkIn: currentDraft(answers: [answer(weight.id, "180.8"), answer(glucose.id, "91")]))
    let fresh = CheckInCoordinator(store: store)
    var spoken: [String] = []
    let m = CheckInMorningModel(coordinator: fresh, store: store, speak: { spoken.append($0) })
    _ = coordinator
    await m.resume()
    #expect(m.step == .questions && m.question.hasSuffix("?"))
    let first = m.question
    await m.apply(turn(.forCoach, "should I bump my carbs", answers: [answer(notes.id, "Should I bump my carbs?")], reply: "That's one for your coach. Want me to add it to your notes?"))
    #expect(m.pendingForCoach == "Should I bump my carbs?" && spoken.last == "That's one for your coach. Want me to add it to your notes?")
    await m.apply(turn(.chitchat, "yes", reply: "Sure."))
    #expect(fresh.answer(for: notes)?.text == "Should I bump my carbs?" && m.pendingForCoach == nil)
    #expect(m.question == first)   // back to the question that was being asked
    // "Say that again" repeats it; "skip" moves on.
    await m.apply(turn(.repeat_, "say that again"))
    #expect(m.question == first)
    await m.apply(turn(.skip, "skip"))
    #expect(m.question != first)
}

@Test func theCheckInCadenceComesFromHisConfirmedRule() throws {
    let cal = Calendar(identifier: .gregorian)
    func date(_ day: Int, month: Int = 10) -> Date { cal.date(from: DateComponents(year: 2026, month: month, day: day, hour: 9))! }
    // Every other week, Thursday, with the last check-in sent Thu Oct 15: the next is Thu Oct 29, not Oct 22.
    let fortnight = CheckInSchedule(dueWeekday: 5, everyWeeks: 2, dueBy: "09:00", lastSentAt: date(15))
    #expect(fortnight.nextDue(from: date(19), calendar: cal) == cal.startOfDay(for: date(29)))
    let period = fortnight.week(endingBefore: date(29), calendar: cal)
    #expect(period.start == cal.startOfDay(for: date(15)) && period.end == cal.startOfDay(for: date(29)))
    #expect(cal.dateComponents([.day], from: period.start, to: period.end).day == 14)
    #expect(fortnight.isCheckInMorning(on: date(29), calendar: cal) && !fortnight.isCheckInMorning(on: date(28), calendar: cal))
    #expect(fortnight.deadline(on: date(29), calendar: cal) == date(29))
    // No check-in sent yet: a full cadence of days.
    let none = CheckInSchedule(dueWeekday: 5, everyWeeks: 2)
    let p2 = none.week(endingBefore: date(29), calendar: cal)
    #expect(cal.dateComponents([.day], from: p2.start, to: p2.end).day == 14)
    // Weekly stays as it was.
    let weekly = CheckInSchedule()
    #expect(cal.dateComponents([.day], from: weekly.week(endingBefore: date(29), calendar: cal).start, to: date(29, month: 10)).day == 7)
    // From the plan: unconfirmed means the default.
    let program = Program(name: "p", weeks: [], importedAt: .now, flags: [])
    var plan = PlanState(version: 1, program: program, targets: .zero, cardioProtocol: "", carriedBlocks: [], replyId: nil)
    plan.checkInSchedule = CheckInCadence(everyWeeks: 2, weekday: 2, dueBy: "08:00", timeZone: "America/Chicago", quote: nil, confirmed: false)
    #expect(CheckInSchedule(plan: plan) == CheckInSchedule())
    plan.checkInSchedule?.confirmed = true
    // Weekly, whatever the email said: only his due day and deadline are taken.
    #expect(CheckInSchedule(plan: plan).dueWeekday == 2 && CheckInSchedule(plan: plan).everyWeeks == 1 && CheckInSchedule(plan: plan).dueBy == "08:00")
    #expect(fortnight.reminderTime(before: date(29), calendar: cal) == cal.date(from: DateComponents(year: 2026, month: 10, day: 28, hour: 19)))
}
