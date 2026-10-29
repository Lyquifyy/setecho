import AVFoundation
import Foundation
import Observation

/// Where Setecho records from (HANDOFF.md §9, block 1). With "Use AirPods mic" on, the session asks
/// for HFP plus iOS 26's Bluetooth high-quality recording, with A2DP kept for output. iOS falls back
/// to call-quality HFP on its own when the AirPods can't do high quality; when that happens, or the
/// output disappears, this switches back to the DJI receiver or the iPhone mic for the rest of the
/// run and says so. Every session activation in the app takes its options from here.
@MainActor
@Observable
final class AirPodsMic {
    static let shared = AirPodsMic()

    /// The AirPods mic was tried and failed this run: back to A2DP output only.
    private(set) var unavailable = false
    /// Shown on Check-in morning, Settings and Probes after a fallback.
    private(set) var notice: String?
    /// What the last check found, for Probes: "AirPods · high quality", "off", …
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
        if isActive { options.formUnion([.allowBluetoothHFP, .bluetoothHighQualityRecording]) }
        return options
    }

    /// The category for the current policy. A refusal of the AirPods options is itself a fallback.
    func apply(to session: AVAudioSession, ducking: Bool) throws {
        do {
            try session.setCategory(.playAndRecord, mode: .default, options: options(ducking: ducking))
        } catch where isActive {
            fallBack(session, reason: "options refused")
            try session.setCategory(.playAndRecord, mode: .default, options: options(ducking: ducking))
        }
    }

    /// After an activation or a route change: if the output dropped to call-quality HFP without high
    /// quality, or there is no output at all, fall back. Returns true when it fell back.
    @discardableResult
    func check(_ session: AVAudioSession) -> Bool {
        let route = session.currentRoute
        let input = route.inputs.first
        let highQuality = input?.bluetoothMicrophoneExtension?.highQualityRecording.isEnabled == true
        guard isActive else {
            state = Settings.shared.useAirPodsMic ? "unavailable this run" : "off"
            return false
        }
        if route.outputs.isEmpty {
            fallBack(session, reason: "no output")
            return true
        }
        if route.outputs.contains(where: { $0.portType == .bluetoothHFP }), !highQuality {
            fallBack(session, reason: "call quality only")
            return true
        }
        state = highQuality ? "\(input?.portName ?? "AirPods") · high quality" : "on · \(input?.portName ?? "no input")"
        return false
    }

    func reset() {
        unavailable = false
        notice = nil
        state = Settings.shared.useAirPodsMic ? "on" : "off"
    }

    private func fallBack(_ session: AVAudioSession, reason: String) {
        unavailable = true
        let dji = session.availableInputs?.contains { $0.portType == .usbAudio } == true
        notice = "AirPods mic unavailable, using the \(dji ? "DJI" : "iPhone") mic"
        state = "fell back · \(reason)"
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
