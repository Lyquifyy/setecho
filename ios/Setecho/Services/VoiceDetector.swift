import Foundation

/// Utterance detection on the mic signal (HANDOFF.md §7 Audio): RMS in dBFS against a noise floor
/// learned over the first 2 s, 300 ms onset, 700 ms hangover, utterances capped at 10 s. Pure and
/// synchronous: feed it mono Float samples, get back finished utterances. Unit-tested with synthetic audio.
final class VoiceDetector {
    struct Config: Equatable {
        var sampleRate: Double
        var blockMs = 20
        var calibrationSeconds = 2.0
        /// 13 dB over the room and 350 ms of it before a turn starts: a dog at the water bowl is not a turn.
        var thresholdAboveFloorDB = 13.0
        var onsetMs = 350
        /// 1.2 s of quiet ends a turn: a breath mid-answer is not the end (Oct 27 rehearsal: he felt cut off at 700 ms).
        var hangoverMs = 1200
        var preRollMs = 300
        var maxUtteranceSeconds = 25.0
        /// A floor this quiet means the mic is dead or muted; the threshold still needs a sane minimum.
        var minimumThresholdDB = -45.0
    }

    struct Utterance: Equatable {
        var samples: [Float]
        var sampleRate: Double
        var peakDB: Double
        var seconds: Double { Double(samples.count) / sampleRate }
    }

    let config: Config
    private(set) var noiseFloorDB: Double?
    private(set) var isSpeaking = false
    private(set) var levelDB: Double = -120

    private var calibrationLevels: [Double] = []
    private var pending: [Float] = []           // samples not yet forming a whole block
    private var preRoll: [Float] = []           // the last preRollMs of audio while quiet
    private var current: [Float] = []           // the utterance being captured
    private var loudBlocks = 0
    private var quietBlocks = 0
    private var currentPeakDB = -120.0

    private var blockSize: Int { Int(config.sampleRate * Double(config.blockMs) / 1000) }
    private var calibrationBlocks: Int { Int(config.calibrationSeconds * 1000) / config.blockMs }
    private var onsetBlocks: Int { config.onsetMs / config.blockMs }
    private var hangoverBlocks: Int { config.hangoverMs / config.blockMs }
    private var preRollSamples: Int { Int(config.sampleRate * Double(config.preRollMs) / 1000) }
    private var maxSamples: Int { Int(config.sampleRate * config.maxUtteranceSeconds) }

    init(config: Config) {
        self.config = config
    }

    var thresholdDB: Double? {
        noiseFloorDB.map { max($0 + config.thresholdAboveFloorDB, config.minimumThresholdDB) }
    }

    /// Feed audio; returns every utterance completed by this call.
    func process(_ samples: [Float]) -> [Utterance] {
        pending.append(contentsOf: samples)
        var finished: [Utterance] = []
        while pending.count >= blockSize {
            let block = Array(pending[0..<blockSize])
            pending.removeFirst(blockSize)
            if let utterance = processBlock(block) { finished.append(utterance) }
        }
        return finished
    }

    /// Call when listening stops, to flush an utterance still in progress.
    func flush() -> Utterance? {
        guard isSpeaking, !current.isEmpty else { reset(); return nil }
        let u = Utterance(samples: current, sampleRate: config.sampleRate, peakDB: currentPeakDB)
        reset()
        return u
    }

    /// Forget the noise floor, e.g. after the input route changes.
    func recalibrate() {
        noiseFloorDB = nil
        calibrationLevels = []
        reset()
    }

    private func reset() {
        isSpeaking = false
        current = []
        loudBlocks = 0
        quietBlocks = 0
        currentPeakDB = -120
    }

    private func processBlock(_ block: [Float]) -> Utterance? {
        let level = Self.rmsDB(block)
        levelDB = level

        guard let threshold = thresholdDB else {
            calibrationLevels.append(level)
            if calibrationLevels.count >= calibrationBlocks {
                // The median ignores a cough during calibration.
                noiseFloorDB = calibrationLevels.sorted()[calibrationLevels.count / 2]
            }
            keepPreRoll(block)
            return nil
        }

        if isSpeaking {
            current.append(contentsOf: block)
            currentPeakDB = max(currentPeakDB, level)
            if level >= threshold {
                quietBlocks = 0
            } else {
                quietBlocks += 1
            }
            if quietBlocks >= hangoverBlocks || current.count >= maxSamples {
                let u = Utterance(samples: current, sampleRate: config.sampleRate, peakDB: currentPeakDB)
                reset()
                return u
            }
            return nil
        }

        if level >= threshold {
            loudBlocks += 1
            current.append(contentsOf: block)
            currentPeakDB = max(currentPeakDB, level)
            if loudBlocks >= onsetBlocks {
                isSpeaking = true
                current = preRoll + current
                quietBlocks = 0
            }
        } else {
            loudBlocks = 0
            current = []
            currentPeakDB = -120
            keepPreRoll(block)
        }
        return nil
    }

    private func keepPreRoll(_ block: [Float]) {
        preRoll.append(contentsOf: block)
        if preRoll.count > preRollSamples {
            preRoll.removeFirst(preRoll.count - preRollSamples)
        }
    }

    static func rmsDB(_ samples: [Float]) -> Double {
        guard !samples.isEmpty else { return -120 }
        var sum: Float = 0
        for v in samples { sum += v * v }
        let rms = (sum / Float(samples.count)).squareRoot()
        return Double(20 * log10(max(rms, 1e-7)))
    }
}
