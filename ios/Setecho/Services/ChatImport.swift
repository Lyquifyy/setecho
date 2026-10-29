import Foundation

/// A check-in as he typed it, read through the coach's form: each line that starts with one of the
/// coach's labels (his prompt and a colon after it optional) opens that field, and the lines below
/// it, up to the next label, are its answer. Numbers come from this text only (rule 5).
enum CheckInText {
    /// Field id → his words after the label. A field written twice keeps the first.
    static func answers(in text: String, template: CheckInTemplate) -> [String: String] {
        let fields = template.orderedFields.filter { $0.kind != .photo }
            .map { (field: $0, label: squash($0.label), prompt: squash($0.prompt ?? "")) }
            .filter { !$0.label.isEmpty }
        var answers: [String: String] = [:]
        var current: String?
        var lines: [String] = []
        func close() {
            if let current, answers[current] == nil { answers[current] = lines.joined(separator: "\n") }
            lines = []
        }
        for line in text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            // The longest label that opens the line, so "Notes on stress" never takes "Notes on stress levels".
            let hit = fields.compactMap { f in remainder(of: line, after: f.label, prompt: f.prompt).map { (f.field.id, $0, f.label.count) } }
                .max { $0.2 < $1.2 }
            if let hit {
                close()
                current = hit.0
                if !hit.1.isEmpty { lines.append(hit.1) }
            } else if current != nil {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty { lines.append(trimmed) }
            }
        }
        close()
        return answers.filter { !$0.value.isEmpty }
    }

    /// The first number in an answer: "181.4 lbs" → 181.4, "10,412" → 10412, "7/10, good week" → 7.
    static func number(in answer: String) -> Double? {
        guard let m = answer.firstMatch(of: /\d{1,3}(?:,\d{3})+(?:\.\d+)?|\d+(?:\.\d+)?|\.\d+/) else { return nil }
        return Double(m.output.replacingOccurrences(of: ",", with: ""))
    }

    /// Lowercase letters and digits only: how a label is matched, whatever the punctuation, bold
    /// asterisks or spacing around it.
    static func squash(_ s: String) -> String {
        String(s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).unicodeScalars
            .filter { CharacterSet.alphanumerics.contains($0) }.map(Character.init)).lowercased()
    }

    /// What follows the label (and its prompt) on the line, when the line opens with it and a
    /// separator or the end of the line comes next; nil when it doesn't.
    private static func remainder(of line: String, after label: String, prompt: String) -> String? {
        // Most lines open with no label at all: one cheap check before the walk.
        guard squash(line).hasPrefix(label) else { return nil }
        let chars = Array(line)
        // Each character as it's matched: its letters and digits, or "" for spacing and punctuation.
        let folded = chars.map { squash(String($0)) }
        var i = 0
        func consume(_ key: String) -> Bool {
            var j = i
            var key = Substring(key)
            while !key.isEmpty {
                while j < folded.count, folded[j].isEmpty { j += 1 }
                guard j < folded.count, key.hasPrefix(folded[j]) else { return false }
                key = key.dropFirst(folded[j].count)
                j += 1
            }
            i = j
            return true
        }
        guard consume(label) else { return nil }
        // A label is a whole phrase: "Notes on sleep" doesn't open "Notes on sleepiness".
        if i < folded.count, !folded[i].isEmpty { return nil }
        let afterLabel = i
        if !prompt.isEmpty, !consume(prompt) { i = afterLabel }
        var rest = String(chars[i...]).drop { " *_)\u{00A0}".contains($0) }
        // A prompt with no letters ("(%)"), or one he wrote his own way, in brackets.
        while rest.first == "(", let close = rest.firstIndex(of: ")") {
            rest = rest[rest.index(after: close)...].drop { " *_\u{00A0}".contains($0) }
        }
        guard let first = rest.first else { return "" }
        guard ":-–—?=".contains(first) else { return nil }
        // "*Current body weight:* 182.6": the bold marker can close after the colon.
        return rest.dropFirst().drop { " *_\u{00A0}".contains($0) }.trimmingCharacters(in: .whitespaces)
    }
}

/// What the chat holds, sorted in code: past check-ins (the athlete's messages whose lines match
/// the form's labels), the coach's messages after each one, and the photos sent with them, linked
/// by time. Everything else is dropped.
enum ChatImport {
    struct Result: Equatable {
        var checkIns: [PastCheckIn] = []
        var coachMessages: [CoachMessage] = []
        /// Every message's key, kept or dropped.
        var keys: [String] = []
        /// The messages kept: a check-in's, its photos, the coach's replies.
        var kept: Set<String> = []
        /// Messages that are neither a check-in, one of its photos, nor a coach reply.
        var dropped: Int { Set(keys).subtracting(kept).count }
        /// The export's files the kept items need: photos and voice notes.
        var files: [String] { checkIns.flatMap(\.photoFiles) + coachMessages.compactMap(\.audioFile) }
    }

    /// Messages a burst can span: one check-in sent as a few messages in a row.
    static let burstGap: TimeInterval = 30 * 60
    /// At least this many of the form's labels make a message a check-in.
    static let minFields = 3
    /// Photos this close to a check-in, before or after, were sent with it.
    static let photoWindow: TimeInterval = 6 * 3600
    /// His messages this long after a check-in, and before the next one, are his reply to it.
    static let replyWindow: TimeInterval = 4 * 24 * 3600
    /// The folder under media/ the export's kept files go to.
    static let mediaFolder = "whatsapp"

    static func classify(_ messages: [ChatMessage], athlete: String, coach: String, template: CheckInTemplate) -> Result {
        let sorted = messages.enumerated().sorted { ($0.element.at, $0.offset) < ($1.element.at, $1.offset) }.map(\.element)
        var result = Result(keys: sorted.map(\.key))

        // Check-ins: runs of his text messages, close together, with no coach message between.
        var burst: [ChatMessage] = []
        func closeBurst() {
            defer { burst = [] }
            var answers: [String: String] = [:]
            var used: [ChatMessage] = []
            for message in burst {
                let found = CheckInText.answers(in: message.text, template: template)
                guard !found.isEmpty else { continue }
                used.append(message)
                answers.merge(found) { old, _ in old }
            }
            guard let first = used.first, answers.count >= minFields else { return }
            result.checkIns.append(PastCheckIn(id: first.key, sentAt: first.at, answers: answers, photoFiles: []))
            result.kept.formUnion(used.map(\.key))
        }
        for message in sorted {
            if message.sender == athlete {
                guard !message.text.isEmpty else { continue }
                if let last = burst.last, message.at.timeIntervalSince(last.at) > burstGap { closeBurst() }
                burst.append(message)
            } else {
                closeBurst()
            }
        }
        closeBurst()

        // His check-in photos: each to the nearest check-in in time, if it's close enough.
        for message in sorted where message.sender == athlete && message.attachmentKind == .photo {
            let nearest = result.checkIns.indices.min { abs(result.checkIns[$0].sentAt.timeIntervalSince(message.at)) < abs(result.checkIns[$1].sentAt.timeIntervalSince(message.at)) }
            guard let nearest, abs(result.checkIns[nearest].sentAt.timeIntervalSince(message.at)) <= photoWindow else { continue }
            result.checkIns[nearest].photoFiles.append("\(mediaFolder)/\(message.attachment!)")
            result.kept.insert(message.key)
        }

        // The coach's replies: his words or voice notes after a check-in, before the next one.
        for message in sorted where message.sender == coach && (!message.text.isEmpty || message.attachmentKind == .audio) {
            guard let checkIn = result.checkIns.last(where: { $0.sentAt < message.at }),
                  message.at.timeIntervalSince(checkIn.sentAt) <= replyWindow else { continue }
            let audio = message.attachmentKind == .audio ? "\(mediaFolder)/\(message.attachment!)" : nil
            result.coachMessages.append(CoachMessage(id: message.key, at: message.at, text: message.text, audioFile: audio, checkInId: checkIn.id))
            result.kept.insert(message.key)
        }
        return result
    }

    /// The senders in the export, most messages first, for "Which one is you?".
    static func senders(_ messages: [ChatMessage]) -> [(name: String, count: Int)] {
        Dictionary(grouping: messages, by: \.sender).map { ($0.key, $0.value.count) }
            .sorted { ($0.count, $1.name) > ($1.count, $0.name) }
    }

    /// The check-in agent's styleExamples: his own lines from the last few check-ins, one field
    /// each, numbers blanked to X like the bundled examples, so the agent copies his tone and never
    /// an old number.
    static func styleExamples(_ checkIns: [PastCheckIn], template: CheckInTemplate, last count: Int = 3) -> [String] {
        let wordy = template.orderedFields.filter { [.text, .scale10, .percent].contains($0.kind) }
        return checkIns.sorted { $0.sentAt < $1.sentAt }.suffix(count).flatMap { checkIn in
            wordy.compactMap { field -> String? in
                guard let answer = checkIn.answers[field.id], !answer.isEmpty else { return nil }
                let label = [field.label, field.prompt].compactMap { $0 }.joined(separator: " ")
                let oneLine = answer.split(separator: "\n").joined(separator: " ")
                return "\(label): \(oneLine.replacing(/\d+(?:[.,]\d+)*/, with: "X"))"
            }
        }
    }
}

/// History's trends: each body measure the coach asks for (weight, the tape measurements, fasted
/// glucose), across every check-in, past and sent from Setecho.
enum HistoryTrends {
    struct Point: Equatable { var date: Date; var value: Double }
    struct Series: Equatable, Identifiable {
        var field: FieldSpec
        var points: [Point]
        var id: String { field.id }
    }

    /// The change since the first check-in, to a tenth: "−6.2", "+0.5", "No change".
    static func delta(_ value: Double) -> String {
        let rounded = (value * 10).rounded() / 10
        if rounded == 0 { return "No change" }
        return (rounded < 0 ? "−" : "+") + Format.number(abs(rounded))
    }

    /// The form's weight, tape and glucose fields; never last check-in's weight, which repeats one.
    static func fields(_ template: CheckInTemplate) -> [FieldSpec] {
        template.orderedFields.filter { field in
            let lower = field.label.lowercased()
            return (field.kind == .measurement && field.source.key != .lastCheckInWeight && !lower.contains("last"))
                || lower.contains("glucose")
        }
    }

    /// One value per field and day: a check-in sent from Setecho and also in the export counts
    /// once, and the app's answer wins where both have one.
    static func series(template: CheckInTemplate, past: [PastCheckIn], sent: [CheckInDraft]) -> [Series] {
        var byDay: [String: (date: Date, answers: [String: String])] = [:]
        for checkIn in past { byDay[DayKey.string(checkIn.sentAt)] = (checkIn.sentAt, checkIn.answers) }
        for draft in sent {
            guard let at = draft.sentAt else { continue }
            let answers = Dictionary(draft.answers.filter { $0.state != .missing }.map { ($0.fieldId, $0.text) }) { a, _ in a }
            let day = DayKey.string(at)
            byDay[day] = (at, (byDay[day]?.answers ?? [:]).merging(answers) { _, app in app })
        }
        let days = byDay.values.sorted { $0.date < $1.date }
        return fields(template).compactMap { field in
            let points = days.compactMap { day in day.answers[field.id].flatMap(CheckInText.number).map { Point(date: day.date, value: $0) } }
            return points.isEmpty ? nil : Series(field: field, points: points)
        }
    }
}

/// The shared export: WhatsApp's zip (with `_chat.txt` and the media) or the chat text alone. The
/// share is copied into the app's temporary folder first, so its files can still be read after the
/// picker's access ends.
struct ChatExport {
    var text: String
    var zip: ZipReader?

    enum ReadError: LocalizedError {
        case noChat
        var errorDescription: String? { "There's no chat in that file. In WhatsApp, export the chat again and share the zip." }
    }

    static func read(_ url: URL, workingCopy: URL) throws -> ChatExport {
        let fm = FileManager.default
        try? fm.removeItem(at: workingCopy)
        try fm.copyItem(at: url, to: workingCopy)
        if url.pathExtension.lowercased() == "txt" {
            return ChatExport(text: try String(contentsOf: workingCopy, encoding: .utf8))
        }
        let zip = try ZipReader(url: workingCopy)
        guard let entry = zip.entry(named: "_chat.txt") ?? zip.entries.first(where: { $0.fileName.lowercased().hasSuffix(".txt") }) else {
            throw ReadError.noChat
        }
        return ChatExport(text: String(decoding: try zip.extract(entry), as: UTF8.self), zip: zip)
    }

    /// One of the export's files, written where the store keeps it.
    func copy(_ fileName: String, to destination: URL) throws {
        guard let zip, let entry = zip.entry(named: fileName) else { throw CocoaError(.fileNoSuchFile) }
        try zip.extract(entry).write(to: destination, options: [.atomic, .completeFileProtection])
    }
}
