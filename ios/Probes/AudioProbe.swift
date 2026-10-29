import AVFoundation
import SwiftUI
import os

/// G2: Spotify plays on AirPods (A2DP). Record 5 s from the DJI receiver over USB to a 16 kHz mono WAV,
/// then speak a callout with ducking. The human listens for full-quality music that dips and comes back.
/// Session rules from HANDOFF.md §7 Audio: .playAndRecord, .mixWithOthers + .allowBluetoothA2DP, never
/// .allowBluetooth (HFP), prefer the .usbAudio input, duck only while speaking.
struct AudioProbeView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var model = AudioProbeModel()

    var body: some View {
        ScreenScaffold {
            LinkButton(title: "Back to probes", chevron: .leading) { dismiss() }
            TitleBlock(
                eyebrow: "G2",
                title: "Audio",
                subtitle: "Start Spotify on the AirPods first. Plug the DJI receiver into the phone."
            )
            SectionCard("Route") {
                LabeledRow("Input", model.currentInput)
                CardDivider()
                LabeledRow("Output", model.currentOutput)
                CardDivider()
                LabeledRow("Available inputs", model.inputs.isEmpty ? "—" : model.inputs.joined(separator: "\n"))
                LinkButton(title: "Refresh route", chevron: .none) { model.configure() }
            }
            SectionCard("Recording") {
                HStack(alignment: .firstTextBaseline) {
                    MetricText(value: model.isRecording ? String(Int(model.levelDB)) : "—", unit: "dBFS")
                    Spacer()
                    if model.isRecording { TargetTag(text: "Recording") }
                }
                if let url = model.wavURL {
                    CardDivider()
                    LabeledRow("File", url.lastPathComponent)
                    LabeledRow("Length", Format.duration(model.wavSeconds))
                    LabeledRow("Format", "16 kHz · mono · 16-bit")
                    HStack(spacing: Theme.Space.s) {
                        LinkButton(title: "Play back", chevron: .none) { model.play() }
                        Spacer()
                        ShareLink(item: url) {
                            Label("Send to Mac", systemImage: "square.and.arrow.up")
                        }
                        .buttonStyle(.setechoOutline)
                    }
                }
            }
            PassChecksCard(items: [
                "Input shows the DJI receiver as USB audio, not the iPhone mic.",
                "Spotify stays full quality while recording (no call-quality drop).",
                "The callout dips the music, then the music returns to full volume.",
                "Play back: your voice is clear. Then AirDrop the WAV to the Mac and run voice_probe.py on it.",
            ])
            ProbeLog(lines: model.log)
        } footer: {
            Button(model.isRecording ? "Recording…" : "Record 5 seconds") {
                Task { await model.record() }
            }
            .buttonStyle(.setechoPrimary)
            .disabled(model.isRecording)
            Button("Speak test callout (ducks music)") { model.speak() }
                .buttonStyle(.setechoOutline)
                .disabled(model.isSpeaking || model.isRecording)
        }
        .task { model.configure() }
    }
}

@MainActor
@Observable
final class AudioProbeModel {
    var log: [String] = []
    var inputs: [String] = []
    var currentInput = "—"
    var currentOutput = "—"
    var isRecording = false
    var isSpeaking = false
    var levelDB: Double = -120
    var wavURL: URL?
    var wavSeconds: Double = 0

    private let session = AVAudioSession.sharedInstance()
    private let capture = CaptureBuffer()
    private let synth = AVSpeechSynthesizer()
    private let speechDelegate = SpeechDelegate()
    private var engine: AVAudioEngine?
    private var player: AVAudioPlayer?

    init() {
        synth.usesApplicationAudioSession = true
        synth.delegate = speechDelegate
    }

    func configure() {
        do {
            #if SETECHO_APP
            // In the app, the same options and input as a session, so "Use AirPods mic" shows here.
            try AirPodsMic.shared.apply(to: session, ducking: false)
            let preferred = AirPodsMic.shared.preferredInput(in: session)
            #else
            try session.setCategory(.playAndRecord, mode: .default, options: [.mixWithOthers, .allowBluetoothA2DP])
            let preferred = session.availableInputs?.first(where: { $0.portType == .usbAudio })
            #endif
            let available = session.availableInputs ?? []
            inputs = available.map { "\($0.portName) · \($0.portType.rawValue)" }
            if let preferred {
                try session.setPreferredInput(preferred)
                note("Preferred input set to \(preferred.portName) (\(preferred.portType.rawValue))")
            } else {
                try? session.setPreferredInput(nil)
                note("No USB or high-quality AirPods input found; \(available.first?.portName ?? "default") will be used")
            }
            try session.setActive(true)
            refreshRoute()
        } catch {
            note("Session error: \(error.localizedDescription)")
        }
    }

    func refreshRoute() {
        let route = session.currentRoute
        let ins = route.inputs.map { "\($0.portName) · \($0.portType.rawValue)" }.joined(separator: ", ")
        let outs = route.outputs.map { "\($0.portName) · \($0.portType.rawValue)" }.joined(separator: ", ")
        currentInput = ins.isEmpty ? "—" : ins
        currentOutput = outs.isEmpty ? "—" : outs
    }

    func record(seconds: Double = 5) async {
        guard !isRecording else { return }
        guard await AVAudioApplication.requestRecordPermission() else {
            note("Microphone permission denied")
            return
        }
        configure()
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            note("Input has no format. Is a mic connected?")
            return
        }
        capture.reset(sampleRate: format.sampleRate)
        let capture = self.capture
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { @Sendable buffer, _ in
            // @Sendable so the closure is not main-actor isolated: the tap runs on the realtime audio thread.
            capture.append(buffer)
        }
        do {
            try engine.start()
        } catch {
            note("Engine failed to start: \(error.localizedDescription)")
            return
        }
        self.engine = engine
        isRecording = true
        refreshRoute()
        note("Recording \(Int(seconds)) s at \(Int(format.sampleRate)) Hz, \(format.channelCount) ch, from \(currentInput)")

        let ticks = Int(seconds * 10)
        for _ in 0..<ticks {
            try? await Task.sleep(for: .milliseconds(100))
            levelDB = capture.levelDB
        }

        input.removeTap(onBus: 0)
        engine.stop()
        self.engine = nil
        isRecording = false

        let (samples, rate) = capture.drain()
        let pcm = Resample.toInt16Mono(samples, from: rate, to: 16_000)
        let data = WAVFile.data(pcm16: pcm, sampleRate: 16_000)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("probe-\(Int(Date.now.timeIntervalSince1970)).wav")
        do {
            try data.write(to: url)
            wavURL = url
            wavSeconds = Double(pcm.count) / 16_000
            note("Saved \(url.lastPathComponent): \(data.count) bytes, \(Format.duration(wavSeconds)), peak \(Int(capture.peakDB)) dBFS")
        } catch {
            note("Write failed: \(error.localizedDescription)")
        }
    }

    func play() {
        guard let wavURL else { return }
        do {
            player = try AVAudioPlayer(contentsOf: wavURL)
            player?.play()
            note("Playing back")
        } catch {
            note("Playback failed: \(error.localizedDescription)")
        }
    }

    func speak(_ text: String = "Set three done. Next, two twenty-five for eight. Rest two thirty.") {
        guard !isSpeaking else { return }
        do {
            try session.setCategory(.playAndRecord, mode: .default, options: callout(ducking: true))
            try session.setActive(true)
        } catch {
            note("Duck failed: \(error.localizedDescription)")
        }
        isSpeaking = true
        note("Speaking with ducking: \"\(text)\"")
        speechDelegate.onFinish = { [weak self] in self?.restoreMixing() }
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
        synth.speak(utterance)
    }

    private func restoreMixing() {
        do {
            // No second activation: that is what threw "can't interrupt others" at the gym (Oct 28).
            try session.setCategory(.playAndRecord, mode: .default, options: callout(ducking: false))
            note("Finished speaking. Music should be back at full volume.")
        } catch {
            note("Restore failed: \(error.localizedDescription)")
        }
        isSpeaking = false
    }

    /// The callout's options: the app's own in the app, mixable either way.
    private func callout(ducking: Bool) -> AVAudioSession.CategoryOptions {
        #if SETECHO_APP
        AirPodsMic.shared.options(ducking: ducking)
        #else
        ducking ? [.mixWithOthers, .duckOthers, .allowBluetoothA2DP] : [.mixWithOthers, .allowBluetoothA2DP]
        #endif
    }

    private func note(_ line: String) {
        log.append("\(Date.now.probeStamp)  \(line)")
    }
}

@MainActor
final class SpeechDelegate: NSObject, AVSpeechSynthesizerDelegate {
    var onFinish: (() -> Void)?

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in self.onFinish?() }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in self.onFinish?() }
    }
}
