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
    /// Check-in morning, the photo session and the wrap-up are one conversation: the music stays ducked
    /// from start to end, and no line changes the session category. Oct 28: switching between duck and
    /// mix around every line kept the mic closed for a moment after each one. Sessions leave it off.
    var holdsDucking = false
    /// The mic took audio again after a line: for "your turn" on screen, and the Probes timing.
    private(set) var micOpenedAt: Date?
    private(set) var levelDB: Double = -120
    private(set) var noiseFloorDB: Double?
    private(set) var inputDescription = "—"
    private(set) var lastError: String?

    /// Called on the main actor with each finished utterance while listening.
    var onUtterance: ((VoiceDetector.Utterance) -> Void)?
    /// Realtime transcription: speech just started (the last second of audio follows at once),
    /// and every chunk captured while the athlete keeps talking.
    var onSpeechStart: (() -> Void)?
    var onLiveSamples: (([Float], Double) -> Void)?
    /// The last second of audio, so the stream can start before the onset was detected.
    private var recent: [Float] = []
    private var wasSpeaking = false

    private let session = AVAudioSession.sharedInstance()
    private let capture = CaptureBuffer()
    private let synth = AVSpeechSynthesizer()
    private let speechDelegate = SpeechFinishDelegate()
    private var engine: AVAudioEngine?
    private var detector: VoiceDetector?
    private var drainTask: Task<Void, Never>?
    private var speechQueue: [String] = []
    @ObservationIgnored private var routeObserver: NSObjectProtocol?
    private var speechContinuation: CheckedContinuation<Void, Never>?
    private var cuePlayer: AVAudioPlayer?

    init() {
        synth.usesApplicationAudioSession = true
        synth.delegate = speechDelegate
        speechDelegate.onFinish = { [weak self] in self?.speechFinished() }
        // AirPods dropping to call quality, or the output vanishing, mid-run: check and fall back.
        routeObserver = NotificationCenter.default.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self, AirPodsMic.shared.isActive, AirPodsMic.shared.check(self.session) else { return }
                self.configure()
            }
        }
    }

    isolated deinit {
        if let routeObserver { NotificationCenter.default.removeObserver(routeObserver) }
    }

    // MARK: Session

    /// .playAndRecord with mixing, A2DP output, the USB (DJI) input preferred. Never HFP.
    func configure() {
        do {
            try AirPodsMic.shared.apply(to: session, ducking: holdsDucking)
            // The DJI receiver when it's plugged in, unless he asked for the AirPods mic.
            if !AirPodsMic.shared.isActive, let usb = session.availableInputs?.first(where: { $0.portType == .usbAudio }) {
                try session.setPreferredInput(usb)
            }
            try session.setActive(true)
            if AirPodsMic.shared.check(session) {
                // Back to A2DP output and the DJI or iPhone mic, then on with the run.
                try AirPodsMic.shared.apply(to: session, ducking: false)
                if let usb = session.availableInputs?.first(where: { $0.portType == .usbAudio }) { try session.setPreferredInput(usb) }
                try session.setActive(true)
            }
            let inputs = session.currentRoute.inputs.map { "\($0.portName) · \($0.portType.rawValue)" }
            inputDescription = inputs.isEmpty ? "—" : inputs.joined(separator: ", ")
            lastError = nil
        } catch {
            lastError = "Audio session: \(error.localizedDescription)"
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
        detector = VoiceDetector(config: .init(sampleRate: format.sampleRate))
        isListening = true
        drainTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                self?.drain()
            }
        }
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
        // While a callout plays, the mic hears nothing we want: drop the audio instead of transcribing ourselves.
        guard !isSpeaking else { return }
        let rate = capture.sampleRate
        recent.append(contentsOf: samples)
        let keep = Int(rate)
        if recent.count > keep { recent.removeFirst(recent.count - keep) }
        let utterances = detector.process(samples)
        if detector.isSpeaking, !wasSpeaking {
            wasSpeaking = true
            onSpeechStart?()
            onLiveSamples?(recent, rate)
        } else if detector.isSpeaking {
            onLiveSamples?(samples, rate)
        } else if wasSpeaking {
            wasSpeaking = false
        }
        for utterance in utterances {
            onUtterance?(utterance)
        }
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

    private func speakNow(_ text: String) async {
        isSpeaking = true
        if !holdsDucking {
            do {
                try AirPodsMic.shared.apply(to: session, ducking: true)
                try session.setActive(true)
            } catch {
                lastError = "Duck: \(error.localizedDescription)"
            }
        }
        let utterance = SpokenText.utterance(text, voice: Self.preferredVoice(), rate: Settings.shared.voiceRate)
        await withCheckedContinuation { continuation in
            speechContinuation = continuation
            synth.speak(utterance)
        }
        if !holdsDucking {
            do {
                try AirPodsMic.shared.apply(to: session, ducking: false)
                try session.setActive(true)
            } catch {
                lastError = "Restore: \(error.localizedDescription)"
            }
        }
        isSpeaking = false
        micOpenedAt = .now
    }

    private func speechFinished() {
        speechContinuation?.resume()
        speechContinuation = nil
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

    /// "Ava (Premium)": the voice every line uses right now, for the check-in screen and Probes.
    static var voiceDescription: String {
        guard let voice = preferredVoice() else { return "no voice installed" }
        let quality = voice.quality == .premium ? "Premium" : voice.quality == .enhanced ? "Enhanced" : "Default"
        return "\(voice.name) (\(quality))"
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
        if !holdsDucking {
            do {
                try AirPodsMic.shared.apply(to: session, ducking: true)
                try session.setActive(true)
            } catch {
                lastError = "Duck: \(error.localizedDescription)"
            }
        }
        if let player = try? AVAudioPlayer(contentsOf: url) {
            cuePlayer = player
            player.play()
            while player.isPlaying { try? await Task.sleep(for: .milliseconds(100)) }
            cuePlayer = nil
        } else {
            lastError = "Couldn't play \(url.lastPathComponent)"
        }
        if !holdsDucking {
            do {
                try AirPodsMic.shared.apply(to: session, ducking: false)
                try session.setActive(true)
            } catch {
                lastError = "Restore: \(error.localizedDescription)"
            }
        }
    }

    func stopSpeaking() {
        speechQueue.removeAll()
        synth.stopSpeaking(at: .immediate)
    }

    /// Duck the music before a pre-rendered line plays through its own engine, and restore after.
    func duck() async {
        while isSpeaking { try? await Task.sleep(for: .milliseconds(20)) }
        isSpeaking = true
        guard !holdsDucking else { return }
        do {
            try AirPodsMic.shared.apply(to: session, ducking: true)
            try session.setActive(true)
        } catch {
            lastError = "Duck: \(error.localizedDescription)"
        }
    }

    func restore() async {
        if !holdsDucking {
            do {
                try AirPodsMic.shared.apply(to: session, ducking: false)
                try session.setActive(true)
            } catch {
                lastError = "Restore: \(error.localizedDescription)"
            }
        }
        isSpeaking = false
        micOpenedAt = .now
    }

    /// How loud the room is right now above its quiet level, 0…1, for the "your turn" ring.
    var inputLevel: Double {
        guard let floor = noiseFloorDB else { return 0 }
        return min(1, max(0, (levelDB - floor) / 30))
    }

    /// A soft system tick the moment a turn ends, so the athlete knows he was heard.
    func playTurnEndSound() {
        AudioServicesPlaySystemSound(1104)
    }

    /// "DJI Mic RX · USB → AirPods Pro · Bluetooth A2DP": the live route for the Probes screen.
    var routeDescription: String {
        let route = session.currentRoute
        let ins = route.inputs.map { "\($0.portName) · \($0.portType.rawValue)" }.joined(separator: ", ")
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
