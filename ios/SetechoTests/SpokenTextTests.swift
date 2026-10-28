import Foundation
import Testing
@testable import Setecho

/// How a line is said by the on-device voice: numbers the gym way, his rate, no repeats.

@Test func numbersReadTheWayAnAthleteSaysThem() {
    #expect(SpokenText.words("180.8") == "one eighty point eight")
    #expect(SpokenText.words("Back-off at 170, his rule.") == "Back-off at one seventy, his rule.")
    #expect(SpokenText.words("225 for 8") == "two twenty five for eight")
    #expect(SpokenText.words("Set 3 of 4") == "Set three of four")
    #expect(SpokenText.words("300") == "three hundred" && SpokenText.words("105") == "one oh five")
    #expect(SpokenText.words("2425 calories") == "two thousand four hundred twenty five calories")
    #expect(SpokenText.words("Waist 31, bicep 16, thigh 24 3/4") == "Waist thirty one, bicep sixteen, thigh twenty four and three quarters")
    #expect(SpokenText.words("6/10, energy was good") == "six out of ten, energy was good")
    #expect(SpokenText.words("100%, macros were hit") == "one hundred percent, macros were hit")
    #expect(SpokenText.words("Steps: avg 10.2k") == "Steps: avg ten thousand two hundred")
    #expect(SpokenText.words("Rest 2:30") == "Rest two thirty")
    #expect(SpokenText.words("1:05") == "one oh five" && SpokenText.words("2:00") == "two minutes")
    #expect(SpokenText.words("Glucose 91 mg/dL") == "Glucose ninety one mg/dL")
    #expect(SpokenText.words("Morning. Step on the scale.") == "Morning. Step on the scale.")
    #expect(SpokenText.words("Slowed 46 percent, that's failure. About 2 left.") == "Slowed forty six percent, that's failure. About two left.")
}

@Test func theWrittenTextIsCleanedForTheEar() {
    // The values Apple Health and the log really produce (backend checkin.py).
    #expect(SpokenText.spoken("Avg 7.2 h/night") == "average seven point two hours a night")
    #expect(SpokenText.spoken("100% (5 of 5 days on macros, 4 of 5 sessions)") == "one hundred percent, five of five days on macros, four of five sessions")
    #expect(SpokenText.spoken("100%, 5 of 5 sessions, PRs: Bench 225×8") == "one hundred percent, five of five sessions, PRs: Bench two twenty five for eight")
    #expect(SpokenText.spoken("Waist 31 in, bicep 16 in") == "Waist thirty one inches, bicep sixteen inches")
    #expect(SpokenText.spoken("Glucose 91 mg/dL") == "Glucose ninety one")
    #expect(SpokenText.spoken("Energy, 1-10?") == "Energy, one to ten?")
    #expect(SpokenText.spoken("10/19/26–10/25/26") == "October nineteenth to October twenty fifth")
    #expect(SpokenText.spoken("2400 kcal · 180 g protein") == "two thousand four hundred calories, one eighty grams protein")
    #expect(SpokenText.spoken("Rest 90 s, then 2 min LISS") == "Rest ninety seconds, then two minutes LISS")
    #expect(SpokenText.spoken("185 lbs") == "one eighty five pounds")
    // Words are left alone: "in" that isn't inches, letters that aren't units.
    #expect(SpokenText.spoken("Step in when you're ready.") == "Step in when you're ready.")
    #expect(SpokenText.spoken("Hold still, then 3 sets in the morning.") == "Hold still, then three sets in the morning.")
    #expect(SpokenText.spoken("Line one\nLine two") == "Line one. Line two")
}

@Test func theRateSliderFollowsTheMeasuredCurve() {
    #expect(SpokenText.ratePercent(0.42) == 91 && SpokenText.ratePercent(0.50) == 100 && SpokenText.ratePercent(0.55) == 129)
    #expect(abs(SpokenText.ratePercent(0.46) - 95.5) < 0.01)
    #expect(SpokenText.ratePercent(0.30) == 91 && SpokenText.ratePercent(0.9) == 129) // clamped to the slider
}

@Test func eachLineVariesALittleAndAlwaysTheSameWay() {
    let lines = (0..<200).map { "Line number \($0)?" }
    let all = lines.map(SpokenText.variation(for:))
    #expect(all.allSatisfy { (-3...3).contains($0.rate) && (-2...2).contains($0.pitch) })
    #expect(Set(all.map { "\($0.rate),\($0.pitch)" }).count > 10) // they do differ
    #expect(lines.map(SpokenText.variation(for:)).map(\.rate) == all.map(\.rate)) // and are stable
}

@Test func theLineIsSSMLWithHisRateAndPitchAndNoBreaks() {
    let text = "Apple Health has you at 180.8. Should I use that?"
    let v = SpokenText.variation(for: text)
    let tone = VoiceTone(rate: 0.50, pitch: 1.05, warmthDB: 2, clarityDB: -1)
    let ssml = SpokenText.ssml(text, tone: tone)
    let pitch = 5 + v.pitch
    #expect(ssml == "<speak><prosody rate=\"\(100 + v.rate)%\" pitch=\"\(pitch >= 0 ? "+" : "")\(pitch)%\">Apple Health has you at one eighty point eight. Should I use that?</prosody></speak>")
    #expect(!ssml.contains("break"))
    #expect(SpokenText.ssml("Waist & hips <3", tone: tone).contains("Waist and hips &lt;three")) // "&" is said; "<" is escaped
    let u = SpokenText.utterance(text, voice: nil, tone: tone)
    #expect(u.volume == 1 && u.preUtteranceDelay == 0 && u.postUtteranceDelay == 0)
}

@Test @MainActor func tonesAreSavedPerVoiceAndClamped() {
    let settings = Settings.shared
    let id = "test.voice.\(UUID().uuidString)"
    defer { settings.voiceTones[id] = nil }
    #expect(settings.tone(for: id).pitch == 1.0 && settings.tone(for: id).warmthDB == 2 && settings.tone(for: id).clarityDB == -1)
    settings.setTone(VoiceTone(rate: 0.9, pitch: 0.5, warmthDB: 10, clarityDB: -10), for: id)
    let saved = settings.tone(for: id)
    #expect(saved.rate == 0.55 && saved.pitch == 0.90 && saved.warmthDB == 6 && saved.clarityDB == -4)
    #expect(settings.tone(for: id + ".other") != saved) // another voice keeps its own
}

@Test func noLineTwiceInARow() {
    #expect(SpokenText.varied("Sorry, can you say that again?", after: nil) == "Sorry, can you say that again?")
    #expect(SpokenText.varied("Sorry, can you say that again?", after: "Sorry, can you say that again?") == "Sorry, I missed that. One more time?")
    #expect(SpokenText.varied("Fasted glucose?", after: "Fasted glucose?") == "Again, fasted glucose?")
    #expect(SpokenText.varied("Got it.", after: "Fasted glucose?") == "Got it.")
    #expect(SpokenText.withAlternates(["Got it.", "Fasted glucose?"]) == ["Got it.", "Fasted glucose?", "Okay, got it."])
}
