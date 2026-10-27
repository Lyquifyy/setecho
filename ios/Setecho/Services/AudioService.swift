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
    private(set) var levelDB: Double = -120
    private(set) var noiseFloorDB: Double?
    private(set) var inputDescription = "—"
    private(set) var lastError: String?

    /// Called on the main actor with each finished utterance while listening.
    var onUtterance: ((VoiceDetector.Utterance) -> Void)?

    private let session = AVAudioSession.sharedInstance()
    private let capture = CaptureBuffer()
    private let synth = AVSpeechSynthesizer()
    private let speechDelegate = SpeechFinishDelegate()
    private var engine: AVAudioEngine?
    private var detector: VoiceDetector?
    private var drainTask: Task<Void, Never>?
    private var speechQueue: [String] = []
    private var speechContinuation: CheckedContinuation<Void, Never>?

    init() {
        synth.usesApplicationAudioSession = true
        synth.delegate = speechDelegate
        speechDelegate.onFinish = { [weak self] in self?.speechFinished() }
    }

    // MARK: Session

    /// .playAndRecord with mixing, A2DP output, the USB (DJI) input preferred. Never HFP.
    func configure() {
        do {
            try session.setCategory(.playAndRecord, mode: .default, options: [.mixWithOthers, .allowBluetoothA2DP])
            if let usb = session.availableInputs?.first(where: { $0.portType == .usbAudio }) {
                try session.setPreferredInput(usb)
            }
            try session.setActive(true)
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
        for utterance in detector.process(samples) {
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
        do {
            try session.setCategory(.playAndRecord, mode: .default, options: [.duckOthers, .allowBluetoothA2DP])
            try session.setActive(true)
        } catch {
            lastError = "Duck: \(error.localizedDescription)"
        }
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        await withCheckedContinuation { continuation in
            speechContinuation = continuation
            synth.speak(utterance)
        }
        do {
            try session.setCategory(.playAndRecord, mode: .default, options: [.mixWithOthers, .allowBluetoothA2DP])
            try session.setActive(true)
        } catch {
            lastError = "Restore: \(error.localizedDescription)"
        }
        isSpeaking = false
    }

    private func speechFinished() {
        speechContinuation?.resume()
        speechContinuation = nil
    }

    func stopSpeaking() {
        speechQueue.removeAll()
        synth.stopSpeaking(at: .immediate)
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
