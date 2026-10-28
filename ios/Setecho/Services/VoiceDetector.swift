import Foundation

/// Utterance detection on the mic signal (HANDOFF.md §7 Audio): RMS in dBFS against a noise floor
/// learned over the first 2 s, an onset, a hangover, utterances capped. Pure and synchronous: feed
/// it mono Float samples, get back finished utterances. Unit-tested with synthetic audio.
///
/// Sessions add a lower trigger (HANDOFF.md §7, Hearing him in a gym): 6 dB over the floor for
/// 150 ms opens the realtime stream (`Event.streamOpened`) before the utterance threshold is
/// reached, so Voice Transcribe hears a quiet "go" too; a stream episode that never reaches the
/// threshold ends as a `NearMiss`, logged with its level and length, and its words (if the stream
/// has any) are still used. A stream with no words costs nothing downstream.
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
        /// The lower trigger that opens the realtime stream; nil: none (the check-in).
        var streamAboveFloorDB: Double?
        var streamOnsetMs = 150
        /// Speech shorter than this (above the threshold) is a clank, not an utterance.
        var minimumSpeechMs = 0

        /// Sessions (HANDOFF.md §7, Hearing him in a gym, Oct 28 gym test): a head-worn mic, so
        /// 8 dB over the floor; 150 ms onset and 0.15 s of speech so a one-word "go" counts; 0.8 s
        /// of quiet ends a command; 10 s of sound is a noise, and the floor rises to meet it. The
        /// stream opens at 6 dB for 150 ms.
        static func session(sampleRate: Double) -> Config {
            Config(sampleRate: sampleRate, thresholdAboveFloorDB: 8, onsetMs: 150, hangoverMs: 800, maxUtteranceSeconds: 10,
                   streamAboveFloorDB: 6, streamOnsetMs: 150, minimumSpeechMs: 150)
        }
    }

    struct Utterance: Equatable {
        var samples: [Float]
        var sampleRate: Double
        var peakDB: Double
        /// It ran to the maximum length: in a session, a noise to discard (the floor has risen to it).
        var hitMax = false
        /// Seconds above the threshold, from the onset to the last loud block: under the minimum it's a clank.
        var speechSeconds: Double = 0
        /// The loudest block over the floor when it was heard, for the debug record.
        var peakAboveFloorDB: Double = 0
        var seconds: Double { Double(samples.count) / sampleRate }
    }

    /// A sound that crossed the stream trigger but never the utterance threshold: "never detected"
    /// told apart from "misheard" in the debug JSON (HANDOFF.md §7, Log the misses).
    struct NearMiss: Equatable {
        var seconds: Double
        var peakAboveFloorDB: Double
    }

    enum Event: Equatable {
        /// The stream trigger fired: open the realtime stream now.
        case streamOpened
        /// The stream episode ended without an utterance.
        case nearMiss(NearMiss)
    }

    let config: Config
    private(set) var noiseFloorDB: Double?
    private(set) var isSpeaking = false
    private(set) var levelDB: Double = -120
    /// The stream trigger fired and the episode hasn't ended.
    private(set) var streamOpen = false
    /// Added to the threshold while Setecho itself is talking, so only he can interrupt it.
    var boostDB: Double = 0

    private var calibrationLevels: [Double] = []
    private var pending: [Float] = []           // samples not yet forming a whole block
    private var preRoll: [Float] = []           // the last preRollMs of audio while quiet
    private var current: [Float] = []           // the utterance being captured
    private var currentLevels: [Double] = []
    private var loudBlocks = 0
    private var quietBlocks = 0
    private var speechBlocks = 0
    private var trailingQuiet = 0
    private var currentPeakDB = -120.0
    private var softBlocks = 0
    private var softQuietBlocks = 0
    private var softEpisodeBlocks = 0
    private var softPeakDB = -120.0
    private var events: [Event] = []

    private var blockSize: Int { Int(config.sampleRate * Double(config.blockMs) / 1000) }
    private var calibrationBlocks: Int { Int(config.calibrationSeconds * 1000) / config.blockMs }
    private var onsetBlocks: Int { config.onsetMs / config.blockMs }
    private var streamOnsetBlocks: Int { config.streamOnsetMs / config.blockMs }
    private var hangoverBlocks: Int { config.hangoverMs / config.blockMs }
    private var preRollSamples: Int { Int(config.sampleRate * Double(config.preRollMs) / 1000) }
    private var maxSamples: Int { Int(config.sampleRate * config.maxUtteranceSeconds) }
    private var blockSeconds: Double { Double(config.blockMs) / 1000 }

    init(config: Config) {
        self.config = config
    }

    var thresholdDB: Double? {
        noiseFloorDB.map { max($0 + config.thresholdAboveFloorDB, config.minimumThresholdDB) + boostDB }
    }

    /// The stream trigger's level, when this config has one.
    var streamThresholdDB: Double? {
        guard let above = config.streamAboveFloorDB, let floor = noiseFloorDB else { return nil }
        return max(floor + above, config.minimumThresholdDB - (config.thresholdAboveFloorDB - above)) + boostDB
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

    /// The stream openings and near misses since the last call.
    func drainEvents() -> [Event] {
        defer { events.removeAll() }
        return events
    }

    /// Call when listening stops, to flush an utterance still in progress.
    func flush() -> Utterance? {
        guard isSpeaking, !current.isEmpty else { reset(); return nil }
        let u = makeUtterance(hitMax: false)
        reset()
        return u
    }

    /// Voice Transcribe marked the words final while the room has been quiet: end the utterance
    /// now instead of waiting out the hangover. Nil when nothing is being heard or it's still loud.
    func endIfQuiet(atLeastMs ms: Int = 250) -> Utterance? {
        guard isSpeaking, quietBlocks * config.blockMs >= ms else { return nil }
        let u = makeUtterance(hitMax: false)
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
        currentLevels = []
        loudBlocks = 0
        quietBlocks = 0
        speechBlocks = 0
        trailingQuiet = 0
        currentPeakDB = -120
        streamOpen = false
        softBlocks = 0
        softQuietBlocks = 0
        softEpisodeBlocks = 0
        softPeakDB = -120
    }

    private func makeUtterance(hitMax: Bool) -> Utterance {
        Utterance(samples: current, sampleRate: config.sampleRate, peakDB: currentPeakDB, hitMax: hitMax,
                  speechSeconds: Double(max(0, speechBlocks - trailingQuiet)) * blockSeconds,
                  peakAboveFloorDB: currentPeakDB - (noiseFloorDB ?? currentPeakDB))
    }

    private func processBlock(_ block: [Float]) -> Utterance? {
        let level = Self.rmsDB(block)
        levelDB = level

        guard let threshold = thresholdDB else {
            calibrationLevels.append(level)
            if calibrationLevels.count >= calibrationBlocks {
                // The quietest fifth: an answer started inside the first two seconds can't raise the floor
                // (with the median, it did, and his next answer went unheard).
                noiseFloorDB = calibrationLevels.sorted()[calibrationLevels.count / 5]
            }
            keepPreRoll(block)
            return nil
        }

        if isSpeaking {
            current.append(contentsOf: block)
            currentLevels.append(level)
            currentPeakDB = max(currentPeakDB, level)
            speechBlocks += 1
            if level >= threshold {
                quietBlocks = 0
                trailingQuiet = 0
            } else {
                quietBlocks += 1
                trailingQuiet += 1
            }
            let hitMax = current.count >= maxSamples
            if quietBlocks >= hangoverBlocks || hitMax {
                let u = makeUtterance(hitMax: hitMax)
                if hitMax { raiseFloor() }
                reset()
                return u
            }
            return nil
        }

        trackStream(level)

        if level >= threshold {
            loudBlocks += 1
            current.append(contentsOf: block)
            currentLevels.append(level)
            currentPeakDB = max(currentPeakDB, level)
            if loudBlocks >= onsetBlocks {
                isSpeaking = true
                speechBlocks = loudBlocks
                current = preRoll + current
                quietBlocks = 0
                if !streamOpen, config.streamAboveFloorDB != nil { events.append(.streamOpened) }
                // The stream episode becomes the utterance: no near miss.
                streamOpen = true
                softQuietBlocks = 0
            }
        } else {
            loudBlocks = 0
            current = []
            currentLevels = []
            currentPeakDB = -120
            keepPreRoll(block)
            // Follow the room while it's quiet: about two thirds of the way to a new level in a second.
            // Never on a sound between the two triggers: that may be him, softly.
            if let floor = noiseFloorDB, level < (streamThresholdDB ?? threshold) {
                noiseFloorDB = floor + (level - floor) * 0.02
            }
        }
        return nil
    }

    /// The lower trigger: opens the stream after its onset, and an episode that ends without
    /// reaching the utterance threshold is a near miss.
    private func trackStream(_ level: Double) {
        guard let soft = streamThresholdDB else { return }
        if level >= soft {
            softBlocks += 1
            softQuietBlocks = 0
            softPeakDB = max(softPeakDB, level)
            if streamOpen { softEpisodeBlocks += 1 }
            if !streamOpen, softBlocks >= streamOnsetBlocks {
                streamOpen = true
                softEpisodeBlocks = softBlocks
                events.append(.streamOpened)
            }
            return
        }
        softBlocks = 0
        guard streamOpen else {
            softPeakDB = -120
            return
        }
        softQuietBlocks += 1
        softEpisodeBlocks += 1
        if softQuietBlocks >= hangoverBlocks {
            let seconds = Double(softEpisodeBlocks - softQuietBlocks) * blockSeconds
            events.append(.nearMiss(NearMiss(seconds: seconds, peakAboveFloorDB: softPeakDB - (noiseFloorDB ?? softPeakDB))))
            streamOpen = false
            softEpisodeBlocks = 0
            softQuietBlocks = 0
            softPeakDB = -120
        }
    }

    /// A maximum-length "utterance" was the room getting louder (music turned up, a machine running):
    /// the floor rises to just under its median level, never down.
    private func raiseFloor() {
        guard let floor = noiseFloorDB, !currentLevels.isEmpty else { return }
        let median = currentLevels.sorted()[currentLevels.count / 2]
        noiseFloorDB = max(floor, median - 3)
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
