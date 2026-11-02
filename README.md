<p><img src="ios/Setecho/Assets.xcassets/Lockup.imageset/Lockup.svg" alt="Setecho" width="320"></p>

**Train with your coach. Skip the paperwork.**

Setecho is an iPhone app for athletes who train under a human coach, like a bodybuilder getting ready for a competition with an online coach. That kind of coaching runs on paperwork. The athlete writes down every set of every workout. Once a week they retype the whole week into the coach's questionnaire, the **check-in**: body weight, food, sleep, how training went and four progress photos. Then they send it on WhatsApp, and the coach replies with changes to the plan.

Setecho takes the paperwork away and leaves the coaching to the coach:

- **Workouts log themselves.** Say "done, twelve" between sets, or put the phone on a tripod and let it count the reps.
- **The weekly check-in fills itself** from the athlete's scale, food log and watch. The rest is answered out loud.
- **The coach's reply becomes plan changes** the athlete approves. The coach keeps his spreadsheet and his WhatsApp, and never installs anything.

<p>
<img src="docs/screens/today.png" alt="Today: the coach's day, the check-in and photos tiles, one Start session button" width="19%">
<img src="docs/screens/session-recording.png" alt="Session, recording: the lifts strip, the camera stage and the set's target" width="19%">
<img src="docs/screens/session-rest.png" alt="Session, rest: 11 reps measured, slowed 46%, the countdown and the next set" width="19%">
<img src="docs/screens/check-in-morning.png" alt="Check-in morning, done: 23 of 23 ready, the summary and Open to send" width="19%">
<img src="docs/screens/coach-reply.png" alt="Coach reply: his voice note, each change beside his exact words, Apply 3 changes" width="19%">
</p>

<sub>Today · a set recording · the rest after a measured set · check-in morning, done · the coach's reply. Rendered from the app with the repo's synthetic fixtures (`make screens`).</sub>

## For judges

Three ways in, from no setup to a phone. Every model the app calls is Meta's, and everything the tests and the replay need from the models is saved under `backend/tests/fixtures/`, so the first path needs no key and no network.

**1. No key, five minutes.** Requires [uv](https://docs.astral.sh/uv/) (`brew install uv` on macOS); it fetches Python 3.12 and the dependencies itself.

```sh
git clone https://github.com/Lyquifyy/setecho && cd setecho
make test       # 749 offline tests on saved Muse Spark, Muse Voice Transcribe and SAM 3.1 output
make replay     # SAM 3.1's saved tracks of a real set, counted by app/reps.py: no key, no network
```

`make replay` is the recorded sample run: my Smith-machine bench set from Oct 27, hand count 7, filmed on a tripod and sent through SAM 3.1 twice. Each pass is saved as the per-frame centroid of the plate SAM tracked, with the clip's real frame timestamps. The output below is what it prints today; as more real sets are saved, they appear in it automatically.

| Set | Hand count | SAM 3.1 | Rep times (s) | Rep speeds (px/s) | Velocity loss | Confidence |
|---|---|---|---|---|---|---|
| bench_smith_7_a | 7 | **7** | 8.0 · 9.4 · 11.0 · 12.2 · 14.6 · 16.6 · 18.9 | 364 · 345 · 302 · 126 · 297 · 240 · 138 | 48.2% | 0.75 |
| bench_smith_7_b | 7 | **7** | 8.0 · 9.4 · 11.0 · 12.2 · 14.6 · 16.6 · 18.9 | 363 · 345 · 302 · 125 · 300 · 239 · 140 | 47.8% | 0.75 |

Both passes count 7 of 7 and read the slowdown within half a point of each other. Rep 4 is the grind (a third of the speed of rep 1, then a recovery), and the last two reps against the first two give the 48% that the spotter line calls failure. Then read [How well it measures](#how-well-it-measures): every camera set from my real sessions, misses included, rebuilt from the raw exports by `backend/scripts/evidence.py`.

**2. Your own Meta key.** Requires macOS, Xcode 26+ and Homebrew for the phone side.

```sh
brew install uv ffmpeg xcodegen
cp backend/.env.example backend/.env    # put your key from dev.meta.ai in MODEL_API_KEY (Standard tier)
make smoke                              # one live call: lists the models, one Muse Spark reply
make dev                                # the API on http://0.0.0.0:8000, OpenAPI docs at /docs
```

Then the phone: `cp ios/Config/Local.example.xcconfig ios/Config/Local.xcconfig`, set `SETECHO_API_BASE` to your Mac's address (`http://localhost:8000` for the simulator) and your team id, and `make ios` opens the generated project in Xcode. On the first screen, "Try it with a sample coach" seeds a made-up athlete and coach and walks the whole loop against your backend; "Set up with your coach's plan" imports a coach's real material. The synthetic coach in `backend/tests/fixtures/import/` (`synthetic_program.csv`, `synthetic_form.txt`, `synthetic_rules_email.txt`) is the one the tests use; the app imports it from Files, or straight against the API:

```sh
cd backend/tests/fixtures/import
curl -s -F file=@synthetic_program.csv http://localhost:8000/import/program | head -c 600   # Muse Spark reads the sheet into a Program
curl -s -F file=@synthetic_form.txt http://localhost:8000/import/form | head -c 600        # the 22-field check-in template
```

The API has a per-address and a daily cap (`backend/app/budget.py`, HTTP 429 `{"error": "budget"}` over them); the defaults are in `.env.example`.

**3. An iPhone, no setup.**
<!-- TESTFLIGHT: replace this paragraph with the public link once Apple approves the external build (TestFlight 202611011916, the "Judges" group). Until then it stays as it is. -->
*TestFlight public link: pending Apple's Beta App Review.* Once it's live: install, tap "Try it with a sample coach" on the first screen, and the sample athlete's day, a measured set, check-in morning and the coach's reply are all there in five minutes, with no coach, no Apple Health data and no WhatsApp needed. The sample runs against the hosted backend at `https://setecho-api.fly.dev`, behind the same caps.

**Provenance.** How to check the claims above:

- **The commit history.** Every line in this repo was written between the kickoff (12:24 PM ET, Oct 26) and the deadline (Nov 4), in small commits; `git log` is the record, and [Built during the hackathon](#built-during-the-hackathon) is the day-by-day.
- **`backend/scripts/evidence.py`.** Rebuilds every table in [How well it measures](#how-well-it-measures) and [What it changed in the first week](#what-it-changed-in-the-first-week) from the raw exports: my Liftoff history and the session exports from the phone. The exports hold personal data and stay out of the repo; the script, its tests on made-up exports (`backend/tests/test_evidence.py`) and the aggregates it prints are in.
- **The saved model output in `backend/tests/fixtures/`.** Raw Muse Spark, Muse Voice Transcribe and SAM 3.1 responses, saved from live runs on synthetic inputs and on my own sets, that the tests and `make replay` run on. Tests never call the live API.
- **The video.** Each measured set in the demo is one unbroken take from the lift to the spoken count; nothing in it is staged after the fact.

**Why I built it.** I'm training for a bodybuilding competition with an online coach. Every week I typed my check-in through an entire 25-minute cardio session, and I tapped my phone between every set. I built Setecho for myself and used it for real during the hackathon: my coach's real program, a real week of training, and a real check-in sent to him through Setecho on Thursday, Oct 29.

## What it changed in the first week

| | By hand (before) | With Setecho |
|---|---|---|
| **One workout** (the same day of my program) | 55–68 min, median 64 (my last four times through it, logged in Liftoff) | 53 min for 18 sets, none of them typed: faster than any of those four, while I still kept a paper logbook beside it to check it. The next day, Day 6: 52 min for 17 sets against a 74-minute median |
| **Weekly check-in** | a whole 25-minute cardio session typing 22 questions into WhatsApp | 7 min 26 s by voice, start to finish, weigh-in and four photos included; I spoke for just over a minute of it (a practice run on my real data on Oct 30, two days into the week, so I answered 19 of the 22 fields out loud) |
| **Typing between sets** | every set, during rest | none |

<!-- EVIDENCE: replace the Setecho column with `uv run python -m scripts.evidence` output once the session
exports are in backend/private/sessions/ (HANDOFF.md §9). The Day 5 row is the Oct 30 export: 52.8 min start to
end, 2.9 min per set against 3.6 before. -->

The "before" numbers come straight from my Liftoff export. `backend/scripts/evidence.py` rebuilds this table from the raw exports, matching each Setecho session to the same program day before Setecho.

My coach replied to that first check-in with a 1:19 WhatsApp voice note. Setecho transcribed it, read it against my plan and found nothing to change. In his words, quoted with his permission:

> "Continuing to do fantastic work, man… A pound a week of fat loss, right on the money… Keep doing what we're doing, it's working."

## The thing my coach could never see

My coach programs every **top set** (the heaviest set of an exercise) to **failure**: until I can't do one more rep. Online, the only evidence he gets is my word.

With the phone on a tripod, **SAM 3.1** tracks the weight plate through the set, frame by frame. Code turns that track into a rep count and each rep's speed, then measures how much the last reps slowed against the first. Slowdown is how sports science estimates reps left in reserve ([Rodríguez-Rosell et al., 2020](https://www.uloyola.es/en/research-transfer/publications/relationship-between-velocity-loss-and-repetitions-in-reserve-in-the-bench-press-and-back-squat-exercises-article)): over about 40%, there was nothing left. Setecho calibrates that map per exercise against how hard I say each set felt (RPE, a 1–10 rating).

<!-- EVIDENCE: true only once SAM has measured a bench top set (the Nov 2 shoot). Until then, say "lines like this one (an example)". -->
So at the bench, during rest, I hear lines like this one: *"Eleven reps, measured. Slowed 46%, that's failure, his target. Back-off at 170, his rule: 20 to 25% lighter."* I say "go with it" and load the bar.

<!-- KEEP ONLY IF the measured top sets ship in the check-in (design/handoff-oct30-evening.md, item 1). -->
In the check-in, each top set goes to him with its measured reps and slowdown, in his own notes field, plus the two videos he asks for, cropped to just the reps. An honor system becomes a measurement, and he still makes every call.

## Not an analyzer, not a coach

- **An analyzer gives the athlete a verdict.** Setecho gives the coach a measurement and no verdict: no form score, no posing feedback, no program, no nutrition advice. The photos go to him exactly as taken.
- **A coach decides.** Setecho applies only rules the coach wrote or the athlete confirmed as his ("back-offs 20 to 25% lighter"). The athlete accepts or keeps his weight, and every adjustment appears in the next check-in.
- **It fits the coach's tools, not the other way round.** The program imports from his Google Sheet, the check-in goes to his WhatsApp in his exact format and order, and his replies, text or voice note, come back the same way.
- **Numbers come from code, never from a model.** Every number Muse Spark says or writes is checked against the facts code computed, Apple Health, or what the athlete said, before it is used.

## How the Meta models work together

One week, end to end:

```text
Coach's sheet, form and email ─▶ Muse Spark ─▶ program, 22-field check-in template, his rules
Phone on a tripod ─▶ SAM 3.1 tracks the plate ─▶ code: reps, rep speeds, slowdown ─▶ his rule ─▶ next weight
"Done, twelve" ─▶ Muse Voice Transcribe ─▶ Muse Spark ─▶ the set is logged
Check-in morning, talking ─▶ Voice Transcribe ─▶ Muse Spark fills the form from Apple Health + the log ─▶ WhatsApp
His reply or voice note ─▶ Voice Transcribe ─▶ Muse Spark: each change beside his words ─▶ athlete approves ─▶ plan
```

| Model | What it does in Setecho |
|---|---|
| **Muse Spark 1.3** | Reads the coach's spreadsheet, questionnaire and rules; drafts the check-in with every number traced to its source; turns the coach's replies into proposed plan changes; understands what the athlete says between sets and on check-in morning. |
| **Muse Voice Transcribe 1.0** | Hears the athlete hands-free in the gym and on check-in morning (realtime), and transcribes the coach's voice notes. |
| **SAM 3.1** | Tracks the weight plates (or, on dumbbells, cables and machines, the moving weight and hands) through each measured set, so code can count the reps and measure how much they slowed. |

Every model the app calls at runtime is Meta's, on the Standard tier. Meta has no text-to-speech, so Setecho speaks with Apple's on-device voice, one swappable component ready for Meta's announced custom voices. Apple Health, Apple's body-pose detection and on-device speech are OS frameworks, not model calls.

## What it can't do (yet)

- **SAM is slower than a rep.** Its count lands 71–111 s after the set (median 85 s over five sets). The athlete's word, or a confident phone count, covers the gap, and a late slowdown is still said during rest.
- **SAM is best so far on a barbell's plates** (two deadlift sets, one checked). Counting by the hands on dumbbells, cables and machines has missed; the phone's count or the athlete's spoken number then stands, and every correction is logged.
- **Effort is an estimate.** It's always labelled "estimated" and calibrated per exercise against spoken RPE. It never replaces the coach's eye; the two videos are there for that.
- **One athlete, one coach, iPhone, English.** Check-in photos never leave the phone except in the WhatsApp send.

## How well it measures

From the session exports so far. `backend/scripts/evidence.py` rebuilds everything here from the raw exports, misses included.

**Every set SAM 3.1 has counted** (confidence in brackets; under 0.6 is never used):

<!-- EVIDENCE: after the Nov 2 shoot, rerun `uv run python -m scripts.evidence` and paste its "Every camera set" table here. -->
| Date | Lift | Set | SAM 3.1 | Phone | Logged | Result |
|---|---|---|---|---|---|---|
| Oct 30 | Seated DB shoulder press | top | 0 (0.00) | — | 8 | missed: I said 8 |
| Oct 31 | Deadlift | top | 2 (1.00) | 5 | 2 | matched my count |
| Oct 31 | Deadlift | back-off | 4 (0.88) | — | 4 | accepted, not verified |
| Oct 31 | Chest-supported row | top | 13 (0.51) | 6 | 6 | under the bar: the phone's 6 stood, not verified |
| Oct 31 | Chest-supported row | back-off | 7 (0.71) | — | 7 | accepted, not verified |

One count is known to be wrong: 0 on the shoulder press, where I said 8. On the row SAM said 13 and the phone 6, and I didn't say which was right. Neither SAM count became my logged reps. Each miss changed the code; the changes are in the latest build and haven't been tested in a session yet:

- **The shoulder press:** SAM tracked a dumbbell sitting on the rack, which never moved, and counted 0 at confidence 0. It now keeps the object that moves and looks at my hands when nothing does.
- **The row:** SAM's look at my hands counted 13 at 0.51, under the bar, so the phone's 6 stood. That track still left "slowed 36%, failure" on the set; a track that loses to another count no longer stores its slowdown.
- **The one wrong rep count I heard** came from the phone, not SAM: its pose count said 5 on a 2-rep deadlift before SAM's 2 arrived, and I corrected it out loud. A doubtful phone count now waits for SAM.

**Effort, speed and time:**

- **Effort:** on the row's back-off set, "slowed 28%, about 2 left" matched what I felt. On the deadlifts the two slow reps read as no slowdown, which is right for a 2-rep set and useless for effort; the rule only fires from 3 reps.
- **Speed:** set end to SAM's count, median 85 s, slowest 111 s, over 5 sets. The clip reaches the phone's export in 7–9 s; the rest is the upload (3–27 s at the gym), the crop (11 s) and SAM itself (31–49 s). The phone's own count covers the gap, and a doubtful phone count now waits for SAM instead of being spoken.
- **Hearing:** end of speech to understood, median 3.0 s; 56 of 116 utterances with words became an action, the rest were questions, chat or people nearby.
- **Time:** Day 6 on Oct 31 ran 52 min for 17 working sets against a 74-minute median (61–78) for the same day in Liftoff, 32% less per set.

## Built during the hackathon

Every line of code in this repo was written between the kickoff (12:24 PM ET, Oct 26) and the deadline (Nov 4). The commit history is the record.

- **Oct 26:** the backend and the iOS app; importing the coach's sheet and form; the hands-free session; the photo session; the check-in draft; the backend deployed.
- **Oct 27:** SAM as the count of record, with rep speeds and the slowdown; the coach's training cycle, add-ons and rules; Check-in morning; the coach-reply loop; measured effort and the rule engine; the spotter line.
- **Oct 28:** the voice moved to Apple's on-device speech (Meta models only); the between-set conversation; fixes from the first gym test (sets start on the athlete's word, the camera follows only him, hearing him over gym noise); machine taken; the session screen.
- **Oct 29:** the first real check-in sent through Setecho; Withings direct; the WhatsApp history import; Liftoff and Garmin history, so Last time is real from the first session; camera sets for flyes, one-arm and bodyweight lifts.
- **Oct 30:** the first camera sets counted end to end in a real session; SAM follows the moving dumbbell and watches the hands on cables and machines; talking to it mid-set; a tighter counting clip; the slowdown said even when SAM's answer arrives late; the evidence script against the pre-Setecho baseline.
- **Oct 31:** the measured top sets reach the coach in the check-in's notes field; check-in morning fixes from a practice run (finished days only, no spoken deltas); a refused spotter reply is asked again once; a set's clip can be shared for SAM tuning; the screens in this README.
- **Nov 1 – Nov 4:** *(to fill in as it lands)*

## Run it

Requirements: macOS, Xcode 26+, Homebrew.

```sh
brew install uv ffmpeg xcodegen
export MODEL_API_KEY=...            # from dev.meta.ai
make test                           # backend, offline
make smoke                          # one live call
make dev                            # API on :8000
cp ios/Config/Local.example.xcconfig ios/Config/Local.xcconfig   # set your team id and backend URL
make ios                            # open in Xcode
make ios-test                       # iOS unit tests
```

## Deploy the backend (Fly.io)

The phone needs a public URL at the gym. The API runs as the Fly app `setecho-api` (org zander-erwin, region dfw) at `https://setecho-api.fly.dev`. To redeploy after a backend change, from `backend/`:

```sh
fly deploy
```

First-time setup on a new machine or account: `brew install flyctl`, `fly auth login`, `fly launch --copy-config --no-deploy`, then `fly secrets set MODEL_API_KEY=...` (the key never lives in the repo). The iOS build points at the URL through `SETECHO_API_BASE` in `ios/Config/Local.xcconfig`. `make testflight` archives a Release build and uploads it to TestFlight.

## Gate probes (M0)

The build started with six gates (HANDOFF.md §9). Each has a probe:

```sh
cd backend
uv run python -m scripts.voice_probe clip.wav                         # Muse Voice Transcribe smoke
uv run python -m scripts.sam_photo_probe front.jpg right.jpg back.jpg left.jpg   # G4: one person mask per photo
uv run python -m scripts.import_probe program.xlsx form.txt            # G5: Program + CheckInTemplate from Spark
```

Probe output lands in `backend/private/` (gitignored). `--fixture` copies raw model output into
`backend/tests/fixtures/`; use it only on synthetic inputs. G2 audio, G3 Apple Health and G6
WhatsApp share run on the phone from the `Probes` scheme, or in the app under Settings → Developer
(turn on Developer tools first); see `ios/Probes/README.md`.

`DESIGN.md` covers the design system and the screen specs. `AGENTS.md` has the repo rules.
