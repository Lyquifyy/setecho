import Foundation
import Observation

/// The talk between sets (HANDOFF.md §7, The between-set conversation; Talk to it like a person):
/// every utterance heard is queued and handled in order, read by the backend as a conversation turn
/// (the fast path's template lines, else Muse Spark with today's facts and the last 8 exchanges),
/// each of its actions applied to the engine, and answered; the session clock's ticks speak
/// through it too. No devices here: the coordinator wires in the
/// backend, the voice, the camera and the chime, and `ConversationTests` wire in fakes, so the path
/// the athlete uses is the path the tests drive.
///
/// During a set "done", counts and "top set" act, and so do questions, notes, this set's weight and
/// "this is another set of laterals"; grunts, counting aloud and the gym are noise. Talk not meant for
/// Setecho is never answered: the HUD
/// shows "Heard: …". A reply is spoken when the turn's actions ask nothing of their own; an action
/// that opens a question (a count to confirm, a machine-taken offer, the end-session yes) speaks
/// the engine's exact words.
@MainActor
@Observable
final class SessionConversation {
    /// One utterance: the words if the realtime stream has them (or a test's transcript), else
    /// the WAV for file transcription.
    struct Heard {
        var transcript: String?
        var wav: Data?
        var seconds: Double
        var speechEndedAt: Date
        /// The realtime stream's words, awaited when the utterance's turn comes.
        var words: (@MainActor () async -> String?)?
    }

    let engine: SessionEngine
    /// What the voice was given, in order: the tests' record of what was said.
    private(set) var said: [String] = []
    private(set) var echo: String?
    private(set) var heard: String?
    private(set) var askBack: String?
    /// The rest-time line being spoken, as text on the HUD (DESIGN.md Session, Rest).
    private(set) var spokenLine: String?
    private(set) var isBusy = false
    /// For the screen's voice card: his words while the turn is being read, the line being said now
    /// (and when it started, so the card can fill it word by word), and the last line, shown in full
    /// for a few seconds after.
    private(set) var reading: String?
    private(set) var speakingLine: String?
    private(set) var speakingSince: Date?
    private(set) var lastLine: String?
    private var lastLineTask: Task<Void, Never>?

    /// The backend: the fast path, else a Spark turn. Throws on a timeout or a failed request.
    @ObservationIgnored var classify: @MainActor (Heard, SessionTurnRequest) async throws -> SessionTurnResponse = { _, _ in
        throw APIError(status: 0, message: "No backend")
    }
    /// Hand a line to the voice. Lines are spoken in the order given.
    @ObservationIgnored var speak: @MainActor (String) async -> Void = { _ in }
    /// The soft chime the moment a command is heard.
    @ObservationIgnored var chime: () -> Void = {}
    /// The moment's own tone and haptic: armed, set started, set ended, rest's up.
    @ObservationIgnored var sound: (SessionEngine.Sound) -> Void = { _ in }
    /// The camera is filming the set now under way: its count, and that a clip goes to SAM.
    @ObservationIgnored var cameraSet: () -> (phone: RepCounter.Result?, willMeasure: Bool)? = { nil }
    /// After a command is applied: the coordinator's side of it (close a clip, replay a cue, save the logbook).
    @ObservationIgnored var applied: (VoiceCommandResponse, _ wasRecording: Bool) -> Void = { _, _ in }
    /// Settings → "Talkative spotter": each line said like a training partner (`Talk.rephrase`). Nil
    /// says the engine's exact templates.
    @ObservationIgnored var rephrase: ((_ line: String, _ turn: Int, _ previous: String?) -> String)?
    /// Settings → "Talkative spotter": after a working set's facts, one short reaction written by
    /// Muse Spark from the same facts (`/spotter/line`, moment "reaction", every number checked).
    /// Nil, or a nil answer, says nothing more.
    @ObservationIgnored var react: (@MainActor (SpotterFacts, [String]) async -> String?)?
    private var talkTurn = 0
    /// One record per utterance for the session's debug JSON.
    @ObservationIgnored var record: (SessionDebug.UtteranceRecord) -> Void = { _ in }
    @ObservationIgnored var now: () -> Date = { .now }
    /// The live input and voice processing, for the debug record.
    @ObservationIgnored var inputState: () -> (input: String, voiceProcessing: Bool) = { ("", false) }

    /// The session's exchanges, for follow-ups ("what about the other one?", "same as last set").
    private(set) var exchanges: [Exchange] = []
    static let recentTurns = 8
    private var queue: [Queued] = []
    /// Mid-set readings started the moment each sound was heard, by its place in the queue.
    private var earlyTasks: [Int: Task<Void, Never>] = [:]
    private var earlyInputs: [Int: (heard: Heard, request: SessionTurnRequest)] = [:]
    private var earlyTurns: [Int: EarlyTurn] = [:]
    private var nextQueued = 0

    private struct Queued {
        var id: Int
        var heard: Heard
    }

    /// A mid-set utterance read ahead of its turn: its words, and the turn read in the state it was heard in.
    private struct EarlyTurn {
        var state: String
        var transcript: String?
        var wordsAt: Date?
        var response: SessionTurnResponse?
        var error: (any Error)?

        func turn() throws -> SessionTurnResponse {
            if let response { return response }
            throw error ?? APIError(status: 0, message: "No reading")
        }
    }
    private var speechQueue: [String] = []
    private var speaking = false
    private var echoTask: Task<Void, Never>?
    private var heardTask: Task<Void, Never>?

    init(engine: SessionEngine) {
        self.engine = engine
    }

    // MARK: Quiet (Oct 31: a conversation with a friend during rest, and Setecho answered every line)

    /// Quiet: he's talking to someone else. Nothing is read by the backend and nothing is said back
    /// until "I'm back"; only the set commands ("go", "done, 9") still act, so a set he lifts while
    /// quiet is never lost. Entered by voice ("quiet", "mute", "talking to someone", "give me a
    /// minute") or a tap on the voice line, which also brings it back.
    private(set) var quiet = false

    static let quietLine = "Quiet. Say \u{201C}I'm back\u{201D} when you're done."
    static let backLine = "Back with you."

    private static let quietPhrases = try! NSRegularExpression(
        pattern: #"^(okay,? |ok,? |alright,? |hey,? )?(setecho,? )?(be )?(quiet|mute|stop listening|hush|hang on|one sec(ond)?|just a (sec(ond)?|minute|moment)|give me (a|two|a couple of|a few) (sec(ond)?s?|minutes?|moments?)|(i'?m )?(talking|speaking) to (someone|somebody|a friend|him|her|them)|not talking to you|don'?t listen)\b"#,
        options: [.caseInsensitive])
    private static let backPhrases = try! NSRegularExpression(
        pattern: #"^(okay,? |ok,? |alright,? |hey,? )?(setecho,? )?(i'?m back|back with you|unmute|listen( up| again| to me)?|start listening|you can listen)\b"#,
        options: [.caseInsensitive])
    /// The set commands that still act while quiet: the rule layer's arm and end phrases, with a count.
    private static let setCommands = try! NSRegularExpression(
        pattern: #"^(okay,? |ok,? |alright,? )?(go|starting|here we go|lifting|top set|back-?off|set (one|two|three|four|five|\d+)|going|done|stop|set done|that was \d+|that was (one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve|thirteen|fourteen|fifteen|twenty))( (\d+|[a-z]+))?\.?$"#,
        options: [.caseInsensitive])

    private static func matches(_ regex: NSRegularExpression, _ words: String) -> Bool {
        let line = words.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: ".!,?"))
        return regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil
    }

    /// A tap on the voice line: quiet, or back.
    func toggleQuiet() {
        setQuiet(!quiet)
    }

    func setQuiet(_ on: Bool) {
        guard on != quiet else { return }
        quiet = on
        show(.init(speech: on ? Self.quietLine : Self.backLine, echo: on ? "Quiet" : "Listening again"))
    }

    /// The words, read on the phone while quiet, or on a quiet phrase: `true` when they were handled here
    /// and the backend never sees them.
    private func handleQuiet(_ words: String?, log: inout SessionDebug.UtteranceRecord) -> Bool {
        guard let words, words.contains(where: \.isLetter) else { return false }
        if quiet {
            if Self.matches(Self.backPhrases, words) {
                log.kind = "quiet off"
                setQuiet(false)
                return true
            }
            if Self.matches(Self.setCommands, words) { return false } // "go", "done, 9": the set still counts
            log.kind = "quiet"
            log.transcript = words
            log.addressed = false
            show(.init(heard: "(quiet) \(words)"))
            return true
        }
        if engine.state != .recording, Self.matches(Self.quietPhrases, words) {
            log.kind = "quiet on"
            log.transcript = words
            setQuiet(true)
            return true
        }
        return false
    }

    // MARK: Utterances

    /// Queue an utterance; they are handled one at a time, in order, and none is dropped.
    func hear(_ heard: Heard) async {
        let id = nextQueued
        nextQueued += 1
        startEarly(heard, id: id)
        queue.append(Queued(id: id, heard: heard))
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        while !queue.isEmpty {
            await handle(queue.removeFirst())
        }
    }

    /// Mid-set what he says is read in the set's own state, so a sound's words and its reading start the
    /// moment it's heard instead of waiting their turn. Oct
    /// 30: ten clanks were queued ahead of a "done", each waiting 3-8 s for its file transcription in
    /// order, and the "done" waited 7 s. The turns are still applied in order, and read again if the
    /// set has ended by then ("done" then "eleven").
    private func startEarly(_ heard: Heard, id: Int) {
        guard engine.state == .recording, heard.transcript == nil, heard.words != nil || heard.wav != nil else { return }
        let request = SessionTurnRequest(transcript: "", state: engine.context.state, recentTurns: Array(exchanges.suffix(Self.recentTurns)),
                                         facts: engine.turnFacts(now: now()))
        earlyInputs[id] = (heard, request)
        earlyTasks[id] = Task { [weak self] in await self?.readEarly(id) }
    }

    private func readEarly(_ id: Int) async {
        guard let input = earlyInputs.removeValue(forKey: id) else { return }
        var heard = input.heard
        var request = input.request
        var early = EarlyTurn(state: request.state)
        if let words = heard.words {
            heard.transcript = await words()
            if heard.transcript != nil { early.wordsAt = now() }
        }
        heard.words = nil
        early.transcript = heard.transcript
        request.transcript = heard.transcript ?? ""
        do {
            early.response = try await classify(heard, request)
        } catch {
            early.error = error
        }
        earlyTurns[id] = early
    }

    /// Everything queued has been handled (for tests and the rehearsal screen).
    var isIdle: Bool { !isBusy && queue.isEmpty }

    private func handle(_ queued: Queued) async {
        var heard = queued.heard
        var log = SessionDebug.UtteranceRecord(at: heard.speechEndedAt, seconds: heard.seconds, state: engine.context.state)
        log.kind = "utterance"
        (log.input, log.voiceProcessing) = inputState()
        var early: EarlyTurn?
        if let task = earlyTasks.removeValue(forKey: queued.id) {
            await task.value
            early = earlyTurns.removeValue(forKey: queued.id)
            heard.words = nil
            heard.transcript = early?.transcript
            if let at = early?.wordsAt { log.toTranscript = at.timeIntervalSince(heard.speechEndedAt) }
            if (heard.transcript ?? "").isEmpty, let words = early?.response?.transcript, !words.isEmpty {
                heard.transcript = words // the file's words, so a reading in another state needn't send it again
            }
        } else if heard.transcript == nil, let words = heard.words {
            heard.transcript = await words()
            if heard.transcript != nil { log.toTranscript = now().timeIntervalSince(heard.speechEndedAt) }
        }
        if handleQuiet(heard.transcript, log: &log) {
            record(log)
            return
        }
        reading = heard.transcript
        defer { reading = nil }
        // The chime the moment he's heard, before the turn's ~2 s: never mid-set, where it waits for a set command.
        var chimed = false
        if engine.state != .recording, let words = heard.transcript, words.contains(where: \.isLetter) {
            chime()
            chimed = true
        }
        let request = SessionTurnRequest(transcript: heard.transcript ?? "", state: engine.context.state,
                                         recentTurns: Array(exchanges.suffix(Self.recentTurns)), facts: engine.turnFacts(now: now()))
        let turn: SessionTurnResponse
        do {
            if let early, early.state == request.state || (heard.transcript ?? "").isEmpty {
                turn = try early.turn()
            } else {
                turn = try await classify(heard, request)
            }
        } catch {
            // A failed or slow request is never a spoken error: the HUD says so and the mic carries on.
            log.error = String(describing: error)
            record(log)
            show(.init(heard: "Didn't catch that"))
            return
        }
        log.transcript = turn.transcript
        log.intent = turn.actions.first?.intent.rawValue
        log.number = turn.actions.first?.number
        log.actions = turn.actions.map(\.intent.rawValue)
        log.classifiedBy = turn.classifiedBy
        log.addressed = turn.addressed
        log.reply = turn.reply
        log.toIntent = now().timeIntervalSince(heard.speechEndedAt)
        let outcome = apply(turn)
        if !chimed, outcome.speech != nil || outcome.echo != nil { chime() }
        if turn.addressed, !turn.transcript.isEmpty { exchanges.append(Exchange(heard: turn.transcript, said: outcome.speech)) }
        log.spoken = outcome.speech
        log.toFirstAudio = outcome.speech == nil ? nil : now().timeIntervalSince(heard.speechEndedAt)
        record(log)
        show(outcome)
    }

    /// The turn's actions on the engine, in order, and what to say. Mid-set only what makes sense
    /// under the bar acts (`actsMidSet`). The reply stands in for the templates unless an action asked
    /// something, and mid-set it's said only when every action in the turn could act.
    private func apply(_ turn: SessionTurnResponse) -> SessionEngine.Outcome {
        guard turn.addressed else { return .init(heard: turn.transcript.isEmpty ? nil : turn.transcript) }
        let wasRecording = engine.state == .recording
        let commands = wasRecording ? turn.commands.filter(Self.actsMidSet) : turn.commands
        let dropped = commands.count < turn.commands.count
        if wasRecording, commands.isEmpty, dropped || (turn.reply ?? "").isEmpty {
            // Mid-set: grunts, counting aloud, someone else, or a command that waits for the rest.
            return .init(heard: turn.transcript.isEmpty ? nil : turn.transcript)
        }
        let askBefore = engine.pendingAskText
        var outcome = SessionEngine.Outcome.none
        var counted = false
        for command in commands {
            // The camera's count belongs to the set it was filming: only the first count can end it.
            let counts = wasRecording && !counted && [.endSet, .reps].contains(command.intent.intent)
            let camera = counts ? cameraSet() : nil
            counted = counted || counts
            outcome = outcome.merged(with: engine.apply(command, now: now(), phone: camera?.phone, willMeasure: camera?.willMeasure ?? false))
            applied(command, wasRecording)
        }
        let openedAsk = engine.pendingAskText != nil && engine.pendingAskText != askBefore
        if let reply = turn.reply, !reply.isEmpty, !openedAsk, !(wasRecording && dropped) {
            outcome.speech = reply
            if commands.isEmpty { outcome.echo = reply }
        }
        return outcome
    }

    private func showLastLine(_ line: String) {
        lastLine = line
        lastLineTask?.cancel()
        lastLineTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(8))
            if !Task.isCancelled { self?.lastLine = nil }
        }
    }

    /// He spoke over a line: it stopped, and the lines waiting behind it are dropped (they're on the HUD).
    func interrupt() {
        speechQueue.removeAll()
    }

    /// What may act during a set (Oct 30: "I need to be able to say anything to it during the set"):
    /// "done", counts and "top set", a question, a note, this set's weight, and "this is another set of
    /// laterals". The backend only sends these mid-set, and only Spark's when the words sounded meant for
    /// Setecho; anything else waits for the rest.
    static func actsMidSet(_ response: VoiceCommandResponse) -> Bool {
        [.endSet, .reps, .topSet, .question, .note, .setLoad, .loadDelta, .addSet].contains(response.intent.intent)
    }

    // MARK: The clock

    /// One second: the rest countdown, a lead-in's count, a hold's countdown, and the 60 s
    /// fallback when SAM is late.
    func tick() {
        let at = now()
        engine.tickArm(at: at)
        show(engine.tickRest())
        show(engine.tickLeadIn(at: at))
        show(engine.tickHold(at: at))
        show(engine.tick(now: at))
    }

    // MARK: Output

    func show(_ outcome: SessionEngine.Outcome) {
        if let tone = outcome.sound { sound(tone) }
        if let text = outcome.echo {
            echo = text
            echoTask?.cancel()
            echoTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(6))
                if !Task.isCancelled { self?.echo = nil }
            }
        }
        if let text = outcome.heard {
            heard = "Heard: \(text)"
            heardTask?.cancel()
            heardTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(3))
                if !Task.isCancelled { self?.heard = nil }
            }
        }
        if outcome.askBack != nil || outcome.echo != nil { askBack = outcome.askBack ?? engine.pendingAskText }
        if let replaceable = outcome.spotterReplaceable, !replaceable.isEmpty { spokenLine = replaceable }
        if let speech = outcome.speech { say(speech) }
        if let facts = outcome.spotterFacts, facts.repSource != RepSource.plan.rawValue, facts.role != SetRole.warmup.rawValue {
            reactAfter(facts)
        }
    }

    /// The reaction comes after the facts, during the rest, and only if nothing has happened since:
    /// no new utterance, no set started, nothing waiting on his answer.
    private func reactAfter(_ facts: SpotterFacts) {
        guard let react else { return }
        let mark = said.count
        let recent = Array(said.suffix(5))
        Task { [weak self] in
            guard let text = await react(facts, recent), !text.isEmpty, let self else { return }
            guard case .rest = self.engine.state, self.engine.pendingAsk == nil, self.said.count == mark, self.queue.isEmpty else { return }
            self.say(text)
        }
    }

    /// Lines go to the voice one at a time, in the order they were made.
    func say(_ template: String) {
        talkTurn += 1
        let line = rephrase?(template, talkTurn, said.last) ?? template
        said.append(line)
        engine.lastSpoken = line
        speechQueue.append(line)
        guard !speaking else { return }
        speaking = true
        Task {
            while !speechQueue.isEmpty {
                let next = speechQueue.removeFirst()
                speakingLine = next
                speakingSince = .now
                await speak(next)
                speakingLine = nil
                showLastLine(next)
            }
            speaking = false
        }
    }
}
