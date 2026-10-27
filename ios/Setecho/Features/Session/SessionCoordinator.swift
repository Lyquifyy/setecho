import Foundation
import Observation

/// Wires the session together: the engine decides, the audio service listens and speaks, the set
/// detector watches the bar, the backend reads commands, the store keeps the result.
@MainActor
@Observable
final class SessionCoordinator {
    let engine: SessionEngine
    let audio = AudioService()
    let detector: SetDetector
    private(set) var echo: String?
    private(set) var askBack: String?
    private(set) var isUploading = false
    private(set) var permissionsDenied = false
    private(set) var started = false
    private(set) var didSave = false

    private let api: APIClient
    private let store: Store
    private var restTask: Task<Void, Never>?
    private var echoTask: Task<Void, Never>?

    init(day: ProgramDay, weekNumber: Int, store: Store, api: APIClient = APIClient()) {
        self.engine = SessionEngine(day: day, weekNumber: weekNumber)
        self.store = store
        self.api = api
        self.detector = SetDetector(mediaDirectory: store.mediaDirectory, sessionId: engine.session.id)
    }

    var state: SessionEngine.State { engine.state }

    var hudState: HUDState.State {
        switch engine.state {
        case .ready: .ready
        case .recording: .recording
        case .saved: .saved
        case .rest(let remaining): .rest(remaining: remaining)
        case .listening: .listening
        case .paused: .paused
        case .ended: .ended
        }
    }

    // MARK: Lifecycle

    func start() async {
        guard !started else { return }
        let mic = await audio.requestMicrophone()
        let camera = await SetDetector.requestCamera()
        guard mic else {
            permissionsDenied = true
            return
        }
        started = true
        audio.configure()
        audio.onUtterance = { [weak self] utterance in
            Task { await self?.handle(utterance) }
        }
        audio.startListening()
        if camera {
            detector.onSetStart = { [weak self] _ in self?.setStarted() }
            detector.onSetEnd = { [weak self] clip, _ in self?.setEnded(clip: clip) }
            detector.start()
        }
        await speak(intro)
    }

    private var intro: String {
        guard let ex = engine.currentExercise else { return "Nothing planned for today." }
        return "\(engine.day.name). \(ex.name), \(Callout.target(load: engine.targetLoadLb, reps: engine.targetRepsText)). Lift when ready, or say starting."
    }

    /// The long-press End session, or "end session" by voice.
    func end() {
        engine.endSession()
        finish()
    }

    private func finish() {
        guard !didSave else { return }
        didSave = true
        restTask?.cancel()
        detector.stop()
        audio.stopListening()
        store.upsert(session: engine.session)
    }

    // MARK: Set detection

    private func setStarted() {
        let outcome = engine.setStarted()
        show(outcome)
    }

    private func setEnded(clip: String?) {
        if let clip { engine.attachClip(clip) }
        let outcome = engine.setEnded()
        show(outcome)
        afterStateChange()
    }

    private func afterStateChange() {
        if case .rest = engine.state { startRestTimer() }
        if engine.state == .ended { finish() }
    }

    private func startRestTimer() {
        restTask?.cancel()
        restTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self else { return }
                guard case .rest = self.engine.state else { return }
                let outcome = self.engine.tickRest()
                if outcome != .none { self.show(outcome) }
            }
        }
    }

    // MARK: Voice

    private func handle(_ utterance: VoiceDetector.Utterance) async {
        // Listen only in Ready and Rest (HANDOFF.md §7): gym noise during a set never becomes a command.
        guard engine.state.isListeningAllowed, !isUploading else { return }
        let pcm = Resample.toInt16Mono(utterance.samples, from: utterance.sampleRate, to: 16_000)
        guard pcm.count > 16_000 / 4 else { return } // under a quarter second: a clank, not a word
        let wav = WAVFile.data(pcm16: pcm, sampleRate: 16_000)
        isUploading = true
        defer { isUploading = false }
        do {
            let response = try await api.voiceCommand(wav: wav, context: engine.context)
            let outcome = engine.apply(response)
            show(outcome)
            afterStateChange()
        } catch {
            show(.init(speech: nil, echo: "Couldn't hear the backend: \(error.localizedDescription)", askBack: nil))
        }
    }

    /// A tap-free fallback for testing: apply a typed command as if transcribed.
    func simulate(_ response: VoiceCommandResponse) {
        show(engine.apply(response))
        afterStateChange()
    }

    // MARK: Output

    private func show(_ outcome: SessionEngine.Outcome) {
        if let text = outcome.echo {
            echo = text
            echoTask?.cancel()
            echoTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(6))
                if !Task.isCancelled { self?.echo = nil }
            }
        }
        askBack = outcome.askBack
        if let speech = outcome.speech {
            Task { await speak(speech) }
        }
    }

    private func speak(_ text: String) async {
        await audio.speak(text)
    }
}
