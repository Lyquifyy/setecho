import Foundation
import Testing
@testable import Setecho

/// The between-set conversation end to end (HANDOFF.md §7): each scenario drives SessionConversation,
/// the coordinator's voice path (queue, set-time gating, engine, speech), with a fake backend that
/// answers from backend/tests/fixtures/conversations/ (the same lines test_voice.py reads through
/// the real rules), a camera that is on or off duty, and a clock. Each checks what is said, in order.

private final class FixtureAnchor {}

private struct FixtureIntent: Decodable {
    var intent: VoiceIntent.Kind
    var number: Double?
    var text: String?
    var topic: VoiceIntent.Topic?
    var reps: Int?
    var setNumber: Int?
}

private struct RawFixture: Decodable {
    struct Line: Decodable {
        var say: String
        var state: String
        var via: String
        var intent: FixtureIntent
    }
    var scenario: String
    var utterances: [Line]
}

@MainActor
private final class Gym {
    let engine: SessionEngine
    let talk: SessionConversation
    var clock = Date(timeIntervalSince1970: 1_800_000_000)
    private var lines: [RawFixture.Line]
    /// Lines the backend was asked about, with the state they were said in.
    private(set) var heardStates: [(String, String)] = []

    init(_ scenario: String, engine: SessionEngine, camera: Bool) throws {
        let bundle = Bundle(for: FixtureAnchor.self)
        let url = try #require(bundle.url(forResource: scenario, withExtension: "json", subdirectory: "conversations"))
        lines = try JSONDecoder().decode(RawFixture.self, from: Data(contentsOf: url)).utterances
        self.engine = engine
        engine.cameraOnDuty = camera
        talk = SessionConversation(engine: engine)
        talk.now = { [unowned self] in self.clock }
        talk.classify = { [unowned self] heard, request in
            let line = self.lines.removeFirst()
            #expect(heard.transcript == line.say)
            // The line is said in the state the backend fixture reads it in.
            #expect(request.state == line.state, "\(line.say)")
            let i = line.intent
            return SessionTurnResponse(command: VoiceCommandResponse(
                transcript: line.say,
                intent: VoiceIntent(intent: i.intent, number: i.number, reps: i.reps, setNumber: i.setNumber,
                                    text: i.text, topic: i.topic, confidence: 0.95),
                classifiedBy: line.via))
        }
    }

    var allSaid: [String] { talk.said }

    /// Say a line; returns what Setecho said back.
    func say(_ line: String) async -> [String] {
        let before = talk.said.count
        await talk.hear(.init(transcript: line, wav: nil, seconds: 1, speechEndedAt: clock))
        return Array(talk.said[before...])
    }

    /// Seconds pass on the session clock; returns what was said meanwhile.
    @discardableResult
    func wait(_ seconds: Int) -> [String] {
        let before = talk.said.count
        for _ in 0..<seconds {
            clock = clock.addingTimeInterval(1)
            talk.tick()
        }
        return Array(talk.said[before...])
    }

    /// Until the rest is over (or the session).
    @discardableResult
    func restOut() -> [String] {
        let before = talk.said.count
        var guardTicks = 0
        // The rest runs into overtime and nothing moves: "out" is when the bell goes.
        while case .rest(let left) = engine.state, left > 0, guardTicks < 600 { wait(1); guardTicks += 1 }
        return Array(talk.said[before...])
    }

    /// The camera films a set: its start, then its end with the phone's count; a clip goes to SAM.
    @discardableResult
    func cameraSet(phone reps: Int, slowdown: Double = 30, seconds: Double = 25) -> [String] {
        let before = talk.said.count
        talk.show(engine.setStarted(at: clock))
        clock = clock.addingTimeInterval(seconds)
        var result = RepCounter.Result(reps: reps, repTimes: (0..<reps).map { Double($0) * 2.5 + 1 }, confidence: 0.9, trackFound: true,
                                       frames: 300, trackedFrames: 300)
        result.velocityLossPct = slowdown
        talk.show(engine.setEnded(at: clock, phone: result, willMeasure: true))
        return Array(talk.said[before...])
    }

    /// SAM answers for a set.
    @discardableResult
    func sam(_ setId: UUID, reps: Int, confidence: Double = 0.9, slowdown: Double = 38) -> [String] {
        let before = talk.said.count
        let response = CountResponse(reps: reps, repTimes: (0..<reps).map { Double($0) * 2.5 + 4 }, repSpeeds: (0..<reps).map { 300 - Double($0) * 10 },
                                     velocityLossPct: slowdown, confidence: confidence, trackFound: true, frames: 300, trackedFrames: 300,
                                     prompt: "weight plate")
        talk.show(engine.measured(setId: setId, response, now: clock))
        return Array(talk.said[before...])
    }

    func intro() -> [String] {
        let before = talk.said.count
        talk.say(engine.intro)
        talk.show(engine.beginLeadInIfDue())
        return Array(talk.said[before...])
    }

    var unheardLines: Int { lines.count }
}

/// Say a line and check what is said back (the actual lines show in a failure).
@MainActor
private func check(_ gym: Gym, _ line: String, _ expected: [String], sourceLocation: SourceLocation = #_sourceLocation) async {
    let got = await gym.say(line)
    #expect(got == expected, sourceLocation: sourceLocation)
}

// MARK: - His plan, his rules

private func p(_ reps: Int?, min: Int? = nil, max: Int? = nil, seconds: Int? = nil, role: SetRole? = nil, load: Double? = nil) -> PlannedSet {
    PlannedSet(reps: reps, repsMin: min, repsMax: max, loadLb: load, rpe: nil, rir: nil, seconds: seconds, role: role)
}

private let smith = PlannedExercise(id: "smith", name: "Smith close-grip press",
                                    sets: [p(nil, min: 6, max: 9, role: .top), p(nil, min: 8, max: 10, role: .backOff)],
                                    restSeconds: 180, notes: "3:1:1:1 tempo, elbows tucked")
private let flyes = PlannedExercise(id: "flyes", name: "Cable incline flyes", sets: [p(12, load: 30), p(12, load: 30), p(12, load: 30)],
                                    restSeconds: 90, notes: nil)
private let incline = PlannedExercise(id: "incline", name: "Incline dumbbell press",
                                      sets: [p(nil, min: 8, max: 10, load: 60), p(nil, min: 8, max: 10, load: 60), p(nil, min: 8, max: 10, load: 60)],
                                      restSeconds: 120, notes: nil)
private let dayFive = ProgramDay(id: "d5", name: "Day 5", exercises: [smith, flyes, incline])
private let smithOnce = PlannedExercise(id: "smith", name: "Smith close-grip press", sets: [p(nil, min: 6, max: 9, role: .top)], restSeconds: 180, notes: nil)
private let shortDay = ProgramDay(id: "d5", name: "Day 5", exercises: [smithOnce, flyes])

private let warmups = WarmupRule(minSets: 1, maxSets: 3, maxReps: 8, quote: "1-3 warm up sets of no more than 6-8 reps", confirmed: true)
private let failure = [RoleTarget(role: .top, rir: 0, source: "Coach's instructions", quote: "to failure", confirmed: true),
                       RoleTarget(role: .backOff, rir: 0, source: "Coach's instructions", quote: "to failure", confirmed: true)]
private let backOffRule = ProgressionRule(id: "rule_1", appliesTo: nil, when: .afterTopSet, byRPE: nil, adjust: .backOff, amount: nil, minPct: 20, maxPct: 25,
                                          scope: .nextSet, source: "Coach's instructions",
                                          quote: "Back down sets are 20-25% lighter than your top set. Beat the logbook every week.", confirmed: true)
private let topRest = RestRule(after: .top, minSeconds: 180, maxSeconds: 240, quote: "Rest 3-4 minutes after a top set", confirmed: true)
private let logbook = ["smith|top": LastSet(loadLb: 145, reps: 9)]

private let abs = AddOn(id: "addon_abs", name: "Abs", exercises: [
    PlannedExercise(id: "raises", name: "Hanging/Lying Leg Raises", sets: [p(12), p(12)], equipment: .bodyweight, restSeconds: 60, notes: nil),
    PlannedExercise(id: "crunch", name: "Cable crunch", sets: [p(15), p(15)], restSeconds: 60, notes: nil),
    PlannedExercise(id: "plank", name: "Plank", sets: [p(nil, seconds: 60)], restSeconds: nil, notes: nil),
], perWeek: 2, timing: .withSession, quote: "Complete this 2x per week:")
private let vacuums = AddOn(id: "addon_vac", name: "Stomach Vacuums", exercises: [
    PlannedExercise(id: "vac", name: "Stomach Vacuums", sets: Array(repeating: p(nil, seconds: 20), count: 4), restSeconds: nil, notes: nil),
], perWeek: 4, timing: .onWaking, quote: "Complete these 4x per week upon waking:")

// MARK: - Scenarios

@Test @MainActor func aTheTopSetGetsTheLogbookLineAndTheBackOffIsHisRule() async throws {
    let engine = SessionEngine(day: dayFive, weekNumber: 1, warmups: warmups, rules: [backOffRule], roleTargets: failure, restRules: [topRest],
                               lastSets: logbook)
    let gym = try Gym("a_top_set_and_back_off", engine: engine, camera: true)
    #expect(gym.intro() == ["Day 5. Smith close-grip press, 145 for 6–9. Last time 145 for 9. Beat the logbook. Warm-ups first."])
    #expect(gym.cameraSet(phone: 6, slowdown: 5) == ["Warm-up one, logged. Rest three minutes, then your top set: 145 for 6–9. Last time 145 for 9. Beat the logbook."])
    gym.wait(60)
    #expect(gym.cameraSet(phone: 5, slowdown: 5) == ["Warm-up two, logged. Rest three minutes, then your top set: 145 for 6–9. Last time 145 for 9. Beat the logbook."])
    await check(gym, "top set", ["Top set. Last time 145 for 9. Beat the logbook."])
    #expect(gym.cameraSet(phone: 9, slowdown: 46) == ["Set 1 done. Rest four minutes."])
    let top = try #require(engine.session.sets.last)
    gym.wait(20)
    #expect(gym.sam(top.id, reps: 9, slowdown: 46) == [
        "Top set: 9 reps, measured. Slowed 46 percent, that's failure. Back-off at 110, his rule: 20–25% lighter than the top set. Say 'go with it' or a weight.",
    ])
    await check(gym, "what's the back-off?", ["Back-off at 110, his rule."])
    await check(gym, "go with it", ["110 it is."])
    #expect(engine.targetLoadLb == 110 && engine.session.suggestions.first?.decision == .accepted)
    #expect(gym.restOut().last == "Rest's up.")
    // A filmed set's end line carries no number and no next target: both come when SAM answers.
    #expect(gym.cameraSet(phone: 10, slowdown: 40) == ["Set 2 done. Rest three minutes."])
    #expect(engine.session.sets.last?.loadLb == 110 && engine.session.sets.last?.role == .backOff)
    #expect(gym.unheardLines == 0)
}

@Test @MainActor func bAPocketSetLogsANewSetAndACorrectionEditsOnlyIt() async throws {
    let engine = SessionEngine(day: shortDay, weekNumber: 1, lastSets: logbook)
    let gym = try Gym("b_pocket_set", engine: engine, camera: false)
    await check(gym, "done, 8", ["8 reps. Smith close-grip press done. Cable incline flyes next. Rest three minutes."])
    #expect(gym.restOut() == ["Rest's up."])
    await check(gym, "done, 12", ["12 reps. Next, 30 for 12. Rest one thirty."])
    let flyesSet = try #require(engine.session.sets.last)
    #expect(flyesSet.exerciseId == "flyes" && flyesSet.setIndex == 0 && flyesSet.reps == 12 && flyesSet.repCount.source == .spoken)
    await check(gym, "actually that was 11", ["Set 1, 11 reps."])
    #expect(engine.session.sets.map(\.reps) == [8, 11] && engine.session.sets[0].exerciseId == "smith")
    #expect(gym.unheardLines == 0)
}

@Test @MainActor func cWithThePhoneInAPocketDoneAsksHowMany() async throws {
    let engine = SessionEngine(day: shortDay, weekNumber: 1, lastSets: logbook)
    let gym = try Gym("c_phone_in_pocket", engine: engine, camera: false)
    await check(gym, "starting", [])
    #expect(engine.state == .recording)
    gym.clock = gym.clock.addingTimeInterval(30)
    await check(gym, "done", ["Set 1 done. Rest three minutes. How many?"])
    #expect(engine.session.sets[0].repCount.source == .plan)
    await check(gym, "ten", ["Set 1, 10 reps. Smith close-grip press done. Cable incline flyes next."])
    #expect(engine.session.sets[0].reps == 10 && engine.session.sets[0].repCount.source == .spoken && engine.pendingAsk == nil)
    #expect(gym.unheardLines == 0)
}

@Test @MainActor func dATakenBenchGetsHisOptionsAndTheCoachSeesTheSwap() async throws {
    let flat = Alternate(name: "Flat dumbbell press", quote: "or flat DB", source: "Sheet")
    var inclineWithAlt = incline
    inclineWithAlt.alternates = [flat]
    let engine = SessionEngine(day: ProgramDay(id: "d", name: "Day 5", exercises: [inclineWithAlt]), weekNumber: 1,
                               takenRule: TakenRule(order: [.alternate, .sameLift], confirmed: true))
    let gym = try Gym("d_machine_taken", engine: engine, camera: true)
    gym.cameraSet(phone: 9)
    await check(gym, "the incline bench is taken", [
        "Incline bench's taken. His first choice is flat dumbbell press. Or incline barbell press. Say 'go with it', 'the other one', or 'I'll wait'.",
    ])
    await check(gym, "the other one", ["Incline barbell press. Noted for Thursday. Weight for these?"])
    #expect(engine.session.deviations.map(\.doneAs) == ["Incline barbell press"] && engine.targetLoadLb == nil)
    gym.wait(30) // the rest keeps running
    await check(gym, "it's free", ["Back to incline dumbbell press. 60 for 8–10."])
    #expect(engine.targetLoadLb == 60 && engine.session.deviations.count == 1)
    #expect(gym.unheardLines == 0)
}

@Test @MainActor func eChatterIsNeverAnswered() async throws {
    let engine = SessionEngine(day: shortDay, weekNumber: 1, lastSets: logbook)
    let gym = try Gym("e_chatter", engine: engine, camera: true)
    gym.cameraSet(phone: 8)
    let before = engine.session
    await check(gym, "let's go", [])
    await check(gym, "ugh, that was brutal", [])
    await check(gym, "did you see the game last night", [])
    #expect(gym.talk.heard == "Heard: did you see the game last night" && engine.session == before && engine.pendingAsk == nil)
    #expect(gym.unheardLines == 0)
}

@Test @MainActor func fEndingTheSessionByVoiceNeedsAYes() async throws {
    let engine = SessionEngine(day: dayFive, weekNumber: 1, lastSets: logbook)
    let gym = try Gym("f_end_session_asks", engine: engine, camera: true)
    for _ in 0..<5 {
        gym.cameraSet(phone: 10)
        gym.restOut()
    }
    await check(gym, "done, 10", ["10 reps. Next, 60 for 8–10. Rest two minutes."])
    await check(gym, "I'm done", ["End the session? Six sets logged."])
    await check(gym, "no", ["Carrying on."])
    #expect(engine.state != .ended && engine.session.endedAt == nil)
    #expect(gym.unheardLines == 0)
}

@Test @MainActor func gWaitThatWasNineIsACount() async throws {
    let engine = SessionEngine(day: shortDay, weekNumber: 1, lastSets: logbook)
    let gym = try Gym("g_wait_is_a_count", engine: engine, camera: false)
    _ = await gym.say("done, 11")
    await check(gym, "wait, that was 9", ["Set 1, 9 reps."])
    #expect(engine.session.sets[0].reps == 9)
    if case .rest = engine.state {} else { Issue.record("paused instead of a count") }
    #expect(gym.unheardLines == 0)
}

@Test @MainActor func hYesAnswersOnlyTheLatestAsk() async throws {
    let bench = PlannedExercise(id: "bench", name: "Bench press", sets: [p(8, load: 100)], restSeconds: 120, notes: nil)
    let day = ProgramDay(id: "d", name: "Day 5", exercises: [bench, smith])
    let engine = SessionEngine(day: day, weekNumber: 1, rules: [backOffRule], roleTargets: failure, lastSets: logbook)
    let gym = try Gym("h_latest_ask_owns_yes", engine: engine, camera: true)
    gym.cameraSet(phone: 8)
    let benchSet = try #require(engine.session.sets.first)
    gym.wait(10)
    gym.restOut()
    // The camera missed the top set: "done, 9" logs it, and his rule asks about the back-off.
    let top = await gym.say("done, 9")
    #expect(top == ["9 reps. Next, 8–10 reps. Rest three minutes. Back-off at 110, his rule: 20–25% lighter than the top set. Say 'go with it' or a weight."])
    #expect(engine.pendingSuggestion != nil)
    // Then SAM is unsure about the bench set: the newer ask.
    #expect(gym.sam(benchSet.id, reps: 7, confidence: 0.4) == ["Set 1, was that 7?"])
    await check(gym, "yes", ["Set 1, 7 reps."])
    #expect(engine.session.sets[0].reps == 7 && engine.session.sets[0].repCount.source == .measured)
    // The older ask lapsed with its default: the back-off keeps its own load, not the rule's.
    #expect(engine.pendingAsk == nil && engine.session.suggestions.first?.decision == .kept && engine.targetLoadLb != 110)
    #expect(gym.unheardLines == 0)
}

@Test @MainActor func iAdviceIsForTheCoachAndAYesNotesIt() async throws {
    let engine = SessionEngine(day: shortDay, weekNumber: 1, lastSets: logbook)
    let gym = try Gym("i_out_of_scope", engine: engine, camera: true)
    gym.cameraSet(phone: 8)
    await check(gym, "should I go heavier next week?", ["That's one for your coach. Want me to note it for Thursday?"])
    await check(gym, "yeah", ["Noted for Thursday."])
    #expect(engine.session.notes.map(\.transcript) == ["should I go heavier next week?"])
    #expect(gym.unheardLines == 0)
}

@Test @MainActor func jQuestionsAreAnsweredFromTheLog() async throws {
    let engine = SessionEngine(day: shortDay, weekNumber: 1, rules: [backOffRule], lastSets: logbook)
    let gym = try Gym("j_questions", engine: engine, camera: false)
    await check(gym, "what did I do last time?", ["Last time 145 for 9. Beat the logbook."])
    _ = await gym.say("done, 8")
    gym.wait(80)
    await check(gym, "how long left?", ["One forty left."])
    #expect(gym.unheardLines == 0)
}

@Test @MainActor func kMorningVacuumsRunWithNothingSaid() async throws {
    let engine = SessionEngine(day: nil, addOns: [vacuums], weekNumber: 1)
    let gym = try Gym("k_vacuums", engine: engine, camera: false)
    #expect(engine.isAllTimed) // the coordinator never starts the camera
    var said = gym.intro()
    while engine.state != .ended, said.count < 100 { said += gym.wait(1) }
    let hold = ["Three.", "Two.", "One.", "Hold.", "Three.", "Two.", "One."]
    let rest = ["Time. Next, 20 s. Rest thirty seconds."]
    #expect(said == ["Stomach vacuums: four holds of twenty seconds."] + hold + rest + hold + rest + hold + rest + hold + ["Time. That's the session."])
    #expect(engine.session.sets.count == 4 && !said.contains("Go."))
    #expect(AddOnPlanner.doneCount(addOnId: "addon_vac", sessions: [engine.session], from: .distantPast, to: .distantFuture) == 1)
}

@Test @MainActor func lAbsGoByVoiceWithNoWarmupsAndThePlankStartsItself() async throws {
    let bench = PlannedExercise(id: "bench", name: "Bench press", sets: [p(10, load: 100)], restSeconds: 120, notes: nil)
    let engine = SessionEngine(day: ProgramDay(id: "d", name: "Day 5", exercises: [bench]), addOns: [abs], weekNumber: 1, warmups: warmups)
    let gym = try Gym("l_abs", engine: engine, camera: true)
    await check(gym, "done, 10", ["10 reps. Bench press done. Abs: Hanging/Lying Leg Raises next. Rest two minutes."])
    #expect(!engine.warmupMode)
    gym.restOut()
    await check(gym, "done, 12", ["12 reps. Next, 12 reps. Rest one minute."])
    gym.restOut()
    await check(gym, "done, 12", ["12 reps. Hanging/Lying Leg Raises done. Cable crunch next. Rest one minute."])
    gym.restOut()
    await check(gym, "done", ["Set 1 done. Rest one minute. How many?"])
    await check(gym, "fifteen", ["Set 1, 15 reps. Next, 15 reps."])
    gym.restOut()
    await check(gym, "done, 15", ["15 reps. Cable crunch done. Plank next. Rest one minute."])
    var said = gym.restOut()
    while engine.state != .ended, said.count < 40 { said += gym.wait(1) }
    #expect(said == ["Plank, sixty seconds. Starting in five.", "Three.", "Two.", "One.", "Hold.", "10 seconds.", "Three.", "Two.", "One.",
                     "Time. That's the session."])
    let abSets = engine.session.sets.filter { $0.exerciseId != "bench" }
    #expect(abSets.map(\.reps) == [12, 12, 15, 15, 0] && abSets.allSatisfy { !$0.isWarmup })
    #expect(!engine.shouldUpload(setId: abSets[0].id))
    #expect(gym.unheardLines == 0)
}

@Test @MainActor func mWhatCanISayAnswersForTheMoment() async throws {
    let engine = SessionEngine(day: shortDay, weekNumber: 1, lastSets: logbook)
    let gym = try Gym("m_help", engine: engine, camera: false)
    let tail = "Talk to me like a spotter: ask anything about today, or tell me if a machine's taken. Undo takes back anything."
    await check(gym, "what can I say?", ["Just lift. When you finish, say done and the count, like done, eight. Ask what's next anytime. " + tail])
    _ = await gym.say("done, 8")
    await check(gym, "what can I say?", ["Fix a count with that was seven. Ask what's next, or how long left. " + tail])
    #expect(engine.session.sets.count == 1)
    #expect(gym.unheardLines == 0)
}

@Test func voiceGuideLoadsFromTheBundle() {
    #expect(VoiceGuide.guides.map(\.title) == ["Working out", "Abs", "Vacuums"])
    #expect(VoiceGuide.guides.allSatisfy { !$0.sections.isEmpty && $0.sections.allSatisfy { !$0.phrases.isEmpty } })
}

// MARK: Talk to it like a person (HANDOFF.md §7): turns from Muse Spark, through the real engine

@MainActor
private func spark(_ engine: SessionEngine, _ turn: SessionTurnResponse) -> SessionConversation {
    let talk = SessionConversation(engine: engine)
    talk.classify = { _, _ in turn }
    return talk
}

@Test @MainActor func aTurnCanCarrySeveralActionsAndTheReplyConfirmsThem() async throws {
    let engine = SessionEngine(day: shortDay, weekNumber: 1, lastSets: logbook)
    let talk = SessionConversation(engine: engine)
    var turns = [
        SessionTurnResponse(transcript: "done, 8", actions: [VoiceIntent(intent: .endSet, number: 8, confidence: 0.95)], classifiedBy: "rules"),
        SessionTurnResponse(transcript: "that was 9, and note my shoulder pinched", actions: [
            VoiceIntent(intent: .reps, number: 9, confidence: 0.9),
            VoiceIntent(intent: .note, text: "my shoulder pinched", confidence: 0.9),
        ], reply: "Nine on set 1. Noted for Thursday.", classifiedBy: "spark"),
    ]
    talk.classify = { _, _ in turns.removeFirst() }
    await talk.hear(.init(transcript: "done, 8", wav: nil, seconds: 1, speechEndedAt: .now))
    let before = talk.said.count
    await talk.hear(.init(transcript: "that was 9, and note my shoulder pinched", wav: nil, seconds: 2, speechEndedAt: .now))
    #expect(engine.session.sets.first?.reps == 9)
    #expect(engine.session.notes.count == 1)
    #expect(Array(talk.said[before...]) == ["Nine on set 1. Noted for Thursday."])
    // The follow-up gets the exchange.
    var seen: SessionTurnRequest?
    talk.classify = { _, request in
        seen = request
        return SessionTurnResponse(transcript: "undo", actions: [VoiceIntent(intent: .undo, confidence: 0.95)], classifiedBy: "rules")
    }
    await talk.hear(.init(transcript: "undo", wav: nil, seconds: 1, speechEndedAt: .now))
    #expect(seen?.recentTurns.last == Exchange(heard: "that was 9, and note my shoulder pinched", said: "Nine on set 1. Noted for Thursday."))
    #expect(seen?.facts.sets.first?.reps == 9)
}

@Test @MainActor func talkNotMeantForSetechoDoesNothing() async {
    let engine = SessionEngine(day: shortDay, weekNumber: 1)
    let talk = spark(engine, SessionTurnResponse(transcript: "bro can I work in", actions: [], addressed: false, classifiedBy: "spark"))
    await talk.hear(.init(transcript: "bro can I work in", wav: nil, seconds: 1, speechEndedAt: .now))
    #expect(talk.said.isEmpty && engine.session.sets.isEmpty && engine.state == .ready)
    #expect(talk.heard == "Heard: bro can I work in")
}

@Test @MainActor func anActionThatAsksSpeaksTheEnginesQuestionNotTheReply() async {
    let engine = SessionEngine(day: shortDay, weekNumber: 1)
    let talk = spark(engine, SessionTurnResponse(transcript: "I'm done for today", actions: [VoiceIntent(intent: .endSession, confidence: 0.9)],
                                                 reply: "Alright, see you Thursday.", classifiedBy: "spark"))
    await talk.hear(.init(transcript: "I'm done for today", wav: nil, seconds: 1, speechEndedAt: .now))
    #expect(talk.said.count == 1 && talk.said[0].hasPrefix("End the session?"))
    #expect(engine.state != .ended)
}

@Test @MainActor func aQuestionIsAnsweredByTheReply() async {
    let engine = SessionEngine(day: shortDay, weekNumber: 1, lastSets: logbook)
    let talk = spark(engine, SessionTurnResponse(transcript: "what'd I get last week", actions: [], reply: "Last time 145 for 9.", classifiedBy: "spark"))
    await talk.hear(.init(transcript: "what'd I get last week", wav: nil, seconds: 1, speechEndedAt: .now))
    #expect(talk.said == ["Last time 145 for 9."])
}

@Test @MainActor func midSetOnlySetCommandsActEvenFromATurn() async {
    let engine = SessionEngine(day: shortDay, weekNumber: 1)
    engine.setStarted()
    let talk = spark(engine, SessionTurnResponse(transcript: "the incline's taken", actions: [VoiceIntent(intent: .equipmentTaken, text: "incline", confidence: 0.9)],
                                                 reply: "Incline's taken.", classifiedBy: "spark"))
    await talk.hear(.init(transcript: "the incline's taken", wav: nil, seconds: 1, speechEndedAt: .now))
    #expect(talk.said.isEmpty && engine.state == .recording)
}
