import AVFoundation
import Foundation
import os

/// Collects mono Float samples from the realtime input tap. Lock-protected: the tap thread writes,
/// the main actor drains. Shared by the Audio probe and the session's AudioService.
final class CaptureBuffer: Sendable {
    private struct State: Sendable {
        var samples: [Float] = []
        var sampleRate: Double = 48_000
        var levelDB: Double = -120
        var peakDB: Double = -120
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    func reset(sampleRate: Double) {
        state.withLock { $0 = State(sampleRate: sampleRate) }
    }

    /// Called from the audio thread. Averages channels to mono and tracks the block level.
    func append(_ buffer: AVAudioPCMBuffer) {
        guard let channels = buffer.floatChannelData else { return }
        let frames = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        guard frames > 0, channelCount > 0 else { return }
        var mono = [Float](repeating: 0, count: frames)
        for channel in 0..<channelCount {
            let p = channels[channel]
            for i in 0..<frames { mono[i] += p[i] }
        }
        if channelCount > 1 {
            let inv = 1 / Float(channelCount)
            for i in 0..<frames { mono[i] *= inv }
        }
        var sum: Float = 0
        var peak: Float = 0
        for v in mono {
            sum += v * v
            peak = max(peak, abs(v))
        }
        let rms = (sum / Float(frames)).squareRoot()
        let levelDB = Double(20 * log10(max(rms, 1e-7)))
        let peakDB = Double(20 * log10(max(peak, 1e-7)))
        let finished = mono
        state.withLock {
            $0.samples.append(contentsOf: finished)
            $0.levelDB = levelDB
            $0.peakDB = max($0.peakDB, peakDB)
        }
    }

    var levelDB: Double { state.withLock { $0.levelDB } }
    var peakDB: Double { state.withLock { $0.peakDB } }
    var sampleRate: Double { state.withLock { $0.sampleRate } }

    /// Take everything captured since the last drain.
    func drain() -> ([Float], Double) {
        state.withLock {
            let result = ($0.samples, $0.sampleRate)
            $0.samples = []
            return result
        }
    }
}

/// Box-average decimation at integer ratios (48 k -> 16 k), linear interpolation otherwise.
/// Good enough for speech to Muse Voice Transcribe; the WAV writer takes the Int16 result.
enum Resample {
    static func toInt16Mono(_ samples: [Float], from inRate: Double, to outRate: Double) -> [Int16] {
        guard !samples.isEmpty, inRate > 0, outRate > 0 else { return [] }
        let ratio = inRate / outRate
        let outCount = Int(Double(samples.count) / ratio)
        var out = [Int16](repeating: 0, count: outCount)
        let factor = Int(ratio.rounded())
        if factor >= 1, abs(ratio - Double(factor)) < 1e-6 {
            for i in 0..<outCount {
                var acc: Float = 0
                let base = i * factor
                for k in 0..<factor { acc += samples[base + k] }
                out[i] = clamp(acc / Float(factor))
            }
        } else {
            for i in 0..<outCount {
                let pos = Double(i) * ratio
                let j = Int(pos)
                let t = Float(pos - Double(j))
                let a = samples[j]
                let b = j + 1 < samples.count ? samples[j + 1] : a
                out[i] = clamp(a + (b - a) * t)
            }
        }
        return out
    }

    private static func clamp(_ v: Float) -> Int16 {
        Int16(max(-1, min(1, v)) * 32_767)
    }
}
