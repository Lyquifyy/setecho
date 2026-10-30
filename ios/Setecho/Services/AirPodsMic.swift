import AVFoundation
import Foundation
import Observation

/// Where Setecho records from (HANDOFF.md §9, block 1). With "Use AirPods mic" on, the session asks
/// for iOS 26's Bluetooth high-quality recording on its own, never with `.allowBluetoothHFP`. Apple's
/// header: the option alone "will be enabled if the route supports it, otherwise the option will be
/// ignored"; combined with HFP, call-quality HFP is the fallback, and HFP ports win routing over A2DP
/// on the same device. That HFP switch took the AirPods off A2DP and stopped his music when a session
/// started (Oct 29). So the AirPods mic is full quality or not used at all: AirPods that can't record
/// at high quality stay on A2DP output, the DJI receiver or the iPhone mic listens, and his music is
/// never touched. Every session activation in the app takes its options and its input from here.
@MainActor
@Observable
final class AirPodsMic {
    static let shared = AirPodsMic()

    /// The AirPods dropped to call quality this run anyway: high-quality recording is off until reset.
    private(set) var unavailable = false
    /// Shown on Check-in morning, Settings and Probes when the AirPods aren't the mic.
    private(set) var notice: String?
    /// What the last check found, for Probes: "AirPods Pro · high quality", "off", …
    private(set) var state = "off"

    var isActive: Bool { Settings.shared.useAirPodsMic && !unavailable }

    /// The category options for every activation: mixing always, ducking too while Setecho speaks.
    /// `.defaultToSpeaker`: with nothing plugged in, .playAndRecord plays through the earpiece, which
    /// made every check-in line thin and quiet (Oct 28) while "Play sample" used the loudspeaker.
    /// AirPods and other headphones still take the output when connected.
    func options(ducking: Bool) -> AVAudioSession.CategoryOptions {
        // Mixable in every configuration, so his music never stops: ducking adds to mixing, never
        // replaces it (Oct 28 gym test: a restore failed with "can't interrupt others", '!int').
        var options: AVAudioSession.CategoryOptions = ducking ? [.mixWithOthers, .duckOthers, .allowBluetoothA2DP] : [.mixWithOthers, .allowBluetoothA2DP]
        options.insert(.defaultToSpeaker)
        // Never `.allowBluetoothHFP`: it makes call quality the fallback and pauses his music.
        if isActive { options.insert(.bluetoothHighQualityRecording) }
        return options
    }

    /// The category for the current policy. A refusal of the AirPods option is itself a fallback.
    /// Already set is left alone: on the AirPods' high-quality link a repeated category sets the link
    /// up again, which pauses his music (Oct 29).
    func apply(to session: AVAudioSession, ducking: Bool) throws {
        let wanted = options(ducking: ducking)
        if session.category == .playAndRecord, session.mode == .default, session.categoryOptions == wanted { return }
        do {
            try session.setCategory(.playAndRecord, mode: .default, options: options(ducking: ducking))
        } catch where isActive {
            fallBack(reason: "option refused", notice: "AirPods mic unavailable, using the \(Self.fallbackMic(session)) mic")
            try session.setCategory(.playAndRecord, mode: .default, options: options(ducking: ducking))
        }
    }

    /// The input to prefer: a plugged-in external mic (the DJI receiver) first, then AirPods that can
    /// record at high quality; nil leaves it to iOS (the iPhone mic, with no HFP on offer). A choice
    /// made in the input picker is replaced, so a call-quality pick never outlives the next start.
    func preferredInput(in session: AVAudioSession) -> AVAudioSessionPortDescription? {
        let inputs = session.availableInputs ?? []
        if let usb = inputs.first(where: { $0.portType == .usbAudio }) { return usb }
        guard isActive else { return nil }
        return inputs.first { $0.bluetoothMicrophoneExtension?.highQualityRecording.isSupported == true }
    }

    /// Prefer this input, unless it already is: a repeated preference re-routes like a new one.
    func prefer(_ port: AVAudioSessionPortDescription?, in session: AVAudioSession) {
        guard session.preferredInput?.uid != port?.uid else { return }
        try? session.setPreferredInput(port)
    }

    /// The AirPods are the mic at high quality right now.
    func isRecordingHighQuality(_ session: AVAudioSession) -> Bool {
        session.currentRoute.inputs.first?.bluetoothMicrophoneExtension?.highQualityRecording.isEnabled == true
    }

    /// After an activation or a route change: says which mic is listening and why. Returns true only
    /// when the AirPods went to call quality anyway, which turns high-quality recording off for the
    /// run; the caller then configures again.
    @discardableResult
    func check(_ session: AVAudioSession) -> Bool {
        let route = session.currentRoute
        let input = route.inputs.first
        guard isActive else {
            state = Settings.shared.useAirPodsMic ? "unavailable this run" : "off"
            return false
        }
        let highQuality = input?.bluetoothMicrophoneExtension?.highQualityRecording.isEnabled == true
        if route.outputs.contains(where: { $0.portType == .bluetoothHFP }), !highQuality {
            fallBack(reason: "call quality", notice: "AirPods mic unavailable, using the \(Self.fallbackMic(session)) mic")
            return true
        }
        let mic = input?.portName ?? "no input"
        if highQuality {
            state = "\(mic) · high quality"
            notice = nil
        } else if input?.portType == .usbAudio {
            state = "\(mic) · external mic first"
            notice = nil
        } else if let headphones = route.outputs.first(where: { [.bluetoothA2DP, .bluetoothLE].contains($0.portType) }) {
            // High-quality recording only engages with the mic open: a check before then reads the
            // iPhone mic, and the route change once it opens checks again.
            state = "\(headphones.portName) can't record at high quality · \(mic)"
            notice = "\(headphones.portName) can't record at full quality, so the \(Self.fallbackMic(session)) mic listens. Your music isn't touched."
        } else {
            state = "no AirPods · \(mic)"
            notice = nil
        }
        return false
    }

    func reset() {
        unavailable = false
        notice = nil
        state = Settings.shared.useAirPodsMic ? "on" : "off"
    }

    private func fallBack(reason: String, notice: String) {
        unavailable = true
        self.notice = notice
        state = "fell back · \(reason)"
    }

    private static func fallbackMic(_ session: AVAudioSession) -> String {
        session.availableInputs?.contains { $0.portType == .usbAudio } == true ? "DJI" : "iPhone"
    }

    /// Every input iOS offers, for Probes: "iPhone Microphone · MicrophoneBuiltIn, AirPods Pro · BluetoothHFP · high quality supported".
    static func describeInputs(_ session: AVAudioSession) -> String {
        let inputs = session.availableInputs ?? []
        guard !inputs.isEmpty else { return "—" }
        return inputs.map { port in
            let hq = port.bluetoothMicrophoneExtension?.highQualityRecording
            let note = hq.map { $0.isEnabled ? " · high quality on" : $0.isSupported ? " · high quality supported" : " · no high quality" } ?? ""
            return "\(port.portName) · \(port.portType.rawValue)\(note)"
        }.joined(separator: ", ")
    }

    /// Option names for the debug record: "mixWithOthers, duckOthers, allowBluetoothHFP, …".
    nonisolated static func describe(_ options: AVAudioSession.CategoryOptions) -> [String] {
        let names: [(AVAudioSession.CategoryOptions, String)] = [
            (.mixWithOthers, "mixWithOthers"), (.duckOthers, "duckOthers"), (.interruptSpokenAudioAndMixWithOthers, "interruptSpokenAudio"),
            (.allowBluetoothHFP, "allowBluetoothHFP"), (.allowBluetoothA2DP, "allowBluetoothA2DP"), (.allowAirPlay, "allowAirPlay"),
            (.defaultToSpeaker, "defaultToSpeaker"), (.bluetoothHighQualityRecording, "bluetoothHighQualityRecording"),
        ]
        return names.filter { options.contains($0.0) }.map(\.1)
    }
}

/// How a session lowers his music for a line while the AirPods record at high quality. Every way is
/// a category change on the AirPods' call-style link, which can set it up again and pause his music
/// (Oct 29), so the music test tries each one and the Developer setting picks.
enum AirPodsLowering: String, CaseIterable, Identifiable {
    /// Lines play over his music at full volume.
    case off
    /// `.duckOthers` added for the line and taken off after, with no activation.
    case optionOnly
    /// `.duckOthers` added with an activation, as on A2DP (the old way).
    case withActivation
    /// `.duckOthers` from the session's start to its end: the music lower throughout, no changes mid-session.
    case wholeSession

    var id: String { rawValue }

    var label: String {
        switch self {
        case .off: "Don't lower"
        case .optionOnly: "Per line, option only"
        case .withActivation: "Per line, with activation"
        case .wholeSession: "Whole session"
        }
    }
}
