import Foundation
import Testing
@testable import Setecho

/// Each change kind's apply logic, the carried-block edit rule, revert, and the PlanState migration.
private func set(_ reps: Int?, _ load: Double?, min: Int? = nil, max: Int? = nil) -> PlannedSet {
    PlannedSet(reps: reps, repsMin: min, repsMax: max, loadLb: load, rpe: nil, rir: nil)
}

private func makePlan() -> PlanState {
    let bench = PlannedExercise(id: "w1_upper_a_bench_press", name: "Bench press", sets: [set(8, 185), set(8, 185), set(8, 185)], restSeconds: 150, notes: nil)
    let row = PlannedExercise(id: "w1_upper_a_barbell_row", name: "Barbell row", sets: [set(nil, 165, min: 8, max: 10), set(nil, 165, min: 8, max: 10)], restSeconds: 120, notes: nil)
    let bench2 = PlannedExercise(id: "w2_upper_a_bench_press", name: "Bench press", sets: [set(8, 190), set(8, 190), set(8, 190)], restSeconds: 150, notes: nil)
    let program = Program(name: "Block", weeks: [
        ProgramWeek(number: 1, days: [ProgramDay(id: "w1_upper_a", name: "Upper A", exercises: [bench, row])]),
        ProgramWeek(number: 2, days: [ProgramDay(id: "w2_upper_a", name: "Upper A", exercises: [bench2])]),
    ], importedAt: .now, flags: [])
    let blocks = [
        CarriedBlock(title: "Nutrition:", text: "On Training Days:\n Calories - 2400\n Protein – 200g\n Carbohydrate – 250g\n Fats – 65g\n\nOn Non-Training Days:\nCalories – 2100\nProtein – 200g\nCarbohydrate – 175g\nFats – 65g"),
        CarriedBlock(title: "Current Supplements:", text: "-  Whey isolate\n-  Creatine Monohydrate - 5g daily\n-  Omega 3 - 2 softgels daily"),
    ]
    return PlanState(version: 1, program: program,
                     targets: MacroTargets(training: Macros(kcal: 2400, proteinG: 200, carbsG: 250, fatG: 65), rest: Macros(kcal: 2100, proteinG: 200, carbsG: 175, fatG: 65)),
                     cardioProtocol: "25 min LISS × 2", carriedBlocks: blocks, replyId: nil)
}

private func change(_ kind: ChangeKind, _ path: String, _ op: ChangeOp, before: String?, after: String?, label: String = "x", from: String? = nil, approved: Bool = true) -> PlanChange {
    PlanChange(id: UUID().uuidString, kind: kind, path: path, label: label, op: op, amount: nil, before: before, after: after, quote: "q", appliesFrom: from, approved: approved)
}

@Test func macroChangeUpdatesTargetsBlockTextAndRemindsAboutMacroFactor() {
    let plan = makePlan()
    let result = PlanApplier.apply([change(.macroTarget, "targets.training.carbsG", .decrease, before: "250 g", after: "225 g", label: "Training-day carbs")], to: plan, replyId: UUID())
    #expect(result.plan.version == 2 && result.plan.targets.training.carbsG == 225 && result.plan.targets.rest.carbsG == 175)
    #expect(result.plan.carriedBlocks[0].text.contains("Carbohydrate – 225g"))
    #expect(result.plan.carriedBlocks[0].text.contains("Carbohydrate – 175g"))   // the rest-day line is untouched
    #expect(result.blocksNeedingHandEdit.isEmpty)
    #expect(result.macroFactorReminders == ["Update MacroFactor: training-day carbs 250 → 225 g"])
}

@Test func restDayMacroEditsTheRightLine() {
    let plan = makePlan()
    let result = PlanApplier.apply([change(.macroTarget, "targets.rest.kcal", .set, before: "2100 kcal", after: "2000 kcal", label: "Rest-day calories")], to: plan, replyId: UUID())
    #expect(result.plan.targets.rest.kcal == 2000 && result.plan.targets.training.kcal == 2400)
    #expect(result.plan.carriedBlocks[0].text.contains("Calories – 2000") && result.plan.carriedBlocks[0].text.contains("Calories - 2400"))
}

@Test func ambiguousBlockLineIsLeftForAHandEdit() {
    var plan = makePlan()
    plan.carriedBlocks[0].text = "Training days: protein 200 and 200 more"   // 200 appears twice on the line
    let result = PlanApplier.apply([change(.macroTarget, "targets.training.proteinG", .set, before: "200 g", after: "210 g", label: "Training-day protein")], to: plan, replyId: UUID())
    #expect(result.plan.targets.training.proteinG == 210)
    #expect(result.blocksNeedingHandEdit == ["Nutrition:"])
    #expect(plan.carriedBlocks[0].text == result.plan.carriedBlocks[0].text)
}

@Test func unapprovedChangesAreSkipped() {
    let plan = makePlan()
    let result = PlanApplier.apply([change(.macroTarget, "targets.training.carbsG", .decrease, before: "250 g", after: "225 g", approved: false)], to: plan, replyId: UUID())
    #expect(result.plan.targets == plan.targets && result.macroFactorReminders.isEmpty && result.plan.version == 2)
}

@Test func cardioReplacesTheProtocol() {
    let result = PlanApplier.apply([change(.cardio, "cardioProtocol", .replace, before: "25 min LISS × 2", after: "30 min LISS x 3")], to: makePlan(), replyId: UUID())
    #expect(result.plan.cardioProtocol == "30 min LISS x 3")
}

@Test func supplementAddRemoveAndReplaceEditTheBlock() {
    let plan = makePlan()
    let added = PlanApplier.apply([change(.supplement, "supplements", .add, before: nil, after: "5g glutamine before bed")], to: plan, replyId: UUID())
    #expect(added.plan.carriedBlocks[1].text.hasSuffix("-  5g glutamine before bed"))
    let removed = PlanApplier.apply([change(.supplement, "supplement.creatine", .remove, before: "Creatine Monohydrate - 5g daily", after: "(removed)")], to: plan, replyId: UUID())
    #expect(!removed.plan.carriedBlocks[1].text.contains("Creatine") && removed.plan.carriedBlocks[1].text.contains("Whey"))
    let replaced = PlanApplier.apply([change(.supplement, "supplement.omega", .replace, before: "Omega 3 - 2 softgels daily", after: "Omega 3 - 3 softgels daily")], to: plan, replyId: UUID())
    #expect(replaced.plan.carriedBlocks[1].text.contains("3 softgels"))
    let missing = PlanApplier.apply([change(.supplement, "supplement.zinc", .remove, before: "Zinc", after: "(removed)")], to: plan, replyId: UUID())
    #expect(missing.blocksNeedingHandEdit == ["Current Supplements:"])
}

@Test func programChangesApplyToEveryWeekByDayAndExerciseName() {
    let plan = makePlan()
    let load = PlanApplier.apply([change(.load, "program.upper_a.bench_press.load", .increase, before: "185 lb", after: "190 lb")], to: plan, replyId: UUID())
    #expect(load.plan.program.weeks[0].days[0].exercises[0].sets.allSatisfy { $0.loadLb == 190 })
    #expect(load.plan.program.weeks[1].days[0].exercises[0].sets.allSatisfy { $0.loadLb == 190 })
    #expect(load.plan.program.weeks[0].days[0].exercises[1].sets[0].loadLb == 165)   // the row is untouched

    let sets = PlanApplier.apply([change(.sets, "program.upper_a.bench_press.sets", .set, before: "3", after: "5")], to: plan, replyId: UUID())
    #expect(sets.plan.program.weeks[0].days[0].exercises[0].sets.count == 5 && sets.plan.program.weeks[1].days[0].exercises[0].sets.count == 5)

    let reps = PlanApplier.apply([change(.reps, "program.upper_a.bench_press.reps", .set, before: "8", after: "10–12")], to: plan, replyId: UUID())
    let first = reps.plan.program.weeks[0].days[0].exercises[0].sets[0]
    #expect(first.reps == nil && first.repsMin == 10 && first.repsMax == 12)
    let single = PlanApplier.apply([change(.reps, "program.upper_a.barbell_row.reps", .set, before: "8–10", after: "6")], to: plan, replyId: UUID())
    #expect(single.plan.program.weeks[0].days[0].exercises[1].sets[0] == set(6, 165))

    let rest = PlanApplier.apply([change(.rest, "program.upper_a.bench_press.rest", .set, before: "150 s", after: "120 s")], to: plan, replyId: UUID())
    #expect(rest.plan.program.weeks[0].days[0].exercises[0].restSeconds == 120)
}

@Test func swapAddAndRemoveExercises() {
    let plan = makePlan()
    let swapped = PlanApplier.apply([change(.exerciseSwap, "program.upper_a.bench_press", .replace, before: nil, after: "Incline DB press")], to: plan, replyId: UUID())
    let ex = swapped.plan.program.weeks[0].days[0].exercises[0]
    #expect(ex.name == "Incline DB press" && ex.equipment == .dumbbell && ex.id == "w1_upper_a_bench_press" && ex.sets.count == 3)

    let added = PlanApplier.apply([change(.exerciseAdd, "program.upper_a", .add, before: nil, after: "Face pulls")], to: plan, replyId: UUID())
    let day = added.plan.program.weeks[0].days[0]
    #expect(day.exercises.count == 3 && day.exercises[2].name == "Face pulls" && day.exercises[2].id == "w1_upper_a_face_pulls")
    #expect(day.exercises[2].equipment == .cable && day.exercises[2].sets.count == 3)
    #expect(added.plan.program.weeks[1].days[0].exercises.count == 2)

    let removed = PlanApplier.apply([change(.exerciseRemove, "program.upper_a.bench_press", .remove, before: nil, after: "(removed)")], to: plan, replyId: UUID())
    #expect(removed.plan.program.weeks[0].days[0].exercises.map(\.name) == ["Barbell row"])
    #expect(removed.plan.program.weeks[1].days[0].exercises.isEmpty)
}

@Test func slugMatchesTheBackend() {
    #expect(PlanApplier.slug("Upper A") == "upper_a")
    #expect(PlanApplier.slug("Incline DB press (pause)") == "incline_db_press_pause")
    #expect(PlanApplier.slug("---") == "item")
}

@Test @MainActor func storeSeedsPlanVersionOneAndRevertsTheLatest() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("plan-\(UUID().uuidString)")
    let plan = makePlan()
    // Before plans existed: a program and template on disk, no plans.json.
    let store = Store(root: root)
    store.saveProgram(plan.program)
    #expect(store.plan?.version == 1 && store.plan?.program == plan.program)
    store.saveTemplate(CheckInTemplate(fields: [], carriedBlocks: plan.carriedBlocks), targets: plan.targets, cardioProtocol: "30 min LISS")
    #expect(store.plan?.version == 2 && store.plan?.targets == plan.targets && store.plan?.cardioProtocol == "30 min LISS")
    #expect(store.currentTemplate?.carriedBlocks == plan.carriedBlocks)

    let reply = CoachReply(id: UUID(), receivedAt: .now, kind: .text, audioFile: nil, transcript: "drop carbs by 25",
                           changes: [change(.macroTarget, "targets.training.carbsG", .decrease, before: "250 g", after: "225 g", label: "Training-day carbs")],
                           unclear: [], appliedVersion: nil)
    store.upsert(reply: reply)
    #expect(store.pendingReply?.id == reply.id)
    let result = PlanApplier.apply(reply.changes, to: store.plan!, replyId: reply.id)
    store.appendPlan(result.plan)
    var applied = reply
    applied.appliedVersion = result.plan.version
    store.upsert(reply: applied)
    #expect(store.plan?.version == 3 && store.plan?.targets.training.carbsG == 225 && store.pendingReply == nil)
    #expect(store.appliedReplies.map(\.id) == [reply.id])

    let reopened = Store(root: root)
    #expect(reopened.plan?.version == 3 && reopened.coachReplies.count == 1)
    reopened.revertLatestPlan()
    #expect(reopened.plan?.version == 2 && reopened.plan?.targets.training.carbsG == 250)
    #expect(reopened.coachReplies[0].appliedVersion == nil && reopened.pendingReply != nil)
    #expect(reopened.revertLatestPlan()?.version == 1)
    #expect(reopened.revertLatestPlan() == nil)   // version 1 stays
}

@Test func replyResponseDecodes() throws {
    let json = """
    {"transcript":"Drop carbs by 25.","changes":[{"id":"c1","kind":"macroTarget","path":"targets.training.carbsG","label":"Training-day carbs","op":"decrease","amount":25.0,"before":"250 g","after":"225 g","quote":"Drop carbs by 25","appliesFrom":null,"approved":true}],"unclear":["and sauna"],"cues":[{"id":"cue1","exerciseId":"w1_upper_a_bench_press","text":"Pause at the bottom.","startSec":2.5,"endSec":5.0}]}
    """
    let r = try JSONCoding.decoder.decode(ReplyResponse.self, from: Data(json.utf8))
    #expect(r.changes[0].beforeAfterText == "250 g → 225 g" && r.changes[0].kind.group == "Targets")
    #expect(r.cues[0].startSec == 2.5 && r.unclear == ["and sauna"])
}
