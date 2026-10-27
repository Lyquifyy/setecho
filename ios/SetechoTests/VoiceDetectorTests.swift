import Foundation
import Testing
@testable import Setecho

private let rate = 16_000.0

private func noise(seconds: Double, amplitude: Float, seed: UInt64 = 1) -> [Float] {
    var state = seed
    return (0..<Int(seconds * rate)).map { _ in
        state = state &* 6364136223846793005 &+ 1442695040888963407
        let unit = Float(state >> 40) / Float(1 << 24) * 2 - 1
        return unit * amplitude
    }
}

private func tone(seconds: Double, amplitude: Float) -> [Float] {
    (0..<Int(seconds * rate)).map { amplitude * sin(Float($0) * 2 * .pi * 300 / Float(rate)) }
}

private func detector() -> VoiceDetector {
    VoiceDetector(config: .init(sampleRate: rate))
}

@Test func learnsTheFloorThenDetectsOneUtterance() {
    let d = detector()
    // 2 s of quiet room noise (about -60 dBFS), then a 1 s word, then quiet.
    var out = d.process(noise(seconds: 2.5, amplitude: 0.001))
    #expect(out.isEmpty)
    #expect(d.noiseFloorDB != nil && d.noiseFloorDB! < -50)
    out += d.process(tone(seconds: 1.0, amplitude: 0.3))
    #expect(out.isEmpty && d.isSpeaking)         // still speaking: no hangover yet
    out += d.process(noise(seconds: 1.0, amplitude: 0.001))
    #expect(out.count == 1 && !d.isSpeaking)
    let u = out[0]
    // 300 ms pre-roll + 1 s word + 700 ms hangover.
    #expect(abs(u.seconds - 2.0) < 0.05)
    #expect(u.peakDB > -15)
}

@Test func shortBlipsBelowTheOnsetAreIgnored() {
    let d = detector()
    _ = d.process(noise(seconds: 2.5, amplitude: 0.001))
    var out = d.process(tone(seconds: 0.2, amplitude: 0.3))   // a 200 ms clank
    out += d.process(noise(seconds: 1.0, amplitude: 0.001))
    #expect(out.isEmpty && !d.isSpeaking)
}

@Test func longSpeechIsCappedAtTenSeconds() {
    let d = detector()
    _ = d.process(noise(seconds: 2.5, amplitude: 0.001))
    let out = d.process(tone(seconds: 12, amplitude: 0.3))
    #expect(out.count == 1)
    #expect(abs(out[0].seconds - 10.0) < 0.05)
}

@Test func aNoisyGymRaisesTheThreshold() {
    let quiet = detector()
    _ = quiet.process(noise(seconds: 2.5, amplitude: 0.001))
    let loud = detector()
    _ = loud.process(noise(seconds: 2.5, amplitude: 0.05))
    #expect(loud.thresholdDB! > quiet.thresholdDB! + 20)
    // A word at the quiet room's level is not heard over gym noise…
    var out = loud.process(tone(seconds: 1.0, amplitude: 0.02))
    out += loud.process(noise(seconds: 1.0, amplitude: 0.05))
    #expect(out.isEmpty)
    // …but a louder one is.
    out = loud.process(tone(seconds: 1.0, amplitude: 0.5))
    out += loud.process(noise(seconds: 1.0, amplitude: 0.05))
    #expect(out.count == 1)
}

@Test func flushReturnsAnUtteranceInProgress() {
    let d = detector()
    _ = d.process(noise(seconds: 2.5, amplitude: 0.001))
    _ = d.process(tone(seconds: 0.8, amplitude: 0.3))
    #expect(d.isSpeaking)
    let u = d.flush()
    #expect(u != nil && abs(u!.seconds - 1.1) < 0.05)   // 300 ms pre-roll + 800 ms
    #expect(d.flush() == nil)
}

@Test func rmsInDecibels() {
    #expect(VoiceDetector.rmsDB([]) == -120)
    #expect(abs(VoiceDetector.rmsDB([1, -1, 1, -1]) - 0) < 1e-6)
    #expect(abs(VoiceDetector.rmsDB([0.1, -0.1]) - (-20)) < 1e-4)
}
