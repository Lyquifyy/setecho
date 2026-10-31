import AudioToolbox
import AVFoundation
import Foundation
import Observation

/// Gym audio (HANDOFF.md §7 Audio): the DJI receiver in over USB, the AirPods out over A2DP, the
/// athlete's music untouched except while a callout ducks it. Owns the audio session, the input
/// tap, the voice detector and the speech synthesizer. Listens only when the session says so.
@MainActor
@Observable
final class AudioService {
    private(set) var isListening = false
    private(set) var isSpeaking = false
    /// Someone is talking into the mic right now (the stream is open): the screen's voice card moves.
    private(set) var isHearing = false
    /// Check-in morning, the photo session and the wrap-up are one conversation: the music stays ducked
    /// from start to end, and no line changes the session category. Oct 28: switching between duck and
    /// mix around every line kept the mic closed for a moment after each one. Sessions leave it off.
    var holdsDucking = false
    /// The mic took audio again after a line: for "your turn" on screen, and the Probes timing.
    private(set) var micOpenedAt: Date?
    private(set) var levelDB: Double = -120
    private(set) var noiseFloorDB: Double?
    private(set) var inputDescription = "—"
    /// Another app's audio (his music) is playing right now.
    var isMusicPlaying: Bool { session.isOtherAudioPlaying }
    /// The live input in plain words for the session HUD: "AirPods mic", "External mic", "Phone mic".
    private(set) var inputLabel = "No mic"
    /// The input is on him (AirPods, the DJI receiver, a headset), not the phone on the tripod.
    private(set) var isHeadWornMic = false
    /// Apple's voice processing (noise suppression and gain control) was on for this run.
    private(set) var voiceProcessingOn = false
    private(set) var lastError: String?

    /// Called on the main actor with each finished utterance while listening.
    var onUtterance: ((VoiceDetector.Utterance) -> Void)?
    /// Realtime transcription: speech just started (the last second of audio follows at once),
    /// and every chunk captured while the athlete keeps talking.
    var onSpeechStart: (() -> Void)?
    var onLiveSamples: (([Float], Double) -> Void)?
    /// A sound crossed the stream trigger but never became an utterance (sessions only).
    var onNearMiss: ((VoiceDetector.NearMiss) -> Void)?
    /// He started talking while Setecho was speaking: the line was cut and the mic is his.
    var onBargeIn: (() -> Void)?
    /// Barge-in (sessions): with the mic on him, speech over a line stops it. With the phone's
    /// own mic the speaker would hear itself, so the mic stays closed while a line plays.
    var allowsBargeIn = false
    /// Apple's voice processing on the input (Settings → Developer). Read when listening starts.
    var wantsVoiceProcessing = false
    /// The detector's settings for this run; nil is the check-in's (sessions use `.session`).
    var detectorConfig: ((Double) -> VoiceDetector.Config)?
    /// The last second of audio, so the stream can start before the onset was detected.
    private var recent: [Float] = []
    private var wasSpeaking = false

    private let session = AVAudioSession.sharedInstance()
    private let capture = CaptureBuffer()
    /// Every line, live or pre-rendered, goes out through this: player → EQ → compressor.
    let output = VoiceOutput()
    /// Lines on the synthesizer's own session while it lowers his music (`AirPodsLowering.appleSpeech`).
    let ownSessionVoice = OwnSessionSpeaker()
    private var engine: AVAudioEngine?
    private var detector: VoiceDetector?
    private var drainTask: Task<Void, Never>?
    private var speechQueue: [String] = []
    @ObservationIgnored private var routeObserver: NSObjectProtocol?
    @ObservationIgnored private var musicObserver: NSObjectProtocol?
    private var cuePlayer: AVAudioPlayer?

    init() {
        // AirPods dropping to call quality, or the output vanishing, mid-run: check and fall back.
        routeObserver = NotificationCenter.default.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] note in
            let reason = (note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt).flatMap(AVAudioSession.RouteChangeReason.init(rawValue:))
            Task { @MainActor in
                guard let self else { return }
                self.updateInput()
                self.logAudio("route change · \(reason.map(Self.describe) ?? "unknown")", lowered: self.isSpeaking, error: nil)
                // The AirPods back after a drop (Oct 31): iOS put the output on them and left the mic on
                // the phone, and the stale preference stopped a plain prefer. Ask again, by force.
                if reason == .newDeviceAvailable, AirPodsMic.shared.isActive, !AirPodsMic.shared.inputIsPreferred(in: self.session) {
                    self.reconnectMic(reason: "new device available")
                    return
                }
                guard AirPodsMic.shared.isActive, AirPodsMic.shared.check(self.session) else { return }
                self.configure()
            }
        }
        // iOS says when another app's audio starts or stops: the debug JSON shows the moment his
        // music stopped against every step around it (Oct 29: it stopped at a session start).
        musicObserver = NotificationCenter.default.addObserver(forName: AVAudioSession.silenceSecondaryAudioHintNotification, object: nil, queue: .main) { [weak self] note in
            let raw = note.userInfo?[AVAudioSessionSilenceSecondaryAudioHintTypeKey] as? UInt
            let began = raw.flatMap(AVAudioSession.SilenceSecondaryAudioHintType.init(rawValue:)) == .begin
            Task { @MainActor in self?.logAudio(began ? "his music started" : "his music stopped", lowered: false, error: nil) }
        }
    }

    isolated deinit {
        if let routeObserver { NotificationCenter.default.removeObserver(routeObserver) }
        if let musicObserver { NotificationCenter.default.removeObserver(musicObserver) }
    }

    // MARK: Session

    /// .playAndRecord with mixing, A2DP output, the USB (DJI) input preferred. Never HFP.
    func configure() {
        do {
            try AirPodsMic.shared.apply(to: session, ducking: holdsDucking)
            // A plugged-in external mic (the DJI receiver) wins, then AirPods at high quality. A
            // preference that won't take never stops the run: iOS's own choice is never HFP.
            AirPodsMic.shared.prefer(AirPodsMic.shared.preferredInput(in: session), in: session)
            // The session's haptics (armed, set ended, rest's up) are muted by iOS while recording unless allowed.
            try? session.setAllowHapticsAndSystemSoundsDuringRecording(true)
            try session.setActive(true)
            if AirPodsMic.shared.check(session) {
                // Back to A2DP output and the DJI or iPhone mic, then on with the run.
                try AirPodsMic.shared.apply(to: session, ducking: holdsDucking)
                AirPodsMic.shared.prefer(AirPodsMic.shared.preferredInput(in: session), in: session)
                try session.setActive(true)
            }
            updateInput()
            lastError = nil
            logAudio("configure", lowered: holdsDucking, error: nil)
        } catch {
            logAudio("configure", lowered: holdsDucking, error: error)
            lastError = "Audio couldn't start"
        }
    }

    /// Back onto the mic we want (the DJI receiver, else the AirPods at high quality) after it came
    /// back, or on a tap of the HUD's audio pill. The preference is asked for again even if it reads
    /// as already set, then the route is checked as after any activation.
    func reconnectMic(reason: String) {
        AirPodsMic.shared.prefer(AirPodsMic.shared.preferredInput(in: session), in: session, force: true)
        AirPodsMic.shared.check(session)
        updateInput()
        logAudio("reconnect mic · \(reason)", lowered: isSpeaking, error: nil)
    }

    /// The route's input in words, for the HUD and the debug record.
    private func updateInput() {
        let inputs = session.currentRoute.inputs
        inputDescription = inputs.isEmpty ? "—" : inputs.map { "\($0.portName) · \($0.portType.rawValue)" }.joined(separator: ", ")
        guard let input = inputs.first else {
            inputLabel = "No mic"
            isHeadWornMic = false
            return
        }
        (inputLabel, isHeadWornMic) = Self.label(portType: input.portType, name: input.portName)
    }

    static func label(portType: AVAudioSession.Port, name: String) -> (String, Bool) {
        switch portType {
        case .usbAudio: ("External mic", true)
        case .bluetoothHFP, .bluetoothLE: (name.localizedCaseInsensitiveContains("airpods") ? "AirPods mic" : "Bluetooth mic", true)
        case .headsetMic: ("Headset mic", true)
        case .builtInMic: ("Phone mic", false)
        default: (name, false)
        }
    }

    func requestMicrophone() async -> Bool {
        await AVAudioApplication.requestRecordPermission()
    }

    // MARK: Listening

    func startListening() {
        guard !isListening else { return }
        configure()
        let engine = AVAudioEngine()
        let input = engine.inputNode
        voiceProcessingOn = false
        if wantsVoiceProcessing, session.isOtherAudioPlaying {
            // Oct 29: with his music playing, a session start with voice processing on stopped it,
            // while the same mic without it kept the music at full quality. His music wins.
            logAudio("voice processing skipped: music playing", lowered: false, error: nil)
        } else if wantsVoiceProcessing {
            // Noise suppression and gain control, with his music ducked as little as iOS allows.
            do {
                try input.setVoiceProcessingEnabled(true)
                input.voiceProcessingOtherAudioDuckingConfiguration = .init(enableAdvancedDucking: false, duckingLevel: .min)
                voiceProcessingOn = true
            } catch {
                lastError = "Voice processing: \(error.localizedDescription)"
            }
            // Voice processing can turn the session into a call (voiceChat, HFP only, not mixable),
            // which stops his music and the AirPods' high quality. Then it goes off and the
            // session's own configuration comes back.
            if voiceProcessingOn, session.mode != .default || !session.categoryOptions.contains(.mixWithOthers) {
                logAudio("voice processing off: it made the session a call", lowered: false, error: nil)
                try? input.setVoiceProcessingEnabled(false)
                voiceProcessingOn = false
                configure()
            }
        }
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            lastError = "No audio input"
            return
        }
        capture.reset(sampleRate: format.sampleRate)
        let capture = self.capture
        input.installTap(onBus: 0, bufferSize: 2048, format: format) { @Sendable buffer, _ in
            capture.append(buffer)
        }
        do {
            try engine.start()
        } catch {
            lastError = "Audio engine: \(error.localizedDescription)"
            return
        }
        self.engine = engine
        detector = VoiceDetector(config: detectorConfig?(format.sampleRate) ?? .init(sampleRate: format.sampleRate))
        isListening = true
        drainTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                self?.drain()
            }
        }
    }

    /// Forget the noise floor and learn it again (after a long noise passed for speech).
    func recalibrate() {
        detector?.recalibrate()
    }

    func stopListening() {
        guard isListening else { return }
        drainTask?.cancel()
        drainTask = nil
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        if let detector, let utterance = detector.flush() {
            onUtterance?(utterance)
        }
        detector = nil
        isListening = false
    }

    private func drain() {
        guard let detector else { return }
        let (samples, _) = capture.drain()
        levelDB = capture.levelDB
        noiseFloorDB = detector.noiseFloorDB
        // While a line plays, the phone's own mic hears only Setecho: drop the audio. With the mic on
        // him, keep listening, and only a voice louder than the threshold by `bargeInBoostDB` cuts in.
        let bargeIn = isSpeaking && allowsBargeIn && isHeadWornMic
        guard !isSpeaking || bargeIn else { return }
        detector.boostDB = bargeIn ? Self.bargeInBoostDB : 0
        let rate = capture.sampleRate
        recent.append(contentsOf: samples)
        let keep = Int(rate)
        if recent.count > keep { recent.removeFirst(recent.count - keep) }
        let utterances = detector.process(samples)
        for event in detector.drainEvents() {
            guard case .nearMiss(let miss) = event else { continue }
            wasSpeaking = false
            onNearMiss?(miss)
        }
        // The stream opens at the lower trigger in sessions, at the utterance's onset in the check-in.
        let live = detector.isSpeaking || detector.streamOpen
        if isHearing != live { isHearing = live }
        if live, !wasSpeaking {
            wasSpeaking = true
            onSpeechStart?()
            onLiveSamples?(recent, rate)
        } else if live {
            onLiveSamples?(samples, rate)
        } else if wasSpeaking {
            wasSpeaking = false
        }
        if bargeIn, detector.isSpeaking {
            stopSpeaking()
            onBargeIn?()
        }
        for utterance in utterances {
            onUtterance?(utterance)
        }
    }

    /// How much louder than the threshold he has to be to cut into a line (his own voice in the
    /// AirPods' speakers is quieter than his voice at the mic).
    static let bargeInBoostDB = 6.0

    /// Voice Transcribe marked his words final and the room has gone quiet: end the utterance now
    /// instead of waiting out the hangover (its own endpointing, HANDOFF.md §7).
    func endUtteranceIfQuiet() {
        guard let detector, let utterance = detector.endIfQuiet() else { return }
        wasSpeaking = false
        onUtterance?(utterance)
    }

    // MARK: Callouts

    /// Speak one line with the music ducked, then restore mixing. Serialized; returns when spoken.
    func speak(_ text: String) async {
        speechQueue.append(text)
        guard !isSpeaking else { return }
        while !speechQueue.isEmpty {
            let next = speechQueue.removeFirst()
            await speakNow(next)
        }
    }

    /// The AirPods record at high quality and he picked Apple's speech session to lower his music:
    /// lines go to `ownSessionVoice`, never through a change to the app's session.
    var speaksOnItsOwnSession: Bool {
        !holdsDucking && Settings.shared.airPodsLowering == .appleSpeech && AirPodsMic.shared.isRecordingHighQuality(session)
    }

    private func speakNow(_ text: String) async {
        isSpeaking = true
        let voice = Self.preferredVoice()
        let tone = Self.currentTone
        if speaksOnItsOwnSession {
            await ownSessionVoice.speak(SpokenText.utterance(text, voice: voice, tone: tone))
            isSpeaking = false
            micOpenedAt = .now
            return
        }
        lowerMusic(true)
        await output.speak(SpokenText.utterance(text, voice: voice, tone: tone), tone: tone)
        lowerMusic(false)
        isSpeaking = false
        micOpenedAt = .now
    }

    /// One voice everywhere (HANDOFF.md §7, The spotter voice): the athlete's pick from Settings,
    /// else Ava (Premium), Zoe (Premium) or Evan (Enhanced), else the best installed English voice,
    /// premium first. Never the coach's.
    static func preferredVoice(identifier: String = Settings.shared.voiceIdentifier) -> AVSpeechSynthesisVoice? {
        if !identifier.isEmpty, let chosen = AVSpeechSynthesisVoice(identifier: identifier) { return chosen }
        if let preferred = defaultVoice { return preferred }
        let english = AVSpeechSynthesisVoice.speechVoices().filter { $0.language.hasPrefix("en") }
        let ranked = english.sorted { a, b in
            if a.quality != b.quality { return a.quality.rawValue > b.quality.rawValue }
            if (a.language == "en-US") != (b.language == "en-US") { return a.language == "en-US" }
            return a.name < b.name
        }
        return ranked.first ?? AVSpeechSynthesisVoice(language: "en-US")
    }

    /// English voices for the Settings picker, best first.
    static func availableVoices() -> [AVSpeechSynthesisVoice] {
        AVSpeechSynthesisVoice.speechVoices().filter { $0.language.hasPrefix("en") }.sorted { a, b in
            if a.quality != b.quality { return a.quality.rawValue > b.quality.rawValue }
            return a.name < b.name
        }
    }

    /// The default voices in order, by name and quality (Oct 28: Premium sounds the most fluent; Evan
    /// has no Premium version).
    static let defaultVoices: [(name: String, quality: AVSpeechSynthesisVoiceQuality)] = [
        ("Ava", .premium), ("Zoe", .premium), ("Ava", .enhanced), ("Zoe", .enhanced), ("Evan", .enhanced),
    ]

    /// The identifier tones are saved under: the voice in use, or "default" when none is installed.
    static var currentVoiceId: String { preferredVoice()?.identifier ?? "default" }

    /// His tone for the voice in use (Settings → Voice).
    static var currentTone: VoiceTone { Settings.shared.tone(for: currentVoiceId) }

    /// "Ava (Premium)" or "Zander (Personal Voice)": the voice every line uses right now, for the
    /// check-in screen and Probes.
    static var voiceDescription: String {
        guard let voice = preferredVoice() else { return "no voice installed" }
        return "\(voice.name) (\(qualityLabel(voice)))"
    }

    /// "Premium", "Enhanced", "Default", or "Personal Voice".
    static func qualityLabel(_ voice: AVSpeechSynthesisVoice) -> String {
        if voice.voiceTraits.contains(.isPersonalVoice) { return "Personal Voice" }
        return voice.quality == .premium ? "Premium" : voice.quality == .enhanced ? "Enhanced" : "Default"
    }

    // MARK: Personal Voice

    /// The athlete's own Personal Voice (Settings → Accessibility → Personal Voice), made on the
    /// phone from his recordings and run on the phone like the other voices. Listed by
    /// `speechVoices()` only once he has allowed Setecho to use it.
    static var personalVoices: [AVSpeechSynthesisVoice] {
        AVSpeechSynthesisVoice.speechVoices().filter { $0.voiceTraits.contains(.isPersonalVoice) }
    }

    static var personalVoiceStatus: AVSpeechSynthesizer.PersonalVoiceAuthorizationStatus {
        AVSpeechSynthesizer.personalVoiceAuthorizationStatus
    }

    /// iOS asks him once whether Setecho may use his Personal Voice.
    static func requestPersonalVoice() async -> AVSpeechSynthesizer.PersonalVoiceAuthorizationStatus {
        await withCheckedContinuation { continuation in
            AVSpeechSynthesizer.requestPersonalVoiceAuthorization { continuation.resume(returning: $0) }
        }
    }

    /// The first default voice that is installed, US English first. Nil until one is downloaded;
    /// Settings says where.
    static var defaultVoice: AVSpeechSynthesisVoice? {
        let english = AVSpeechSynthesisVoice.speechVoices().filter { $0.language.hasPrefix("en") }
        for wanted in defaultVoices {
            let matches = english.filter { $0.name == wanted.name && $0.quality == wanted.quality }
            if let voice = matches.first(where: { $0.language == "en-US" }) ?? matches.first { return voice }
        }
        return nil
    }

    /// Play one audio file (a coach cue) with the music ducked, then restore mixing. Serialized
    /// with the callouts: returns when it has finished.
    func play(file url: URL) async {
        while isSpeaking { try? await Task.sleep(for: .milliseconds(100)) }
        isSpeaking = true
        defer {
            isSpeaking = false
            micOpenedAt = .now
        }
        lowerMusic(true)
        if let player = try? AVAudioPlayer(contentsOf: url) {
            cuePlayer = player
            player.play()
            while player.isPlaying { try? await Task.sleep(for: .milliseconds(100)) }
            cuePlayer = nil
        } else {
            lastError = "Couldn't play \(url.lastPathComponent)"
        }
        lowerMusic(false)
    }

    // MARK: His music

    /// Every audio-session step, for the session's debug JSON (never on screen).
    var onAudioEvent: ((SessionDebug.AudioEvent) -> Void)?
    /// Lowering the music per line failed twice this run: lines now play over it at full volume, and
    /// the configuration is never changed per line again (his music must never stop).
    private(set) var perLineDuckingOff = false
    private var musicFailures = 0
    /// A line lowered his music and it hasn't been brought back yet.
    private var musicLowered = false

    /// Lower his music for a line, or bring it back. It can't fail the session: the session stays
    /// active and mixable throughout. Lowering is an activation with `.duckOthers` (mixable);
    /// bringing it back only changes the options on the active session, with no second activation
    /// (that reactivation is what threw "can't interrupt others" at the gym, Oct 28). A failure is
    /// logged, the mixable configuration put back, and after two the per-line lowering stops.
    /// With the AirPods recording at high quality, the AirPods are on a call-style link (BluetoothHFP
    /// at full bandwidth), any change to the session sets it up again, and his music app pauses as if
    /// the headphones were unplugged (Oct 29). There the session never changes per line: lines play
    /// over his music, or lower it the whole session, or Apple's speech session lowers it for each
    /// spoken line by itself (a coach cue file plays over it).
    func lowerMusic(_ lowered: Bool) {
        guard !holdsDucking else { return }
        if lowered, !perLineDuckingOff, AirPodsMic.shared.isRecordingHighQuality(session) {
            perLineDuckingOff = true
            logAudio("per-line lowering off: the AirPods mic is at high quality", lowered: false, error: nil)
        }
        if lowered ? perLineDuckingOff : !musicLowered { return }
        do {
            try AirPodsMic.shared.apply(to: session, ducking: lowered)
            if lowered { try session.setActive(true) }
            musicLowered = lowered
            logAudio(lowered ? "lower" : "restore", lowered: lowered, error: nil)
        } catch {
            logAudio(lowered ? "lower" : "restore", lowered: lowered, error: error)
            musicFailures += 1
            try? AirPodsMic.shared.apply(to: session, ducking: false)
            musicLowered = false
            if musicFailures >= 2 {
                perLineDuckingOff = true
                logAudio("per-line lowering off after \(musicFailures) failures", lowered: false, error: nil)
            }
        }
    }

    func logAudio(_ step: String, lowered: Bool, error: Error?) {
        let route = session.currentRoute
        let event = SessionDebug.AudioEvent(
            at: .now, step: step,
            requested: AirPodsMic.describe(AirPodsMic.shared.options(ducking: lowered)),
            applied: AirPodsMic.describe(session.categoryOptions),
            route: (route.inputs.map(\.portName) + ["→"] + route.outputs.map(\.portName)).joined(separator: " "),
            otherAudioPlaying: session.isOtherAudioPlaying,
            error: error.map(Self.describe))
        onAudioEvent?(event)
    }

    /// A route change's reason in Apple's words, for the debug JSON.
    nonisolated static func describe(_ reason: AVAudioSession.RouteChangeReason) -> String {
        switch reason {
        case .newDeviceAvailable: "new device available"
        case .oldDeviceUnavailable: "old device unavailable"
        case .categoryChange: "category change"
        case .override: "override"
        case .wakeFromSleep: "wake from sleep"
        case .noSuitableRouteForCategory: "no suitable route"
        case .routeConfigurationChange: "route configuration change"
        default: "reason \(reason.rawValue)"
        }
    }

    /// "!int (560557684): …": an OSStatus as its four characters, so a log reads like Apple's docs.
    nonisolated static func describe(_ error: Error) -> String {
        let code = (error as NSError).code
        let bytes = [24, 16, 8, 0].map { UInt8((UInt32(truncatingIfNeeded: code) >> $0) & 0xFF) }
        let fourCC = bytes.allSatisfy { (32...126).contains($0) } ? String(decoding: bytes, as: UTF8.self) : nil
        return [fourCC, "\(code)", (error as NSError).localizedDescription].compactMap { $0 }.joined(separator: " · ")
    }

    func stopSpeaking() {
        speechQueue.removeAll()
        output.cancel()
        ownSessionVoice.stop()
    }

    /// Duck the music before a pre-rendered line plays through its own engine, and restore after.
    func duck() async {
        while isSpeaking { try? await Task.sleep(for: .milliseconds(20)) }
        isSpeaking = true
        lowerMusic(true)
    }

    func restore() async {
        lowerMusic(false)
        isSpeaking = false
        micOpenedAt = .now
    }

    /// How loud the room is right now above its quiet level, 0…1, for the "your turn" ring.
    var inputLevel: Double {
        guard let floor = noiseFloorDB else { return 0 }
        return min(1, max(0, (levelDB - floor) / 30))
    }

    /// A soft chime the moment a turn ends, so he knows he was heard; nothing is spoken until the reply.
    func playTurnEndSound() {
        output.chime()
    }

    /// "DJI Mic RX · USB → AirPods Pro · Bluetooth A2DP": the live route for the Probes screen.
    var routeDescription: String {
        let route = session.currentRoute
        let ins = route.inputs.map {
            "\($0.portName) · \($0.portType.rawValue)\($0.bluetoothMicrophoneExtension?.highQualityRecording.isEnabled == true ? " · high quality" : "")"
        }.joined(separator: ", ")
        let outs = route.outputs.map { "\($0.portName) · \($0.portType.rawValue)" }.joined(separator: ", ")
        return "\(ins.isEmpty ? "no input" : ins) → \(outs.isEmpty ? "no output" : outs)"
    }
}

@MainActor
final class SpeechFinishDelegate: NSObject, AVSpeechSynthesizerDelegate {
    var onFinish: (() -> Void)?

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in self.onFinish?() }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in self.onFinish?() }
    }
}
