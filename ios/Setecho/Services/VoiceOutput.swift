import AudioToolbox
import AVFoundation
import Foundation

/// His tone for one voice (Settings → Voice), saved per voice: rate and pitch go into the line's
/// SSML; warmth and clarity are EQ on the way out. Audio processing only, no models.
struct VoiceTone: Codable, Equatable {
    /// The slider value, 0.42–0.55 in `AVSpeechUtterance.rate` terms (0.5 is the voice's normal speed).
    var rate = SpokenText.defaultRate
    /// `pitchMultiplier` terms, 0.90–1.10.
    var pitch = 1.0
    /// Low shelf at 180 Hz, dB.
    var warmthDB = 2.0
    /// Bell at 3 kHz, dB.
    var clarityDB = -1.0

    static let pitchRange = 0.90...1.10
    static let warmthRange = -3.0...6.0
    static let clarityRange = -4.0...4.0

    var clamped: VoiceTone {
        func clamp(_ v: Double, _ r: ClosedRange<Double>) -> Double { min(max(v, r.lowerBound), r.upperBound) }
        return VoiceTone(rate: clamp(rate, SpokenText.rateRange), pitch: clamp(pitch, Self.pitchRange),
                         warmthDB: clamp(warmthDB, Self.warmthRange), clarityDB: clamp(clarityDB, Self.clarityRange))
    }
}

/// Every line Setecho says goes out here (HANDOFF.md §7, The spotter voice):
/// `AVSpeechSynthesizer.write` → buffers → `AVAudioPlayerNode` → `AVAudioUnitEQ` (warmth, clarity) →
/// a light `AUDynamicsProcessor` so lines carry over music → output. A live line starts playing on
/// its first buffer, so the chain adds no wait; a pre-rendered line plays its file through the same
/// chain. One output per audio owner.
@MainActor
final class VoiceOutput {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let eq = AVAudioUnitEQ(numberOfBands: 2)
    private let compressor = AVAudioUnitEffect(audioComponentDescription: AudioComponentDescription(
        componentType: kAudioUnitType_Effect, componentSubType: kAudioUnitSubType_DynamicsProcessor,
        componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0))
    private let synth = AVSpeechSynthesizer()
    private var format: AVAudioFormat?

    /// Bumped at every line: callbacks from an earlier line are ignored.
    private var generation = 0
    private var scheduled = 0
    private var played = 0
    private var ended = false
    private var lastActivity = Date.now

    /// A line whose synthesizer goes quiet this long without finishing is over (a route change, a stall).
    static let stallSeconds = 4.0

    init() {
        synth.usesApplicationAudioSession = true
        engine.attach(player)
        engine.attach(eq)
        engine.attach(compressor)
        let warmth = eq.bands[0]
        warmth.filterType = .lowShelf
        warmth.frequency = 180
        warmth.bypass = false
        let clarity = eq.bands[1]
        clarity.filterType = .parametric
        clarity.frequency = 3000
        clarity.bandwidth = 1.0
        clarity.bypass = false
        // Light compression above −20 dB with 5 dB of makeup gain: lines come out about 1.5 dB louder
        // than the raw voice with peaks near 0.85 (measured offline, Oct 28), leaving room for warmth.
        let unit = compressor.audioUnit
        AudioUnitSetParameter(unit, kDynamicsProcessorParam_Threshold, kAudioUnitScope_Global, 0, -20, 0)
        AudioUnitSetParameter(unit, kDynamicsProcessorParam_HeadRoom, kAudioUnitScope_Global, 0, 8, 0)
        AudioUnitSetParameter(unit, kDynamicsProcessorParam_AttackTime, kAudioUnitScope_Global, 0, 0.003, 0)
        AudioUnitSetParameter(unit, kDynamicsProcessorParam_ReleaseTime, kAudioUnitScope_Global, 0, 0.1, 0)
        AudioUnitSetParameter(unit, kDynamicsProcessorParam_OverallGain, kAudioUnitScope_Global, 0, 5, 0)
    }

    /// Warmth and clarity for the next line (the sliders apply on the next line or sample).
    func apply(_ tone: VoiceTone) {
        let tone = tone.clamped
        eq.bands[0].gain = Float(tone.warmthDB)
        eq.bands[1].gain = Float(tone.clarityDB)
    }

    /// Speak one line live: each buffer plays the moment the synthesizer writes it.
    func speak(_ utterance: AVSpeechUtterance, tone: VoiceTone) async {
        let line = begin(tone)
        synth.write(utterance) { [weak self] buffer in
            let copy = (buffer as? AVAudioPCMBuffer).map(Self.standardCopy) ?? nil
            let isEnd = (buffer as? AVAudioPCMBuffer)?.frameLength == 0
            let box = BufferBox(buffer: copy)
            Task { @MainActor in self?.received(box.buffer, end: isEnd, line: line) }
        }
        await finish(line)
    }

    /// Play one pre-rendered line through the same chain. A file that cannot be read throws.
    func play(file url: URL, tone: VoiceTone) async throws {
        let file = try AVAudioFile(forReading: url)
        let line = begin(tone)
        try connect(file.processingFormat)
        scheduled = 1
        player.scheduleFile(file, at: nil, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { @MainActor in self?.bufferPlayed(line) }
        }
        ended = true
        player.play()
        await finish(line, limit: Double(file.length) / file.processingFormat.sampleRate + 1.5)
    }

    /// Cut the line now.
    func cancel() {
        generation += 1
        synth.stopSpeaking(at: .immediate)
        player.stop()
        ended = true
    }

    // MARK: Chain

    private func begin(_ tone: VoiceTone) -> Int {
        cancel()
        apply(tone)
        scheduled = 0
        played = 0
        ended = false
        lastActivity = .now
        return generation
    }

    private func connect(_ newFormat: AVAudioFormat) throws {
        if format != newFormat {
            player.stop()
            engine.connect(player, to: eq, format: newFormat)
            engine.connect(eq, to: compressor, format: newFormat)
            engine.connect(compressor, to: engine.mainMixerNode, format: newFormat)
            format = newFormat
        }
        if !engine.isRunning { try engine.start() }
    }

    private func received(_ buffer: AVAudioPCMBuffer?, end: Bool, line: Int) {
        guard line == generation else { return }
        lastActivity = .now
        if end {
            ended = true
            return
        }
        guard let buffer, buffer.frameLength > 0 else { return }
        do {
            try connect(buffer.format)
        } catch {
            ended = true
            return
        }
        scheduled += 1
        player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { @MainActor in self?.bufferPlayed(line) }
        }
        if !player.isPlaying { player.play() }  // the first buffer starts the line
    }

    private func bufferPlayed(_ line: Int) {
        guard line == generation else { return }
        played += 1
        lastActivity = .now
    }

    /// Wait until everything written has played, or the line stalls, or `limit` passes.
    private func finish(_ line: Int, limit: Double? = nil) async {
        let started = Date.now
        while line == generation {
            if ended, played >= scheduled { break }
            if Date.now.timeIntervalSince(lastActivity) > Self.stallSeconds { break }
            if let limit, Date.now.timeIntervalSince(started) > limit { break }
            try? await Task.sleep(for: .milliseconds(15))
        }
        if line == generation { player.stop() }
    }

    /// The synthesizer may reuse its buffer and may write Int16: copy into the standard float format
    /// the EQ and compressor take.
    nonisolated static func standardCopy(_ pcm: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard pcm.frameLength > 0,
              let target = AVAudioFormat(standardFormatWithSampleRate: pcm.format.sampleRate, channels: pcm.format.channelCount),
              let converter = AVAudioConverter(from: pcm.format, to: target),
              let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: pcm.frameLength)
        else { return nil }
        do { try converter.convert(to: out, from: pcm) } catch { return nil }
        return out
    }
}

/// Hands a copied buffer from the synthesizer's queue to the main actor; nothing else touches it.
private struct BufferBox: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer?
}
