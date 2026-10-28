"""Numbers to words for the natural voice (HANDOFF.md §9, block 1): "180.8" → "one eighty point
eight", "24 3/4" → "twenty four and three quarters", "6/10" → "six out of ten", "91 mg/dL" → "ninety
one". Loads and weights read the way an athlete says them: "two twenty five", not "two hundred and
twenty-five". Only the digits change; every other word is left as written.
"""

from __future__ import annotations

import re

_UNITS = [
    "zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten", "eleven", "twelve",
    "thirteen", "fourteen", "fifteen", "sixteen", "seventeen", "eighteen", "nineteen",
]  # fmt: skip
_TENS = ["", "", "twenty", "thirty", "forty", "fifty", "sixty", "seventy", "eighty", "ninety"]
_FRACTIONS = {
    "1/4": "a quarter",
    "1/2": "a half",
    "3/4": "three quarters",
    "1/3": "a third",
    "2/3": "two thirds",
}


def two_digits(n: int) -> str:
    if n < 20:
        return _UNITS[n]
    tens, ones = divmod(n, 10)
    return _TENS[tens] if ones == 0 else f"{_TENS[tens]} {_UNITS[ones]}"


def integer(n: int) -> str:
    """0–99 plainly; 100–999 the gym way ("one eighty", "two twenty five", "three hundred"); larger
    numbers in full ("two thousand four hundred twenty five")."""
    if n < 0:
        return "minus " + integer(-n)
    if n < 100:
        return two_digits(n)
    if n < 1000:
        hundreds, rest = divmod(n, 100)
        if rest == 0:
            return f"{_UNITS[hundreds]} hundred"
        if rest < 10:
            return f"{_UNITS[hundreds]} oh {_UNITS[rest]}"
        return f"{_UNITS[hundreds]} {two_digits(rest)}"
    if n < 1_000_000:
        thousands, rest = divmod(n, 1000)
        head = f"{integer(thousands)} thousand"
        if rest == 0:
            return head
        if rest < 100:
            return f"{head} {two_digits(rest)}"
        hundreds, tail = divmod(rest, 100)
        return f"{head} {_UNITS[hundreds]} hundred" + (f" {two_digits(tail)}" if tail else "")
    return str(n)


def number(token: str) -> str:
    """One numeric token: "180.8" → "one eighty point eight"; "0.5" → "zero point five"."""
    if "." in token:
        whole, frac = token.split(".", 1)
        digits = " ".join(_UNITS[int(d)] for d in frac if d.isdigit())
        return f"{integer(int(whole or 0))} point {digits}".strip()
    return integer(int(token))


_TOKEN = re.compile(
    r"(?P<mixed>\b\d+ (?:1/4|1/2|3/4|1/3|2/3)\b)"  # 24 3/4
    r"|(?P<frac>\b(?:1/4|1/2|3/4|1/3|2/3)\b)"  # 3/4
    r"|(?P<scale>\b\d+(?:\.\d+)?/10\b)"  # 6/10
    r"|(?P<pct>\b\d+(?:\.\d+)?%)"  # 100%
    r"|(?P<thousands>\b\d+(?:\.\d+)?k\b)"  # 10k, 10.2k
    r"|(?P<time>\b\d{1,2}:\d{2}\b)"  # 2:30
    r"|(?P<num>\b\d+(?:\.\d+)?\b)"
)


def words(text: str) -> str:
    """Every number in `text` as words, the rest untouched."""

    def swap(m: re.Match) -> str:
        if m.group("mixed"):
            whole, frac = m.group("mixed").split(" ")
            return f"{integer(int(whole))} and {_FRACTIONS[frac]}"
        if m.group("frac"):
            return _FRACTIONS[m.group("frac")]
        if m.group("scale"):
            return f"{number(m.group('scale')[:-3])} out of ten"
        if m.group("pct"):
            return f"{number(m.group('pct')[:-1])} percent"
        if m.group("thousands"):
            value = m.group("thousands")[:-1]
            return f"{number(value)} thousand"
        if m.group("time"):
            minutes, seconds = m.group("time").split(":")
            mins = int(minutes)
            secs = int(seconds)
            head = "one minute" if mins == 1 else f"{integer(mins)} minutes"
            return (
                head
                if secs == 0
                else f"{integer(mins)} {('oh ' + _UNITS[secs]) if secs < 10 else two_digits(secs)}"
            )
        return number(m.group("num"))

    return _TOKEN.sub(swap, text)
