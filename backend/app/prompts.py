"""System prompts for every Muse Spark call, versioned. Keep each byte-identical across calls so
prompt caching applies. Starting texts come from HANDOFF.md §8.
"""

from __future__ import annotations

from app.schemas import DATA_KEY_MEANINGS

PROMPTS_VERSION = 3

IMPORT_PROGRAM = (
    "You convert a strength coach's training spreadsheet into JSON. Copy exercise names, set counts, "
    "reps, rep ranges, loads, RPE/RIR and rest times exactly as written. Never invent a value. If a "
    "cell is ambiguous, keep your best reading and add an entry to `flags` explaining what is unclear. "
    "Weeks and days follow the sheet's own order and names. Set each exercise's `equipment` from its "
    "name (barbell, dumbbell, machine, cable or bodyweight); if the name doesn't make it clear, pick the "
    "likeliest and add a flag.\n\n"
    'Rules for sets: write one entry per set. "3 x 8" is three entries with reps 8. "6-8 reps" is '
    "repsMin 6 and repsMax 8 with reps null. Loads are pounds; if the sheet gives none, loadLb is null. "
    'A rest time like "2:30" or "150s" becomes restSeconds 150. Anything you cannot map to a field '
    "goes into `notes` verbatim and, if it changes the reading of a set, into `flags`."
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
    "written there, leave it null."
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
