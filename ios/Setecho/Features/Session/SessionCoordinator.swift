import Foundation
import Observation

/// Wires the session together: the engine decides, the audio service listens and speaks, the set
/// detector watches the bar and counts, the backend reads commands and measures reps from the
/// clip (SAM is the count of record; the phone's count is the silent fallback), the store keeps
/// the result.
@MainActor
@Observable
final class SessionCoordinator {
    let engine: SessionEngine
    let audio = AudioService()
    /// The one voice (HANDOFF.md §7): callouts are built from the moment, so they are spoken live.
    @ObservationIgnored private let voice: SystemSpeaker
    let detector: SetDetector
    private(set) var echo: String?
    private(set) var askBack: String?
    private(set) var isUploading = false
    private(set) var permissionsDenied = false
    private(set) var started = false
    private(set) var didSave = false
    private(set) var countsInFlight = 0
    /// Filming mode: every line and utterance saved with one clock, off the speaking path.
    private(set) var filming: FilmingRecorder?
    private(set) var showSlate = false

    private let api: APIClient
    private let store: Store
    /// One tick a second: the rest countdown, and the 60 s fallback when SAM is late (HANDOFF.md §7).
    private var clockTask: Task<Void, Never>?
    private var echoTask: Task<Void, Never>?
    private var cameraOn = false
    /// The set the camera is filming, by its real start on the capture clock.
    private var currentSetStart: Double?
    /// Logged sets waiting for their clips, keyed by the set's capture-clock start.
    private var setsAwaitingClips: [Double: UUID] = [:]

    /// Retry delays for a clip upload, about ten minutes in all (HANDOFF.md §7, Rep counting).
    static let uploadRetryDelays: [Double] = [10, 30, 60, 120, 180, 200]

    /// The day's session with the add-ons joining it today, or a morning session of one add-on
    /// (day nil). The engine gets his confirmed warm-up rule and the add-ons "add abs" can bring in.
    init(day: ProgramDay?, addOns: [AddOn] = [], weekNumber: Int, store: Store, api: APIClient = APIClient(), settings: Settings = .shared) {
        let plan = store.plan
        self.engine = SessionEngine(day: day, addOns: addOns,
                                    availableAddOns: plan?.program.addOns.filter { $0.timing == .withSession } ?? [],
                                    weekNumber: weekNumber, warmups: plan?.warmups,
                                    rules: plan?.rules ?? [], roleTargets: plan?.roleTargets ?? [], restRules: plan?.restRules ?? [],
                                    loadSteps: settings.loadSteps, lastSets: store.lastSets, nextSessionLoads: store.nextSessionLoads,
                                    suggestionsEnabled: settings.nextSetSuggestions, calibration: store.calibration,
                                    athleteName: settings.athleteFirstName.isEmpty ? nil : settings.athleteFirstName)
        self.store = store
        self.api = api
        self.voice = SystemSpeaker(audio: audio, cacheDirectory: store.mediaDirectory.appendingPathComponent("voice", isDirectory: true))
        self.detector = SetDetector(mediaDirectory: store.mediaDirectory, sessionId: engine.session.id)
        if settings.coachVoiceInSessions {
            engine.cues = Dictionary(store.cues.filter(\.approved).map { ($0.exerciseId, $0) }, uniquingKeysWith: { a, _ in a })
        }
    }

    /// "I'm doing Day 5 today" before any set: the view rebuilds the session on that day.
    var requestedDayNumber: Int? { engine.requestedDayNumber }

    var state: SessionEngine.State { engine.state }

    var hudState: HUDState.State {
        switch engine.state {
        case .ready: engine.warmupMode ? .warmup(engine.warmupCount + 1) : .ready
        case .recording: .recording
        case .saved: .saved
        case .rest(let remaining): .rest(remaining: remaining)
        case .hold(let remaining): .hold(remaining: remaining)
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
        Task { [api] in _ = try? await api.health() } // warm the backend's route before the first set
        if Settings.shared.filmingMode {
            let recorder = FilmingRecorder(root: store.mediaDirectory, kind: "session")
            filming = recorder
            showSlate = true
            recorder.slate()
            Task { try? await Task.sleep(for: .milliseconds(300)); showSlate = false }
        }
        audio.configure()
        audio.onUtterance = { [weak self] utterance in
            Task { await self?.handle(utterance) }
        }
        audio.startListening()
        startClock()
        if camera {
            cameraOn = true
            detector.onSetStart = { [weak self] start in self?.cameraSetStarted(at: start) }
            detector.onSetEnd = { [weak self] end in self?.cameraSetEnded(at: end) }
            detector.onClipsReady = { [weak self] clips in self?.clipsReady(clips) }
            detector.start()
        }
        await speak(intro)
        await playCueIfDue()
    }

    /// The coach's cue for the current exercise, once, in Ready, before its first set (HANDOFF.md §7).
    private func playCueIfDue() async {
        guard let cue = engine.cueDue() else { return }
        engine.cuePlayed(cue)
        echo = "Coach · \(engine.currentExercise?.name ?? "")\n“\(cue.text)”"
        await play(cue)
    }

    private func play(_ cue: VoiceCue) async {
        if let file = cue.audioFile {
            await audio.play(file: store.cuesDirectory.appendingPathComponent(file))
        } else {
            await speak("Coach says: \(cue.text)")
        }
        var played = cue
        played.lastPlayedAt = .now
        store.update(cue: played)
    }

    private var intro: String {
        guard let ex = engine.currentExercise else { return "Nothing planned for today." }
        if engine.currentSetIsTimed { return "\(engine.title). \(ex.name), \(engine.targetRepsText). Say go." }
        var line = "\(engine.title). \(ex.name), \(Callout.target(load: engine.targetLoadLb, reps: engine.targetRepsText))."
        if let logbook = engine.logbookLine(for: ex) { line += " \(logbook)" }
        line += engine.warmupMode ? " Warm-ups first." : " Lift when ready, or say starting."
        if engine.needsLoad { line += " Weight for the top set?" }
        return line
    }

    /// The long-press End session, or "end session" by voice.
    func end() {
        engine.endSession()
        finish()
    }

    private func finish() {
        guard !didSave else { return }
        didSave = true
        clockTask?.cancel()
        detector.stop()
        audio.stopListening()
        for file in countFilesHeld.values { try? FileManager.default.removeItem(at: store.mediaDirectory.appendingPathComponent(file)) }
        countFilesHeld.removeAll()
        save()
    }

    private func save() {
        store.upsert(session: engine.session)
        for sample in engine.calibrationSamples.dropFirst(savedCalibrationSamples) {
            store.addCalibration(exerciseId: sample.exerciseId, velocityLossPct: sample.velocityLossPct, rpe: sample.rpe)
        }
        savedCalibrationSamples = engine.calibrationSamples.count
    }

    private var savedCalibrationSamples = 0

    // MARK: Set detection

    private func cameraSetStarted(at start: Double) {
        // A timed set is a countdown, never a camera set (HANDOFF.md §7, Timed sets).
        guard !engine.currentSetIsTimed else { return }
        currentSetStart = start
        detector.restPause = engine.currentSetIsRestPause
        show(engine.setStarted())
    }

    private func cameraSetEnded(at end: Double) {
        let start = currentSetStart
        currentSetStart = nil
        detector.restPause = false
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
            show(engine.countFailed(setId: setId))
            return
        }
        // A warm-up is never uploaded (HANDOFF.md §7, Warm-up sets); its count file waits in case
        // the athlete says "that was my top set".
        guard engine.shouldUpload(setId: setId) else {
            countFilesHeld[setId] = countFile
            return
        }
        Task { await upload(countFile: countFile, for: setId) }
    }

    /// Count clips of warm-ups, kept until the session ends in case a warm-up becomes a working set.
    private var countFilesHeld: [UUID: String] = [:]

    /// A warm-up reclassified by voice uploads then (HANDOFF.md §7).
    private func uploadReclassified() {
        for setId in engine.setsNeedingUpload() {
            guard let file = countFilesHeld.removeValue(forKey: setId) else { continue }
            Task { await upload(countFile: file, for: setId) }
        }
    }

    /// Send the small clip to /sets/count, retrying in the background for about ten minutes.
    private func upload(countFile: String, for setId: UUID) async {
        let url = store.mediaDirectory.appendingPathComponent(countFile)
        defer { try? FileManager.default.removeItem(at: url) }
        guard let data = try? Data(contentsOf: url),
              let set = engine.session.sets.first(where: { $0.id == setId }),
              let exercise = engine.exercises.first(where: { $0.exercise.id == set.exerciseId })?.exercise
        else {
            show(engine.countFailed(setId: setId))
            return
        }
        let planned = exercise.sets.indices.contains(set.setIndex) ? exercise.sets[set.setIndex] : nil
        let context = CountContext(exerciseId: set.exerciseId, equipment: exercise.equipment,
                                   plannedReps: planned?.reps ?? planned?.repsMin, phoneReps: set.repCount.phone,
                                   setRole: set.role?.rawValue)
        countsInFlight += 1
        defer { countsInFlight -= 1 }
        for (attempt, delay) in ([0.0] + Self.uploadRetryDelays).enumerated() {
            if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
            guard !didSave || attempt == 0 else { break } // the session is over: stop retrying
            do {
                let response = try await api.countSet(mp4: data, context: context)
                logCount(setId: setId, attempt: attempt, response: response, error: nil)
                let outcome = engine.measured(setId: setId, response, now: .now)
                show(outcome)
                if didSave { save() }
                return
            } catch let error as APIError where (400..<500).contains(error.status) {
                logCount(setId: setId, attempt: attempt, response: nil, error: String(describing: error))
                break // a bad clip will not get better with retries
            } catch {
                logCount(setId: setId, attempt: attempt, response: nil, error: String(describing: error))
                continue
            }
        }
        show(engine.countFailed(setId: setId))
        if didSave { save() }
    }

    /// Every answer and failure, with its latency, for the session's debug JSON (HANDOFF.md §9, P5).
    private func logCount(setId: UUID, attempt: Int, response: CountResponse?, error: String?) {
        let endedAt = engine.session.sets.first { $0.id == setId }?.endedAt
        let record = SessionDebug.CountAttempt(setId: setId, attempt: attempt, at: .now,
                                               secondsAfterSetEnd: endedAt.map { Date.now.timeIntervalSince($0) },
                                               response: response, error: error)
        SessionDebug.append(record, sessionId: engine.session.id, in: store.mediaDirectory)
    }

    /// Median seconds from set end to SAM's result this session (HANDOFF.md §9, P1b latency report).
    var medianCountLatency: TimeInterval? { engine.medianCountLatency }

    private func afterStateChange() {
        if engine.state == .ended { finish() }
        if engine.state == .ready { Task { await playCueIfDue() } }
    }

    /// The session clock: every second, the rest countdown ticks, and a set SAM has not answered
    /// within 60 s gets the phone's count spoken.
    private func startClock() {
        clockTask?.cancel()
        clockTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, !self.didSave else { return }
                let rest = self.engine.tickRest()
                if rest != .none {
                    self.show(rest)
                    if self.engine.state == .ready { await self.playCueIfDue() }
                }
                let hold = self.engine.tickHold(at: .now)
                if hold != .none {
                    self.show(hold)
                    self.afterStateChange()
                }
                let fallback = self.engine.tick(now: .now)
                if fallback != .none { self.show(fallback) }
            }
        }
    }

    // MARK: Voice

    private func handle(_ utterance: VoiceDetector.Utterance) async {
        // Listen only in Ready and Rest (HANDOFF.md §7): gym noise during a set never becomes a command.
        guard engine.state.isListeningAllowed, !isUploading else { return }
        let pcm = Resample.toInt16Mono(utterance.samples, from: utterance.sampleRate, to: 16_000)
        guard pcm.count > 16_000 / 4 else { return } // under a quarter second: a clank, not a word
        filming?.heard(pcm16: pcm, sampleRate: 16_000)
        let wav = WAVFile.data(pcm16: pcm, sampleRate: 16_000)
        isUploading = true
        defer { isUploading = false }
        do {
            let response = try await api.voiceCommand(wav: wav, context: engine.context)
            filming?.transcribed(response.transcript)
            apply(response)
        } catch {
            show(.init(speech: nil, echo: error.userMessage, askBack: nil))
        }
    }

    /// A tap-free fallback for testing: apply a typed command as if transcribed.
    func simulate(_ response: VoiceCommandResponse) {
        apply(response)
    }

    private func apply(_ response: VoiceCommandResponse) {
        let wasRecording = engine.state == .recording
        let outcome = engine.apply(response)
        if response.intent.intent == .replayCue, let cue = engine.cueToReplay() {
            Task { await play(cue) }
        }
        if wasRecording, engine.state != .recording, cameraOn {
            // "Done" by voice: close the clip the camera was filming for this set.
            if let start = currentSetStart, let setId = engine.lastLoggedSetId { setsAwaitingClips[start] = setId }
            currentSetStart = nil
            detector.restPause = false
            detector.endSetByVoice()
        }
        if response.intent.intent == .topSet { uploadReclassified() }
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
            Task { await speak(speech, facts: outcome.spotterFacts, replaceable: outcome.spotterReplaceable) }
        }
    }

    /// A rest-time line goes through /spotter/line first (HANDOFF.md §7, The spotter voice): the
    /// model's line replaces the templated facts when the validator passed it, within a few seconds;
    /// otherwise the template is spoken. The next target and the suggestion's ask are always spoken.
    private func speak(_ text: String, facts: SpotterFacts?, replaceable: String?) async {
        guard let facts, let replaceable, !replaceable.isEmpty, text.contains(replaceable) else {
            await speak(text)
            return
        }
        let request = SpotterLineRequest(moment: "restAfterSet", facts: facts, recent: engine.recentLines,
                                         styleHints: [engine.athleteName.map { "first name: \($0)" } ?? "no name", "casual"])
        if let line = try? await api.spotterLine(request), line.ok, !line.text.isEmpty {
            spokenLine = line.text
            await speak(text.replacingOccurrences(of: replaceable, with: line.text))
        } else {
            spokenLine = replaceable
            await speak(text)
        }
    }

    /// The rest-time line being spoken, as text on the HUD (DESIGN.md Session, Rest).
    private(set) var spokenLine: String?

    private func speak(_ text: String) async {
        filming?.spoke(text, voice: AudioService.preferredVoice())
        await voice.speak(text)
    }
}
