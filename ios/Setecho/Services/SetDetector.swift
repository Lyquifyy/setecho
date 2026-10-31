import AVFoundation
import Foundation
import Observation
import Vision

/// The camera half of set detection (HANDOFF.md §7): the back wide camera at 1080p, a body-pose
/// request on every 4th frame, the wrist signal fed with the frame's own timestamp, every joint
/// kept for the instant rep count, and continuous recording split at set ends so each set's clip
/// has pre-roll. Events arrive on the main actor; times are capture-clock seconds.
///
/// Only his body counts (Sets start on his word): `BodyTracker` follows the body picked when he
/// arms, and a start is reported only while `startsAllowed` (he armed, or the camera may start
/// sets). The count clip carries his boxes over the set, so SAM sees only his station.
@MainActor
@Observable
final class SetDetector: NSObject {
    /// One set's exported clips: the full-quality MOV and the small silent MP4 for /sets/count.
    struct Clips: Equatable {
        var setStart: Double
        var clipFile: String?
        var countFile: String?
        /// His boxes over the set plus room for the bar, normalized in the upright frame: the
        /// backend crops the count clip to it before SAM. The clip for his coach stays whole.
        var cropBox: CGRect?
        /// Seconds from the set's end until the count clip was written, for the debug record.
        var countReadySeconds: Double?
    }

    private(set) var isRunning = false
    private(set) var isRecording = false
    /// Body pose has found at least 6 joints in at least half the frames of the last 10 s.
    private(set) var isOnDuty = false
    /// The camera sees his hips, knees or ankles, not only his upper body (Oct 31, the deadlifts).
    private(set) var seesLowerBody = true
    /// The back camera as the dual-wide virtual device where the phone has one: zooming out to the
    /// ultra-wide is then a zoom factor, with no input to swap and the recording untouched.
    private var device: AVCaptureDevice?
    /// The dual-wide camera's factor for the 1× wide lens (its switch-over), 1 on any other camera.
    private var wideZoomFactor: CGFloat = 1
    /// The ultra-wide is in use: about twice the view each way.
    private(set) var zoomedOut = false
    /// The back camera has an ultra-wide to zoom out to (never the front camera).
    var canZoomOut: Bool { !front && device?.deviceType == .builtInDualWideCamera }
    /// Since when the camera has seen only his upper body, on the frame clock.
    private var upperOnlySince: Double?
    nonisolated static let zoomOutAfterSeconds = 2.0
    /// The picture is dark, as in a pocket: under 6% brightness, and lit again above 12% (Oct 29: the
    /// screen hid his camera until the body tracker found him, so he couldn't frame himself).
    private(set) var isDark = false
    private(set) var lastWristY: Double?
    private(set) var framesSeen = 0
    private(set) var lastError: String?
    /// The latest frame's capture-clock time: the end of a set ended by voice.
    var lastFrameTime: Double? { lastFrameT }

    /// A start may be reported: he armed the set, or Settings lets the camera start sets. While
    /// false, movement (his or anyone's) starts nothing.
    var startsAllowed = true
    /// Bodies in the latest pose frame, for the HUD and the debug record.
    private(set) var bodiesInFrame = 0
    /// His box in the latest pose frame (normalized, top-left origin, the upright unmirrored frame),
    /// for the screen's lock-on brackets; nil when he isn't in it.
    private(set) var trackedBox: CGRect?

    /// The set's real start (capture-clock seconds).
    var onSetStart: ((Double) -> Void)?
    /// The set's real end, when the bar stopped moving.
    var onSetEnd: ((Double) -> Void)?
    /// Both exports for a set finished (either file may be nil if its export failed).
    var onClipsReady: ((Clips) -> Void)?
    /// The camera zoomed out to the ultra-wide by itself: it saw him from the hips up for 2 s in
    /// Ready and had no room to ask him to step back (Oct 31).
    var onZoomOut: (() -> Void)?

    let captureSession = AVCaptureSession()
    private let processor = FrameProcessor()
    private let movieOutput = AVCaptureMovieFileOutput()
    private let queue = DispatchQueue(label: "com.getsetecho.setdetector")
    private var signal = WristSignal()
    private var joints = JointSeries()
    private var tracker = BodyTracker()
    private var relockPending = false
    /// His box per pose frame, for the count clip's crop.
    private var boxes: [(t: Double, box: CGRect)] = []
    private let mediaDirectory: URL
    private let sessionId: UUID
    private var clipIndex = 0
    private var segmentIndex = 0
    /// One per file until it finishes: the movie output's callback for each file must outlive the next file's start.
    private var recordingDelegates: [URL: RecordingDelegate] = [:]
    private var lastFrameT: Double?
    private var currentSetStart: Double?
    /// When the file now being written started, in capture-clock seconds.
    private var segmentStartT: Double?
    /// The set whose clip lives in the segment that is being finalized.
    private var pendingSets: [URL: (start: Double, end: Double, segmentStart: Double, crop: CGRect?)] = [:]
    private var stopping = false
    /// The tuning record (HANDOFF.md §7): the whole session's wrist series (the live signal keeps
    /// only 10 minutes), set events, the pose around each set, and the capture clock against the wall.
    private var debugWrist: [[Double]] = []
    private var debugEvents: [[String: Any]] = []
    private var debugSetWindows: [[String: Any]] = []
    private var clockAnchor: (t: Double, epoch: Double)?

    /// The signal's channels in the debug record, one column each.
    static let debugChannels: [WristSignal.Channel] = [.wrists, .gap, .shoulders, .head, .hips]
    static let preRollSeconds = 3.0
    static let postRollSeconds = 1.0
    /// The count clip's own window, tighter than the coach's: every second cut is about 1 s less of
    /// SAM (15 frames at ~0.07 s each). The set's start is where the movement began, so 1.5 s still
    /// gives `reps.py` its rest position before the first rep (HANDOFF.md §5, step 4).
    static let countPreRollSeconds = 1.5
    static let countPostRollSeconds = 0.5
    /// A rest-pause set ends after its third round, after this long still, or on "done" (§13).
    static let restPauseRounds = 3
    static let restPauseStillSeconds = 75.0

    /// The set being filmed is a rest-pause set: stillness between rounds does not end it.
    var restPause = false
    private var restPauseRound = 0
    private var restPausePausedAt: Double?

    /// The front camera faces him from the bench; the back camera faces away (the default until
    /// SAM's count is measured front against back).
    let front: Bool

    init(mediaDirectory: URL, sessionId: UUID, front: Bool = false) {
        self.mediaDirectory = mediaDirectory
        self.sessionId = sessionId
        self.front = front
        super.init()
    }

    static func requestCamera() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .video)
    }

    func start() {
        guard !isRunning else { return }
        captureSession.beginConfiguration()
        // The camera never records sound, and AudioService owns the audio session. Left on, the
        // capture session sets the session up itself, interrupting other audio by default (Apple's
        // header): starting a session stopped his music while "Check the mic" kept it (Oct 29).
        captureSession.automaticallyConfiguresApplicationAudioSession = false
        let dualWide = front ? nil : AVCaptureDevice.default(.builtInDualWideCamera, for: .video, position: .back)
        guard let device = dualWide ?? AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: front ? .front : .back),
              let input = try? AVCaptureDeviceInput(device: device), captureSession.canAddInput(input)
        else {
            lastError = "No back camera"
            captureSession.commitConfiguration()
            return
        }
        captureSession.addInput(input)
        self.device = device
        if device.deviceType == .builtInDualWideCamera {
            // Start on the 1× wide lens, as before; the ultra-wide is factor 1.0, a zoom-out away.
            wideZoomFactor = device.virtualDeviceSwitchOverVideoZoomFactors.first.map { CGFloat(truncating: $0) } ?? 2
            if (try? device.lockForConfiguration()) != nil {
                device.videoZoomFactor = wideZoomFactor
                device.unlockForConfiguration()
            }
        }
        zoomedOut = false
        upperOnlySince = nil
        // 1080p for the coach's clip; a front camera that can't gets its best (720p is still plenty for pose and SAM).
        captureSession.sessionPreset = captureSession.canSetSessionPreset(.hd1920x1080) ? .hd1920x1080 : .high
        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(processor, queue: queue)
        if captureSession.canAddOutput(output) { captureSession.addOutput(output) }
        if captureSession.canAddOutput(movieOutput) { captureSession.addOutput(movieOutput) }
        // Never mirrored: the pose boxes, the clip and the backend's crop all see the same frame.
        for connection in output.connections + movieOutput.connections where connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = false
        }
        processor.orientation = front ? .left : .right
        captureSession.commitConfiguration()

        processor.onPose = { [weak self] frame in
            Task { @MainActor in self?.handle(frame) }
        }
        let session = captureSession
        queue.async { session.startRunning() }
        isRunning = true
        stopping = false
    }

    func stop() {
        guard isRunning else { return }
        stopping = true
        processor.onPose = nil
        if signal.isActive, let start = currentSetStart, let t = lastFrameT {
            // The session ended mid-set: keep what was filmed as that set's clip.
            endSet(realEnd: t, from: start)
        } else if movieOutput.isRecording {
            movieOutput.stopRecording()
        }
        signal.reset()
        let session = captureSession
        queue.async { session.stopRunning() }
        isRunning = false
        exportDebugSeries()
    }

    /// Zoom out once the camera has seen only his upper body for 2 s with no set under way, where it
    /// can. Pure, so the rule is tested without a camera.
    nonisolated static func shouldZoomOut(upperOnlySince: Double?, now: Double, canZoomOut: Bool, zoomedOut: Bool, filming: Bool) -> Bool {
        guard canZoomOut, !zoomedOut, !filming, let since = upperOnlySince else { return false }
        return now - since >= zoomOutAfterSeconds
    }

    /// To the ultra-wide (factor 1.0 on the dual-wide camera), ramped so the picture doesn't jump.
    /// Stays out for the rest of the session: the clips keep one framing.
    private func zoomOut(at t: Double) {
        guard let device, canZoomOut, (try? device.lockForConfiguration()) != nil else { return }
        device.ramp(toVideoZoomFactor: 1.0, withRate: 2)
        device.unlockForConfiguration()
        zoomedOut = true
        joints = JointSeries()   // the old frames saw the old picture; judge the framing afresh
        upperOnlySince = nil
        debugEvents.append(["kind": "zoomOut", "t": t, "from": Double(wideZoomFactor)])
        onZoomOut?()
    }

    /// He armed a set: the next pose frame picks him again (largest, nearest the centre) and follows him.
    func lockOnHim() {
        relockPending = true
    }

    /// The set was ended by voice: close its clip now instead of waiting for stillness.
    func endSetByVoice() {
        guard let start = currentSetStart, let t = lastFrameT, signal.isActive || restPausePausedAt != nil else { return }
        let end = restPausePausedAt ?? t
        signal.reset()
        restPauseRound = 0
        endSet(realEnd: end, from: start)
    }

    /// The instant count over the set that just ended (HANDOFF.md §7, Rep counting).
    func phoneCount(from start: Double, to end: Double) -> RepCounter.Result? {
        let result = joints.phoneCount(from: start, to: end)
        recordSetWindow(from: start, to: end, result: result)
        return result
    }

    // MARK: Frames

    private func handle(_ frame: FrameProcessor.PoseFrame) {
        framesSeen += 1
        if let brightness = frame.brightness {
            if isDark, brightness > 0.12 { isDark = false } else if !isDark, brightness < 0.06 { isDark = true }
        }
        bodiesInFrame = frame.bodies.count
        let him: BodyTracker.Body?
        if relockPending, !frame.bodies.isEmpty {
            relockPending = false
            let (body, changed) = tracker.lock(frame.bodies, at: frame.t)
            him = body
            // The wrist history was someone else's: start his afresh (the clip's 3 s pre-roll still covers a late arm).
            if changed, !signal.isActive { signal.clearHistory() }
            debugEvents.append(["kind": "lock", "t": frame.t, "bodies": frame.bodies.count, "changed": changed])
        } else {
            him = tracker.follow(frame.bodies, at: frame.t)
        }
        if let box = him?.box { boxes.append((frame.t, box)) }
        if trackedBox != him?.box { trackedBox = him?.box }
        handle(JointSeries.Sample(t: frame.t, joints: him?.joints ?? [:], wristX: him?.wristX ?? [:]))
    }

    private func handle(_ sample: JointSeries.Sample) {
        lastFrameT = sample.t
        if clockAnchor == nil { clockAnchor = (sample.t, Date.now.timeIntervalSince1970) }
        joints.add(sample)
        if framesSeen % 150 == 0 {
            joints.trim(olderThan: 300, now: sample.t)
            boxes.removeAll { $0.t < sample.t - 300 }
            signal.trim(olderThan: 600, now: sample.t)
        }
        if framesSeen % 15 == 0 {
            isOnDuty = joints.isOnDuty(now: sample.t)
            seesLowerBody = joints.seesLowerBody(now: sample.t)
            upperOnlySince = isOnDuty && !seesLowerBody ? (upperOnlySince ?? sample.t) : nil
            if Self.shouldZoomOut(upperOnlySince: upperOnlySince, now: sample.t, canZoomOut: canZoomOut, zoomedOut: zoomedOut,
                                  filming: currentSetStart != nil || restPausePausedAt != nil) {
                zoomOut(at: sample.t)
            }
        }
        if !movieOutput.isRecording, !stopping { startSegment(at: sample.t) }

        let readings = WristSignal.readings(joints: sample.joints, wristX: sample.wristX)
        // A frame without him still moves the clock on: stillness seen in a few frames ends the set
        // (Oct 30: after his flyes the pose found him in 1 frame of 10, and the set never ended).
        if !readings.isEmpty {
            lastWristY = readings[.wrists]
            // -1: that part of him unseen in this frame.
            debugWrist.append([sample.t] + Self.debugChannels.map { readings[$0] ?? -1 })
        }
        // Between rest-pause rounds: 75 s still ends the set where the last round stopped.
        if let pausedAt = restPausePausedAt, let start = currentSetStart, sample.t - pausedAt >= Self.restPauseStillSeconds {
            restPausePausedAt = nil
            restPauseRound = 0
            endSet(realEnd: pausedAt, from: start)
            return
        }
        switch signal.add(readings, at: sample.t) {
        case .start(_, let realStart):
            if !startsAllowed, currentSetStart == nil, restPausePausedAt == nil {
                // Not armed: someone else, or him re-racking. Nothing starts, and the signal looks again next frame.
                signal.reset()
                break
            }
            if restPausePausedAt != nil, currentSetStart != nil {
                restPausePausedAt = nil // the next round of the same set
            } else {
                currentSetStart = realStart
                restPauseRound = 0
                debugEvents.append(["kind": "start", "t": realStart, "channel": signal.activeChannel?.rawValue ?? ""])
                onSetStart?(realStart)
            }
        case .end(_, let stillSince):
            guard let start = currentSetStart else { break }
            if restPause {
                restPauseRound += 1
                if restPauseRound < Self.restPauseRounds {
                    restPausePausedAt = stillSince // held open through the pause
                    break
                }
                restPauseRound = 0
            }
            endSet(realEnd: stillSince, from: start)
        case nil:
            break
        }
    }

    private func endSet(realEnd: Double, from start: Double) {
        currentSetStart = nil
        restPausePausedAt = nil
        debugEvents.append(["kind": "end", "t": realEnd, "start": start])
        onSetEnd?(realEnd)
        let window = boxes.filter { $0.t >= start - Self.preRollSeconds && $0.t <= realEnd + Self.postRollSeconds }.map(\.box)
        rotateSegment(for: (start, realEnd), crop: BodyTracker.cropBox(window))
    }

    // MARK: Continuous recording, split at set ends

    private func segmentURL() -> URL {
        segmentIndex += 1
        return mediaDirectory.appendingPathComponent("segment-\(sessionId.uuidString.prefix(8))-\(segmentIndex).mov")
    }

    private func startSegment(at t: Double) {
        let delegate = RecordingDelegate { [weak self] url, ok in
            Task { @MainActor in self?.segmentFinished(url, ok: ok) }
        }
        let url = segmentURL()
        recordingDelegates[url] = delegate
        segmentStartT = t
        movieOutput.startRecording(to: url, recordingDelegate: delegate)
        isRecording = true
    }

    /// Close the current file on this set's end; the next pose frame opens the next one. Switching
    /// files with a new `startRecording` is macOS-only (Apple's header): until Oct 30 it was done here,
    /// and no set ever got its clip or its count.
    private func rotateSegment(for set: (start: Double, end: Double), crop: CGRect?) {
        guard movieOutput.isRecording, let url = movieOutput.outputFileURL, let segmentStart = segmentStartT else {
            onClipsReady?(Clips(setStart: set.start, clipFile: nil, countFile: nil))
            return
        }
        pendingSets[url] = (set.start, set.end, segmentStart, crop)
        movieOutput.stopRecording()
    }

    private func segmentFinished(_ url: URL, ok: Bool) {
        recordingDelegates[url] = nil
        if !movieOutput.isRecording { isRecording = false }
        guard let set = pendingSets.removeValue(forKey: url) else {
            try? FileManager.default.removeItem(at: url) // no set in this segment: pre-roll only
            return
        }
        guard ok else {
            try? FileManager.default.removeItem(at: url)
            onClipsReady?(Clips(setStart: set.start, clipFile: nil, countFile: nil))
            return
        }
        clipIndex += 1
        let index = clipIndex
        let window = (start: max(0, set.start - Self.preRollSeconds - set.segmentStart),
                      end: set.end + Self.postRollSeconds - set.segmentStart)
        let countWindow = (start: max(0, set.start - Self.countPreRollSeconds - set.segmentStart),
                           end: set.end + Self.countPostRollSeconds - set.segmentStart)
        let endedAt = lastFrameT.map { Date.now.addingTimeInterval(set.end - $0) } ?? .now
        Task { [weak self] in
            guard let self else { return }
            let clips = await ClipExporter.export(segment: url, window: window, countWindow: countWindow, into: self.mediaDirectory,
                                                  name: "set-\(self.sessionId.uuidString.prefix(8))-\(index)")
            try? FileManager.default.removeItem(at: url)
            if let error = clips.error { self.lastError = error }
            self.onClipsReady?(Clips(setStart: set.start, clipFile: clips.clipFile, countFile: clips.countFile, cropBox: set.crop,
                                     countReadySeconds: clips.countReadyAt.map { $0.timeIntervalSince(endedAt) }))
        }
    }

    /// The pose joints over [start − 3 s, end + 1 s] and the phone's count, for tuning `RepCounter`.
    private func recordSetWindow(from start: Double, to end: Double, result: RepCounter.Result?) {
        let names = JointSeries.joints
        let rows: [[Any]] = joints.samples.filter { $0.t >= start - Self.preRollSeconds && $0.t <= end + Self.postRollSeconds }.map { sample in
            [sample.t] + names.map { sample.joints[$0].map { $0 as Any } ?? NSNull() }
        }
        var window: [String: Any] = ["start": start, "end": end, "columns": ["t"] + names, "rows": rows]
        if let result {
            window["phone"] = ["reps": result.reps.map { $0 as Any } ?? NSNull(), "repTimes": result.repTimes, "confidence": result.confidence,
                               "trackedFrames": result.trackedFrames, "frames": result.frames]
        }
        debugSetWindows.append(window)
    }

    /// The detector's series for tuning thresholds offline (HANDOFF.md §7); History shares it with the session.
    private func exportDebugSeries() {
        let url = mediaDirectory.appendingPathComponent(SessionDebug.detectorFile(sessionId: sessionId))
        var json: [String: Any] = [
            "wrist": ["columns": ["t"] + Self.debugChannels.map(\.rawValue), "rows": debugWrist],
            "events": debugEvents,
            "sets": debugSetWindows,
            "config": ["medianWindow": signal.config.medianWindow, "startRange": signal.config.startRange, "endRange": signal.config.endRange,
                       "startWindowSeconds": signal.config.startWindowSeconds, "endSeconds": signal.config.endSeconds],
        ]
        if let clockAnchor { json["clock"] = ["t": clockAnchor.t, "epoch": clockAnchor.epoch] }
        if let data = try? JSONSerialization.data(withJSONObject: json) {
            try? data.write(to: url)
        }
    }
}

/// Trims one set out of a recorded segment: a 720p, 15 fps, silent MP4 for /sets/count (rep speed
/// needs the extra frames) over the set's tight window, written first because the count waits on it,
/// then a full-quality MOV for History with the full pre-roll. Both exports run off the main actor.
enum ClipExporter {
    struct Exported: Sendable {
        var clipFile: String?
        var countFile: String?
        var error: String?
        /// When the count clip was written.
        var countReadyAt: Date?
    }

    static func export(segment: URL, window: (start: Double, end: Double), countWindow: (start: Double, end: Double)? = nil,
                       into directory: URL, name: String) async -> Exported {
        let asset = AVURLAsset(url: segment)
        var out = Exported()
        guard let duration = try? await asset.load(.duration).seconds, duration > 0 else {
            out.error = "Clip: empty recording"
            return out
        }
        func range(_ w: (start: Double, end: Double)) -> CMTimeRange {
            let start = min(w.start, duration)
            let end = min(max(w.end, start + 0.5), duration)
            return CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 600), end: CMTime(seconds: end, preferredTimescale: 600))
        }

        let countURL = directory.appendingPathComponent("\(name)-count.mp4")
        let countRange = range(countWindow ?? window)
        do {
            let composition = try await countComposition(for: asset)
            try await run(asset: asset, preset: AVAssetExportPreset1280x720, range: countRange, composition: composition, to: countURL, type: .mp4)
            out.countFile = countURL.lastPathComponent
        } catch {
            // Without the frame-rate composition the backend still counts; it just gets more frames.
            if (try? await run(asset: asset, preset: AVAssetExportPreset1280x720, range: countRange, composition: nil, to: countURL, type: .mp4)) != nil {
                out.countFile = countURL.lastPathComponent
            } else {
                out.error = "Count export: \(error.localizedDescription)"
            }
        }
        out.countReadyAt = .now

        let clipURL = directory.appendingPathComponent("\(name).mov")
        do {
            try await run(asset: asset, preset: AVAssetExportPresetPassthrough, range: range(window), composition: nil, to: clipURL, type: .mov)
            out.clipFile = clipURL.lastPathComponent
        } catch {
            out.error = "Clip export: \(error.localizedDescription)"
        }
        return out
    }

    /// The frame rate of the clip that goes to /sets/count (HANDOFF.md §6, SAM on video).
    static let countFPS: Int32 = 15

    /// 15 fps, with the recording's own orientation applied.
    private static func countComposition(for asset: AVURLAsset) async throws -> AVMutableVideoComposition {
        let composition = try await AVMutableVideoComposition.videoComposition(withPropertiesOf: asset)
        composition.frameDuration = CMTime(value: 1, timescale: countFPS)
        return composition
    }

    private static func run(asset: AVURLAsset, preset: String, range: CMTimeRange, composition: AVVideoComposition?,
                            to url: URL, type: AVFileType) async throws {
        guard let session = AVAssetExportSession(asset: asset, presetName: preset) else {
            throw NSError(domain: "Setecho", code: 1, userInfo: [NSLocalizedDescriptionKey: "no export session for \(preset)"])
        }
        session.timeRange = range
        session.videoComposition = composition
        session.shouldOptimizeForNetworkUse = true
        if composition != nil { session.audioMix = nil }
        try? FileManager.default.removeItem(at: url)
        try await session.export(to: url, as: type)
    }
}

/// Runs Vision on the capture queue and reports every body in the frame (each joint's normalized y,
/// and the body's box) with the frame's timestamp. `SetDetector` picks which body is him.
final class FrameProcessor: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    struct PoseFrame: Sendable {
        var t: Double
        var bodies: [BodyTracker.Body]
        /// The frame's mean brightness, 0…1, from a grid of its luma: near 0 in a pocket.
        var brightness: Double?
    }

    var onPose: (@Sendable (PoseFrame) -> Void)?
    /// How the sensor's frames turn upright with the phone standing on the tripod: the back
    /// camera's turn right, the front camera's (unmirrored) turn left.
    var orientation: CGImagePropertyOrientation = .right
    private var frameCount = 0
    private let request = VNDetectHumanBodyPoseRequest()

    private static let jointNames: [(String, VNHumanBodyPoseObservation.JointName)] = [
        ("left_wrist", .leftWrist), ("right_wrist", .rightWrist),
        ("left_elbow", .leftElbow), ("right_elbow", .rightElbow),
        ("left_hip", .leftHip), ("right_hip", .rightHip),
        ("left_knee", .leftKnee), ("right_knee", .rightKnee),
        ("left_ankle", .leftAnkle), ("right_ankle", .rightAnkle),
        ("left_shoulder", .leftShoulder), ("right_shoulder", .rightShoulder),
        ("neck", .neck), ("root", .root), ("nose", .nose),
    ]

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        frameCount += 1
        guard frameCount % 4 == 0, let onPose, let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let t = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: orientation)
        var bodies: [BodyTracker.Body] = []
        if (try? handler.perform([request])) != nil {
            for observation in request.results ?? [] {
                guard let points = try? observation.recognizedPoints(.all) else { continue }
                let seen = points.values.filter { $0.confidence > 0.3 }
                guard seen.count >= 4 else { continue }
                var joints: [String: Double] = [:]
                for (name, joint) in Self.jointNames {
                    if let p = points[joint], p.confidence > 0.3 { joints[name] = Double(p.location.y) }
                }
                var wristX: [String: Double] = [:]
                for (name, joint) in [("left_wrist", VNHumanBodyPoseObservation.JointName.leftWrist), ("right_wrist", .rightWrist)] {
                    if let p = points[joint], p.confidence > 0.3 { wristX[name] = Double(p.location.x) }
                }
                // Vision's points are bottom-up; the box is top-left origin like the rest of UIKit.
                let xs = seen.map { $0.location.x }, ys = seen.map { $0.location.y }
                let box = CGRect(x: xs.min()!, y: 1 - ys.max()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
                bodies.append(BodyTracker.Body(box: box, joints: joints, wristX: wristX))
            }
        }
        onPose(PoseFrame(t: t, bodies: bodies, brightness: Self.brightness(pixelBuffer)))
    }

    /// Mean luma over a 16 × 16 grid of the frame's first plane (the camera's 4:2:0 formats), or the
    /// green of a BGRA frame; nil for any other format.
    static func brightness(_ buffer: CVPixelBuffer) -> Double? {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let format = CVPixelBufferGetPixelFormatType(buffer)
        let planar = CVPixelBufferIsPlanar(buffer)
        let bgra = format == kCVPixelFormatType_32BGRA
        guard planar || bgra,
              let base = planar ? CVPixelBufferGetBaseAddressOfPlane(buffer, 0) : CVPixelBufferGetBaseAddress(buffer)
        else { return nil }
        let width = planar ? CVPixelBufferGetWidthOfPlane(buffer, 0) : CVPixelBufferGetWidth(buffer)
        let height = planar ? CVPixelBufferGetHeightOfPlane(buffer, 0) : CVPixelBufferGetHeight(buffer)
        let stride = planar ? CVPixelBufferGetBytesPerRowOfPlane(buffer, 0) : CVPixelBufferGetBytesPerRow(buffer)
        guard width > 0, height > 0 else { return nil }
        let bytes = base.assumingMemoryBound(to: UInt8.self)
        var sum = 0
        for row in 0..<16 {
            let y = (row * 2 + 1) * height / 32
            for col in 0..<16 {
                let x = (col * 2 + 1) * width / 32
                sum += Int(bytes[y * stride + (bgra ? x * 4 + 1 : x)])
            }
        }
        return Double(sum) / (256 * 255)
    }
}

final class RecordingDelegate: NSObject, AVCaptureFileOutputRecordingDelegate, @unchecked Sendable {
    private let completion: @Sendable (URL, Bool) -> Void

    init(completion: @escaping @Sendable (URL, Bool) -> Void) {
        self.completion = completion
    }

    func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo outputFileURL: URL, from connections: [AVCaptureConnection], error: Error?) {
        // A recording that was cut by the next startRecording reports a benign error with the file intact.
        let ok = error == nil || ((error as NSError?)?.userInfo[AVErrorRecordingSuccessfullyFinishedKey] as? Bool ?? false)
        completion(outputFileURL, ok)
    }
}
