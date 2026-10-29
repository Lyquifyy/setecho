import CryptoKit
import Foundation

/// One message from a WhatsApp export's `_chat.txt`.
struct ChatMessage: Equatable {
    var at: Date
    var sender: String
    /// His or the athlete's words, every line of them, without the attachment marker.
    var text: String
    /// A file in the export, e.g. "00000012-PHOTO-2026-10-19-07-42-11.jpg".
    var attachment: String?
    /// Exported without media: "<Media omitted>", "image omitted".
    var mediaOmitted = false

    enum Kind { case photo, audio, video, document }

    var attachmentKind: Kind? {
        guard let attachment else { return nil }
        switch (attachment as NSString).pathExtension.lowercased() {
        case "jpg", "jpeg", "png", "heic", "webp": return .photo
        case "opus", "ogg", "m4a", "mp3", "aac", "wav": return .audio
        case "mp4", "mov", "3gp": return .video
        default: return .document
        }
    }

    /// Timestamp + sender + text (and the attachment's name, so two photos sent in one second
    /// stay two), hashed: how a re-import knows a message it has already read.
    var key: String {
        let raw = "\(Int(at.timeIntervalSince1970))|\(sender)|\(text)|\(attachment ?? "")"
        return SHA256.hash(data: Data(raw.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
    }
}

/// Reads WhatsApp's Export Chat text in code (HANDOFF.md §9, WhatsApp history import). Both iPhone
/// date styles, `[10/19/26, 7:42:11 AM]` and `[2026-10-19, 07:42:11]`, and Android's
/// `19/10/2026, 07:42 - `; a line without a timestamp continues the message above it. The day/month
/// order is read from the whole file: any first number over 12 means day first, otherwise month
/// first, the athlete's US style.
enum WhatsAppChat {
    static func parse(_ text: String, timeZone: TimeZone = .current) -> [ChatMessage] {
        struct Raw { var a: Int, b: Int, c: Int, hour: Int, minute: Int, second: Int, meridiem: Character?, body: String }
        var raws: [Raw] = []
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
        for line in lines {
            let clean = stripMarks(String(line))
            let ns = clean as NSString
            if let m = header.firstMatch(in: clean, range: NSRange(location: 0, length: ns.length)) {
                func int(_ i: Int) -> Int? {
                    let r = m.range(at: i)
                    return r.location == NSNotFound ? nil : Int(ns.substring(with: r))
                }
                let meridiemRange = m.range(at: 7)
                raws.append(Raw(a: int(1) ?? 0, b: int(2) ?? 0, c: int(3) ?? 0, hour: int(4) ?? 0, minute: int(5) ?? 0,
                                second: int(6) ?? 0,
                                meridiem: meridiemRange.location == NSNotFound ? nil : ns.substring(with: meridiemRange).lowercased().first,
                                body: ns.substring(with: m.range(at: 8))))
            } else if !raws.isEmpty {
                raws[raws.count - 1].body += "\n" + String(line)
            }
        }

        let dayFirst = raws.contains { $0.a <= 31 && $0.a > 12 }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return raws.compactMap { raw in
            var parts = DateComponents()
            if raw.a > 31 {
                (parts.year, parts.month, parts.day) = (raw.a, raw.b, raw.c)
            } else {
                parts.year = raw.c < 100 ? 2000 + raw.c : raw.c
                (parts.month, parts.day) = dayFirst ? (raw.b, raw.a) : (raw.a, raw.b)
            }
            var hour = raw.hour
            if raw.meridiem == "p", hour < 12 { hour += 12 }
            if raw.meridiem == "a", hour == 12 { hour = 0 }
            (parts.hour, parts.minute, parts.second) = (hour, raw.minute, raw.second)
            guard let at = calendar.date(from: parts) else { return nil }
            return message(at: at, body: raw.body)
        }
    }

    // MARK: Lines

    /// `[10/19/26, 7:42:11 AM] `, `[2026-10-19, 07:42:11] ` or `19/10/2026, 07:42 - `; the space
    /// before AM/PM is often a narrow no-break space.
    private static let header = try! NSRegularExpression(pattern:
        #"^\[?(\d{1,4})[./-](\d{1,2})[./-](\d{1,4}),?[\s  ]+(\d{1,2})[:.](\d{2})(?:[:.](\d{2}))?(?:[\s  ]*([AaPp])\.?[\s  ]?[Mm]\.?)?(?:\][\s ]?|\s[-–]\s)(.*)$"#)
    private static let attached = try! NSRegularExpression(pattern: #"<attached:\s*([^>]+)>"#)
    private static let androidAttached = try! NSRegularExpression(pattern: #"^(\S.*?\.[A-Za-z0-9]{2,5}) \(file attached\)"#)
    private static let omitted = try! NSRegularExpression(pattern:
        #"^(?:<media omitted>|.*\b(?:image|video|audio|sticker|gif|document|contact card) omitted)$"#, options: [.caseInsensitive])
    /// WhatsApp's own lines, not anyone's words.
    private static let systemPhrases = ["messages and calls are end-to-end encrypted", "this message was deleted",
                                        "you deleted this message", "missed voice call", "missed video call", "waiting for this message"]

    /// Directional marks and the byte-order mark WhatsApp puts before attachments and system lines.
    private static func stripMarks(_ s: String) -> String {
        String(s.unicodeScalars.filter { !["\u{200E}", "\u{200F}", "\u{202A}", "\u{202B}", "\u{202C}", "\u{FEFF}"].contains($0) })
    }

    /// "Name: words" → a message; a line with no sender ("You created group") is WhatsApp's, dropped.
    private static func message(at: Date, body: String) -> ChatMessage? {
        let body = stripMarks(body)
        guard let colon = body.range(of: ": ") else { return nil }
        let sender = body[..<colon.lowerBound].trimmingCharacters(in: .whitespaces)
        var text = String(body[colon.upperBound...])
        guard !sender.isEmpty else { return nil }
        var attachment: String?
        var ns = text as NSString
        if let m = attached.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) {
            attachment = ns.substring(with: m.range(at: 1)).trimmingCharacters(in: .whitespaces)
            text = ns.replacingCharacters(in: m.range, with: "")
        } else if let m = androidAttached.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) {
            attachment = ns.substring(with: m.range(at: 1))
            text = ns.replacingCharacters(in: m.range, with: "")
        }
        text = text.replacingOccurrences(of: "<This message was edited>", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        ns = text as NSString
        var mediaOmitted = false
        if attachment == nil, omitted.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) != nil {
            mediaOmitted = true
            text = ""
        }
        let lower = text.lowercased()
        if attachment == nil, !mediaOmitted, text.isEmpty || systemPhrases.contains(where: lower.hasPrefix) { return nil }
        return ChatMessage(at: at, sender: sender, text: text, attachment: attachment, mediaOmitted: mediaOmitted)
    }
}
