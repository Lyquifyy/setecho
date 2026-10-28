import AVFoundation
import Foundation
import Vision

/// The live checks for the photo session (HANDOFF.md §7), all on the device with no network:
/// Vision person segmentation at about 10 fps, a framing verdict from the mask's bounding box,
/// and stillness as the mask IoU between consecutive checks.
struct PersonMask: Sendable, Equatable {
    /// Normalized (0…1), origin top-left, in the portrait frame.
    var box: CGRect
    /// A coarse occupancy grid of the mask for IoU.
    var grid: [UInt8]
    var gridWidth: Int
    var gridHeight: Int

    static func iou(_ a: PersonMask, _ b: PersonMask) -> Double {
        guard a.grid.count == b.grid.count, !a.grid.isEmpty else { return 0 }
        var inter = 0
        var union = 0
        for i in 0..<a.grid.count {
            let x = a.grid[i] != 0
            let y = b.grid[i] != 0
            if x && y { inter += 1 }
            if x || y { union += 1 }
        }
        return union == 0 ? 0 : Double(inter) / Double(union)
    }
}

/// What to tell the athlete about where they stand.
enum Framing: Equatable {
    case noPerson
    case good
    case stepBack
    case moveLeft
    case moveRight

    /// At least 4% margin on every side, else a cue.
    static func judge(_ mask: PersonMask?, margin: CGFloat = 0.04) -> Framing {
        guard let mask else { return .noPerson }
        let b = mask.box
        if b.minY < margin || b.maxY > 1 - margin { return .stepBack }
        if b.width > 1 - 2 * margin { return .stepBack }
        if b.minX < margin { return .moveLeft }     // at the image's left edge: the athlete's left
        if b.maxX > 1 - margin { return .moveRight }
        return .good
    }

    var spoken: String? {
        switch self {
        case .noPerson: "Step into frame"
        case .good: nil
        case .stepBack: "Step back a little"
        case .moveLeft: "Move left"
        case .moveRight: "Move right"
        }
    }
}

/// Stillness: IoU above 0.93 between consecutive masks for 1 s. Up to two near-misses in a row (a
/// breath, a sway: IoU above 0.85) are forgiven; a real move resets it. Oct 28: at 0.97 with any
/// shaky frame resetting it, an arms-up pose was almost never still.
struct StillnessTracker: Equatable {
    var requiredSeconds = 1.0
    var minimumIoU = 0.93
    var nearMissIoU = 0.85
    var forgivenFrames = 2
    private var last: PersonMask?
    private var stillSince: TimeInterval?
    private var misses = 0
    private(set) var isStill = false
    private(set) var progress: Double = 0

    mutating func update(_ mask: PersonMask?, at t: TimeInterval) {
        defer { last = mask }
        let iou = mask.flatMap { m in last.map { PersonMask.iou($0, m) } } ?? 0
        guard iou >= minimumIoU else {
            if iou >= nearMissIoU, misses < forgivenFrames {
                // A breath: the hold's clock keeps running.
                misses += 1
                if let since = stillSince {
                    progress = min(1, (t - since) / requiredSeconds)
                    isStill = t - since >= requiredSeconds
                }
                return
            }
            misses = 0
            stillSince = nil
            isStill = false
            progress = 0
            return
        }
        misses = 0
        let since = stillSince ?? t
        stillSince = since
        progress = min(1, (t - since) / requiredSeconds)
        isStill = t - since >= requiredSeconds
    }

    mutating func reset() {
        last = nil
        misses = 0
        stillSince = nil
        isStill = false
        progress = 0
    }
}

/// Runs the segmentation request on the capture queue and reports a coarse mask.
final class PersonFrameProcessor: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    var onMask: (@Sendable (PersonMask?, TimeInterval) -> Void)?
    private let request: VNGeneratePersonSegmentationRequest = {
        let r = VNGeneratePersonSegmentationRequest()
        r.qualityLevel = .balanced
        r.outputPixelFormat = kCVPixelFormatType_OneComponent8
        return r
    }()
    private var lastProcessed: TimeInterval = -1
    private let interval: TimeInterval = 0.1
    private let gridWidth = 24
    private let gridHeight = 32

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        let t = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds
        guard t - lastProcessed >= interval, let onMask, let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        lastProcessed = t
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer)
        guard (try? handler.perform([request])) != nil, let result = request.results?.first else {
            onMask(nil, t)
            return
        }
        onMask(Self.coarseMask(result.pixelBuffer, gridWidth: gridWidth, gridHeight: gridHeight), t)
    }

    /// Downsample the mask to a grid and find its bounding box. Nil when fewer than 1% of cells are on.
    static func coarseMask(_ buffer: CVPixelBuffer, gridWidth: Int, gridHeight: Int) -> PersonMask? {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        let bytes = base.assumingMemoryBound(to: UInt8.self)
        var grid = [UInt8](repeating: 0, count: gridWidth * gridHeight)
        var minX = gridWidth, maxX = -1, minY = gridHeight, maxY = -1
        var on = 0
        for gy in 0..<gridHeight {
            let y = min(height - 1, Int((Double(gy) + 0.5) / Double(gridHeight) * Double(height)))
            for gx in 0..<gridWidth {
                let x = min(width - 1, Int((Double(gx) + 0.5) / Double(gridWidth) * Double(width)))
                if bytes[y * stride + x] > 127 {
                    grid[gy * gridWidth + gx] = 1
                    on += 1
                    minX = min(minX, gx); maxX = max(maxX, gx)
                    minY = min(minY, gy); maxY = max(maxY, gy)
                }
            }
        }
        guard on >= gridWidth * gridHeight / 100 else { return nil }
        let box = CGRect(
            x: CGFloat(minX) / CGFloat(gridWidth),
            y: CGFloat(minY) / CGFloat(gridHeight),
            width: CGFloat(maxX - minX + 1) / CGFloat(gridWidth),
            height: CGFloat(maxY - minY + 1) / CGFloat(gridHeight)
        )
        return PersonMask(box: box, grid: grid, gridWidth: gridWidth, gridHeight: gridHeight)
    }
}
