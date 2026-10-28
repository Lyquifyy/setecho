import AVFoundation
import Foundation

/// How a line is said by Apple's on-device voice (HANDOFF.md §7, The spotter voice): numbers as
/// words the way an athlete says them ("180.8" → "one eighty point eight", "225 for 8" → "two twenty
/// five for eight", "24 3/4" → "twenty four and three quarters", "6/10" → "six out of ten"), short
/// pauses between clauses through SSML, and a different wording when the same line would come twice
/// in a row. Only the digits change; every other word is said as written.
enum SpokenText {
    // MARK: Numbers as words

    private static let units = ["zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten", "eleven",
                                "twelve", "thirteen", "fourteen", "fifteen", "sixteen", "seventeen", "eighteen", "nineteen"]
    private static let tens = ["", "", "twenty", "thirty", "forty", "fifty", "sixty", "seventy", "eighty", "ninety"]
    private static let fractions = ["1/4": "a quarter", "1/2": "a half", "3/4": "three quarters", "1/3": "a third", "2/3": "two thirds"]

    static func twoDigits(_ n: Int) -> String {
        if n < 20 { return units[n] }
        let (t, o) = n.quotientAndRemainder(dividingBy: 10)
        return o == 0 ? tens[t] : "\(tens[t]) \(units[o])"
    }

    /// 0–99 plainly; 100–999 the gym way ("one eighty", "two twenty five", "one oh five", "three
    /// hundred"); larger numbers in full ("two thousand four hundred twenty five").
    static func integer(_ n: Int) -> String {
        if n < 0 { return "minus " + integer(-n) }
        if n < 100 { return twoDigits(n) }
        if n < 1000 {
            let (h, rest) = n.quotientAndRemainder(dividingBy: 100)
            if rest == 0 { return "\(units[h]) hundred" }
            if rest < 10 { return "\(units[h]) oh \(units[rest])" }
            return "\(units[h]) \(twoDigits(rest))"
        }
        if n < 1_000_000 {
            let (th, rest) = n.quotientAndRemainder(dividingBy: 1000)
            let head = "\(integer(th)) thousand"
            if rest == 0 { return head }
            if rest < 100 { return "\(head) \(twoDigits(rest))" }
            let (h, tail) = rest.quotientAndRemainder(dividingBy: 100)
            return "\(head) \(units[h]) hundred" + (tail > 0 ? " \(twoDigits(tail))" : "")
        }
        return String(n)
    }

    /// One numeric token: "180.8" → "one eighty point eight"; "0.5" → "zero point five".
    static func number(_ token: String) -> String {
        let parts = token.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
        let whole = integer(Int(parts[0]) ?? 0)
        guard parts.count == 2 else { return whole }
        let digits = parts[1].compactMap(\.wholeNumberValue).map { units[$0] }.joined(separator: " ")
        return "\(whole) point \(digits)"
    }

    private static let token = try! NSRegularExpression(pattern: [
        #"(?<mixed>\b\d+ (?:1/4|1/2|3/4|1/3|2/3)\b)"#, // 24 3/4
        #"(?<frac>\b(?:1/4|1/2|3/4|1/3|2/3)\b)"#, // 3/4
        #"(?<scale>\b\d+(?:\.\d+)?/10\b)"#, // 6/10
        #"(?<pct>\b\d+(?:\.\d+)?%)"#, // 100%
        #"(?<thousands>\b\d+(?:\.\d+)?k\b)"#, // 10k, 9.4k
        #"(?<time>\b\d{1,2}:\d{2}\b)"#, // 2:30
        #"(?<num>\b\d+(?:\.\d+)?\b)"#,
    ].joined(separator: "|"))

    /// Every number in `text` as words, the rest untouched.
    static func words(_ text: String) -> String {
        let ns = text as NSString
        var out = ""
        var last = 0
        for match in token.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: last, length: match.range.location - last))
            func group(_ name: String) -> String? {
                let r = match.range(withName: name)
                return r.location == NSNotFound ? nil : ns.substring(with: r)
            }
            if let mixed = group("mixed") {
                let parts = mixed.split(separator: " ")
                out += "\(integer(Int(parts[0]) ?? 0)) and \(fractions[String(parts[1])] ?? "")"
            } else if let frac = group("frac") {
                out += fractions[frac] ?? frac
            } else if let scale = group("scale") {
                out += "\(number(String(scale.dropLast(3)))) out of ten"
            } else if let pct = group("pct") {
                out += "\(number(String(pct.dropLast()))) percent"
            } else if let k = group("thousands") {
                out += "\(number(String(k.dropLast()))) thousand"
            } else if let time = group("time") {
                let parts = time.split(separator: ":").compactMap { Int($0) }
                let (mins, secs) = (parts[0], parts[1])
                if secs == 0 {
                    out += mins == 1 ? "one minute" : "\(integer(mins)) minutes"
                } else {
                    out += "\(integer(mins)) " + (secs < 10 ? "oh \(units[secs])" : twoDigits(secs))
                }
            } else if let num = group("num") {
                out += number(num)
            }
            last = match.range.location + match.range.length
        }
        out += ns.substring(from: last)
        return out
    }

    // MARK: Pauses

    /// Pauses on top of the voice's own: 250 ms after a clause, a little more between sentences,
    /// never longer than 400 ms.
    static let clausePause = "250ms"
    static let sentencePause = "350ms"

    /// The line as SSML: numbers as words, XML escaped, a break after each clause and sentence.
    static func ssml(_ text: String) -> String {
        var out = ""
        let chars = Array(words(text))
        for (i, c) in chars.enumerated() {
            // Escaped as it goes, so the ";" of "&amp;" is never taken for a clause.
            switch c {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            default: out.append(c)
            }
            let next: Character? = i + 1 < chars.count ? chars[i + 1] : nil
            guard next == " " else { continue }
            if ".?!".contains(c) {
                out += "<break time=\"\(sentencePause)\"/>"
            } else if ",;:—".contains(c) {
                out += "<break time=\"\(clausePause)\"/>"
            }
        }
        return "<speak>\(out)</speak>"
    }

    static let defaultRate = 0.49
    static let rateRange = 0.42...0.55

    /// The utterance every line is spoken or rendered with: SSML when the voice accepts it, the plain
    /// words otherwise; his rate, pitch and volume at 1, no delay before or after.
    static func utterance(_ text: String, voice: AVSpeechSynthesisVoice?, rate: Double) -> AVSpeechUtterance {
        let utterance = AVSpeechUtterance(ssmlRepresentation: ssml(text)) ?? AVSpeechUtterance(string: words(text))
        utterance.voice = voice
        utterance.rate = Float(min(max(rate, rateRange.lowerBound), rateRange.upperBound))
        utterance.pitchMultiplier = 1.0
        utterance.volume = 1.0
        utterance.preUtteranceDelay = 0
        utterance.postUtteranceDelay = 0
        utterance.prefersAssistiveTechnologySettings = false
        return utterance
    }

    // MARK: No line twice in a row

    /// Another way to say a fixed line, so a repeat doesn't sound like a recording.
    static let alternates: [String: String] = [
        "Sorry, say that again?": "Sorry, one more time?",
        "Didn't catch that. Say it again?": "Missed that. Once more?",
        "Got it.": "Okay.",
        "Got it": "Okay",
        "Skipped.": "Skipping that one.",
        "Take your time.": "No rush.",
        "Hold it there.": "Right there.",
        "Hold still for a second.": "Stay still, just a second.",
        "Step into frame": "Come into the frame",
        "Step back a little": "Back a touch",
        "Move left": "A bit left",
        "Move right": "A bit right",
        "Welcome back.": "Back again.",
    ]

    /// `text`, unless it is exactly the line just said: then its alternate, or "Again, …" for a
    /// question asked twice.
    static func varied(_ text: String, after last: String?) -> String {
        guard text == last else { return text }
        if let alternate = alternates[text] { return alternate }
        guard let first = text.first else { return text }
        return "Again, " + first.lowercased() + text.dropFirst()
    }

    /// Each fixed line and its alternate, for pre-rendering.
    static func withAlternates(_ lines: [String]) -> [String] {
        lines + lines.compactMap { alternates[$0] }
    }

    // MARK: Rendering

    /// Render the line with the voice to a CAF file, off the speaking path; returns its seconds.
    nonisolated static func render(_ text: String, voice: AVSpeechSynthesisVoice?, rate: Double, to url: URL) async -> TimeInterval? {
        await withCheckedContinuation { continuation in
            let synth = AVSpeechSynthesizer()
            let partial = url.deletingPathExtension().appendingPathExtension("part.caf") // the extension names the file type
            var file: AVAudioFile?
            var frames: AVAudioFramePosition = 0
            var rate: Double = 0
            var resumed = false
            synth.write(utterance(text, voice: voice, rate: rate)) { buffer in
                _ = synth // held until the last buffer
                guard let pcm = buffer as? AVAudioPCMBuffer, !resumed else { return }
                if pcm.frameLength == 0 {
                    resumed = true
                    file = nil // closes it
                    let ok = rate > 0 && frames > 0 && (try? FileManager.default.moveItem(at: partial, to: url)) != nil
                    continuation.resume(returning: ok ? Double(frames) / rate : nil)
                    return
                }
                if file == nil {
                    try? FileManager.default.removeItem(at: partial)
                    file = try? AVAudioFile(forWriting: partial, settings: pcm.format.settings, commonFormat: pcm.format.commonFormat,
                                            interleaved: pcm.format.isInterleaved)
                    rate = pcm.format.sampleRate
                }
                try? file?.write(from: pcm)
                frames += AVAudioFramePosition(pcm.frameLength)
            }
        }
    }
}
