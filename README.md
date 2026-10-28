<p><img src="ios/Setecho/Assets.xcassets/Lockup.imageset/Lockup.svg" alt="Setecho" width="320"></p>

**The prep that logs itself.**

Setecho takes the manual work out of a coached bodybuilding prep. Import your coach's spreadsheet and check-in form once. After that:
- your sets log themselves while you train hands-free: SAM counts every rep from the video and measures how hard each set was, and your coach's own rules suggest your next weight
- your coach's two weekly video reviews go to the sets that most need them
- your check-in photos take themselves, four poses in your coach's order, hands-free
- your check-in is half written from Apple Health before you answer the rest by voice
- your coach's reply, a text or a voice note, updates the plan once you approve it

Built on Meta Model API:
- **Muse Spark 1.3** reads the coach's material and replies, writes the check-in with every number traced to its source, turns each reply into plan changes, and gives the spotter its words.
- **Muse Voice Transcribe** runs the hands-free session and the wrap-up, and transcribes the coach's voice notes.
- **SAM 3.1** counts the reps in every set and measures how much they slowed.


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
WhatsApp share run on the phone from the `Probes` scheme; see `ios/Probes/README.md`.

`DESIGN.md` covers the design system and the screen specs. `AGENTS.md` has the repo rules.
