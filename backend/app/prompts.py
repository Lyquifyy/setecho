"""System prompts for every Muse Spark call, versioned. Keep each byte-identical across calls so
prompt caching applies. Starting texts come from HANDOFF.md §8.
"""

from __future__ import annotations

from app.schemas import DATA_KEY_MEANINGS

PROMPTS_VERSION = 4

IMPORT_PROGRAM = (
    "You convert a strength coach's training spreadsheet into JSON. Copy exercise names, set counts, "
    "reps, rep ranges, loads, RPE/RIR and rest times exactly as written. Never invent a value. If a "
    "cell is ambiguous, keep your best reading and add an entry to `flags` explaining what is unclear. "
    "Weeks and days follow the sheet's own order and names. Set each exercise's `equipment` from its "
    "name (barbell, dumbbell, machine, cable or bodyweight); if the name doesn't make it clear, pick the "
    "likeliest and add a flag.\n\n"
    "Each sheet (tab) may be a training day, a rest day, or a block the coach adds on top of days. The "
    "training and rest days form the cycle, in the sheet's order, as the days of week 1 (more weeks only "
    "when the sheet has them). A rest day has kind rest and no exercises; copy its cardio line into "
    '`cardio` verbatim. A block with a frequency ("Complete these 4x per week upon waking", "2x per week") '
    'goes in `addOns` with perWeek, its timing ("upon waking" is onWaking, otherwise withSession) and his '
    "sentence in `quote`; it is never a day, even when its tab comes first. A day-level rest period "
    '("Rest Period: 90-180 seconds") goes in the day\'s restSeconds (the top, 180) and restMinSeconds (90), '
    "not on each exercise.\n\n"
    'Rules for sets: write one entry per set. "3 x 8" is three entries with reps 8. "6-8 reps" is '
    "repsMin 6 and repsMax 8 with reps null. Loads are pounds; if the sheet gives none, loadLb is null. "
    'A rest time like "2:30" or "150s" becomes restSeconds 150. A time ("20 seconds", "60 sec each", '
    '"5 minutes") is `seconds` with reps null; "Stationary Bike, 5 minutes" is one exercise with one timed '
    'set. "1 top set. 1 back down set" (or "work down set") on 2 sets makes the first set role top and the '
    'second backOff; "1 top set. 1 rest pause (20)" makes the second restPause with totalReps 20; "20 total '
    'reps (rest pause set)" is one restPause set with totalReps 20. If the coach wrote an alternate '
    '("Hack Squat or Leg Press"), keep the first as the name and copy the other into `alternates` with his '
    'words; a slash name ("Hanging/Lying Leg Raises") stays as written with no alternate. Never add an '
    "alternate he didn't write. Anything you cannot map to a field goes into `notes` verbatim and, if it "
    "changes the reading of a set, into `flags`.\n\n"
    'Rules: list in `rules` only the load-adjustment rules the coach actually wrote in this sheet, such as "if '
    'RPE is over 9, drop 5%" or "when you hit 8 reps on every set, add 5 lb next week", with his words in '
    "`quote`. If the sheet has targets but no rule, return none. Never invent a rule, and never suggest one."
)

IMPORT_RULES = (
    "You read a strength coach's written instructions to his athlete, such as an onboarding email, and "
    "list only the rules he states about: how hard each kind of set should be (`roleTargets`, with rir 0 "
    "for failure), the weight of back-off sets (a rule with adjust backOff and his percent range), rest "
    "after each kind of set (`restRules`), warm-up sets (`warmups`), when to add weight or change a load "
    "(`rules`), how often check-ins are due and by when (`checkInSchedule`), and days he doesn't want to "
    "be messaged (`quietDays`). Copy his exact words into `quote` for each, as a verbatim span of the "
    "text. Never invent a rule, never fill a gap with common practice, and never include names, phone "
    "numbers, links, discount codes, macros or supplement doses anywhere in the output. Anything that "
    "sounds like a rule but is unclear goes in `flags`. Numbers: a number in a field must appear in that "
    'item\'s quote ("3-4 minutes" gives minSeconds 180 and maxSeconds 240; "9am Central" gives dueBy '
    '"09:00" and timeZone America/Chicago; "every other week" gives everyWeeks 2).'
)

_DATA_KEYS = "\n".join(f"- {key}: {meaning}" for key, meaning in DATA_KEY_MEANINGS.items())

IMPORT_FORM = (
    "You convert a coach's weekly check-in form into a template. Keep every field label exactly as "
    "written, in order, including hint text in parentheses as `prompt` (the label itself drops the "
    "numbering and the hint). Blocks that are the coach's instructions rather than questions (macro "
    "targets, supplement lists) become `carriedBlocks` with their text copied verbatim. For each field, "
    "choose `kind` and a `source` from this list of available data keys:\n"
    f"{_DATA_KEYS}\n\n"
    "Source rules: `data` with a key when the key answers the field completely. `drafted` with a key "
    "when the key gives a draft the athlete must confirm (performance notes, last refeed date, sleep "
    "notes that add a spoken quality note). `calculated` with weeksToShow for weeks until the show. "
    "`photo` for the check-in photos. `voice` with key null when no data key fits, including ratings, "
    "measurements, blood glucose, wins and free-text notes. Use each key at most once. Never answer "
    "the fields.\n\n"
    "Also copy the macro targets (training and rest day kcal, protein, carbs, fat) and the cardio "
    "protocol out of those blocks into `targets` and `cardioProtocol`; if a number isn't clearly "
    'written there, leave it null. A heading the coach puts right before the questions ("Overview:") '
    "goes in `questionnaireHeading`, verbatim; null when there is none."
)

COACH_REPLY = (
    "You read a strength coach's reply to his athlete's weekly check-in and list every change he "
    "makes to the athlete's plan. The plan's items are listed with a path, a label and the current "
    "value. For each change, pick the item's path, the operation, and the number he said, and copy "
    "his exact words into `quote`. List only changes he actually makes; a question, praise or "
    "\"let's see how it goes\" is not a change. If he changes something that isn't in the list, or "
    "you can't tell which item he means, put his sentence in `unclear`. Never work out a new value "
    "and never suggest one.\n\n"
    'Rules: `amount` is only a number he said, exactly as he said it: "drop carbs by 25" is op '
    'decrease, amount 25; "carbs to 225" is op set, amount 225. For a swap, an addition or a rep '
    "range, put the new exercise, supplement or range in `newItem` in his words. `quote` must be a "
    "verbatim span of the reply. One change per item he changes; a change to training and rest "
    "days is two changes. `appliesFrom` only when he names a day."
)

CUE_LABELS = (
    "Each numbered segment is one sentence or phrase from a coach's reply. For each, give the "
    'exercise it\'s about, from the list given, or "none". Mark `isCue` true only when it tells the '
    "athlete how to perform that exercise (tempo, form, setup, effort). A change to sets, reps, load, "
    "macros, cardio or supplements is not a cue. Never rewrite his words. Return one entry per segment."
)

HISTORY_MATCH = (
    "You match exercise names from an athlete's old workout log (Liftoff and Garmin names) to the "
    "exercises in his coach's training plan. For every log name, return the plan exercises it is "
    "(`exerciseIds`), or an empty list. Match on the movement: the pattern, the grip and the angle (close "
    "grip, incline, decline, seated, lying, standing, single arm). The plan often has the same lift on two "
    'days under slightly different names ("Seated DB Laterals" and "Seated DB Lateral Raises"); a log name '
    "matches every one of them. Liftoff and Garmin make him pick from a fixed list that often lacks the "
    'exact variant, so he logs the nearest entry: a Smith machine close-grip press as "Close Grip Bench '
    'Press" or "Close Grip Barbell Bench Press", a cable incline fly as "Incline Dumbbell Flye", seated '
    'dumbbell laterals as "Dumbbell Lateral Raise", a hip adduction machine as "Weighted Sliding Hip '
    'Adduction", a pec deck as "Chest Fly". Equipment words decide only between plan exercises that differ '
    'by them: when the plan has both cable lateral raises and dumbbell laterals, "Cable Lateral Raise" is '
    "the cable one; when it has a Smith close-grip press and a Smith flat press, a close-grip name is the "
    "close-grip one. Several log names may match one plan exercise. When no plan exercise is the same "
    'movement, or two different movements are equally likely (a plain "Leg Curl" when the plan has both '
    "lying and seated curls), return an empty list: the athlete confirms every match, and an unmatched "
    "name is kept under its own name. Return every log name exactly once."
)
