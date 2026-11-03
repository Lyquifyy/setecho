# Setecho — submission write-up (draft)

Paste into the Cerebral Valley form on Wed Nov 4. Keep every number traceable to `backend/scripts/evidence.py`
or the README; fill the bracketed ones from the session exports before posting.

**Tagline:** Train with your coach. Skip the paperwork.

**Demo video (3 min):** https://youtu.be/6Q68cvNYVKc (unlisted)

**One line:** Setecho is an iPhone app for athletes who train under a human coach. It logs every workout from
the athlete's voice and the phone's camera, fills in the weekly check-in the coach asks for, sends it to
WhatsApp in his exact format, and turns his reply into plan changes the athlete approves.

## Project Description (as entered in the form, Nov 3)

I'm training for a bodybuilding competition with a coach who works with me online, so he only knows what I send him. In the gym I wrote down every set. Every week I typed him a check-in: my weight, food, sleep, training and progress photos, about 25 minutes of typing. And the one thing he programs for, whether my heaviest set of each lift really went to failure, he could never see.

Setecho is the iPhone app I built for that, in ten days, and used for real the whole time. It does three things:

1. A hands-free workout. The phone sits on a tripod. I say "done, twelve" and the set is logged; if I walk away and say "done" from across the room, it still hears me. For a filmed set, SAM 3.1 tracks the weight through every rep and code counts them and measures how much the last reps slowed, which is how sports science estimates reps in reserve. During rest the app says the count back ("Set 1, was that 11?" when it isn't sure), then the measured result: 11 reps, slowed 45%, failure. My coach's own rule sets the next weight. I never touch my phone.

2. An easy way to send my data back and forth with my coach. On check-in day I just talk to it. It fills in what it can from my scale, food log and watch through Apple Health, shows where every number came from, takes my four progress photos, and sends the check-in to WhatsApp in his exact format and order. 25 minutes of typing became about seven, and I'm only talking for one of them.

3. His reply becomes plan changes. He answers on WhatsApp, with text or a voice note; I share it into Setecho and each change shows up next to his exact words. Nothing changes until I approve it. He doesn't have to install anything.

Setecho never coaches. No form judgments, no nutrition advice, no rules it invents. Every number comes from code, Apple Health or my own words, never from a model, and a validator checks every spoken line.

Everything in the demo video is real: my coach's program, a real week of training, the check-in I sent him on Oct 29, his 1:19 voice-note reply on Oct 30 ("Keep doing what we're doing, it's working"), and one unbroken take of the measured bench top set on Nov 2. The first week's numbers: a workout that took 64 minutes by hand took 53 with Setecho; the weekly check-in went from 25:00 to 7:26. backend/scripts/evidence.py rebuilds every number from the raw exports, and the README's "For judges" section reruns SAM's measurement of a real set with no key and no network. 749 offline backend tests, 335 iOS tests, 250+ commits.

## Describe your use of Meta products (as entered)

Every model the app calls at runtime is Meta's, through Meta Model API on the Standard tier. In the video's words: Muse Spark reads and writes, Voice Transcribe listens, SAM measures.

Muse Spark 1.3 reads my coach's spreadsheet, check-in form and rules once (any coach's: the import is tested on a second coach's material) into structured data with a strict JSON schema. On check-in day it drafts the 22-field check-in through tool calls, so every number is traced to Apple Health or the log, and writes it in his format. It reads his replies, text or voice note, into proposed plan changes against the enumerated plan, with the before and after values computed by code. It also holds the between-set and check-in-morning conversations at low reasoning effort, behind a validator that refuses any spoken line carrying a number code didn't compute (one retry, then a template line).

Muse Voice Transcribe 1.0 hears me hands-free in the gym and on check-in morning through a realtime WebSocket relay on the backend (file mode as the fallback), and transcribes the coach's voice notes before Spark reads them.

SAM 3.1 tracks the weight plate, dumbbell, stack or my hands through each filmed set. OpenCV, NumPy and SciPy turn the track into reps, each rep's speed on the video's real timestamps, and the velocity loss between the first and the last reps. A count under 0.6 confidence is never used; the phone asks me instead.

Meta has no text-to-speech, so the spoken voice is Apple's on-device synthesizer behind one swappable component. Apple Health, Apple's body-pose detection and on-device speech are OS frameworks, not model calls. The backend (FastAPI on Fly.io) is stateless and holds only the API key, behind per-address and daily spend caps; the phone owns every record. Raw Muse Spark, Voice Transcribe and SAM 3.1 outputs from live runs are saved under backend/tests/fixtures/, so the tests and `make replay` run with no key.

## Why are Meta's models important to your solution? (as entered)

Because each of the three does something I could not do any other way, and together they close a loop my coach and I had been running on paperwork.

SAM 3.1 turns an honor system into a measurement. My coach programs every top set to failure, and online he had only my word for it. A phone on a tripod, SAM tracking the plate frame by frame, and code reading the slowdown gives him a number instead: on the set in the video, 11 reps, slowed 45%. No pose model or hand-written heuristic I tried came close on a loaded bar.

Muse Voice Transcribe is what makes the session hands-free. Zero taps, with earbuds or not, in gym noise, with people talking nearby. Realtime transcription is what lets a set end on the word "done" and the count be said back within seconds, even from across the room.

Muse Spark is the reader and writer that fits into the coach's world instead of replacing it. It reads whatever spreadsheet, form and rules he already uses, writes the check-in in his exact format with every number cited, and reads his replies, text or voice, into changes I approve. Because every number it says or writes is checked against code or Apple Health before it is used, I trusted it with my real prep and my real coach from the third day.

One API for all three also kept the project honest about provenance: the raw model outputs are saved in the repo, the judges can rerun the measurement without a key, and the video is unbroken takes of the real thing.

---

The earlier draft follows, for the numbers and tables.

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
- The demo video's measured set is real: on Nov 2 the Smith bench top set came back from SAM 3.1 as 11 reps,
  slowed 45%, the count I had confirmed out loud, in one unbroken take.

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
  media files. 749 offline backend tests on saved model output, 335 iOS tests.

## What it can't do yet

SAM's count lands 71–111 s after the set (median 75 s over seven sets); the athlete's word or a confident
phone count covers the gap. Seven camera sets is too few to quote an accuracy rate: SAM matched two of the
three counts I checked out loud (a deadlift top set and the Smith bench top set in the video), missed the
other (0 against my 8), and disagreed with the phone on a fourth that nobody checked. It is best so far on a barbell's plates; counting by the hands on dumbbells, cables and
machines has missed. Effort is an estimate, always labelled and calibrated against spoken RPE. When the
earbuds dropped mid-session, the phone's microphone heard the gym and Spark answered people who weren't
talking to it; the reconnect and quiet mode for that are in the latest build, untested. One athlete, one
coach, iPhone, English.

## Built during the hackathon

Every line was written between the kickoff (12:24 PM ET, Oct 26) and the deadline. Over 250 commits in ten days;
the README has the day-by-day timeline. Repo: https://github.com/Lyquifyy/setecho
