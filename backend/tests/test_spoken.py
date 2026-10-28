"""Numbers to words for the natural voice: the gym way for loads and weights, fractions for the tape."""

from app import spoken


def test_numbers_read_the_way_an_athlete_says_them():
    assert spoken.words("180.8") == "one eighty point eight"
    assert spoken.words("Back-off at 170, his rule.") == "Back-off at one seventy, his rule."
    assert spoken.words("225 for 8") == "two twenty five for eight"
    assert spoken.words("Set 3 of 4") == "Set three of four"
    assert spoken.words("300") == "three hundred" and spoken.words("105") == "one oh five"
    assert spoken.words("2425 calories") == "two thousand four hundred twenty five calories"
    assert (
        spoken.words("Waist 31, bicep 16, thigh 24 3/4")
        == "Waist thirty one, bicep sixteen, thigh twenty four and three quarters"
    )
    assert spoken.words("6/10, energy was good") == "six out of ten, energy was good"
    assert spoken.words("100%, macros were hit") == "one hundred percent, macros were hit"
    assert spoken.words("Steps: avg 10.2k") == "Steps: avg ten point two thousand"
    assert (
        spoken.words("Rest 2:30") == "Rest two thirty"
        and spoken.words("1:05") == "one oh five"
        and spoken.words("2:00") == "two minutes"
    )
    assert spoken.words("Glucose 91 mg/dL") == "Glucose ninety one mg/dL"
    assert spoken.words("Morning. Step on the scale.") == "Morning. Step on the scale."
    assert (
        spoken.words("Slowed 46 percent, that's failure. About 2 left.")
        == "Slowed forty six percent, that's failure. About two left."
    )
