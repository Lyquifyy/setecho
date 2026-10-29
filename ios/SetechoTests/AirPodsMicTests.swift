import AVFoundation
import Testing
@testable import Setecho

/// "Use AirPods mic" (HANDOFF.md §9, block 1): off keeps AirPods as A2DP output only; on asks for
/// HFP plus high-quality recording, with A2DP kept for output.
@Test @MainActor func theAirPodsSwitchDecidesTheSessionOptions() {
    let settings = Settings.shared
    let before = settings.useAirPodsMic
    defer { settings.useAirPodsMic = before; AirPodsMic.shared.reset() }

    settings.useAirPodsMic = false
    AirPodsMic.shared.reset()
    let off = AirPodsMic.shared.options(ducking: false)
    #expect(off.contains(.allowBluetoothA2DP) && off.contains(.mixWithOthers) && off.contains(.defaultToSpeaker)) // never the earpiece
    #expect(!off.contains(.allowBluetoothHFP) && !off.contains(.bluetoothHighQualityRecording))

    settings.useAirPodsMic = true
    AirPodsMic.shared.reset()
    let on = AirPodsMic.shared.options(ducking: true)
    #expect(on.contains(.allowBluetoothHFP) && on.contains(.bluetoothHighQualityRecording) && on.contains(.allowBluetoothA2DP))
    #expect(on.contains(.duckOthers))
    #expect(AirPodsMic.shared.isActive && AirPodsMic.shared.notice == nil)
}

/// Oct 28 gym test: with the AirPods mic and music playing, restoring the music failed with '!int'
/// ("can't interrupt others"). Every configuration is mixable, ducking or not, AirPods or not.
@Test @MainActor func everyConfigurationMixesWithHisMusic() {
    let settings = Settings.shared
    let before = settings.useAirPodsMic
    defer { settings.useAirPodsMic = before; AirPodsMic.shared.reset() }
    for airPods in [false, true] {
        settings.useAirPodsMic = airPods
        AirPodsMic.shared.reset()
        for ducking in [false, true] {
            #expect(AirPodsMic.shared.options(ducking: ducking).contains(.mixWithOthers), "airPods \(airPods), ducking \(ducking)")
        }
    }
    #expect(AirPodsMic.describe([.mixWithOthers, .duckOthers, .bluetoothHighQualityRecording])
            == ["mixWithOthers", "duckOthers", "bluetoothHighQualityRecording"])
}

@Test func anAudioErrorReadsByItsFourCharacterCode() {
    let error = NSError(domain: NSOSStatusErrorDomain, code: 560557684)
    #expect(AudioService.describe(error).hasPrefix("!int · 560557684"))
}
