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
    #expect(SpokenText.words("Steps: avg 10.2k") == "Steps: avg ten point two thousand")
    #expect(SpokenText.words("Rest 2:30") == "Rest two thirty")
    #expect(SpokenText.words("1:05") == "one oh five" && SpokenText.words("2:00") == "two minutes")
    #expect(SpokenText.words("Glucose 91 mg/dL") == "Glucose ninety one mg/dL")
    #expect(SpokenText.words("Morning. Step on the scale.") == "Morning. Step on the scale.")
    #expect(SpokenText.words("Slowed 46 percent, that's failure. About 2 left.") == "Slowed forty six percent, that's failure. About two left.")
}

@Test func everyUtteranceHasHisRateAndNoDelays() {
    let u = SpokenText.utterance("Fasted glucose?", voice: nil, rate: 0.49)
    #expect(u.speechString == "Fasted glucose?") // no SSML: the voice phrases it
    #expect(abs(u.rate - 0.49) < 0.0001 && u.pitchMultiplier == 1 && u.volume == 1 && u.preUtteranceDelay == 0 && u.postUtteranceDelay == 0)
    #expect(abs(SpokenText.utterance("x", voice: nil, rate: 0.9).rate - 0.55) < 0.0001) // clamped to the slider's range
}

@Test func noLineTwiceInARow() {
    #expect(SpokenText.varied("Sorry, can you say that again?", after: nil) == "Sorry, can you say that again?")
    #expect(SpokenText.varied("Sorry, can you say that again?", after: "Sorry, can you say that again?") == "Sorry, I missed that. One more time?")
    #expect(SpokenText.varied("Fasted glucose?", after: "Fasted glucose?") == "Again, fasted glucose?")
    #expect(SpokenText.varied("Got it.", after: "Fasted glucose?") == "Got it.")
    #expect(SpokenText.withAlternates(["Got it.", "Fasted glucose?"]) == ["Got it.", "Fasted glucose?", "Okay, got it."])
}
