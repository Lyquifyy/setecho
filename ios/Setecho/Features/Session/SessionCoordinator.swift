import Foundation
import Observation

/// Wires the session together: the engine decides, the audio service listens and speaks, the set
/// detector watches the bar and counts, the backend reads commands and measures reps from the
/// clip, the store keeps the result.
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
    private(set) var countsInFlight = 0

    private let api: APIClient
    private let store: Store
    private var restTask: Task<Void, Never>?
    private var echoTask: Task<Void, Never>?
    private var cameraOn = false
    /// The set the camera is filming, by its real start on the capture clock.
    private var currentSetStart: Double?
    /// Logged sets waiting for their clips, keyed by the set's capture-clock start.
    private var setsAwaitingClips: [Double: UUID] = [:]

    /// Retry delays for a clip upload, about ten minutes in all (HANDOFF.md §7, Rep counting).
    static let uploadRetryDelays: [Double] = [10, 30, 60, 120, 180, 200]

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
            cameraOn = true
            detector.onSetStart = { [weak self] start in self?.cameraSetStarted(at: start) }
            detector.onSetEnd = { [weak self] end in self?.cameraSetEnded(at: end) }
            detector.onClipsReady = { [weak self] clips in self?.clipsReady(clips) }
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
        save()
    }

    private func save() {
        store.upsert(session: engine.session)
    }

    // MARK: Set detection

    private func cameraSetStarted(at start: Double) {
        currentSetStart = start
        show(engine.setStarted())
    }

    private func cameraSetEnded(at end: Double) {
        let start = currentSetStart
        currentSetStart = nil
        let phone = start.flatMap { detector.phoneCount(from: $0, to: end) }
        let outcome = engine.setEnded(phone: phone, willMeasure: true)
        if let start, let setId = engine.lastLoggedSetId { setsAwaitingClips[start] = setId }
        show(outcome)
        afterStateChange()
    }

    private func clipsReady(_ clips: SetDetector.Clips) {
        guard let setId = setsAwaitingClips.removeValue(forKey: clips.setStart) else { return }
        if let clip = clips.clipFile { engine.attachClip(setId: setId, file: clip) }
        guard let countFile = clips.countFile else {
            engine.countFailed(setId: setId)
            return
        }
        Task { await upload(countFile: countFile, for: setId) }
    }

    /// Send the small clip to /sets/count, retrying in the background for about ten minutes.
    private func upload(countFile: String, for setId: UUID) async {
        let url = store.mediaDirectory.appendingPathComponent(countFile)
        defer { try? FileManager.default.removeItem(at: url) }
        guard let data = try? Data(contentsOf: url),
              let set = engine.session.sets.first(where: { $0.id == setId }),
              let exercise = engine.day.exercises.first(where: { $0.id == set.exerciseId })
        else {
            engine.countFailed(setId: setId)
            return
        }
        let planned = exercise.sets.indices.contains(set.setIndex) ? exercise.sets[set.setIndex] : nil
        let context = CountContext(exerciseId: set.exerciseId, equipment: exercise.equipment,
                                   plannedReps: planned?.reps ?? planned?.repsMin, phoneReps: set.repCount.phone)
        countsInFlight += 1
        defer { countsInFlight -= 1 }
        for (attempt, delay) in ([0.0] + Self.uploadRetryDelays).enumerated() {
            if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
            guard !didSave || attempt == 0 else { break } // the session is over: stop retrying
            do {
                let response = try await api.countSet(mp4: data, context: context)
                let outcome = engine.measured(setId: setId, response)
                show(outcome)
                if didSave { save() }
                return
            } catch let error as APIError where (400..<500).contains(error.status) {
                break // a bad clip will not get better with retries
            } catch {
                continue
            }
        }
        engine.countFailed(setId: setId)
        if didSave { save() }
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
            apply(response)
        } catch {
            show(.init(speech: nil, echo: "Couldn't hear the backend: \(error.localizedDescription)", askBack: nil))
        }
    }

    /// A tap-free fallback for testing: apply a typed command as if transcribed.
    func simulate(_ response: VoiceCommandResponse) {
        apply(response)
    }

    private func apply(_ response: VoiceCommandResponse) {
        let wasRecording = engine.state == .recording
        let outcome = engine.apply(response)
        if wasRecording, engine.state != .recording, cameraOn {
            // "Done" by voice: close the clip the camera was filming for this set.
            if let start = currentSetStart, let setId = engine.lastLoggedSetId { setsAwaitingClips[start] = setId }
            currentSetStart = nil
            detector.endSetByVoice()
        }
        show(outcome)
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
        if outcome.askBack != nil || outcome.echo != nil { askBack = outcome.askBack }
        if let speech = outcome.speech {
            Task { await speak(speech) }
        }
    }

    private func speak(_ text: String) async {
        await audio.speak(text)
    }
}
