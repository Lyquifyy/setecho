<p><img src="ios/Setecho/Assets.xcassets/Lockup.imageset/Lockup.svg" alt="Setecho" width="320"></p>

**Your workout, logged hands-free.**

Setecho is an iPhone app for bodybuilding athletes who follow a human coach's training plan. It records workouts, takes progress photos hands-free and prepares updates to send the coach on WhatsApp.

A **check-in** is that regular progress update: answers to the coach's questionnaire, health and workout data, photos and selected exercise videos. A **rep** is one repetition of an exercise; a **set** is a group of repetitions.

Import your coach's training spreadsheet and check-in questionnaire once. After that:
- **Record workouts hands-free.** With the phone on a tripod, SAM tracks movement in video so code can count repetitions and measure their speed. Away from the camera, say the weight and repetitions you completed.
- **Use your coach's rules for the next weight.** Code applies the coach's confirmed adjustment rules. You decide whether to accept a suggestion.
- **Select exercise videos for review.** Say "flag that" to mark a recorded set for your coach. The two selected videos are trimmed to the exercise repetitions.
- **Take progress photos hands-free.** The phone captures four poses in your coach's order, keeping the photos exactly as taken.
- **Prepare your progress update.** Apple Health and your workout log fill parts of the questionnaire. Answer the remaining questions by voice, then review the message and photos before sending them through WhatsApp.
- **Apply your coach's changes after reviewing them.** Import a text or voice message, see each proposed change beside the coach's exact words, and approve what goes into the plan.

I built it while preparing for a bodybuilding competition in the natural Classic Physique category. The first real progress update went to my coach through Setecho on Thursday, Oct 29.

## Your coach makes the decisions

Setecho records training and handles the paperwork around a human coach's plan. The coach decides what the athlete should do.

- **It never writes a plan.** The program, the check-in form and the rules for changing loads all come from the coach, imported once from his own spreadsheet, form and messages.
- **It never judges form or posing, and never gives nutrition advice.** The videos the coach asks for go to him cropped to the reps, with no verdict attached. The photos go to him exactly as taken.
- **Weight suggestions follow the coach's rules.** A next-set weight comes only from a confirmed rule, such as "make the next set 20 to 25% lighter." The athlete decides, and the coach sees every adjustment in the next check-in. If equipment is occupied, any suggested substitute stays within the same movement family or the coach's own alternatives.
- **Code calculates and checks the numbers:**
  - **SAM 3.1** tracks the weight plates through each set's video. Code turns the track into a rep count, each rep's speed, and how much the reps slowed.
  - **A rule engine**, written in code, applies the coach's written rules to that measurement: how to round weights, how much to change them and which limits to respect.
  - **Muse Spark** reads the coach's material into structured data and holds the conversation. Every number it says is checked against the facts code computed before the line is used.
  - **Muse Voice Transcribe** hears the athlete hands-free in the gym and during the check-in.
- **It's used for real:** a real coach, a real program, a real week of training and a real check-in sent on WhatsApp.

## Which Meta model does what

| Model | What it does in Setecho |
|---|---|
| **Muse Spark 1.3** | Reads the coach's spreadsheet, questionnaire and rules; drafts progress updates with numbers traced to their sources; proposes plan changes from the coach's replies; understands spoken requests and phrases the app's responses. |
| **Muse Voice Transcribe 1.0** | Hears the athlete hands-free during sessions and the check-in (realtime), and transcribes the coach's voice notes. |
| **SAM 3.1** | Tracks the weight plates in each measured set's video, so code can count the reps and measure how much they slowed. |

Every model the app calls at runtime is Meta's, on the Standard tier. Meta has no text-to-speech, so Setecho speaks with Apple's on-device voice. The voice is one swappable component, ready for Meta's announced custom voices. Apple Health, Apple's body-pose detection and on-device speech are OS frameworks, not model calls.

## Built during the hackathon

Every line of code in this repo was written between the kickoff (12:24 PM ET, Oct 26) and the deadline (Nov 4). The commit history is the record.

- **Oct 26:** the backend and the iOS app; importing the coach's sheet and form; the hands-free session; the photo session; the check-in draft; the backend deployed.
- **Oct 27:** SAM as the count of record, with rep speeds and the slowdown; the coach's training cycle, add-ons and rules; Check-in morning; the coach-reply loop; measured effort and the rule engine; the spotter line.
- **Oct 28:** the voice moved to Apple's on-device speech (Meta models only); the between-set conversation; fixes from the first gym test (sets start on the athlete's word, the camera follows only him, hearing him over gym noise); machine taken; the session screen.
- **Oct 29:** the first real check-in sent through Setecho; Withings direct; the WhatsApp history import; Liftoff and Garmin history, so Last time is real from the first session.
- **Oct 30 – Nov 4:** *(to fill in as it lands)*


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
