import AVFoundation
import Foundation
import Observation
import UIKit

/// Filming mode (HANDOFF.md §9, block 1): every line Setecho speaks saved as audio, every one of
/// the athlete's utterances saved as its WAV, each stamped from one clock; one SRT captions file
/// per check-in or session; a slate at the start. Everything stays on the phone under
/// media/filming/<take>/ and is exported by AirDrop from History. It never changes timing: the
/// line's pre-rendered file is copied as played, and any other line is rendered off the speaking path.
@MainActor
@Observable
final class FilmingRecorder {
    struct Line: Codable, Equatable {
        var at: TimeInterval
        var duration: TimeInterval?
        var speaker: String
        var text: String
        var file: String?
    }

    let directory: URL
    let startedAt: Date
    private(set) var lines: [Line] = []
    private(set) var slateAt: TimeInterval?
    private var index = 0

    init(root: URL, kind: String, now: Date = .now) {
        let name = "\(kind)-\(Int(now.timeIntervalSince1970))"
        directory = root.appendingPathComponent("filming", isDirectory: true).appendingPathComponent(name, isDirectory: true)
        startedAt = now
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private func stamp(_ date: Date) -> TimeInterval { date.timeIntervalSince(startedAt) }

    /// The slate: a white flash and a short beep, with its time logged. The view shows the flash.
    func slate(at now: Date = .now) {
        slateAt = stamp(now)
        AudioServicesPlaySystemSound(1057)
        lines.append(Line(at: stamp(now), duration: 0.3, speaker: "slate", text: "[slate]", file: nil))
        save()
    }

    /// A line Setecho spoke. With `audio` its pre-rendered file is copied as played; without it the
    /// same utterance is rendered to a file, off the speaking path.
    func spoke(_ text: String, at now: Date = .now, audio: URL? = nil, voice: AVSpeechSynthesisVoice? = nil) {
        let tone = AudioService.currentTone
        index += 1
        let name = String(format: "%03d-setecho", index)
        var line = Line(at: stamp(now), duration: nil, speaker: "setecho", text: text, file: nil)
        if let audio {
            let dest = directory.appendingPathComponent("\(name).\(audio.pathExtension)")
            try? FileManager.default.copyItem(at: audio, to: dest)
            line.file = dest.lastPathComponent
            if let player = try? AVAudioPlayer(contentsOf: dest) { line.duration = player.duration }
            lines.append(line)
            save()
            return
        }
        let dest = directory.appendingPathComponent("\(name).caf")
        line.file = dest.lastPathComponent
        lines.append(line)
        let position = lines.count - 1
        save()
        Task.detached(priority: .utility) {
            let seconds = await SpokenText.render(text, voice: voice, tone: tone, to: dest)
            await MainActor.run {
                if self.lines.indices.contains(position) { self.lines[position].duration = seconds }
                self.save()
            }
        }
    }

    /// One of the athlete's utterances, as its WAV.
    func heard(pcm16: [Int16], sampleRate: Int, at now: Date = .now, transcript: String? = nil) {
        index += 1
        let dest = directory.appendingPathComponent(String(format: "%03d-athlete.wav", index))
        try? WAVFile.data(pcm16: pcm16, sampleRate: sampleRate).write(to: dest)
        let duration = Double(pcm16.count) / Double(sampleRate)
        lines.append(Line(at: stamp(now) - duration, duration: duration, speaker: "athlete", text: transcript ?? "", file: dest.lastPathComponent))
        save()
    }

    func transcribed(_ transcript: String) {
        if let i = lines.lastIndex(where: { $0.speaker == "athlete" && $0.text.isEmpty }) {
            lines[i].text = transcript
            save()
        }
    }

    /// The manifest and the captions (SRT), rewritten after every line.
    private func save() {
        if let data = try? JSONCoding.encoder.encode(lines) { try? data.write(to: directory.appendingPathComponent("manifest.json")) }
        try? srt().write(to: directory.appendingPathComponent("captions.srt"), atomically: true, encoding: .utf8)
    }

    func srt() -> String {
        var out: [String] = []
        for (n, line) in lines.enumerated() where !line.text.isEmpty {
            let start = max(0, line.at)
            let end = start + (line.duration ?? max(1, Double(line.text.split(separator: " ").count) / 2.5))
            out.append("\(n + 1)\n\(Self.srtTime(start)) --> \(Self.srtTime(end))\n\(line.speaker == "athlete" ? "ATHLETE: " : "")\(line.text)\n")
        }
        return out.joined(separator: "\n")
    }

    static func srtTime(_ seconds: TimeInterval) -> String {
        let ms = Int((seconds * 1000).rounded())
        return String(format: "%02d:%02d:%02d,%03d", ms / 3_600_000, ms / 60_000 % 60, ms / 1000 % 60, ms % 1000)
    }

    /// A take as one zip in the temporary folder, for AirDrop (Oct 28: a folder would not go after
    /// the fact, and the system's upload zip came out empty).
    static func zipped(_ take: URL) throws -> URL {
        let dest = FileManager.default.temporaryDirectory.appendingPathComponent(take.lastPathComponent + ".zip")
        try ZipWriter.zip(folder: take, to: dest)
        return dest
    }

    /// Every take under media/filming, newest first, for History's AirDrop export.
    static func takes(in root: URL) -> [URL] {
        let folder = root.appendingPathComponent("filming", isDirectory: true)
        let items = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.creationDateKey])) ?? []
        return items.sorted { $0.lastPathComponent > $1.lastPathComponent }
    }
}
