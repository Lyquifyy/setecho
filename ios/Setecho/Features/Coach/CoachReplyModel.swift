import AVFoundation
import Foundation
import Observation

/// Reads a reply through the backend, keeps it in the Store, applies what the athlete approves,
/// and cuts the cues out of the voice note (HANDOFF.md §7, Coach reply and Coach voice cues).
@MainActor
@Observable
final class CoachReplyModel {
    private(set) var reply: CoachReply?
    private(set) var cues: [VoiceCue] = []
    private(set) var isReading = false
    private(set) var error: String?
    private(set) var applied: PlanApplier.Result?
    private(set) var audioDuration: TimeInterval?

    let store: Store
    private let api: APIClient
    private let settings: Settings
    private var player: AVAudioPlayer?
    private let speech = AudioService()

    init(store: Store, reply: CoachReply? = nil, api: APIClient = APIClient(), settings: Settings = .shared) {
        self.store = store
        self.api = api
        self.settings = settings
        self.reply = reply
        if let reply {
            cues = store.cues.filter { $0.replyId == reply.id }
            audioDuration = reply.audioFile.flatMap { Self.duration(of: store.mediaDirectory.appendingPathComponent($0)) }
        }
    }

    var changes: [PlanChange] { reply?.changes ?? [] }
    var approvedCount: Int { changes.filter(\.approved).count }
    var cuesEnabled: Bool { settings.coachVoiceInSessions }

    /// Changes grouped in the design's order: Targets, Training, Cardio, Supplements.
    var groupedChanges: [(group: String, changes: [PlanChange])] {
        ["Targets", "Training", "Cardio", "Supplements"].compactMap { group in
            let items = changes.filter { $0.kind.group == group }
            return items.isEmpty ? nil : (group, items)
        }
    }

    // MARK: Reading a reply in

    func read(text: String) async {
        guard let plan = store.plan else { error = "Import the program and the form first."; return }
        await read(plan: plan, kind: .text, audio: nil) {
            try await self.api.coachReply(text: text, plan: plan, cuesEnabled: self.cuesEnabled)
        }
    }

    func read(audio data: Data, filename: String) async {
        guard let plan = store.plan else { error = "Import the program and the form first."; return }
        let name = "reply-\(UUID().uuidString.prefix(8)).\(URL(fileURLWithPath: filename).pathExtension.isEmpty ? "m4a" : URL(fileURLWithPath: filename).pathExtension)"
        let url = store.mediaDirectory.appendingPathComponent(name)
        try? data.write(to: url)
        audioDuration = Self.duration(of: url)
        await read(plan: plan, kind: .voiceNote, audio: name) {
            try await self.api.coachReply(audio: data, filename: filename, plan: plan, cuesEnabled: self.cuesEnabled)
        }
    }

    private func read(plan: PlanState, kind: ReplyKind, audio: String?, _ call: @escaping () async throws -> ReplyResponse) async {
        guard !isReading else { return }
        isReading = true
        error = nil
        defer { isReading = false }
        do {
            let response = try await call()
            let id = UUID()
            let reply = CoachReply(id: id, receivedAt: .now, kind: kind, audioFile: audio, transcript: response.transcript,
                                   changes: response.changes, unclear: response.unclear, appliedVersion: nil)
            self.reply = reply
            store.upsert(reply: reply)
            var cut: [VoiceCue] = []
            for cue in response.cues {
                var voice = VoiceCue(id: "\(id.uuidString.prefix(8))-\(cue.id)", replyId: id, exerciseId: cue.exerciseId, text: cue.text,
                                     audioFile: nil, startSec: cue.startSec, endSec: cue.endSec, approved: true, lastPlayedAt: nil)
                if let audio, let start = cue.startSec, let end = cue.endSec {
                    voice.audioFile = await CueCutter.cut(note: store.mediaDirectory.appendingPathComponent(audio), start: start, end: end,
                                                          into: store.cuesDirectory, name: voice.id)
                }
                cut.append(voice)
            }
            cues = cut
            // The new reply's cues replace the old ones once it is applied; until then they sit with the reply.
        } catch {
            self.error = error.localizedDescription
        }
    }

    // MARK: Review

    func toggle(_ change: PlanChange) {
        guard var reply, let i = reply.changes.firstIndex(where: { $0.id == change.id }) else { return }
        reply.changes[i].approved.toggle()
        self.reply = reply
        store.upsert(reply: reply)
    }

    func toggle(cue: VoiceCue) {
        guard let i = cues.firstIndex(where: { $0.id == cue.id }) else { return }
        cues[i].approved.toggle()
        if store.cues.contains(where: { $0.id == cue.id }) { store.update(cue: cues[i]) }
    }

    /// Apply the approved changes: a new plan version, the carried blocks edited, the cues installed.
    func apply() {
        guard let reply, let plan = store.plan else { return }
        let result = PlanApplier.apply(reply.changes, to: plan, replyId: reply.id)
        store.appendPlan(result.plan)
        var done = reply
        done.appliedVersion = result.plan.version
        self.reply = done
        store.upsert(reply: done)
        store.replaceCues(with: cues)
        if !result.macroFactorReminders.isEmpty { store.addMacroFactorReminders(result.macroFactorReminders) }
        applied = result
    }

    /// "Program updated from Mon Nov 2 · Targets updated"
    var appliedSummary: String? {
        guard let applied, let reply else { return nil }
        var parts: [String] = []
        let approved = reply.changes.filter(\.approved)
        if approved.contains(where: { $0.kind.group == "Training" }) {
            let from = approved.compactMap(\.appliesFromDate).min()
            parts.append("Program updated" + (from.map { " from \($0.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()))" } ?? ""))
        }
        if approved.contains(where: { $0.kind == .macroTarget }) { parts.append("Targets updated") }
        if approved.contains(where: { $0.kind == .cardio }) { parts.append("Cardio updated") }
        if approved.contains(where: { $0.kind == .supplement }) { parts.append("Supplements updated") }
        if !applied.blocksNeedingHandEdit.isEmpty { parts.append("Edit by hand: \(applied.blocksNeedingHandEdit.joined(separator: ", "))") }
        return parts.isEmpty ? "Nothing changed" : parts.joined(separator: " · ")
    }

    // MARK: Playback on this screen (taps are fine here)

    func playNote() {
        guard let file = reply?.audioFile else { return }
        play(url: store.mediaDirectory.appendingPathComponent(file))
    }

    func play(cue: VoiceCue) {
        if let file = cue.audioFile {
            play(url: store.cuesDirectory.appendingPathComponent(file))
        } else {
            Task { await speech.speak("Coach says: \(cue.text)") }
        }
    }

    private func play(url: URL) {
        player?.stop()
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [])
        try? AVAudioSession.sharedInstance().setActive(true)
        player = try? AVAudioPlayer(contentsOf: url)
        player?.play()
    }

    static func duration(of url: URL) -> TimeInterval? {
        (try? AVAudioPlayer(contentsOf: url))?.duration
    }
}

/// Cuts one cue out of the local voice note with AVAssetExportSession (HANDOFF.md §7, Coach voice cues).
enum CueCutter {
    static func cut(note: URL, start: Double, end: Double, into directory: URL, name: String) async -> String? {
        let asset = AVURLAsset(url: note)
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else { return nil }
        let out = directory.appendingPathComponent("\(name).m4a")
        try? FileManager.default.removeItem(at: out)
        session.timeRange = CMTimeRange(start: CMTime(seconds: max(0, start - 0.15), preferredTimescale: 600),
                                        end: CMTime(seconds: end + 0.15, preferredTimescale: 600))
        do {
            try await session.export(to: out, as: .m4a)
            return out.lastPathComponent
        } catch {
            return nil
        }
    }
}
