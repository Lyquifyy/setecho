import AVFoundation
import Foundation

/// The two videos for the coach (HANDOFF.md §7, Two videos for your coach): each flagged set's MOV
/// cropped from 0.5 s before the first rep to 0.5 s after the last, using SAM's rep times, else the
/// set's own start and end; H.264 720p, 20 MB or less. The athlete picks; nothing judges or ranks.
enum VideoCropper {
    static let paddingSeconds = 0.5
    static let maxBytes = 20 * 1024 * 1024
    /// The clip's pre-roll and post-roll, as `SetDetector` exports them.
    static let preRollSeconds = 3.0
    static let postRollSeconds = 1.0

    /// The crop window inside the clip, in seconds. `clipDuration` caps the end. With no rep times,
    /// the whole set (the clip's pre-roll excluded) is kept.
    static func window(repTimes: [Double], clipDuration: Double, preRoll: Double = preRollSeconds) -> (start: Double, end: Double) {
        if let first = repTimes.first, let last = repTimes.last {
            return (max(0, first - paddingSeconds), min(clipDuration, last + paddingSeconds))
        }
        return (max(0, preRoll - paddingSeconds), max(0, clipDuration - max(0, postRollSeconds - paddingSeconds)))
    }

    /// "Incline DB press · top set"
    static func caption(exerciseName: String, set: LoggedSet) -> String {
        let role = set.role?.label.lowercased() ?? "set \(set.setIndex + 1)"
        return "\(exerciseName) · \(role)"
    }

    /// The flagged sets of the period, two at most, from two different movements, newest first.
    static func picks(from sessions: [Session], names: (String) -> String, limit: Int = 2) -> [VideoPick] {
        var picks: [VideoPick] = []
        var movements: Set<String> = []
        let sets = sessions.sorted { $0.startedAt > $1.startedAt }.flatMap { $0.sets.filter { $0.flaggedForCoach && $0.clipFile != nil } }
        for set in sets where !movements.contains(set.exerciseId) {
            picks.append(pick(for: set, exerciseName: names(set.exerciseId)))
            movements.insert(set.exerciseId)
            if picks.count == limit { break }
        }
        return picks
    }

    static func pick(for set: LoggedSet, exerciseName: String, clipDuration: Double? = nil) -> VideoPick {
        let duration = clipDuration ?? max(1, set.endedAt.timeIntervalSince(set.startedAt) + preRollSeconds + postRollSeconds)
        let w = window(repTimes: set.repCount.repTimes, clipDuration: duration)
        return VideoPick(setId: set.id, caption: caption(exerciseName: exerciseName, set: set), cropStart: w.start, cropEnd: w.end)
    }

    /// Export the crop as a 720p H.264 MP4 next to the clip. Returns the file name.
    static func export(clip url: URL, pick: VideoPick, into directory: URL, progress: (@Sendable @MainActor (Double) -> Void)? = nil) async throws -> String {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        let start = min(pick.cropStart, max(0, duration - 0.5))
        let end = min(max(pick.cropEnd, start + 0.5), duration)
        let name = "video-\(pick.setId.uuidString.prefix(8)).mp4"
        let out = directory.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: out)
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPreset1280x720) else {
            throw NSError(domain: "Setecho", code: 2, userInfo: [NSLocalizedDescriptionKey: "no export session"])
        }
        session.timeRange = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 600), end: CMTime(seconds: end, preferredTimescale: 600))
        session.shouldOptimizeForNetworkUse = true
        session.fileLengthLimit = Int64(maxBytes)
        // The export's own progress, a few times a second, for the bar on Review and send.
        nonisolated(unsafe) let watched = session  // read for its progress only, while export() runs it
        let watcher = Task { @Sendable in
            for await state in watched.states(updateInterval: 0.2) {
                if case .exporting(let p) = state { await progress?(p.fractionCompleted) }
            }
        }
        defer { watcher.cancel() }
        try await session.export(to: out, as: .mp4)
        await progress?(1)
        return name
    }
}
