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
/// During a set only the rule layer's set commands count ("done", "done, 12", "that was 8", "top
/// set"); everything else then is noise. Talk not meant for Setecho is never answered: the HUD
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
    /// One record per utterance for the session's debug JSON.
    @ObservationIgnored var record: (SessionDebug.UtteranceRecord) -> Void = { _ in }
    @ObservationIgnored var now: () -> Date = { .now }
    /// The live input and voice processing, for the debug record.
    @ObservationIgnored var inputState: () -> (input: String, voiceProcessing: Bool) = { ("", false) }

    /// The session's exchanges, for follow-ups ("what about the other one?", "same as last set").
    private(set) var exchanges: [Exchange] = []
    static let recentTurns = 8
    private var queue: [Heard] = []
    private var speechQueue: [String] = []
    private var speaking = false
    private var echoTask: Task<Void, Never>?
    private var heardTask: Task<Void, Never>?

    init(engine: SessionEngine) {
        self.engine = engine
    }

    // MARK: Utterances

    /// Queue an utterance; they are handled one at a time, in order, and none is dropped.
    func hear(_ heard: Heard) async {
        queue.append(heard)
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        while !queue.isEmpty {
            await handle(queue.removeFirst())
        }
    }

    /// Everything queued has been handled (for tests and the rehearsal screen).
    var isIdle: Bool { !isBusy && queue.isEmpty }

    private func handle(_ heard: Heard) async {
        var heard = heard
        var log = SessionDebug.UtteranceRecord(at: heard.speechEndedAt, seconds: heard.seconds, state: engine.context.state)
        log.kind = "utterance"
        (log.input, log.voiceProcessing) = inputState()
        if heard.transcript == nil, let words = heard.words {
            heard.transcript = await words()
            if heard.transcript != nil { log.toTranscript = now().timeIntervalSince(heard.speechEndedAt) }
        }
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
            turn = try await classify(heard, request)
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

    /// The turn's actions on the engine, in order, and what to say. Mid-set only the rules' set
    /// commands act. The reply stands in for the templates unless an action asked something.
    private func apply(_ turn: SessionTurnResponse) -> SessionEngine.Outcome {
        guard turn.addressed else { return .init(heard: turn.transcript.isEmpty ? nil : turn.transcript) }
        let wasRecording = engine.state == .recording
        let commands = wasRecording ? turn.commands.filter(Self.isSetCommand) : turn.commands
        if wasRecording, commands.isEmpty {
            // Mid-set: grunts, counting aloud, someone else. Never a command.
            return .init(heard: turn.transcript.isEmpty ? nil : turn.transcript)
        }
        let askBefore = engine.pendingAskText
        var outcome = SessionEngine.Outcome.none
        for (i, command) in commands.enumerated() {
            // The camera's count belongs to the set it was filming: only the first command can end it.
            let camera = wasRecording && i == 0 ? cameraSet() : nil
            outcome = outcome.merged(with: engine.apply(command, now: now(), phone: camera?.phone, willMeasure: camera?.willMeasure ?? false))
            applied(command, wasRecording)
        }
        let openedAsk = engine.pendingAskText != nil && engine.pendingAskText != askBefore
        if let reply = turn.reply, !reply.isEmpty, !openedAsk {
            outcome.speech = reply
            if commands.isEmpty { outcome.echo = reply }
        }
        return outcome
    }

    /// He spoke over a line: it stopped, and the lines waiting behind it are dropped (they're on the HUD).
    func interrupt() {
        speechQueue.removeAll()
    }

    /// What may act during a set: the rule layer's "done", counts and "top set".
    static func isSetCommand(_ response: VoiceCommandResponse) -> Bool {
        guard response.intent.intent != .chatter else { return false }
        guard response.classifiedBy == nil || response.classifiedBy == "rules" else { return false }
        return [.endSet, .reps, .topSet].contains(response.intent.intent)
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
    }

    /// Lines go to the voice one at a time, in the order they were made.
    func say(_ line: String) {
        said.append(line)
        engine.lastSpoken = line
        speechQueue.append(line)
        guard !speaking else { return }
        speaking = true
        Task {
            while !speechQueue.isEmpty {
                await speak(speechQueue.removeFirst())
            }
            speaking = false
        }
    }
}
