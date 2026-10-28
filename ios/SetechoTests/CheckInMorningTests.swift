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
    draft.answers.append(FieldAnswer(fieldId: weight.id, text: "180.8", state: .filled,
                                     provenance: [Provenance(source: "Withings via Apple Health", detail: "180.8")]))
    #expect(flow.nextStep(draft: draft, photosTakenToday: false) == .weight)   // filled from Apple Health: offered first
    draft.answers[draft.answers.count - 1].state = .confirmed
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
    #expect(flow.prompt(for: [refeed], draft: draft) == "For your last refeed or cheat meal, I've got 10/24/26. Sound right?")
    #expect(CheckInMorningFlow.isYes("Yes.") && CheckInMorningFlow.isYes("yeah") && !CheckInMorningFlow.isYes("yes it was 180"))
    #expect(CheckInMorningFlow.isYes("Use that.") && CheckInMorningFlow.isYes("Sounds good"))   // the weight offer's own words
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

@Test @MainActor func aFreshRehearsalResetsWhatWasSpokenAndKeepsTheData() async throws {
    let store = makeStore()
    store.saveTemplate(try template())
    let flow = CheckInMorningFlow(template: try template())
    let weight = try #require(flow.weightField)
    let energy = try #require(flow.template.fields.first { $0.id.contains("energy") })
    let dataField = try #require(flow.template.fields.first { $0.source.type != .voice && $0.id != weight.id && $0.source.type != .photo })
    var spokenEnergy = answer(energy.id, "7/10")
    spokenEnergy.provenance = [Provenance(source: "You said · 2026-10-27", detail: "seven")]
    let fromData = FieldAnswer(fieldId: dataField.id, text: "2,340", state: .filled,
                               provenance: [Provenance(source: "Apple Health", detail: "the week")])
    store.upsert(checkIn: currentDraft(answers: [answer(weight.id, "180.8"), spokenEnergy, fromData]))
    let coordinator = CheckInCoordinator(store: store)
    coordinator.resetSpokenAnswers()
    let answers = try #require(coordinator.draft?.answers)
    #expect(answers.first { $0.fieldId == energy.id }?.state == .missing)
    #expect(answers.first { $0.fieldId == weight.id }?.state == .missing)
    #expect(answers.first { $0.fieldId == dataField.id }?.text == "2,340")
    #expect(coordinator.draft?.photoSetId == nil)
}

@Test func theDataIsReadBackOneFieldAtATime() throws {
    let flow = CheckInMorningFlow(template: try template())
    let steps = try #require(flow.template.fields.first { $0.source.key == .avgDailySteps })
    let training = try #require(flow.template.fields.first { $0.source.key == .trainingConsistency })
    let fromData = { (id: String, text: String) in
        FieldAnswer(fieldId: id, text: text, state: .filled, provenance: [Provenance(source: "Apple Health", detail: text)])
    }
    let draft = CheckInDraft(id: UUID(), weekStart: .now, weekEnd: .now,
                             answers: [fromData(steps.id, "9.4k"), fromData(training.id, "100%, 5 of 5 sessions")], photoSetId: nil, sentAt: nil)
    let items = flow.readBackFields(draft: draft)
    #expect(items.map(\.field.id) == flow.template.orderedFields.map(\.id).filter { $0 == steps.id || $0 == training.id })
    let first = CheckInMorningFlow.readBackPrompt(items[0].field, items[0].answer, index: 0, first: true)
    let second = CheckInMorningFlow.readBackPrompt(items[1].field, items[1].answer, index: 1, first: false)
    #expect(first == "Quick check on your data. Training consistency came in at 100%, 5 of 5 sessions. Sound right?")
    #expect(second == "Average daily steps came in at 9.4k. Look right?")   // a different tail each line
    #expect(SpokenText.spoken(second) == "Average daily steps came in at nine thousand four hundred. Look right?")
    #expect([first, second].allSatisfy { line in items.filter { line.contains($0.answer.text) }.count == 1 })   // one field per line
}

@Test func theQuestionsSoundAskedNotRead() throws {
    let fields = try template().orderedFields
    func ask(_ label: String) throws -> String { WrapUpModel.question(for: [try #require(fields.first { $0.label == label })]) }
    #expect(try ask("Energy levels") == "How were your energy levels this week, out of ten?")
    #expect(try ask("Notes on stress") == "How was your stress this week, out of ten?")
    #expect(try ask("Notes on recovery") == "How's your recovery been this week?")
    #expect(try ask("Biggest win this week") == "What was your biggest win this week?")
    #expect(try ask("Fasted blood glucose") == "What's your fasted blood glucose?")
    #expect(try ask("Additional notes or concerns") == "Anything else you want your coach to know?")
    #expect(try ask("Date of last refeed or cheat meal") == "When was your last refeed or cheat meal?")
    let tape = fields.filter { $0.kind == .measurement && $0.source.type == .voice }
    #expect(WrapUpModel.question(for: tape) == "What did the tape say for your waist, bicep and thigh?")
    #expect(SpokenText.words("I've got 10/24/26.") == "I've got October twenty fourth.")
    #expect(SpokenText.ordinal(1) == "first" && SpokenText.ordinal(22) == "twenty second" && SpokenText.ordinal(30) == "thirtieth")
}

@Test func theIntroductionNamesTheAthleteTheDayAndWhatIsComing() {
    #expect(CheckInMorningFlow.intro(firstName: "Zander", dueDay: "Thursday", isDueMorning: true)
            == "Morning, Zander. It's your Thursday check-in. We'll do your weight, glucose and photos, then your coach's questions.")
    #expect(CheckInMorningFlow.intro(firstName: " ", dueDay: "Thursday", isDueMorning: false)
            == "Morning. This is a practice run of your Thursday check-in. We'll do your weight, glucose and photos, then your coach's questions.")
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
    #expect(m.step == .weight && spoken.last == "Hop on the scale, and tell me when you're off.")
    // The introduction is spoken by start(), before the draft builds; its words come from the flow.
    #expect(m.intro.hasPrefix("Morning") && m.intro.contains("check-in"))
    // "Give me a couple of minutes": a pause keeps listening and asks nothing.
    await m.apply(turn(.pause, "give me a couple of minutes", reply: "No rush. Tell me when you're ready."))
    #expect(m.isPaused && m.isListening && spoken.last == "No rush. Tell me when you're ready.")
    // Any answer resumes and counts: one utterance answers two fields.
    await m.apply(turn(.answer, "180.8, and glucose was 91", answers: [answer(weight.id, "180.8"), answer(glucose.id, "91")], reply: "Weight 180.8 and glucose 91, got it."))
    #expect(!m.isPaused)
    #expect(fresh.answer(for: weight)?.text == "180.8" && fresh.answer(for: glucose)?.text == "91")
    #expect(store.checkIns.first?.answers.count == 2)   // saved after the answer
    #expect(m.step == .photos && m.question == "Time for photos. Set up the tripod, and tell me when you're ready.")
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
    await m.apply(turn(.forCoach, "should I bump my carbs", answers: [answer(notes.id, "Should I bump my carbs?")], reply: "That's a good one for your coach. Want me to add it to your notes?"))
    #expect(m.pendingForCoach == "Should I bump my carbs?" && spoken.last == "That's a good one for your coach. Want me to add it to your notes?")
    await m.apply(turn(.chitchat, "yes", reply: "Sure."))
    #expect(fresh.answer(for: notes)?.text == "Should I bump my carbs?" && m.pendingForCoach == nil)
    // Back to the question that was being asked, plainly: the run's opener ("Now, your coach's
    // questions.") is not said twice.
    #expect(first.hasSuffix(m.question) && m.question.hasSuffix("?"))
    // "Say that again" repeats it; "skip" moves on.
    let plain = m.question
    await m.apply(turn(.repeat_, "say that again"))
    #expect(m.question == plain)
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

@Test func shortRepliesAreReadTheWayPeopleSayThem() {
    for said in ["Let's keep that.", "Sounds good to me", "yeah that works for me", "go with it", "Yep, keep it.", "I think so, yeah", "perfect"] {
        #expect(SpokenReply.read(said, offered: true) == .keep, "\(said)")
    }
    for said in ["Nah, that's off.", "that's not right", "nope", "change it", "not quite"] {
        #expect(SpokenReply.read(said, offered: true) == .decline, "\(said)")
    }
    for said in ["Hang on, let me check.", "one sec", "give me two minutes", "okay, hold on", "not yet"] {
        #expect(SpokenReply.read(said, offered: false) == .hold, "\(said)")
    }
    #expect(SpokenReply.read("Umm... hmm.", offered: false) == .thinking)
    // A new value, a "but", a yes and a no together, or not knowing: Spark's to read, with the offer.
    for said in ["no, it was 180.6", "sounds good but it's 181", "no, that's right", "keep it at one eighty one", "no idea", "wait, no", "hang on, it's 180"] {
        #expect(SpokenReply.read(said, offered: true) == nil, "\(said)")
    }
    // With nothing offered, "sounds good" is not a yes to anything.
    #expect(SpokenReply.read("sounds good", offered: false) == nil)
}

/// A morning where the only question left is a drafted answer: what's offered is that answer.
@MainActor private func draftedMorning() throws -> (CheckInMorningModel, CheckInCoordinator, FieldSpec, () -> String?) {
    let store = makeStore()
    let template = try template()
    store.saveTemplate(template)
    let refeed = try #require(template.fields.first { $0.id.contains("refeed") })
    let answers = template.fields.map { $0.id == refeed.id ? answer($0.id, "10/24/26", state: .drafted) : answer($0.id, "x") }
    store.upsert(photoSet: PhotoSet(id: UUID(), takenAt: .now, poses: [], collageFile: "c.jpg"))
    store.upsert(checkIn: currentDraft(answers: answers))
    let coordinator = CheckInCoordinator(store: store)
    nonisolated(unsafe) var spoken: [String] = []
    let m = CheckInMorningModel(coordinator: coordinator, store: store, speak: { spoken.append($0) })
    return (m, coordinator, refeed, { spoken.last })
}

@Test @MainActor func aDraftedAnswerIsKeptOnALetsKeepThatEvenAfterAWait() async throws {
    let (m, coordinator, refeed, lastSpoken) = try draftedMorning()
    await m.resume()
    #expect(m.step == .questions && m.offer == .drafted(fieldId: refeed.id))
    #expect(m.context().offered?.contains("10/24/26") == true)   // Spark sees what's on offer
    // "Hang on, let me check": a wait, and the offer stays open.
    await m.apply(turn(.pause, "Hang on, let me check.", reply: "Take your time."))
    #expect(m.isPaused && lastSpoken() == "Take your time." && coordinator.answer(for: refeed)?.state == .drafted)
    #expect(m.offer == .drafted(fieldId: refeed.id))
    // "Um": thinking out loud, nothing said back.
    await m.apply(turn(.chitchat, "um"))
    #expect(lastSpoken() == "Take your time." && m.isListening)
    // "Sounds good to me": kept, and the wait is over.
    await m.apply(turn(.keep, "Sounds good to me"))
    #expect(coordinator.answer(for: refeed)?.state == .confirmed && coordinator.answer(for: refeed)?.text == "10/24/26" && !m.isPaused)
}

@Test @MainActor func aDraftedAnswerIsChangedOnANoOrANewValue() async throws {
    let (m, coordinator, refeed, lastSpoken) = try draftedMorning()
    await m.resume()
    // A no with no new value asks for one.
    await m.apply(turn(.decline, "nah, that's off"))
    #expect(lastSpoken() == "What should it say?" && coordinator.answer(for: refeed)?.state == .drafted)
    // A new value replaces it.
    await m.apply(turn(.answer, "it was the twenty sixth", answers: [answer(refeed.id, "10/26/26")], reply: "Okay, the 26th."))
    #expect(coordinator.answer(for: refeed)?.text == "10/26/26" && coordinator.answer(for: refeed)?.state == .filled)
}

@Test func aTurnCarriesItsChangeFieldAndAnUnknownIntentIsUnclear() throws {
    let json = #"{"transcript":"let me change energy","intent":"change","answers":[],"reply":"Sure.","confidence":0.9,"changeFieldId":"energy_levels","unclearReason":null}"#
    let r = try JSONCoding.decoder.decode(TurnResponse.self, from: Data(json.utf8))
    #expect(r.intent == .change && r.changeFieldId == "energy_levels")
    let future = #"{"transcript":"x","intent":"somethingNew","answers":[],"reply":"","confidence":0.5}"#
    #expect(try JSONCoding.decoder.decode(TurnResponse.self, from: Data(future.utf8)).intent == .unclear)
}

/// The coach's questions follow each other the way a person asks them: the first opens the run,
/// the ones between join on with "and", the last says so, and a question asked again is plain.
@Test func theQuestionsFollowEachOtherLikeAConversation() {
    #expect(CheckInMorningFlow.bridged("What was your biggest win this week?", index: 0, count: 4) == "Now, your coach's questions. What was your biggest win this week?")
    #expect(CheckInMorningFlow.bridged("How's your recovery been this week?", index: 1, count: 4) == "And how's your recovery been this week?")
    #expect(CheckInMorningFlow.bridged("For your last refeed or cheat meal, I've got 10/24/26. Sound right?", index: 2, count: 4)
            == "And for your last refeed or cheat meal, I've got 10/24/26. Sound right?")
    #expect(CheckInMorningFlow.bridged("Anything else you want your coach to know?", index: 3, count: 4) == "Last one. Anything else you want your coach to know?")
    // A line that doesn't start like a question is left as it is, and a lone question has nothing to join.
    #expect(CheckInMorningFlow.bridged("Anything else you want your coach to know?", index: 1, count: 3) == "Anything else you want your coach to know?")
    #expect(CheckInMorningFlow.bridged("How's your sleep been this week?", index: 0, count: 1) == "How's your sleep been this week?")
}

/// Every line said and every answer stored lands in the conversation on screen, an acknowledgment
/// goes out in the same breath as the next question, and "skip" on the photos moves on without them.
@Test @MainActor func theConversationOnScreenKeepsEveryLineAndAnswer() async throws {
    let store = makeStore()
    store.saveTemplate(try template())
    let flow = CheckInMorningFlow(template: try template())
    let weight = try #require(flow.weightField)
    let glucose = try #require(flow.glucoseField)
    store.upsert(checkIn: currentDraft(answers: []))
    let coordinator = CheckInCoordinator(store: store)
    nonisolated(unsafe) var spoken: [String] = []
    let m = CheckInMorningModel(coordinator: coordinator, store: store, speak: { spoken.append($0) })
    await m.resume(opening: true)
    #expect(m.transcript.last?.kind == .setecho && m.transcript.last?.text == CheckInMorningModel.scaleLine)
    #expect(m.phase == .listening)
    // One utterance, two answers: his words, then one card per answer, then the acknowledgment and
    // the next line as two entries on screen but one utterance out loud.
    await m.apply(turn(.answer, "180.8, and glucose was 91", answers: [answer(weight.id, "180.8"), answer(glucose.id, "91")], reply: "Weight 180.8 and glucose 91, got it."))
    let kinds = m.transcript.suffix(5).map(\.kind)
    #expect(kinds[0] == .athlete && m.transcript.suffix(5).first?.text == "180.8, and glucose was 91")
    #expect(kinds[1] == .answer(label: "Current body weight", value: "180.8", source: "You said · 2026-10-29"))
    #expect(kinds[2] == .answer(label: "Fasted blood glucose", value: "91", source: "You said · 2026-10-29"))
    #expect(kinds[3] == .setecho && kinds[4] == .setecho)
    #expect(m.transcript.last?.text == CheckInMorningModel.photosLine && m.question == CheckInMorningModel.photosLine)
    #expect(spoken.last == "Got it, weight 180.8 and glucose 91. " + CheckInMorningModel.photosLine)
    // "Skip" on the photos: left for later, and the coach's questions open.
    await m.apply(turn(.skip, "skip"))
    #expect(m.step == .questions && m.question.hasPrefix("Now, your coach's questions. "))
    #expect(spoken.last?.hasPrefix("Okay, we'll leave the photos for later. Now, your coach's questions. ") == true)
    #expect(coordinator.answer(for: try #require(flow.template.fields.first { $0.source.type == .photo })) == nil)
    // The next question joins on; "say that again" asks it plainly.
    let first = m.question
    await m.apply(turn(.skip, "skip"))
    #expect(m.question.hasPrefix("And ") || m.question.hasPrefix("Last one. "))
    #expect(m.question != first)
    await m.apply(turn(.repeat_, "say that again"))
    #expect(!m.question.hasPrefix("And ") && !m.question.hasPrefix("Now, "))
}
