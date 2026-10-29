<p><img src="ios/Setecho/Assets.xcassets/Lockup.imageset/Lockup.svg" alt="Setecho" width="320"></p>

**The prep that logs itself.**

Setecho takes the manual work out of a coached bodybuilding prep. Import your coach's spreadsheet and check-in form once. After that:
- your sets log themselves while you train hands-free: SAM counts every rep from the video and measures how much the reps slowed, and your coach's own written rules suggest your next weight
- the two videos your coach asks for each week are the sets you flag ("flag that"), cropped to just the reps
- your check-in photos take themselves, four poses in your coach's order, hands-free
- your check-in is half written from Apple Health before you answer the rest by voice, in one hands-free conversation
- your coach's reply, a text or a voice note, updates the plan once you approve it

I built it for my own natural Classic Physique prep. The first real check-in went to my coach through Setecho on Thursday, Oct 29.

## How Setecho differs from a sports analyzer or coach

Setecho is a spotter for a human coach's plan. It measures, logs and does the paperwork. The coaching stays with the coach.

- **It never writes a plan.** The program, the check-in form and the rules for changing loads all come from the coach, imported once from his own spreadsheet, form and messages.
- **It never judges form or posing, and never gives nutrition advice.** The videos the coach asks for go to him cropped to the reps, with no verdict attached. The photos go to him exactly as taken.
- **It never coaches on its own authority.** A next-set weight is only ever the coach's own written rule applied to a measured set ("Back-off at 145, his rule: 20 to 25% lighter"), and only a rule the athlete confirmed. The athlete decides, and the coach sees every adjustment in the next check-in. A swap when a machine is taken stays within the same lift or the coach's own alternates.
- **It's engine-backed, not one prompt:**
  - **SAM 3.1** tracks the weight plates through each set's video. Code turns the track into a rep count, each rep's speed, and how much the reps slowed.
  - **A deterministic rule engine**, in code, applies the coach's written rules to that measurement: his rounding, his load steps, his limits.
  - **Muse Spark** reads the coach's material into structured data and holds the conversation. Every number it says is checked against the facts code computed before the line is used.
  - **Muse Voice Transcribe** hears the athlete hands-free in the gym and during the check-in.
- **It's used for real:** a real coach, a real program, a real week of training and a real check-in sent on WhatsApp.

## Which Meta model does what

| Model | What it does in Setecho |
|---|---|
| **Muse Spark 1.3** | Reads the coach's spreadsheet, check-in form and rules into the plan; drafts the check-in with every number traced to its source; turns each coach reply into plan changes next to his exact words; understands what the athlete says between sets and during the check-in; gives the spotter its words. |
| **Muse Voice Transcribe 1.0** | Hears the athlete hands-free during sessions and the check-in (realtime), and transcribes the coach's voice notes. |
| **SAM 3.1** | Tracks the weight plates in each measured set's video, so code can count the reps and measure how much they slowed. |

Every model the app calls at runtime is Meta's, on the Standard tier. Meta has no text-to-speech, so Setecho speaks with Apple's on-device voice. The voice is one swappable component, ready for Meta's announced custom voices. Apple Health, Apple's body-pose detection and on-device speech are OS frameworks, not model calls.

## Built during the hackathon

Every line of code in this repo was written between the kickoff (12:24 PM ET, Oct 26) and the deadline (Nov 4). The commit history is the record.

- **Oct 26:** the backend and the iOS app; importing the coach's sheet and form; the hands-free session; the photo session; the check-in draft; the backend deployed.
- **Oct 27:** SAM as the count of record, with rep speeds and the slowdown; the coach's training cycle, add-ons and rules; Check-in morning; the coach-reply loop; measured effort and the rule engine; the spotter line.
- **Oct 28:** the voice moved to Apple's on-device speech (Meta models only); the between-set conversation; fixes from the first gym test (sets start on the athlete's word, the camera follows only him, hearing him over gym noise); machine taken; the session screen.
- **Oct 29:** the first real check-in sent through Setecho.
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
