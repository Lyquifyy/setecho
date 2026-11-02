# Setecho — submission write-up (draft)

Paste into the Cerebral Valley form on Wed Nov 4. Keep every number traceable to `backend/scripts/evidence.py`
or the README; fill the bracketed ones from the session exports before posting.

**Tagline:** Train with your coach. Skip the paperwork.

**One line:** Setecho is an iPhone app for athletes who train under a human coach. It logs every workout from
the athlete's voice and the phone's camera, fills in the weekly check-in the coach asks for, sends it to
WhatsApp in his exact format, and turns his reply into plan changes the athlete approves.

## The problem

Online coaching runs on paperwork. The athlete writes down every set, then once a week retypes the whole week
into the coach's questionnaire on WhatsApp: body weight, food, sleep, how training went, four progress photos.
The coach reads it and replies with changes. The coach never sees the one thing he programs for: whether the
heaviest set of each lift really went to failure.

## What Setecho does

- **Workouts log themselves.** Say "done, twelve" between sets, or put the phone on a tripod and let it count.
  SAM 3.1 tracks the weight through the set; code turns the track into a rep count, each rep's speed and how
  much the last reps slowed. During rest the athlete hears the count, the measured effort and, when the coach
  wrote a rule for it, the next weight by that rule. He says "go with it" or "keep it".
- **The weekly check-in fills itself** from the scale, the food log and the watch (through Apple Health), with
  every number carrying its source. The rest is one hands-free conversation on check-in morning, photos
  included, then three sends to WhatsApp in the coach's order.
- **The coach's reply becomes plan changes.** His WhatsApp text or voice note is shared into Setecho; each change
  appears beside his exact words; nothing changes until the athlete approves it. The coach keeps his
  spreadsheet and WhatsApp and installs nothing.

Setecho is the spotter, not the coach: no form judgments, no nutrition advice, no rules it invents. Every
number comes from code, Apple Health or the athlete's own words, never from a model.

## Impact (real use, one athlete, one coach)

- Built for my own prep and used for real during the hackathon: my coach's real program, a real week of
  training, a real check-in sent on Thursday Oct 29, and his real reply (a voice note) read by Setecho.
- Check-in: 25 minutes of typing became 7 min 26 s by voice, about 1 min of it talking (practice run, Oct 30).
- Training, two program days so far (`scripts/evidence.py`, Liftoff export against the session exports):
  Day 5, 64 min by hand over my last four (55–68), 53 min for 18 sets with Setecho; Day 6, 74 min by hand
  (61–78), 52 min for 17 sets with a six-minute conversation in the middle. Minutes per working set
  3.6 → 2.9 and 4.5 → 3.1. None typed; every set was on the record within about ten seconds of "done".
- What did not change: how long I rest. Median rest between sets was 96 s on Day 6, the same 80–120 s my
  watch recorded on four hand-logged sessions. The time came out of logging and transitions, not out of
  the training.
- What the coach sees that he couldn't before: the heaviest deadlift set has been 385 × 2 for three weeks,
  down from 385 × 5 the three weeks before; the back-off set dropped from 6 to 4. Every number is from
  the log, and the check-in says it in one line.
- Works with any coach's material: the import reads a second coach's program and form the same way.
- [Fill only if it happens: my coach's one line on the measured top sets, quoted with his permission.]
- [Fill only if it happens: a second athlete with a different coach, her program imported and one session logged hands-free.]

## Use of Meta AI tooling

| Model | Role |
|---|---|
| Muse Spark 1.3 | Reads the coach's spreadsheet, form and rules into structured data (strict JSON schema); drafts the check-in with tool calls, every number traced; turns replies into proposed changes against an enumerated plan; holds the between-set and check-in-morning conversations at low reasoning effort. |
| Muse Voice Transcribe 1.0 | Hears the athlete hands-free in the gym and on check-in morning (realtime WebSocket relay through the backend, file mode as fallback), and transcribes the coach's voice notes. |
| SAM 3.1 | Tracks the weight plate, dumbbell, stack or the athlete's hands through each measured set so code can count reps and measure the slowdown. |

Every runtime model is Meta's, Standard tier. Meta has no text-to-speech, so the voice is Apple's on-device
synthesizer behind one swappable component.

## Technical depth

- **Effort measured from video, not guessed.** SAM 3.1 tracks the moving weight (or the athlete's hands on
  dumbbells, cables and machines) frame by frame. OpenCV, NumPy and SciPy turn the track into reps, each rep's
  speed on the video's real timestamps (iPhone video has a variable frame rate) and the velocity loss between
  the first reps and the last. Velocity loss maps to reps in reserve, calibrated per exercise against the
  athlete's spoken RPE. Tracker artifacts (a rep over twice the set's median speed) are left out of the slowdown.
- **A count is used only when it's trustworthy.** SAM's confidence comes from the tracked-frame share and the
  regularity of the rep intervals; under 0.6 it is never used. In the latest build (not yet tested in a
  session), a doubtful phone count also waits for SAM, and a top-set count far from the athlete's usual is
  asked about out loud before it is stored. Every camera set so far, misses included, is in the README
  ("How well it measures").
- **Hands-free in a real gym.** Realtime Voice Transcribe through the backend, a voice detector tuned for gym
  noise, sets that start on the athlete's word, a camera that locks onto him among other people, and every
  voice action said back and undoable. A quiet mode for when a friend is talking is in the latest build, not
  yet tested in a session.
- **Validators between the model and the user.** A spoken line must carry only numbers that code computed or
  the athlete said; the coach-reply validator keeps only changes whose quote is in the transcript and whose
  path exists in the plan, with before/after values computed by code.
- **Stateless backend** (FastAPI on Fly.io) that holds only the API key; the phone owns every record as JSON and
  media files. 730 offline backend tests on saved model output, 310 iOS tests.

## What it can't do yet

SAM's count lands 71–111 s after the set (median 85 s over five sets); the athlete's word or a confident
phone count covers the gap. Five camera sets is too few to quote an accuracy rate: SAM matched one of the
two counts I checked out loud, missed the other (0 against my 8), and disagreed with the phone on a third
that nobody checked. It is best so far on a barbell's plates; counting by the hands on dumbbells, cables and
machines has missed. Effort is an estimate, always labelled and calibrated against spoken RPE. When the
earbuds dropped mid-session, the phone's microphone heard the gym and Spark answered people who weren't
talking to it; the reconnect and quiet mode for that are in the latest build, untested. One athlete, one
coach, iPhone, English.

## Built during the hackathon

Every line was written between the kickoff (12:24 PM ET, Oct 26) and the deadline. [N] commits over ten days;
the README has the day-by-day timeline. Repo: https://github.com/Lyquifyy/setecho
