import Foundation
import Observation

/// The talk between sets (HANDOFF.md §7, The between-set conversation): every utterance heard is
/// queued and handled in order, read by the backend, applied to the engine and answered; the
/// session clock's ticks speak through it too. No devices here: the coordinator wires in the
/// backend, the voice, the camera and the chime, and `ConversationTests` wire in fakes, so the path
/// the athlete uses is the path the tests drive.
///
/// During a set only the rule layer's set commands count ("done", "done, 12", "that was 8", "top
/// set"); everything else then is noise. Chatter is never answered: the HUD shows "Heard: …".
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

    /// The backend: rules then Spark. Throws on a timeout or a failed request.
    @ObservationIgnored var classify: @MainActor (Heard, SessionContext) async throws -> VoiceCommandResponse = { _, _ in
        throw APIError(status: 0, message: "No backend")
    }
    /// Hand a line to the voice. Lines are spoken in the order given.
    @ObservationIgnored var speak: @MainActor (String) async -> Void = { _ in }
    /// The soft chime the moment a command is heard.
    @ObservationIgnored var chime: () -> Void = {}
    /// The camera is filming the set now under way: its count, and that a clip goes to SAM.
    @ObservationIgnored var cameraSet: () -> (phone: RepCounter.Result?, willMeasure: Bool)? = { nil }
    /// After a command is applied: the coordinator's side of it (close a clip, replay a cue, save the logbook).
    @ObservationIgnored var applied: (VoiceCommandResponse, _ wasRecording: Bool) -> Void = { _, _ in }
    /// One record per utterance for the session's debug JSON.
    @ObservationIgnored var record: (SessionDebug.UtteranceRecord) -> Void = { _ in }
    @ObservationIgnored var now: () -> Date = { .now }

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
        if heard.transcript == nil, let words = heard.words {
            heard.transcript = await words()
            if heard.transcript != nil { log.toTranscript = now().timeIntervalSince(heard.speechEndedAt) }
        }
        let context = engine.context
        let response: VoiceCommandResponse
        do {
            response = try await classify(heard, context)
        } catch {
            // A failed or slow request is never a spoken error: the HUD says so and the mic carries on.
            log.error = String(describing: error)
            record(log)
            show(.init(heard: "Didn't catch that"))
            return
        }
        log.transcript = response.transcript
        log.intent = response.intent.intent.rawValue
        log.number = response.intent.number
        log.classifiedBy = response.classifiedBy
        log.toIntent = now().timeIntervalSince(heard.speechEndedAt)
        var outcome: SessionEngine.Outcome
        let wasRecording = engine.state == .recording
        if wasRecording, !Self.isSetCommand(response) {
            // Mid-set: grunts, counting aloud, someone else. Never a command.
            outcome = .init(heard: response.transcript.isEmpty ? nil : response.transcript)
        } else {
            let camera = wasRecording ? cameraSet() : nil
            outcome = engine.apply(response, now: now(), phone: camera?.phone, willMeasure: camera?.willMeasure ?? false)
            applied(response, wasRecording)
        }
        if outcome.speech != nil || outcome.echo != nil { chime() }
        log.spoken = outcome.speech
        log.toFirstAudio = outcome.speech == nil ? nil : now().timeIntervalSince(heard.speechEndedAt)
        record(log)
        show(outcome)
    }

    /// What may act during a set: the rule layer's "done", counts and "top set".
    static func isSetCommand(_ response: VoiceCommandResponse) -> Bool {
        guard response.classifiedBy == nil || response.classifiedBy == "rules" else { return false }
        return [.endSet, .reps, .topSet].contains(response.intent.intent)
    }

    // MARK: The clock

    /// One second: the rest countdown, a lead-in's count, a hold's countdown, and the 60 s
    /// fallback when SAM is late.
    func tick() {
        let at = now()
        show(engine.tickRest())
        show(engine.tickLeadIn(at: at))
        show(engine.tickHold(at: at))
        show(engine.tick(now: at))
    }

    // MARK: Output

    func show(_ outcome: SessionEngine.Outcome) {
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
