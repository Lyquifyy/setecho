import Foundation
import Observation
import UIKit

/// The hands-free photo session (DESIGN.md Photo session, HANDOFF.md §7): speak the pose, wait
/// until the athlete is framed and still, capture, acknowledge it ("Got it.", "Okay.", "Nice." in turn), move on. Then align each still
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
    /// How far the hold has got, 0…1, for the bar on screen.
    private(set) var stillProgress: Double = 0
    private(set) var photoSet: PhotoSet?
    private(set) var collage: UIImage?
    private(set) var alignmentNotes: [String] = []

    let capture = PhotoCapture()
    let audio = AudioService()
    /// The one voice, with the pose cues and fixed lines pre-rendered.
    let voice: SystemSpeaker
    private let store: Store
    private let api: APIClient
    private var loop: Task<Void, Never>?
    private var lastCueAt: Date = .distantPast
    private var cancelled = false
    private var lastAcknowledgment: String?

    /// "Got it.", "Okay.", "Nice." in turn after each photo, never the same twice in a row.
    private func nextAcknowledgment() -> String {
        let ack = SpokenFacts.next(after: lastAcknowledgment, beforeAFact: false)
        lastAcknowledgment = ack
        return ack + "."
    }

    init(store: Store, api: APIClient = APIClient()) {
        self.store = store
        self.api = api
        audio.holdsDucking = true
        self.voice = SystemSpeaker(audio: audio, cacheDirectory: store.mediaDirectory.appendingPathComponent("voice", isDirectory: true))
    }

    /// Every line the session can say, rendered once when it starts.
    private static let fixedLines = ["Got it.", "Okay.", "Nice.", "That's all four. Say retake and a pose to redo one, or we're done.", "Step into the frame", "Take a step back",
                                     "Move a little to your left", "Move a little to your right", "Perfect, hold it right there.", "Just hold still for a second.", "Okay, taking it now."]

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
        voice.prerender(Pose.allCases.map(\.spokenCue) + Self.fixedLines)
        await voice.warm([Pose.allCases[0].spokenCue])
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
        voice.stop()
    }

    private func run() async {
        for pose in Pose.allCases {
            guard !cancelled else { return }
            phase = .posing(pose)
            capture.resetStillness()
            await voice.speak(pose.spokenCue)
            guard await waitUntilStill(poseCueAt: .now, pose: pose) else { return }
            do {
                let data = try await capture.capture()
                captured[pose] = data
                thumbnails[pose] = UIImage(data: data).map { Self.thumbnail($0) }
                await voice.speak(nextAcknowledgment())
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
            await voice.speak(pose.spokenCue)
            guard await waitUntilStill(poseCueAt: .now, pose: pose) else { return }
            if let data = try? await capture.capture() {
                captured[pose] = data
                thumbnails[pose] = UIImage(data: data).map { Self.thumbnail($0) }
                await voice.speak(nextAcknowledgment())
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
        await voice.speak("That's all four. Say retake and a pose to redo one, or we're done.")
    }

    /// Guidance that sounds like a person at the camera. Four seconds to get into position after the
    /// pose cue; a framing cue only once the framing has held for a second, the same one no sooner
    /// than 8 s later. Once framed: "Hold it there", once, and the progress on screen. Capture when
    /// still for 1 s. It never just sits (Oct 28): after 4 s framed but not still, "Hold still for a
    /// second"; after 7 s framed in all, the photo is taken anyway; after 15 s without a capture the
    /// pose cue is said again. False if cancelled.
    private func waitUntilStill(poseCueAt: Date, pose: Pose) async -> Bool {
        var candidate: Framing?
        var candidateSince = Date.now
        var lastSpoken: Framing?
        var framedFor: TimeInterval = 0
        var saidHold = false
        var saidStill = false
        var lastTick = Date.now
        var lastPoseCue = poseCueAt
        while !cancelled {
            try? await Task.sleep(for: .milliseconds(100))
            if Task.isCancelled { return false }
            let now = Date.now
            let framing = capture.framing
            if framing != candidate {
                candidate = framing
                candidateSince = now
            }
            if framing == .good {
                framedFor += now.timeIntervalSince(lastTick)
                lastTick = now
                stillProgress = capture.stillness.progress
                cue = capture.stillness.isStill ? nil : "Hold still"
                if capture.stillness.isStill { return true }
                if !saidHold, now.timeIntervalSince(poseCueAt) >= 1.5 {
                    saidHold = true
                    await voice.speak("Perfect, hold it right there.")
                } else if !saidStill, framedFor >= 4 {
                    saidStill = true
                    await voice.speak("Just hold still for a second.")
                } else if framedFor >= 7 {
                    await voice.speak("Okay, taking it now.")
                    return true
                }
                continue
            }
            lastTick = now
            stillProgress = 0
            cue = framing.spoken
            if now.timeIntervalSince(lastPoseCue) >= 15 {
                // Stuck: start the pose over, as a person would.
                lastPoseCue = now
                lastSpoken = nil
                capture.resetStillness()
                await voice.speak(pose.spokenCue)
                continue
            }
            guard let line = framing.spoken,
                  now.timeIntervalSince(candidateSince) >= 1.0,
                  now.timeIntervalSince(lastPoseCue) >= 4.0
            else { continue }
            let gap = framing == lastSpoken ? 8.0 : 2.5
            guard now.timeIntervalSince(lastCueAt) >= gap else { continue }
            lastSpoken = framing
            lastCueAt = now
            await voice.speak(line)
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
        await voice.speak("All done. Your four photos are saved.")
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
