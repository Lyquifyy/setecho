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
    out += d.process(noise(seconds: 1.5, amplitude: 0.001))
    #expect(out.count == 1 && !d.isSpeaking)
    let u = out[0]
    // 300 ms pre-roll + 1 s word + 1.2 s hangover.
    #expect(abs(u.seconds - 2.5) < 0.05)
    #expect(u.peakDB > -15)
}

@Test func anAnswerInsideTheCalibrationWindowDoesNotRaiseTheFloor() {
    // Oct 28: he answered the first question at once; with a median the floor became his voice
    // and the next answer went unheard.
    let d = detector()
    var out = d.process(noise(seconds: 0.6, amplitude: 0.001))
    out += d.process(tone(seconds: 1.4, amplitude: 0.3))
    #expect(d.noiseFloorDB != nil && d.noiseFloorDB! < -50)
    out += d.process(noise(seconds: 2.0, amplitude: 0.001))
    out += d.process(tone(seconds: 1.0, amplitude: 0.3))
    out += d.process(noise(seconds: 1.5, amplitude: 0.001))
    #expect(out.count == 1)
}

@Test func shortBlipsBelowTheOnsetAreIgnored() {
    let d = detector()
    _ = d.process(noise(seconds: 2.5, amplitude: 0.001))
    var out = d.process(tone(seconds: 0.2, amplitude: 0.3))   // a 200 ms clank
    out += d.process(noise(seconds: 1.0, amplitude: 0.001))
    #expect(out.isEmpty && !d.isSpeaking)
}

@Test func longSpeechIsCappedAtTwentyFiveSeconds() {
    let d = detector()
    _ = d.process(noise(seconds: 2.5, amplitude: 0.001))
    let out = d.process(tone(seconds: 27, amplitude: 0.3))
    #expect(out.count == 1)
    #expect(abs(out[0].seconds - 25.0) < 0.05)
}

@Test func aNoisyGymRaisesTheThreshold() {
    let quiet = detector()
    _ = quiet.process(noise(seconds: 2.5, amplitude: 0.001))
    let loud = detector()
    _ = loud.process(noise(seconds: 2.5, amplitude: 0.05))
    #expect(loud.thresholdDB! > quiet.thresholdDB! + 20)
    // A word at the quiet room's level is not heard over gym noise…
    var out = loud.process(tone(seconds: 1.0, amplitude: 0.02))
    out += loud.process(noise(seconds: 1.5, amplitude: 0.05))
    #expect(out.isEmpty)
    // …but a louder one is.
    out = loud.process(tone(seconds: 1.0, amplitude: 0.5))
    out += loud.process(noise(seconds: 1.5, amplitude: 0.05))
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

// MARK: Sessions (HANDOFF.md §7, Hearing him in a gym)

private func sessionDetector() -> VoiceDetector {
    VoiceDetector(config: .session(sampleRate: rate))
}

/// A tone this many dB over a floor of amplitude 0.01 (about -43 dBFS RMS for the noise).
private func over(_ d: VoiceDetector, db: Double, seconds: Double) -> [Float] {
    let target = d.noiseFloorDB! + db
    // A sine's RMS is amplitude / sqrt(2).
    let amplitude = Float(pow(10, target / 20) * 2.0.squareRoot())
    return tone(seconds: seconds, amplitude: amplitude)
}

@Test func aShortQuietGoIsHeardInASession() {
    // Oct 28 gym test: 13 dB and 350 ms let short commands through the floor. A "go" is ~0.3 s.
    let d = sessionDetector()
    _ = d.process(noise(seconds: 2.5, amplitude: 0.01))
    var out = d.process(over(d, db: 10, seconds: 0.3))
    out += d.process(noise(seconds: 1.2, amplitude: 0.01))
    #expect(out.count == 1)
    #expect(out[0].speechSeconds >= 0.15 && out[0].speechSeconds < 0.5)
    #expect(d.drainEvents().first == .streamOpened)
}

@Test func aSoundBetweenTheTriggersOpensTheStreamAndEndsAsANearMiss() {
    let d = sessionDetector()
    _ = d.process(noise(seconds: 2.5, amplitude: 0.01))
    var out = d.process(over(d, db: 7, seconds: 0.5))
    out += d.process(noise(seconds: 1.2, amplitude: 0.01))
    #expect(out.isEmpty)
    let events = d.drainEvents()
    #expect(events.first == .streamOpened)
    guard case .nearMiss(let miss) = events.last else {
        Issue.record("no near miss: \(events)")
        return
    }
    #expect(abs(miss.seconds - 0.5) < 0.1)
    #expect(miss.peakAboveFloorDB > 6 && miss.peakAboveFloorDB < 8)
}

@Test func theCheckInHasNoStreamTrigger() {
    let d = detector()
    _ = d.process(noise(seconds: 2.5, amplitude: 0.01))
    _ = d.process(tone(seconds: 0.5, amplitude: 0.05))
    _ = d.process(noise(seconds: 1.5, amplitude: 0.01))
    #expect(d.drainEvents().isEmpty)
}

@Test func aMaximumLengthNoiseRaisesTheFloor() {
    let d = sessionDetector()
    _ = d.process(noise(seconds: 2.5, amplitude: 0.01))
    let before = d.noiseFloorDB!
    let out = d.process(noise(seconds: 11, amplitude: 0.1, seed: 7)) // music turned up, 20 dB louder
    #expect(out.count == 1 && out[0].hitMax)
    #expect(d.noiseFloorDB! > before + 12)
    // The louder room is now the floor: the same music no longer starts an utterance at once.
    #expect(d.process(noise(seconds: 2, amplitude: 0.1, seed: 9)).isEmpty && !d.isSpeaking)
}

@Test func theStreamEndsAnUtteranceOnceTheRoomIsQuiet() {
    let d = sessionDetector()
    _ = d.process(noise(seconds: 2.5, amplitude: 0.01))
    _ = d.process(over(d, db: 15, seconds: 0.6))
    #expect(d.endIfQuiet() == nil) // still loud
    _ = d.process(noise(seconds: 0.3, amplitude: 0.01))
    let u = d.endIfQuiet()
    #expect(u != nil && !d.isSpeaking)
}

@Test func whileSetechoTalksOnlyALouderVoiceInterrupts() {
    let d = sessionDetector()
    _ = d.process(noise(seconds: 2.5, amplitude: 0.01))
    d.boostDB = 6
    var out = d.process(over(d, db: 10, seconds: 0.4)) // 10 dB over the floor: under 8 + 6
    out += d.process(noise(seconds: 1.2, amplitude: 0.01))
    #expect(out.isEmpty)
    out = d.process(over(d, db: 18, seconds: 0.4))
    #expect(d.isSpeaking)
}
