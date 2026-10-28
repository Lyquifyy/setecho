# Setecho — agent instructions

Setecho takes the manual work out of a coached bodybuilding prep. Sets log and count themselves, check-in photos take themselves, the WhatsApp check-in is half written before the athlete says a word, and the coach's reply updates the plan. Built for the Meta Global AI Developer Hackathon (Oct 26 – Nov 4, 2026, indie track).

Plan of record: "Setecho hackathon build plan" (Claude Docs), which holds the schedule, gates, cut list and check-in field map. If this file and the plan disagree, the plan wins.

**Read `HANDOFF.md` before building anything.** It has the architecture, API contract, Meta API details, milestones and acceptance checks. **UI work: read `DESIGN.md` first.** The design system (tokens, type, components, brand assets) is built. Build the screens listed in DESIGN.md using only those components and tokens.

## Layout
- `backend/`: Python 3.12, uv, FastAPI. Stateless: it holds the API key, measures, and returns JSON. Logs live on the phone.
  - `app/meta.py` is the ONLY module that calls Meta Model API. Nothing else imports `openai`.
  - `scripts/` holds the live probes (`smoke.py`, `sam_probe.py`). They cost money; run them deliberately.
  - `tests/fixtures/` holds saved raw SAM / Spark output. Build measurement math against these.
- `ios/`: SwiftUI, iOS 26+. XcodeGen generates the project from `ios/project.yml`; never edit the .xcodeproj.
  - `Setecho/DesignSystem/` holds the tokens, type, components, number formatting and the component gallery preview.
  - `Setecho/Assets.xcassets` holds the app icon, lockup, logo and wordmark. `TabCoach` is unused; delete it.
  - `Setecho/App/` holds placeholder tabs (Today / History / Check-in). Replace them with the real screens.
- `watch/` (stretch, P6): the Garmin watch app (Monkey C, Connect IQ) for the Venu 4. Motion, haptics and messages to the phone only. `make watch` / `make watch-sim`.
- `design/` holds the approved boards and brand files, **local only**: it's gitignored and never committed (HANDOFF §11). Read it for reference; never add it to git or link it from the README.

## Commands
- `make test`: offline backend tests. Must pass before every commit.
- `make ios-test`: iOS unit tests on the simulator.
- `make lint`: ruff.
- `make dev`: run the API on 0.0.0.0:8000.
- `make smoke`: one live call.
- `make ios`: regenerate the project and open Xcode. After adding Swift files, rerun `xcodegen generate`.

## Rules
1. Every model call goes to Meta Model API (`https://api.meta.ai/v1`): `muse-spark-1.3` for reasoning and parsing, `muse-voice-transcribe-1.0` for speech, `sam-3.1` for segmentation and tracking. Meta has no text-to-speech, so spoken lines use iOS speech, or a natural-voice service the human picks that only speaks text the app wrote (HANDOFF §7, The spotter voice). No other model providers in product code. The Garmin watch app makes no model or network calls; it talks only to the phone.
2. The key comes from the `MODEL_API_KEY` env var only. Never write keys, `.env` files or clips into the repo.
3. Use the Standard tier only. Contributor-tier data can be used by Meta, and the footage contains bystanders.
4. Tests never hit the live API. Use the fixtures in `tests/fixtures/`.
5. Numbers come from code or Apple Health, never from the model. The check-in agent gets every number through tool calls, and the backend checks each answer against its source before returning it.
6. Measurement math lives in Python (OpenCV, NumPy, SciPy), not Swift. Two exceptions run on the phone because they can't wait for the network: set detection and the fallback rep count. Keep them small, and test `RepCounter` against the same fixtures as `reps.py`.
7. Use real video timestamps for velocity; iPhone video can have a variable frame rate.
8. Commit small and often with clear messages; the commit history is part of the submission.
9. Brand: cobalt #2541D8 for actions and data sources, navy #171D36 for text, yellow #F0CD50 only for the next thing waiting on the athlete, white cards on #EEF2F9. Use the SF Pro system font with tabular numbers, and the wordmark as an image. Full rules are in `DESIGN.md`.
10. Setecho never coaches on its own authority. No form judgments, no nutrition advice, and no rules it invents. A next-set load suggestion only applies a rule the coach wrote or the athlete confirmed as his, the athlete decides, and the coach sees it in the check-in. A machine-taken swap stays within the same movement family or the coach's own alternates, a reorder stays within today's lifts and passes the fatigue check in code, and every swap and reorder reaches the coach in the check-in.
11. Apple Health is read-only, and only the types the check-in needs are requested: body mass, dietary energy, protein, carbohydrates, fat, steps, sleep and workouts. Weight can also come straight from Withings' API once it's connected (stretch); its tokens live in the Keychain and its secrets in Fly secrets, never in the repo. Check-in photos never leave the phone except in the WhatsApp send, exactly as taken; SAM does not touch them.
12. Nothing from the coach's reply changes the plan without the athlete's approval. Every change keeps his exact words, and `before`/`after` values are computed by code from the plan, never by the model.
13. Every number in a spoken line comes from code. Muse Spark only puts computed facts into words, and a validator checks every line (HANDOFF §5, `/spotter/line`).
