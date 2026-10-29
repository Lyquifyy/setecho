import AVFoundation
import Foundation
import Observation
import UIKit

/// The photo session's camera: back camera, portrait, a video feed for the live person checks and
/// a photo output for the stills. Masks arrive on the main actor.
@MainActor
@Observable
final class PhotoCapture: NSObject {
    private(set) var isRunning = false
    private(set) var framing: Framing = .noPerson
    private(set) var stillness = StillnessTracker()
    private(set) var lastMask: PersonMask?
    private(set) var lastError: String?

    let captureSession = AVCaptureSession()
    private let processor = PersonFrameProcessor()
    private let photoOutput = AVCapturePhotoOutput()
    private let queue = DispatchQueue(label: "com.getsetecho.photocapture")
    private var photoDelegate: PhotoDelegate?

    static func requestCamera() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .video)
    }

    /// The inputs and outputs go in once. A retake starts the same session again (Oct 29: adding the
    /// camera a second time failed, so a retake shot from a stopped camera and kept the old photo).
    private var isConfigured = false

    func start() {
        guard !isRunning else { return }
        if !isConfigured {
            guard configure() else { return }
        }
        processor.onMask = { [weak self] mask, t in
            Task { @MainActor in self?.handle(mask, at: t) }
        }
        framing = .noPerson
        stillness.reset()
        let session = captureSession
        queue.async { session.startRunning() }
        isRunning = true
    }

    private func configure() -> Bool {
        captureSession.beginConfiguration()
        // No sound in a photo: the camera leaves the app's audio session, and his music, alone.
        captureSession.automaticallyConfiguresApplicationAudioSession = false
        captureSession.sessionPreset = .photo
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
              let input = try? AVCaptureDeviceInput(device: device), captureSession.canAddInput(input)
        else {
            lastError = "No back camera"
            captureSession.commitConfiguration()
            return false
        }
        captureSession.addInput(input)
        let video = AVCaptureVideoDataOutput()
        video.alwaysDiscardsLateVideoFrames = true
        video.setSampleBufferDelegate(processor, queue: queue)
        if captureSession.canAddOutput(video) { captureSession.addOutput(video) }
        if captureSession.canAddOutput(photoOutput) { captureSession.addOutput(photoOutput) }
        for connection in [video.connection(with: .video), photoOutput.connection(with: .video)].compactMap({ $0 })
        where connection.isVideoRotationAngleSupported(90) {
            connection.videoRotationAngle = 90 // portrait, so masks and stills share one frame
        }
        captureSession.commitConfiguration()
        isConfigured = true
        return true
    }

    func stop() {
        guard isRunning else { return }
        processor.onMask = nil
        framing = .noPerson
        stillness.reset()
        let session = captureSession
        queue.async { session.stopRunning() }
        isRunning = false
    }

    private func handle(_ mask: PersonMask?, at t: TimeInterval) {
        lastMask = mask
        framing = Framing.judge(mask)
        stillness.update(framing == .good ? mask : nil, at: t)
    }

    /// Start the hold again; `seconds` is how long he has to stay still for the photo.
    func resetStillness(seconds: Double? = nil) {
        stillness.reset()
        if let seconds { stillness.requiredSeconds = seconds }
    }

    /// One JPEG still.
    func capture() async throws -> Data {
        let settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.jpeg])
        return try await withCheckedThrowingContinuation { continuation in
            let delegate = PhotoDelegate { result in
                Task { @MainActor in
                    continuation.resume(with: result)
                }
            }
            photoDelegate = delegate
            photoOutput.capturePhoto(with: settings, delegate: delegate)
        }
    }
}

final class PhotoDelegate: NSObject, AVCapturePhotoCaptureDelegate, @unchecked Sendable {
    private let completion: @Sendable (Result<Data, Error>) -> Void

    init(completion: @escaping @Sendable (Result<Data, Error>) -> Void) {
        self.completion = completion
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        if let error {
            completion(.failure(error))
        } else if let data = photo.fileDataRepresentation() {
            completion(.success(data))
        } else {
            completion(.failure(APIError(status: 0, message: "No photo data")))
        }
    }
}
