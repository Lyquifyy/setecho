import Foundation
import Observation

/// Wires the session together: the engine decides, the conversation hears and answers (in order,
/// none dropped, the realtime stream's words when it has them), the audio service listens and
/// speaks, the set detector watches the bar and counts, the backend reads commands and measures
/// reps from the clip (SAM is the count of record; the phone's count is the silent fallback), the
/// store keeps the result.
@MainActor
@Observable
final class SessionCoordinator {
    let engine: SessionEngine
    let audio = AudioService()
    /// The one voice (HANDOFF.md §7): callouts are built from the moment, so they are spoken live.
    @ObservationIgnored private let voice: SystemSpeaker
    let detector: SetDetector
    let conversation: SessionConversation
    var echo: String? { conversation.echo }
    var heard: String? { conversation.heard }
    var askBack: String? { conversation.askBack }
    /// The rest-time line being spoken, as text on the HUD (DESIGN.md Session, Rest).
    var spokenLine: String? { conversation.spokenLine }
    private(set) var permissionsDenied = false
    private(set) var started = false
    private(set) var didSave = false
    private(set) var countsInFlight = 0
    /// Filming mode: every line and utterance saved with one clock, off the speaking path.
    private(set) var filming: FilmingRecorder?
    private(set) var showSlate = false

    private let api: APIClient
    private let store: Store
    /// One tick a second: the rest countdown, lead-ins and holds, and the 60 s fallback when SAM is late (HANDOFF.md §7).
    private var clockTask: Task<Void, Never>?
    private var cameraOn = false
    /// Rehearsal (Developer → Session rehearsal): no camera, typed lines through the real backend.
    let rehearsal: Bool
    /// The realtime stream of the utterance being heard now; a new one opens for each utterance.
    private var stream: RealtimeTranscriber?
    /// The set the camera is filming, by its real start on the capture clock.
    private var currentSetStart: Double?
    /// Logged sets waiting for their clips, keyed by the set's capture-clock start.
    private var setsAwaitingClips: [Double: UUID] = [:]

    /// Retry delays for a clip upload, about ten minutes in all (HANDOFF.md §7, Rep counting).
    static let uploadRetryDelays: [Double] = [10, 30, 60, 120, 180, 200]

    /// The day's session with the add-ons joining it today, or a morning session of one add-on
    /// (day nil). The engine gets his confirmed warm-up rule and the add-ons "add abs" can bring in.
    init(day: ProgramDay?, addOns: [AddOn] = [], weekNumber: Int, store: Store, api: APIClient = APIClient(), settings: Settings = .shared,
         rehearsal: Bool = false) {
        let plan = store.plan
        self.engine = SessionEngine(day: day, addOns: addOns,
                                    availableAddOns: plan?.program.addOns.filter { $0.timing == .withSession } ?? [],
                                    weekNumber: weekNumber, warmups: plan?.warmups,
                                    rules: plan?.rules ?? [], roleTargets: plan?.roleTargets ?? [], restRules: plan?.restRules ?? [],
                                    loadSteps: settings.loadSteps, lastSets: store.lastSets, nextSessionLoads: store.nextSessionLoads,
                                    suggestionsEnabled: settings.nextSetSuggestions, calibration: store.calibration,
                                    athleteName: settings.athleteFirstName.isEmpty ? nil : settings.athleteFirstName,
                                    autoHolds: settings.autoStartHolds, takenRule: plan?.takenRule, takenHelp: settings.machineTakenHelp,
                                    variantLoads: store.variantLoads, recentVariants: store.recentVariants)
        self.store = store
        self.api = api
        self.rehearsal = rehearsal
        self.conversation = SessionConversation(engine: engine)
        self.voice = SystemSpeaker(audio: audio, cacheDirectory: store.mediaDirectory.appendingPathComponent("voice", isDirectory: true))
        self.detector = SetDetector(mediaDirectory: store.mediaDirectory, sessionId: engine.session.id, front: settings.frontCameraInSessions)
        if settings.coachVoiceInSessions {
            engine.cues = Dictionary(store.cues.filter(\.approved).map { ($0.exerciseId, $0) }, uniquingKeysWith: { a, _ in a })
        }
        wireConversation()
    }

    private func wireConversation() {
        conversation.classify = { [api, engine] heard, request in
            do {
                if let words = heard.transcript, !words.isEmpty { return try await api.sessionTurn(request) }
                guard let wav = heard.wav else { return SessionTurnResponse(transcript: "", actions: [], addressed: false) }
                return try await api.sessionTurn(wav: wav, request)
            } catch let error as APIError where error.status == 404 {
                // A backend from before the conversation turn: the old command path, one intent.
                let context = engine.context
                if let words = heard.transcript, !words.isEmpty {
                    return SessionTurnResponse(command: try await api.voiceCommand(transcript: words, context: context))
                }
                guard let wav = heard.wav else { throw error }
                return SessionTurnResponse(command: try await api.voiceCommand(wav: wav, context: context))
            }
        }
        conversation.inputState = { [audio] in (audio.inputLabel, audio.voiceProcessingOn) }
        conversation.speak = { [weak self] line in await self?.speak(line) }
        conversation.chime = { [weak self] in self?.audio.playTurnEndSound() }
        conversation.sound = { [weak self] tone in
            self?.audio.output.cue(tone)
            SessionHaptics.play(tone)
        }
        conversation.cameraSet = { [weak self] in
            // "Done" on a set the camera is filming keeps its count and its clip for SAM.
            guard let self, self.cameraOn, let start = self.currentSetStart, let t = self.detector.lastFrameTime else { return nil }
            return (self.detector.phoneCount(from: start, to: t), true)
        }
        conversation.applied = { [weak self] response, wasRecording in self?.afterVoice(response, wasRecording: wasRecording) }
        conversation.record = { [weak self] record in
            guard let self else { return }
            SessionDebug.append(record, sessionId: self.engine.session.id, in: self.store.mediaDirectory)
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
        case .leadIn: .ready
        case .listening: .listening
        case .paused: .paused
        case .ended: .ended
        }
    }

    // MARK: Lifecycle

    func start() async {
        guard !started else { return }
        let mic = await audio.requestMicrophone()
        // A morning of holds never starts the camera: it can't start or end a hold (no 6 AM permission prompt).
        let wantsCamera = !rehearsal && !engine.isAllTimed
        let camera = wantsCamera ? await SetDetector.requestCamera() : false
        guard mic else {
            permissionsDenied = true
            return
        }
        started = true
        let settings = Settings.shared
        let firstSession = settings.sessionsStarted == 0
        if !rehearsal { settings.sessionsStarted += 1 }
        Task { [api] in _ = try? await api.health() } // warm the backend's route before the first set
        if Settings.shared.filmingMode {
            let recorder = FilmingRecorder(root: store.mediaDirectory, kind: "session")
            filming = recorder
            showSlate = true
            recorder.slate()
            Task { try? await Task.sleep(for: .milliseconds(300)); showSlate = false }
        }
        audio.configure()
        audio.detectorConfig = { VoiceDetector.Config.session(sampleRate: $0) }
        audio.allowsBargeIn = true
        audio.wantsVoiceProcessing = settings.voiceProcessing
        audio.onSpeechStart = { [weak self] in
            let stream = RealtimeTranscriber()
            // Voice Transcribe's own endpointing: its final words and a quiet room end the turn at once.
            stream.onFinal = { [weak self] in self?.audio.endUtteranceIfQuiet() }
            stream.start()
            self?.stream?.cancel()
            self?.stream = stream
        }
        audio.onNearMiss = { [weak self] miss in
            Task { await self?.nearMiss(miss) }
        }
        audio.onBargeIn = { [weak self] in
            guard let self else { return }
            self.conversation.interrupt()
            var record = SessionDebug.UtteranceRecord(at: .now, seconds: 0, state: self.engine.context.state)
            record.kind = "bargeIn"
            record.bargedIn = true
            record.input = self.audio.inputLabel
            SessionDebug.append(record, sessionId: self.engine.session.id, in: self.store.mediaDirectory)
        }
        audio.onLiveSamples = { [weak self] samples, rate in self?.stream?.send(samples, rate: rate) }
        audio.onUtterance = { [weak self] utterance in
            Task { await self?.handle(utterance) }
        }
        if !rehearsal { audio.startListening() }
        startClock()
        engine.cameraStartsSets = settings.cameraStartsSets
        engine.usesArming = camera
        engine.armReminder = settings.sessionsStarted <= 3 && !rehearsal
        if camera {
            cameraOn = true
            syncCamera()
            detector.onSetStart = { [weak self] start in self?.cameraSetStarted(at: start) }
            detector.onSetEnd = { [weak self] end in self?.cameraSetEnded(at: end) }
            detector.onClipsReady = { [weak self] clips in self?.clipsReady(clips) }
            detector.start()
        }
        if firstSession, !rehearsal { conversation.say(Self.firstSessionIntro) }
        conversation.say(engine.intro)
        // The tripod is 2-3 m away: the phone's own mic misses short commands under gym music.
        if camera, !audio.isHeadWornMic { conversation.say("I hear you best through your AirPods mic.") }
        await playCueIfDue()
        conversation.show(engine.beginLeadInIfDue())
    }

    /// Before his first session ever, about 15 seconds: how to talk to it, so he never needs a list
    /// (HANDOFF.md §7, Talk to it like a person).
    static let firstSessionIntro = "Talk to me like a spotter. Say go when you lift, tell me what you got, "
        + "or ask me anything about today. If a machine's taken, just say so."

    /// The coach's cue for the current exercise, once, in Ready, before its first set (HANDOFF.md §7).
    private func playCueIfDue() async {
        guard let cue = engine.cueDue() else { return }
        engine.cuePlayed(cue)
        conversation.show(.init(echo: "Coach · \(engine.currentExercise?.name ?? "")\n“\(cue.text)”"))
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
        stream?.cancel()
        stream = nil
        for file in countFilesHeld.values { try? FileManager.default.removeItem(at: store.mediaDirectory.appendingPathComponent(file)) }
        countFilesHeld.removeAll()
        save()
    }

    private func save() {
        guard !rehearsal else { return } // a rehearsal never reaches the log or the check-in
        store.upsert(session: engine.session)
        for entry in engine.logbookEntries.dropFirst(savedLogbookEntries) { store.addLogbook(entry) }
        savedLogbookEntries = engine.logbookEntries.count
        for sample in engine.calibrationSamples.dropFirst(savedCalibrationSamples) {
            store.addCalibration(exerciseId: sample.exerciseId, velocityLossPct: sample.velocityLossPct, rpe: sample.rpe)
        }
        savedCalibrationSamples = engine.calibrationSamples.count
    }

    private var savedCalibrationSamples = 0
    private var savedLogbookEntries = 0

    // MARK: Set detection

    private func cameraSetStarted(at start: Double) {
        // A timed set is a countdown, and an add-on set goes by voice: never a camera set (HANDOFF.md §7).
        guard !engine.currentSetIsVoiceOnly else { return }
        // Started by voice in a pocket and then seen, or armed by "go": his set. Anything else is
        // someone else's movement (the detector only reports starts it's allowed, but the arm may have lapsed).
        guard engine.state == .recording || engine.cameraMayStart else { return }
        currentSetStart = start
        detector.restPause = engine.currentSetIsRestPause
        show(engine.state == .recording ? .none : engine.cameraStarted())
        syncCamera()
    }

    /// The detector follows the arm: "go" picks him again in the frame, and only an armed set (or
    /// one under way) may start. With Settings → "Start sets from the camera" any movement may.
    private var lastArmedAt: Date?
    private func syncCamera() {
        guard cameraOn else { return }
        if engine.armedAt != lastArmedAt {
            if engine.armedAt != nil { detector.lockOnHim() }
            lastArmedAt = engine.armedAt
        }
        detector.startsAllowed = engine.cameraMayStart || engine.state == .recording
    }

    private func cameraSetEnded(at end: Double) {
        guard currentSetStart != nil || engine.state == .recording else { return }
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
        if let crop = clips.cropBox { cropBoxes[setId] = crop }
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
    /// His station per set: the count clip is cut to it before SAM.
    private var cropBoxes: [UUID: CGRect] = [:]

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
        let crop = cropBoxes[setId].map { [Double($0.minX), Double($0.minY), Double($0.width), Double($0.height)] }
        let context = CountContext(exerciseId: set.exerciseId, equipment: exercise.equipment,
                                   plannedReps: planned?.reps ?? planned?.repsMin, phoneReps: set.repCount.phone,
                                   setRole: set.role?.rawValue, cropBox: crop, camera: detector.front ? "front" : "back")
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
        if engine.state == .ready || engine.restIsUp { Task { await playCueIfDue() } }
    }

    /// The session clock: every second, the rest countdown, a lead-in's count, a hold's countdown
    /// (from the wall clock), and the phone's count for a set SAM has not answered within 60 s.
    private func startClock() {
        clockTask?.cancel()
        clockTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, !self.didSave else { return }
                let before = self.engine.state
                self.engine.cameraOnDuty = self.cameraOn && self.detector.isOnDuty
                self.conversation.tick()
                self.syncCamera()
                if self.engine.state != before { self.afterStateChange() }
            }
        }
    }

    // MARK: Voice

    /// One utterance from the mic: never dropped, queued behind any still being handled. Under
    /// 0.15 s of speech it's a clank; one that ran to the 10 s limit was noise (the detector's floor
    /// has risen to it).
    private func handle(_ utterance: VoiceDetector.Utterance) async {
        let stream = self.stream
        self.stream = nil
        let endedAt = Date.now
        if utterance.hitMax || utterance.speechSeconds < Self.minimumSpeechSeconds {
            stream?.cancel()
            var record = SessionDebug.UtteranceRecord(at: endedAt, seconds: utterance.seconds, state: engine.context.state,
                                                      error: utterance.hitMax ? "too long (noise)" : "too short")
            record.kind = "utterance"
            record.levelAboveFloorDB = utterance.peakAboveFloorDB
            record.speechSeconds = utterance.speechSeconds
            record.input = audio.inputLabel
            record.voiceProcessing = audio.voiceProcessingOn
            SessionDebug.append(record, sessionId: engine.session.id, in: store.mediaDirectory)
            return
        }
        let pcm = Resample.toInt16Mono(utterance.samples, from: utterance.sampleRate, to: 16_000)
        filming?.heard(pcm16: pcm, sampleRate: 16_000)
        var heard = SessionConversation.Heard(transcript: nil, wav: WAVFile.data(pcm16: pcm, sampleRate: 16_000),
                                              seconds: utterance.seconds, speechEndedAt: endedAt)
        if let stream {
            let words: @MainActor () async -> String? = { await stream.end() }
            heard.words = words
        }
        engine.cameraOnDuty = cameraOn && detector.isOnDuty
        await conversation.hear(heard)
    }

    static let minimumSpeechSeconds = 0.15

    /// A sound that crossed the stream trigger but never the utterance threshold. Logged either way;
    /// if Voice Transcribe found words in it, they are heard like any utterance (a quiet "go").
    private func nearMiss(_ miss: VoiceDetector.NearMiss) async {
        let stream = self.stream
        self.stream = nil
        let endedAt = Date.now
        var record = SessionDebug.UtteranceRecord(at: endedAt, seconds: miss.seconds, state: engine.context.state)
        record.kind = "nearMiss"
        record.levelAboveFloorDB = miss.peakAboveFloorDB
        record.input = audio.inputLabel
        record.voiceProcessing = audio.voiceProcessingOn
        let words = await stream?.end()
        record.transcript = words
        if words != nil { record.toTranscript = Date.now.timeIntervalSince(endedAt) }
        guard let words, words.contains(where: \.isLetter) else {
            record.error = stream == nil ? "no stream" : "no words"
            SessionDebug.append(record, sessionId: engine.session.id, in: store.mediaDirectory)
            return
        }
        SessionDebug.append(record, sessionId: engine.session.id, in: store.mediaDirectory)
        engine.cameraOnDuty = cameraOn && detector.isOnDuty
        await conversation.hear(.init(transcript: words, wav: nil, seconds: miss.seconds, speechEndedAt: endedAt))
    }

    /// Developer → Session rehearsal: a typed line through the real backend, as if it was heard.
    func rehearse(_ line: String) async {
        engine.cameraOnDuty = false
        await conversation.hear(.init(transcript: line, wav: nil, seconds: 0, speechEndedAt: .now))
    }

    /// The coordinator's side of a command: a spoken "done" closes the camera's clip, "say that
    /// again" replays the cue, "that was my top set" uploads the held clip, the session ends or
    /// moves on.
    private func afterVoice(_ response: VoiceCommandResponse, wasRecording: Bool) {
        filming?.transcribed(response.transcript)
        if response.intent.intent == .replayCue, let cue = engine.cueToReplay() {
            Task { await play(cue) }
        }
        if wasRecording, engine.state != .recording, cameraOn {
            if let start = currentSetStart, let setId = engine.lastLoggedSetId { setsAwaitingClips[start] = setId }
            currentSetStart = nil
            detector.restPause = false
            detector.endSetByVoice()
        }
        if response.intent.intent == .topSet { uploadReclassified() }
        syncCamera()
        afterStateChange()
    }

    // MARK: Output

    private func show(_ outcome: SessionEngine.Outcome) {
        conversation.show(outcome)
    }

    /// Every line is a template with the engine's numbers, said the moment it's ready (rest lines
    /// no longer wait on /spotter/line: HANDOFF.md §7, The spotter voice).
    private func speak(_ text: String) async {
        filming?.spoke(text, voice: AudioService.preferredVoice())
        await voice.speak(text)
    }
}
