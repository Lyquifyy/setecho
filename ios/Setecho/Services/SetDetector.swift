import AVFoundation
import Foundation
import Observation
import Vision

/// The camera half of set detection (HANDOFF.md §7): the back wide camera at 1080p, a body-pose
/// request on every 4th frame, the wrist signal fed with the frame's own timestamp, every joint
/// kept for the instant rep count, and continuous recording split at set ends so each set's clip
/// has pre-roll. Events arrive on the main actor; times are capture-clock seconds.
@MainActor
@Observable
final class SetDetector: NSObject {
    /// One set's exported clips: the full-quality MOV and the small silent MP4 for /sets/count.
    struct Clips: Equatable {
        var setStart: Double
        var clipFile: String?
        var countFile: String?
    }

    private(set) var isRunning = false
    private(set) var isRecording = false
    /// Body pose has found at least 6 joints in at least half the frames of the last 10 s.
    private(set) var isOnDuty = false
    private(set) var lastWristY: Double?
    private(set) var framesSeen = 0
    private(set) var lastError: String?

    /// The set's real start (capture-clock seconds).
    var onSetStart: ((Double) -> Void)?
    /// The set's real end, when the bar stopped moving.
    var onSetEnd: ((Double) -> Void)?
    /// Both exports for a set finished (either file may be nil if its export failed).
    var onClipsReady: ((Clips) -> Void)?

    let captureSession = AVCaptureSession()
    private let processor = FrameProcessor()
    private let movieOutput = AVCaptureMovieFileOutput()
    private let queue = DispatchQueue(label: "com.getsetecho.setdetector")
    private var signal = WristSignal()
    private var joints = JointSeries()
    private let mediaDirectory: URL
    private let sessionId: UUID
    private var clipIndex = 0
    private var segmentIndex = 0
    private var recordingDelegate: RecordingDelegate?
    private var lastFrameT: Double?
    private var currentSetStart: Double?
    /// When the file now being written started, in capture-clock seconds.
    private var segmentStartT: Double?
    /// The set whose clip lives in the segment that is being finalized.
    private var pendingSets: [URL: (start: Double, end: Double, segmentStart: Double)] = [:]
    private var stopping = false

    static let preRollSeconds = 3.0
    static let postRollSeconds = 1.0

    init(mediaDirectory: URL, sessionId: UUID) {
        self.mediaDirectory = mediaDirectory
        self.sessionId = sessionId
        super.init()
    }

    static func requestCamera() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .video)
    }

    func start() {
        guard !isRunning else { return }
        captureSession.beginConfiguration()
        captureSession.sessionPreset = .hd1920x1080
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
              let input = try? AVCaptureDeviceInput(device: device), captureSession.canAddInput(input)
        else {
            lastError = "No back camera"
            captureSession.commitConfiguration()
            return
        }
        captureSession.addInput(input)
        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(processor, queue: queue)
        if captureSession.canAddOutput(output) { captureSession.addOutput(output) }
        if captureSession.canAddOutput(movieOutput) { captureSession.addOutput(movieOutput) }
        captureSession.commitConfiguration()

        processor.onPose = { [weak self] sample in
            Task { @MainActor in self?.handle(sample) }
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

    /// The set was ended by voice: close its clip now instead of waiting for stillness.
    func endSetByVoice() {
        guard signal.isActive, let start = currentSetStart, let t = lastFrameT else { return }
        signal.reset()
        endSet(realEnd: t, from: start)
    }

    /// The instant count over the set that just ended (HANDOFF.md §7, Rep counting).
    func phoneCount(from start: Double, to end: Double) -> RepCounter.Result? {
        joints.phoneCount(from: start, to: end)
    }

    // MARK: Frames

    private func handle(_ sample: JointSeries.Sample) {
        framesSeen += 1
        lastFrameT = sample.t
        joints.add(sample)
        if framesSeen % 150 == 0 {
            joints.trim(olderThan: 300, now: sample.t)
            signal.trim(olderThan: 600, now: sample.t)
        }
        if framesSeen % 15 == 0 { isOnDuty = joints.isOnDuty(now: sample.t) }
        if !movieOutput.isRecording, !stopping { startSegment(at: sample.t) }

        let wrists = [sample.joints["left_wrist"], sample.joints["right_wrist"]].compactMap { $0 }
        guard !wrists.isEmpty else { return }
        let y = wrists.reduce(0, +) / Double(wrists.count)
        lastWristY = y
        switch signal.add(y: y, at: sample.t) {
        case .start(_, let realStart):
            currentSetStart = realStart
            onSetStart?(realStart)
        case .end(_, let stillSince):
            if let start = currentSetStart { endSet(realEnd: stillSince, from: start) }
        case nil:
            break
        }
    }

    private func endSet(realEnd: Double, from start: Double) {
        currentSetStart = nil
        onSetEnd?(realEnd)
        rotateSegment(for: (start, realEnd))
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
        recordingDelegate = delegate
        segmentStartT = t
        movieOutput.startRecording(to: segmentURL(), recordingDelegate: delegate)
        isRecording = true
    }

    /// Close the current file on this set's end and open the next one right away.
    private func rotateSegment(for set: (start: Double, end: Double)) {
        guard movieOutput.isRecording, let url = movieOutput.outputFileURL, let segmentStart = segmentStartT else {
            onClipsReady?(Clips(setStart: set.start, clipFile: nil, countFile: nil))
            return
        }
        pendingSets[url] = (set.start, set.end, segmentStart)
        if stopping {
            movieOutput.stopRecording()
        } else if let t = lastFrameT {
            startSegment(at: t) // AVCaptureMovieFileOutput finishes the previous file and keeps writing
        }
    }

    private func segmentFinished(_ url: URL, ok: Bool) {
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
        Task { [weak self] in
            guard let self else { return }
            let clips = await ClipExporter.export(segment: url, window: window, into: self.mediaDirectory,
                                                  name: "set-\(self.sessionId.uuidString.prefix(8))-\(index)")
            try? FileManager.default.removeItem(at: url)
            if let error = clips.error { self.lastError = error }
            self.onClipsReady?(Clips(setStart: set.start, clipFile: clips.clipFile, countFile: clips.countFile))
        }
    }

    /// The wrist series for tuning thresholds offline (HANDOFF.md §7).
    private func exportDebugSeries() {
        let url = mediaDirectory.appendingPathComponent("wrist-\(sessionId.uuidString.prefix(8)).json")
        if let data = try? JSONSerialization.data(withJSONObject: ["columns": ["t", "raw", "smoothed"], "rows": signal.debugRows]) {
            try? data.write(to: url)
        }
    }
}

/// Trims one set out of a recorded segment: a full-quality MOV for History, and a 720p, 15 fps,
/// silent MP4 for /sets/count (rep speed needs the extra frames). Both exports run off the main actor.
enum ClipExporter {
    struct Exported: Sendable {
        var clipFile: String?
        var countFile: String?
        var error: String?
    }

    static func export(segment: URL, window: (start: Double, end: Double), into directory: URL, name: String) async -> Exported {
        let asset = AVURLAsset(url: segment)
        var out = Exported()
        guard let duration = try? await asset.load(.duration).seconds, duration > 0 else {
            out.error = "Clip: empty recording"
            return out
        }
        let start = min(window.start, duration)
        let end = min(max(window.end, start + 0.5), duration)
        let range = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 600),
                                end: CMTime(seconds: end, preferredTimescale: 600))

        let clipURL = directory.appendingPathComponent("\(name).mov")
        do {
            try await run(asset: asset, preset: AVAssetExportPresetPassthrough, range: range, composition: nil, to: clipURL, type: .mov)
            out.clipFile = clipURL.lastPathComponent
        } catch {
            out.error = "Clip export: \(error.localizedDescription)"
        }

        let countURL = directory.appendingPathComponent("\(name)-count.mp4")
        do {
            let composition = try await countComposition(for: asset)
            try await run(asset: asset, preset: AVAssetExportPreset1280x720, range: range, composition: composition, to: countURL, type: .mp4)
            out.countFile = countURL.lastPathComponent
        } catch {
            // Without the frame-rate composition the backend still counts; it just gets more frames.
            if (try? await run(asset: asset, preset: AVAssetExportPreset1280x720, range: range, composition: nil, to: countURL, type: .mp4)) != nil {
                out.countFile = countURL.lastPathComponent
            } else {
                out.error = "Count export: \(error.localizedDescription)"
            }
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

/// Runs Vision on the capture queue and reports every joint's normalized y with the frame's timestamp.
final class FrameProcessor: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    var onPose: (@Sendable (JointSeries.Sample) -> Void)?
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
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .right)
        var joints: [String: Double] = [:]
        if (try? handler.perform([request])) != nil,
           let body = request.results?.first,
           let points = try? body.recognizedPoints(.all) {
            for (name, joint) in Self.jointNames {
                if let p = points[joint], p.confidence > 0.3 { joints[name] = Double(p.location.y) }
            }
        }
        onPose(JointSeries.Sample(t: t, joints: joints))
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
