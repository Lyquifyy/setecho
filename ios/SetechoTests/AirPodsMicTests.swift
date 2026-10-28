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
    #expect(off.contains(.allowBluetoothA2DP) && off.contains(.mixWithOthers))
    #expect(!off.contains(.allowBluetoothHFP) && !off.contains(.bluetoothHighQualityRecording))

    settings.useAirPodsMic = true
    AirPodsMic.shared.reset()
    let on = AirPodsMic.shared.options(ducking: true)
    #expect(on.contains(.allowBluetoothHFP) && on.contains(.bluetoothHighQualityRecording) && on.contains(.allowBluetoothA2DP))
    #expect(on.contains(.duckOthers))
    #expect(AirPodsMic.shared.isActive && AirPodsMic.shared.notice == nil)
}
