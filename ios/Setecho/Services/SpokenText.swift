import AVFoundation
import Foundation

/// How a line is said by Apple's on-device voice (HANDOFF.md §7, The spotter voice): numbers as
/// words the way an athlete says them ("180.8" → "one eighty point eight", "225 for 8" → "two twenty
/// five for eight", "24 3/4" → "twenty four and three quarters", "6/10" → "six out of ten"), and a
/// different wording when the same line would come twice in a row. Only the digits change; every other word is said as written.
enum SpokenText {
    // MARK: Clean for the ear

    /// The written text, said the way a person reads it aloud (Oct 28: units, symbols and the form's
    /// shorthand came out letter by letter or stumbled): "Avg 7.2 h/night" → "average 7.2 hours a
    /// night", "100% (5 of 5 days on macros)" → "100%, 5 of 5 days on macros", "Bench 225×8" →
    /// "Bench 225 for 8", "31 in" → "31 inches", "91 mg/dL" → "91", "1-10" → "1 to 10". Only what
    /// is spoken changes; the check-in his coach reads keeps its own text.
    static func clean(_ text: String) -> String {
        var s = text
        for (pattern, template) in cleanups {
            s = s.replacingOccurrences(of: pattern, with: template, options: [.regularExpression, .caseInsensitive])
        }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// In order: symbols and layout first, then units after a number, then the form's shorthand.
    private static let cleanups: [(String, String)] = [
        (#"\s*\n+\s*"#, ". "),                               // lines become sentences
        (#"\s*[·•|]\s*"#, ", "),
        (#"\s*—\s*"#, ", "),
        (#"(\d)\s*[–-]\s*(\d)"#, "$1 to $2"),                 // 1-10, 20–25, 10/19/26–10/25/26
        (#"(\d)\s*[×x]\s*(\d)"#, "$1 for $2"),                // 225×8
        (#"\s*→\s*"#, " to "),
        (#"\s*\(\s*"#, ", "),                                // asides read as a clause
        (#"\s*\)"#, ""),
        (#"\s*&\s*"#, " and "),
        (#"\bw/\s*"#, "with "),
        (#"\s*/\s*(night|day|week|session)\b"#, " a $1"),
        (#"(\d)\s*h\b"#, "$1 hours"),
        (#"(\d)\s*hrs?\b"#, "$1 hours"),
        (#"(\d)\s*mins?\b"#, "$1 minutes"),
        (#"(\d)\s*s\b(?!\w)"#, "$1 seconds"),
        (#"(\d)\s*lbs?\b"#, "$1 pounds"),
        (#"(\d)\s*kg\b"#, "$1 kilos"),
        (#"(\d)\s*kcal\b"#, "$1 calories"),
        (#"(\d)\s*g\b"#, "$1 grams"),
        (#"(\d)\s*bpm\b"#, "$1 beats a minute"),
        (#"(\d)\s*mg/dl\b"#, "$1"),
        (#"(\d)\s*in\b(?=\s*(?:$|[,.;!?]))"#, "$1 inches"),   // "31 in", not "in the morning"
        (#"~\s*(\d)"#, "about $1"),
        (#"\bavg\b\.?"#, "average"),
        (#"\bapprox\.?(?=\s)"#, "about"),
        (#"\bvs\.?(?=\s)"#, "versus"),
        (#"\be\.g\.,?"#, "for example"),
        (#"\betc\.?"#, "and so on"),
        (#",\s*,"#, ","),
        (#"\s{2,}"#, " "),
    ]

    /// What the synthesizer is given: the cleaned text with every number as words.
    static func spoken(_ text: String) -> String { words(clean(text)) }

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

    private static let months = ["January", "February", "March", "April", "May", "June", "July", "August", "September",
                                 "October", "November", "December"]

    /// 1–31 as spoken in a date: "first", "twenty fourth", "thirtieth".
    static func ordinal(_ n: Int) -> String {
        let special = [1: "first", 2: "second", 3: "third", 5: "fifth", 8: "eighth", 9: "ninth", 12: "twelfth"]
        if let word = special[n] { return word }
        if n < 20 { return units[n] + "th" }
        let (t, o) = n.quotientAndRemainder(dividingBy: 10)
        if o == 0 { return String(tens[t].dropLast()) + "ieth" }
        return "\(tens[t]) \(ordinal(o))"
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
        #"(?<date>\b\d{1,2}/\d{1,2}/\d{2,4}\b)"#, // 10/24/26
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
                // "9.4k" → "nine thousand four hundred": how people say a step count.
                let value = (Double(k.dropLast()) ?? 0) * 1000
                out += value < 1_000_000 ? integer(Int(value.rounded())) : "\(number(String(k.dropLast()))) thousand"
            } else if let date = group("date") {
                let parts = date.split(separator: "/").compactMap { Int($0) }
                out += (1...12).contains(parts[0]) && (1...31).contains(parts[1])
                    ? "\(months[parts[0] - 1]) \(ordinal(parts[1]))" : date
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

    static let defaultRate = 0.49
    static let rateRange = 0.42...0.55

    // MARK: Prosody

    /// The rate slider as an SSML speed, from measured durations (Oct 28, on the device's synthesizer):
    /// 0.42 → 91%, 0.50 → 100%, 0.52 → 108%, 0.53 → 118%, 0.55 → 129%. An SSML utterance ignores
    /// `utterance.rate` and `pitchMultiplier` (same audio at 0.42 and 0.55), so both go into `<prosody>`.
    static let rateCurve: [(rate: Double, percent: Double)] = [(0.42, 91), (0.50, 100), (0.51, 104), (0.52, 108), (0.53, 118), (0.55, 129)]

    static func ratePercent(_ rate: Double) -> Double {
        let r = min(max(rate, rateRange.lowerBound), rateRange.upperBound)
        for (a, b) in zip(rateCurve, rateCurve.dropFirst()) where r <= b.rate {
            return a.percent + (r - a.rate) / (b.rate - a.rate) * (b.percent - a.percent)
        }
        return rateCurve.last!.percent
    }

    /// A small, steady difference per line, so a run of lines doesn't sound stamped out: speed within
    /// ±3% and pitch within ±2%, the same for the same words every time (pre-rendered files stay valid).
    static func variation(for text: String) -> (rate: Int, pitch: Int) {
        var hash: UInt64 = 0xcbf29ce484222325 // FNV-1a: stable across launches, unlike hashValue
        for byte in text.utf8 { hash = (hash ^ UInt64(byte)) &* 0x100000001b3 }
        return (Int(hash % 7) - 3, Int((hash / 7) % 5) - 2)
    }

    /// The line as SSML: numbers as words, XML escaped, one `<prosody>` with his rate and pitch plus the
    /// line's variation. No `<break>`: the voice phrases the punctuation itself (Oct 28, added pauses
    /// made every comma stall).
    static func ssml(_ text: String, tone: VoiceTone) -> String {
        let tone = tone.clamped
        let v = variation(for: text)
        let rate = Int((ratePercent(tone.rate) * (1 + Double(v.rate) / 100)).rounded())
        let pitch = Int(((tone.pitch - 1) * 100).rounded()) + v.pitch
        var escaped = ""
        for c in spoken(text) {
            switch c {
            case "&": escaped += "&amp;"
            case "<": escaped += "&lt;"
            case ">": escaped += "&gt;"
            default: escaped.append(c)
            }
        }
        return "<speak><prosody rate=\"\(rate)%\" pitch=\"\(pitch >= 0 ? "+" : "")\(pitch)%\">\(escaped)</prosody></speak>"
    }

    /// The utterance every line is spoken or rendered with: SSML with his rate and pitch, volume 1, no
    /// delay before or after. If the voice refuses the SSML, the plain words with the same rate and pitch.
    static func utterance(_ text: String, voice: AVSpeechSynthesisVoice?, tone: VoiceTone) -> AVSpeechUtterance {
        let tone = tone.clamped
        let utterance: AVSpeechUtterance
        if let ssml = AVSpeechUtterance(ssmlRepresentation: ssml(text, tone: tone)) {
            utterance = ssml
        } else {
            utterance = AVSpeechUtterance(string: spoken(text))
            utterance.rate = Float(tone.rate)
            utterance.pitchMultiplier = Float(tone.pitch)
        }
        utterance.voice = voice
        utterance.volume = 1.0
        utterance.preUtteranceDelay = 0
        utterance.postUtteranceDelay = 0
        utterance.prefersAssistiveTechnologySettings = false
        return utterance
    }

    // MARK: No line twice in a row

    /// Another way to say a fixed line, so a repeat doesn't sound like a recording.
    static let alternates: [String: String] = [
        "Sorry, can you say that again?": "Sorry, I missed that. One more time?",
        "Sorry, I didn't catch that.": "Hmm, I didn't get that.",
        "Didn't catch that. Say it again?": "Missed that. Once more?",
        "Got it.": "Okay, got it.",
        "Okay, we'll skip that one.": "No problem, skipping it.",
        "Take your time.": "No rush.",
        "Perfect, hold it right there.": "That's it, stay right there.",
        "Just hold still for a second.": "Nice and still, just a second.",
        "Step into the frame": "Come on into the frame",
        "Take a step back": "Back up just a little",
        "Move a little to your left": "A touch more to your left",
        "Move a little to your right": "A touch more to your right",
        "Welcome back. Let's pick up where we left off.": "Okay, let's keep going.",
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
    nonisolated static func render(_ text: String, voice: AVSpeechSynthesisVoice?, tone: VoiceTone, to url: URL) async -> TimeInterval? {
        await withCheckedContinuation { continuation in
            let synth = AVSpeechSynthesizer()
            let partial = url.deletingPathExtension().appendingPathExtension("part.caf") // the extension names the file type
            var file: AVAudioFile?
            var frames: AVAudioFramePosition = 0
            var rate: Double = 0
            var resumed = false
            synth.write(utterance(text, voice: voice, tone: tone)) { buffer in
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
