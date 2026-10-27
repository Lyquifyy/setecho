import AVFoundation
import Foundation
import Observation
import Vision

/// The camera half of set detection (HANDOFF.md §7): the back wide camera at 1080p, a body-pose
/// request on every 4th frame, the wrist signal fed with the frame's own timestamp, and a movie
/// file output that records only while a set is in progress. Events arrive on the main actor.
@MainActor
@Observable
final class SetDetector: NSObject {
    private(set) var isRunning = false
    private(set) var isRecording = false
    private(set) var lastWristY: Double?
    private(set) var framesSeen = 0
    private(set) var lastError: String?

    var onSetStart: ((Double) -> Void)?
    /// (clip file name or nil, stillSince seconds)
    var onSetEnd: ((String?, Double) -> Void)?

    let captureSession = AVCaptureSession()
    private let processor = FrameProcessor()
    private let movieOutput = AVCaptureMovieFileOutput()
    private let queue = DispatchQueue(label: "com.getsetecho.setdetector")
    private var signal = WristSignal()
    private let mediaDirectory: URL
    private let sessionId: UUID
    private var clipIndex = 0
    private var recordingDelegate: RecordingDelegate?
    private var pendingStillSince: Double?

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

        processor.onWrist = { [weak self] y, t in
            Task { @MainActor in self?.handleWrist(y: y, at: t) }
        }
        let session = captureSession
        queue.async { session.startRunning() }
        isRunning = true
    }

    func stop() {
        guard isRunning else { return }
        processor.onWrist = nil
        if movieOutput.isRecording { movieOutput.stopRecording() }
        let session = captureSession
        queue.async { session.stopRunning() }
        isRunning = false
        exportDebugSeries()
    }

    private func handleWrist(y: Double, at t: Double) {
        framesSeen += 1
        lastWristY = y
        switch signal.add(y: y, at: t) {
        case .start(let at):
            startClip()
            onSetStart?(at)
        case .end(let at, let stillSince):
            _ = at
            pendingStillSince = stillSince
            stopClip()
        case nil:
            break
        }
        if framesSeen % 300 == 0 { signal.trim(olderThan: 600, now: t) }
    }

    // MARK: Clips

    private func startClip() {
        guard !movieOutput.isRecording else { return }
        clipIndex += 1
        let name = "set-\(sessionId.uuidString.prefix(8))-\(clipIndex).mov"
        let url = mediaDirectory.appendingPathComponent(name)
        let delegate = RecordingDelegate { [weak self] fileName in
            Task { @MainActor in self?.clipFinished(fileName) }
        }
        recordingDelegate = delegate
        movieOutput.startRecording(to: url, recordingDelegate: delegate)
        isRecording = true
    }

    private func stopClip() {
        guard movieOutput.isRecording else {
            if let still = pendingStillSince { onSetEnd?(nil, still) }
            pendingStillSince = nil
            return
        }
        movieOutput.stopRecording()
    }

    private func clipFinished(_ fileName: String?) {
        isRecording = false
        let still = pendingStillSince ?? 0
        pendingStillSince = nil
        onSetEnd?(fileName, still)
    }

    /// The wrist series for tuning thresholds offline (HANDOFF.md §7).
    private func exportDebugSeries() {
        let url = mediaDirectory.appendingPathComponent("wrist-\(sessionId.uuidString.prefix(8)).json")
        if let data = try? JSONSerialization.data(withJSONObject: ["columns": ["t", "raw", "smoothed"], "rows": signal.debugRows]) {
            try? data.write(to: url)
        }
    }
}

/// Runs Vision on the capture queue and reports the wrists' mean y with the frame's timestamp.
final class FrameProcessor: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    var onWrist: (@Sendable (Double, Double) -> Void)?
    private var frameCount = 0
    private let request = VNDetectHumanBodyPoseRequest()

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        frameCount += 1
        guard frameCount % 4 == 0, let onWrist, let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let t = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .right)
        guard (try? handler.perform([request])) != nil,
              let body = request.results?.first,
              let points = try? body.recognizedPoints(.all)
        else { return }
        let wrists = [points[.leftWrist], points[.rightWrist]].compactMap { $0 }.filter { $0.confidence > 0.3 }
        guard !wrists.isEmpty else { return }
        let y = wrists.map { Double($0.location.y) }.reduce(0, +) / Double(wrists.count)
        onWrist(y, t)
    }
}

final class RecordingDelegate: NSObject, AVCaptureFileOutputRecordingDelegate, @unchecked Sendable {
    private let completion: @Sendable (String?) -> Void

    init(completion: @escaping @Sendable (String?) -> Void) {
        self.completion = completion
    }

    func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo outputFileURL: URL, from connections: [AVCaptureConnection], error: Error?) {
        completion(error == nil ? outputFileURL.lastPathComponent : nil)
    }
}
