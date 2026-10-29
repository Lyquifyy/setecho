import Foundation
import Observation
import UIKit

/// The hands-free photo session (DESIGN.md Photo session, HANDOFF.md §7): speak the pose, give him
/// time to turn and settle, wait until he is framed and still, capture, acknowledge it ("Got it.",
/// "Okay.", "Nice." in turn), move on. Each photo is written the moment it is taken, under a name of
/// its own, so a retake replaces exactly that pose. He can say "retake the front", "wait" or "done".
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
    /// Each pose's photo as it stands now: the file in the media folder and its size.
    private(set) var taken: [Pose: PosePhoto] = [:]
    private(set) var thumbnails: [Pose: UIImage] = [:]
    private(set) var cue: String?
    /// How far the hold has got, 0…1, for the bar on screen.
    private(set) var stillProgress: Double = 0
    private(set) var photoSet: PhotoSet?
    /// He said he's done: the view closes.
    private(set) var finished = false
    /// What was heard last, for the HUD: "Retake front".
    private(set) var heard: String?

    let capture = PhotoCapture()
    let audio = AudioService()
    /// The one voice, with the pose cues and fixed lines pre-rendered.
    let voice: SystemSpeaker
    let realtime = RealtimeTranscriber()
    private let store: Store
    private let api: APIClient
    private var loop: Task<Void, Never>?
    private var lastCueAt: Date = .distantPast
    private var cancelled = false
    private var lastAcknowledgment: String?
    /// Poses he asked to redo while the run was going: taken again once the four are done.
    private var redo: [Pose] = []
    /// "Wait": the hold can't start before this.
    private var notBefore: Date = .distantPast
    private let setId: UUID

    /// Seconds after a pose cue ends before the hold can start: time to turn, raise the arms and
    /// settle (Oct 29: with no gap, a still athlete was shot the moment the cue ended, in the old pose).
    static let turnSeconds: TimeInterval = 5
    /// The first pose and a retake: he is walking back from the phone.
    static let walkBackSeconds: TimeInterval = 8
    /// How long he holds still for the photo.
    static let holdSeconds = 1.5

    /// "Got it.", "Okay.", "Nice." in turn after each photo, never the same twice in a row.
    private func nextAcknowledgment() -> String {
        let ack = SpokenFacts.next(after: lastAcknowledgment, beforeAFact: false)
        lastAcknowledgment = ack
        return ack + "."
    }

    /// With `existing`, the session opens on that set's review, to retake a pose or look again.
    init(store: Store, api: APIClient = APIClient(), existing: PhotoSet? = nil) {
        self.store = store
        self.api = api
        audio.holdsDucking = true
        self.voice = SystemSpeaker(audio: audio, cacheDirectory: store.mediaDirectory.appendingPathComponent("voice", isDirectory: true))
        setId = existing?.id ?? UUID()
        if let existing {
            photoSet = existing
            for photo in existing.poses { taken[photo.pose] = photo }
            phase = .review
        }
    }

    static let reviewLine = "That's all four. Say retake and a pose to redo one, or say done."
    static let whichLine = "Which one? Front, right side, back or left side?"

    /// Every line the session can say, rendered once when it starts.
    private static let fixedLines = ["Got it.", "Okay.", "Nice.", reviewLine, whichLine, "Step into the frame", "Take a step back",
                                     "Move a little to your left", "Move a little to your right", "Perfect, hold it right there.",
                                     "Just hold still for a second.", "Okay, taking it now.", "Take your time.", "Okay, all four again."]
        + Pose.allCases.map { "Okay, I'll redo the \($0.spokenName) after this one." }

    var currentPose: Pose? {
        if case .posing(let pose) = phase { return pose }
        return nil
    }

    var slots: [(pose: Pose, slot: PoseSlots.Slot)] {
        Pose.allCases.map { pose in
            if currentPose == pose { return (pose, .current) }
            if taken[pose] != nil { return (pose, .captured(thumbnails[pose])) }
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
        listen()
        // Opened on a set already taken: wait on the review for a retake.
        guard phase != .review else { return }
        await voice.warm([Pose.allCases[0].spokenCue])
        capture.start()
        if let error = capture.lastError {
            phase = .failed(error)
            return
        }
        loop = Task { await run(Pose.allCases) }
    }

    func cancel() {
        cancelled = true
        loop?.cancel()
        loop = nil
        capture.stop()
        voice.stop()
        realtime.cancel()
        audio.stopListening()
    }

    /// The poses in order, then any he asked to redo along the way, then the set is saved.
    private func run(_ poses: [Pose]) async {
        var queue = poses
        var first = true
        while !queue.isEmpty {
            let pose = queue.removeFirst()
            guard !cancelled, await shoot(pose, walkingBack: first) else { return }
            first = false
            if queue.isEmpty, !redo.isEmpty {
                queue = redo
                redo = []
            }
        }
        capture.stop()
        save()
        await voice.speak(Self.reviewLine)
    }

    /// One pose: the cue, his time to get there, the hold, the photo. False if cancelled or it failed.
    private func shoot(_ pose: Pose, walkingBack: Bool) async -> Bool {
        phase = .posing(pose)
        cue = nil
        stillProgress = 0
        await voice.speak(pose.spokenCue)
        guard !cancelled else { return false }
        notBefore = .now.addingTimeInterval(walkingBack ? Self.walkBackSeconds : Self.turnSeconds)
        guard await waitUntilStill(pose: pose) else { return false }
        do {
            let data = try await capture.capture()
            try keep(data, for: pose)
            await voice.speak(nextAcknowledgment())
            // A beat before the next cue, so it doesn't run straight on.
            try? await Task.sleep(for: .milliseconds(800))
            return true
        } catch {
            phase = .failed("Couldn't take the \(pose.title.lowercased()) photo: \(error.localizedDescription)")
            return false
        }
    }

    /// "Retake front" (or any pose): that one again, then the set is saved again. Only that pose's
    /// file changes.
    func retake(_ pose: Pose) {
        guard phase == .review else { return }
        cancelled = false
        loop = Task {
            capture.start()
            if let error = capture.lastError {
                phase = .failed(error)
                return
            }
            await run([pose])
        }
    }

    /// All four again, from the front.
    func retakeAll() {
        guard phase == .review else { return }
        cancelled = false
        loop = Task {
            capture.start()
            await run(Pose.allCases)
        }
    }

    /// The photo exactly as taken, at full resolution, written now under a name of its own (Oct 29: a
    /// retake reused the name, and screens showed the old photo from their cache). The one it
    /// replaces is deleted.
    private func keep(_ jpeg: Data, for pose: Pose) throws {
        let take = UUID().uuidString.prefix(4)
        let file = "pose-\(setId.uuidString.prefix(8))-\(pose.rawValue)-\(take).jpg"
        try jpeg.write(to: store.mediaDirectory.appendingPathComponent(file))
        if let old = taken[pose]?.file, old != file {
            try? FileManager.default.removeItem(at: store.mediaDirectory.appendingPathComponent(old))
        }
        let image = UIImage(data: jpeg)
        let box = CGRect(origin: .zero, size: image?.size ?? .zero)
        taken[pose] = PosePhoto(pose: pose, file: file, bodyBox: box, alignedFile: file, cropRect: box, maskFile: nil)
        thumbnails[pose] = image.map { Self.thumbnail($0) }
    }

    /// The photos as taken, in his order (HANDOFF.md §7, Photo session, decided Oct 27), saved as
    /// this week's set. Nothing is cropped, aligned or sent to SAM.
    private func save() {
        let poses = Pose.allCases.compactMap { taken[$0] }
        let set = PhotoSet(id: setId, takenAt: .now, poses: poses, collageFile: "")
        store.upsert(photoSet: set)
        photoSet = set
        phase = .review
        cue = nil
        loop = nil
    }

    // MARK: Listening

    /// The mic stays open for the whole session; the voice closes it while a line plays.
    private func listen() {
        audio.onUtterance = { [weak self] utterance in Task { await self?.hear(utterance) } }
        audio.onSpeechStart = { [weak self] in self?.realtime.start() }
        audio.onLiveSamples = { [weak self] samples, rate in self?.realtime.send(samples, rate: rate) }
        audio.startListening()
    }

    private func hear(_ utterance: VoiceDetector.Utterance) async {
        let pcm = Resample.toInt16Mono(utterance.samples, from: utterance.sampleRate, to: 16_000)
        guard pcm.count > 16_000 / 4, !cancelled else {
            realtime.cancel()
            return
        }
        var words = await realtime.end()
        if words?.isEmpty ?? true {
            // File mode: only the words are used; the photo step's commands are read here.
            let context = TurnContext(template: CheckInTemplate(fields: [], carriedBlocks: []), step: "photos", askedFieldId: nil,
                                      pending: [], answered: [], styleExamples: [], askedOn: DayKey.string(.now), offered: nil)
            words = try? await api.checkInTurn(wav: WAVFile.data(pcm16: pcm, sampleRate: 16_000), context: context).transcript
        }
        guard let words, let command = PhotoCommand.read(words) else { return }
        heard = words
        await perform(command)
    }

    func perform(_ command: PhotoCommand) async {
        switch command {
        case .retake(let pose):
            if phase == .review {
                retake(pose)
            } else if let current = currentPose, current == pose {
                // The pose being taken now: start its clock again.
                capture.resetStillness()
                notBefore = .now.addingTimeInterval(Self.turnSeconds)
            } else if taken[pose] != nil, !redo.contains(pose) {
                redo.append(pose)
                await voice.speak("Okay, I'll redo the \(pose.spokenName) after this one.")
            }
        case .retakeWhich:
            if phase == .review { await voice.speak(Self.whichLine) }
        case .retakeAll:
            if phase == .review {
                await voice.speak("Okay, all four again.")
                retakeAll()
            }
        case .wait:
            guard currentPose != nil else { return }
            capture.resetStillness()
            notBefore = .now.addingTimeInterval(Self.turnSeconds + 3)
            await voice.speak("Take your time.")
        case .done:
            guard phase == .review else { return }
            cancel()
            finished = true
        }
    }

    /// Guidance that sounds like a person at the camera. Nothing happens until `notBefore` (his time
    /// to turn and settle). Then framing cues once the framing has held for a second, the same one no
    /// sooner than 8 s later. Once framed: "Perfect, hold it right there", and the hold starts after
    /// the line; capture when still for 1.5 s. It never just sits (Oct 28): after 4 s framed but not
    /// still, "Hold still for a second"; after 8 s framed, the photo is taken anyway; after 20 s
    /// without a capture the pose cue is said again. False if cancelled.
    private func waitUntilStill(pose: Pose) async -> Bool {
        var candidate: Framing?
        var candidateSince = Date.now
        var lastSpoken: Framing?
        var framedSince: Date?
        var saidStill = false
        var lastPoseCue = Date.now
        while !cancelled {
            try? await Task.sleep(for: .milliseconds(100))
            if Task.isCancelled { return false }
            let now = Date.now
            if now < notBefore {
                // Turning and settling: no photo, no corrections.
                cue = "Get into position"
                stillProgress = 0
                framedSince = nil
                continue
            }
            let framing = capture.framing
            if framing != candidate {
                candidate = framing
                candidateSince = now
            }
            if framing == .good {
                guard let since = framedSince else {
                    // Framed: say so once, then the hold starts from the end of the line.
                    cue = "Hold still"
                    await voice.speak("Perfect, hold it right there.")
                    capture.resetStillness(seconds: Self.holdSeconds)
                    framedSince = .now
                    continue
                }
                stillProgress = capture.stillness.progress
                cue = capture.stillness.isStill ? nil : "Hold still"
                if capture.stillness.isStill { return true }
                let framedFor = now.timeIntervalSince(since)
                if !saidStill, framedFor >= 4 {
                    saidStill = true
                    await voice.speak("Just hold still for a second.")
                } else if framedFor >= 8 {
                    await voice.speak("Okay, taking it now.")
                    return true
                }
                continue
            }
            // Out of frame after the hold began: it starts again once he's back.
            framedSince = nil
            stillProgress = 0
            cue = framing.spoken
            if now.timeIntervalSince(lastPoseCue) >= 20 {
                // Stuck: start the pose over, as a person would.
                lastPoseCue = now
                lastSpoken = nil
                await voice.speak(pose.spokenCue)
                notBefore = .now.addingTimeInterval(Self.turnSeconds)
                continue
            }
            guard let line = framing.spoken, now.timeIntervalSince(candidateSince) >= 1.0 else { continue }
            let gap = framing == lastSpoken ? 8.0 : 2.5
            guard now.timeIntervalSince(lastCueAt) >= gap else { continue }
            lastSpoken = framing
            lastCueAt = now
            await voice.speak(line)
        }
        return false
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
