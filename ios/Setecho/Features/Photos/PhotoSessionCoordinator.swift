import Foundation
import Observation
import UIKit

/// The hands-free photo session (DESIGN.md Photo session, HANDOFF.md §7): speak the pose, wait
/// until the athlete is framed and still, capture, say "Got it", move on. Then align each still
/// through /photos/segment against the reference week, build the collage and save the set.
@MainActor
@Observable
final class PhotoSessionCoordinator {
    enum Phase: Equatable {
        case starting
        case posing(Pose)
        case aligning
        case review
        case failed(String)
    }

    private(set) var phase: Phase = .starting
    private(set) var captured: [Pose: Data] = [:]
    private(set) var thumbnails: [Pose: UIImage] = [:]
    private(set) var cue: String?
    private(set) var photoSet: PhotoSet?
    private(set) var collage: UIImage?
    private(set) var alignmentNotes: [String] = []

    let capture = PhotoCapture()
    let audio = AudioService()
    /// The natural voice when the backend has one; the system voice otherwise.
    let natural: NaturalVoiceSpeaker
    private let store: Store
    private let api: APIClient
    private var loop: Task<Void, Never>?
    private var lastCueAt: Date = .distantPast
    private var cancelled = false

    init(store: Store, api: APIClient = APIClient()) {
        self.store = store
        self.api = api
        self.natural = NaturalVoiceSpeaker(api: api, fallback: audio, cacheDirectory: store.mediaDirectory.appendingPathComponent("voice", isDirectory: true))
    }

    /// Every line the session can say, generated once and cached.
    private static let fixedLines = ["Got it", "All four. Say retake and a pose, or you're done.", "Step into frame", "Step back a little",
                                     "Move left", "Move right"]

    var currentPose: Pose? {
        if case .posing(let pose) = phase { return pose }
        return nil
    }

    var slots: [(pose: Pose, slot: PoseSlots.Slot)] {
        Pose.allCases.map { pose in
            if captured[pose] != nil { return (pose, .captured(thumbnails[pose])) }
            if currentPose == pose { return (pose, .current) }
            return (pose, .empty)
        }
    }

    /// Last week's mask for the current pose, as the faint alignment outline.
    var outlineImage: UIImage? {
        guard let pose = currentPose, let last = store.lastPhotoSet, let file = last.photo(for: pose)?.maskFile,
              let data = try? Data(contentsOf: store.mediaDirectory.appendingPathComponent(file))
        else { return nil }
        return UIImage(data: data)
    }

    // MARK: Run

    func start() async {
        guard loop == nil else { return }
        guard await PhotoCapture.requestCamera() else {
            phase = .failed("Camera access is needed for the photo session.")
            return
        }
        _ = await audio.requestMicrophone()
        audio.configure()
        await natural.prepare()
        natural.pregenerate(Pose.allCases.map(\.spokenCue) + Self.fixedLines)
        await natural.warm([Pose.allCases[0].spokenCue])
        capture.start()
        if let error = capture.lastError {
            phase = .failed(error)
            return
        }
        loop = Task { await run() }
    }

    func cancel() {
        cancelled = true
        loop?.cancel()
        capture.stop()
        natural.stop()
    }

    private func run() async {
        for pose in Pose.allCases {
            guard !cancelled else { return }
            phase = .posing(pose)
            capture.resetStillness()
            await natural.speak(pose.spokenCue)
            guard await waitUntilStill(poseCueAt: .now) else { return }
            do {
                let data = try await capture.capture()
                captured[pose] = data
                thumbnails[pose] = UIImage(data: data).map { Self.thumbnail($0) }
                await natural.speak("Got it")
            } catch {
                phase = .failed("Capture failed: \(error.localizedDescription)")
                return
            }
        }
        capture.stop()
        await save()
    }

    /// "Retake front" (or any pose): that one again, then save the four again.
    func retake(_ pose: Pose) {
        guard loop == nil || phase == .review else { return }
        cancelled = false
        loop = Task {
            capture.start()
            phase = .posing(pose)
            capture.resetStillness()
            await natural.speak(pose.spokenCue)
            guard await waitUntilStill(poseCueAt: .now) else { return }
            if let data = try? await capture.capture() {
                captured[pose] = data
                thumbnails[pose] = UIImage(data: data).map { Self.thumbnail($0) }
                await natural.speak("Got it")
            }
            capture.stop()
            await save()
        }
    }

    /// The photos exactly as taken, at full resolution, in his order (HANDOFF.md §7, Photo session,
    /// decided Oct 27): written to the media folder and saved as this week's set. Nothing is cropped,
    /// aligned or sent to SAM.
    private func save() async {
        let setId = photoSet?.id ?? UUID()
        var poses: [PosePhoto] = []
        for pose in Pose.allCases {
            guard let jpeg = captured[pose] else { continue }
            let file = "pose-\(setId.uuidString.prefix(8))-\(pose.rawValue).jpg"
            do {
                try jpeg.write(to: store.mediaDirectory.appendingPathComponent(file))
            } catch {
                phase = .failed("Could not save \(pose.title): \(error.localizedDescription)")
                return
            }
            let size = UIImage(data: jpeg)?.size ?? .zero
            let box = CGRect(origin: .zero, size: size)
            poses.append(PosePhoto(pose: pose, file: file, bodyBox: box, alignedFile: file, cropRect: box, maskFile: nil))
        }
        let set = PhotoSet(id: setId, takenAt: .now, poses: poses, collageFile: "")
        store.upsert(photoSet: set)
        photoSet = set
        phase = .review
        loop = nil
        await natural.speak("All four. Say retake and a pose, or you're done.")
    }

    /// Guidance that sounds like a person at the camera (Oct 27 rehearsal): four seconds to get into
    /// position after the pose cue, a cue only once the framing has held for a second, the same cue
    /// no sooner than 8 s later and at most twice in a row, a different cue after 2.5 s, and nothing
    /// said once the framing is good. Capture when still for 1.2 s. False if cancelled.
    private func waitUntilStill(poseCueAt: Date) async -> Bool {
        var candidate: Framing?
        var candidateSince = Date.now
        var lastSpoken: Framing?
        var repeats = 0
        while !cancelled {
            try? await Task.sleep(for: .milliseconds(100))
            if Task.isCancelled { return false }
            let framing = capture.framing
            if framing != candidate {
                candidate = framing
                candidateSince = .now
            }
            if framing == .good {
                cue = capture.stillness.isStill ? nil : "Hold still"
                if capture.stillness.isStill { return true }
                continue
            }
            cue = framing.spoken
            guard let line = framing.spoken,
                  Date.now.timeIntervalSince(candidateSince) >= 1.0,
                  Date.now.timeIntervalSince(poseCueAt) >= 4.0
            else { continue }
            if framing != lastSpoken { repeats = 0 }
            let gap = framing == lastSpoken ? 8.0 : 2.5
            guard repeats < 2, Date.now.timeIntervalSince(lastCueAt) >= gap else { continue }
            lastSpoken = framing
            repeats += 1
            lastCueAt = .now
            await natural.speak(line)
        }
        return false
    }

    // MARK: Align and save

    private func align() async {
        let setId = UUID()
        let reference = store.referencePhotoSet
        var poses: [PosePhoto] = []
        var tiles: [Pose: UIImage] = [:]
        for pose in Pose.allCases {
            guard let jpeg = captured[pose] else { continue }
            let prefix = "pose-\(setId.uuidString.prefix(8))-\(pose.rawValue)"
            let file = "\(prefix).jpg"
            let alignedFile = "\(prefix)-aligned.jpg"
            let maskFile = "\(prefix)-mask.png"
            do {
                try jpeg.write(to: store.mediaDirectory.appendingPathComponent(file))
                let referenceFraction = reference?.photo(for: pose)?.bodyFraction
                let result = try await api.segment(jpeg: jpeg, referenceFraction: referenceFraction)
                guard let aligned = PhotoAlign.crop(jpeg: jpeg, to: result.cropRect) else {
                    throw APIError(status: 0, message: "Could not crop \(pose.title)")
                }
                try aligned.write(to: store.mediaDirectory.appendingPathComponent(alignedFile))
                if let mask = result.maskData {
                    try mask.write(to: store.mediaDirectory.appendingPathComponent(maskFile))
                }
                if result.clamped { alignmentNotes.append("\(pose.title): stood too close or off-centre; cropped as far as possible.") }
                poses.append(PosePhoto(pose: pose, file: file, bodyBox: result.boxRect, alignedFile: alignedFile,
                                       cropRect: result.cropRect, maskFile: result.maskData == nil ? nil : maskFile))
                if let image = UIImage(data: aligned) { tiles[pose] = image }
            } catch {
                phase = .failed("\(pose.title): \(error.localizedDescription)")
                return
            }
        }
        let collageImage = PhotoAlign.collage(tiles)
        let collageFile = "collage-\(setId.uuidString.prefix(8)).jpg"
        guard let collageData = collageImage.jpegData(compressionQuality: 0.9) else {
            phase = .failed("Could not build the collage")
            return
        }
        do {
            try collageData.write(to: store.mediaDirectory.appendingPathComponent(collageFile))
        } catch {
            phase = .failed("Could not save the collage: \(error.localizedDescription)")
            return
        }
        let set = PhotoSet(id: setId, takenAt: .now, poses: poses, collageFile: collageFile)
        store.upsert(photoSet: set)
        photoSet = set
        collage = collageImage
        phase = .review
        await natural.speak("Done. Your collage is ready.")
    }

    private static func thumbnail(_ image: UIImage) -> UIImage {
        let target = CGSize(width: 150, height: 200)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: target, format: format).image { _ in
            image.draw(in: PhotoAlign.aspectFill(image.size, in: CGRect(origin: .zero, size: target)))
        }
    }
}
