import Foundation
import Testing
@testable import Setecho

/// Machine taken (HANDOFF.md §7): his options in his confirmed order, variant names from the
/// catalog, a swap logged for the coach with its own load, and Wait always last.

private func p(_ reps: Int?, min: Int? = nil, max: Int? = nil, load: Double? = nil) -> PlannedSet {
    PlannedSet(reps: reps, repsMin: min, repsMax: max, loadLb: load, rpe: nil, rir: nil)
}

private let flatAlt = Alternate(name: "Flat dumbbell press", quote: "or flat DB if the bench is busy", source: "Sheet")
private let incline = PlannedExercise(id: "incline", name: "Incline dumbbell press", sets: [p(nil, min: 8, max: 10, load: 60), p(nil, min: 8, max: 10, load: 60)],
                                      restSeconds: 120, notes: nil, alternates: [flatAlt])
private let smith = PlannedExercise(id: "smith", name: "Smith close-grip press", sets: [p(8), p(8)], restSeconds: 180, notes: nil)
private let confirmed = TakenRule(order: [.alternate, .sameLift], confirmed: true)
private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

private func said(_ kind: VoiceIntent.Kind, _ transcript: String = "", number: Double? = nil, text: String? = nil) -> VoiceCommandResponse {
    VoiceCommandResponse(transcript: transcript, intent: VoiceIntent(intent: kind, number: number, text: text, confidence: 0.95))
}

@Test func theCatalogNamesHisLiftsFamilies() {
    #expect(!ExerciseFamily.catalog.isEmpty)
    #expect(ExerciseFamily.family(of: "Smith close-grip press")?.id == "close-grip-press")
    #expect(ExerciseFamily.family(of: "Incline DB Press")?.id == "incline-press")
    #expect(ExerciseFamily.family(of: "Cable incline flyes")?.id == "fly")      // flyes on an incline bench are still flyes
    #expect(ExerciseFamily.family(of: "Hanging leg raises") == nil)
    #expect(ExerciseFamily.equipment(of: "Smith close-grip press", fallback: .barbell) == "smith")
    #expect(ExerciseFamily.equipment(of: "Incline DB Press", fallback: .barbell) == "dumbbell")
}

@Test func hisOrderComesFirstAndWaitIsAlwaysLast() {
    // Alternates first: his own words, then the catalog's same lift on other equipment.
    let options = TakenEngine.options(for: incline, rule: confirmed, takenEquipment: ["dumbbell"])
    #expect(options.map(\.name) == ["Flat dumbbell press", "Incline barbell press", "Wait"])
    // His other order: the same lift first. Equipment taken earlier today is never offered.
    let sameFirst = TakenRule(order: [.sameLift, .alternate], confirmed: true)
    #expect(TakenEngine.options(for: incline, rule: sameFirst, takenEquipment: ["dumbbell", "barbell"]).map(\.name)
            == ["Incline Smith press", "Incline machine press", "Wait"])
    // The variant he did most recently comes first.
    #expect(TakenEngine.options(for: smith, rule: sameFirst, takenEquipment: ["smith"], recentVariants: ["Close-grip dumbbell press"]).map(\.name)
            == ["Close-grip dumbbell press", "Close-grip bench press", "Wait"])
    // Not confirmed, or no rule: only Wait.
    #expect(TakenEngine.options(for: incline, rule: TakenRule.suggested, takenEquipment: []) == [.wait])
    #expect(TakenEngine.options(for: incline, rule: nil, takenEquipment: []) == [.wait])
}

@Test @MainActor func theOtherOneIsLoggedForTheCoachWithItsOwnLoad() {
    let engine = SessionEngine(day: ProgramDay(id: "d", name: "Day 5", exercises: [smith, incline]), weekNumber: 1, takenRule: confirmed,
                               variantLoads: ["incline|incline barbell press": 135])
    engine.apply(said(.nextExercise))
    let offer = engine.apply(said(.equipmentTaken, "the incline bench is taken", text: "incline bench"), now: t0)
    #expect(offer.speech == "Incline bench's taken. His first choice is flat dumbbell press. Or incline barbell press. Say 'go with it', 'the other one', or 'I'll wait'.")
    #expect(engine.takenOffer?.options.count == 3)
    let other = engine.apply(said(.choose, "the other one", number: 2), now: t0)
    #expect(other.speech == "Incline barbell press. Noted for Thursday. 135 for 8–10.")
    #expect(engine.targetLoadLb == 135)   // that variant's own last load, never converted from the dumbbells
    let deviation = engine.session.deviations.first
    #expect(deviation?.doneAs == "Incline barbell press" && deviation?.reason == "Incline bench taken" && deviation?.kind == .swap)
    engine.setStarted(at: t0)
    engine.setEnded(at: t0.addingTimeInterval(30))
    #expect(engine.session.sets.last?.doneAs == "Incline barbell press" && engine.session.sets.last?.loadLb == 135)
    // "It's free": back to the plan, which never changed.
    let free = engine.apply(said(.equipmentFree, "it's free"))
    #expect(free.speech == "Back to incline dumbbell press. 60 for 8–10." && engine.targetLoadLb == 60)
    #expect(engine.exercises.map(\.exercise) == [smith, incline])
}

@Test @MainActor func goWithItTakesHisFirstChoiceAndIllWaitWaits() {
    let engine = SessionEngine(day: ProgramDay(id: "d", name: "Day 5", exercises: [incline]), weekNumber: 1, takenRule: confirmed)
    engine.apply(said(.equipmentTaken, "can I swap this?", text: nil))
    let go = engine.apply(said(.acceptSuggestion, "go with it"))
    #expect(go.speech == "Flat dumbbell press. Noted for Thursday. Weight for these?" && engine.doneAs["incline"] == "Flat dumbbell press")
    let other = SessionEngine(day: ProgramDay(id: "d", name: "Day 5", exercises: [incline]), weekNumber: 1, takenRule: confirmed)
    let offer = other.apply(said(.equipmentTaken, "is there another machine I can use?", text: nil))
    #expect(offer.speech?.hasPrefix("For incline dumbbell press, his first choice is flat dumbbell press.") == true)
    let wait = other.apply(said(.choose, "I'll wait", text: "wait"))
    #expect(wait.speech == "Waiting for it. Say 'it's free' when it is." && other.session.deviations.isEmpty && other.waitingFor == "incline")
    #expect(other.apply(said(.equipmentFree, "bench is open")).speech == "Back to incline dumbbell press.")
}

@Test @MainActor func withNoConfirmedRuleOrTheSwitchOffOnlyHisOwnSwapIsOffered() {
    for engine in [SessionEngine(day: ProgramDay(id: "d", name: "Day 5", exercises: [incline]), weekNumber: 1),
                   SessionEngine(day: ProgramDay(id: "d", name: "Day 5", exercises: [incline]), weekNumber: 1, takenRule: confirmed, takenHelp: false)] {
        let out = engine.apply(said(.equipmentTaken, "the bench is taken", text: "bench"))
        #expect(out.speech == "Bench's taken. The rest keeps running. Say what you'll do instead, or wait." && engine.pendingAsk == nil)
        let own = engine.apply(said(.swapTo, "doing dumbbells on the flat bench instead", text: "dumbbells on the flat bench"))
        #expect(own.speech == "Noted for Thursday. Weight for these?" && engine.session.deviations.first?.doneAs == "dumbbells on the flat bench")
    }
}
