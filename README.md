# Chalkline

A coach that remembers every rep. Photograph your coach's program, film your sets, and Chalkline measures every rep's speed and bar path, finds where your form starts to break, and remembers all of it.

Built on Meta Model API: **SAM 3.1** tracks the weight plate through each set; **Muse Spark 1.3** parses programs, reads your spoken notes, and powers the coach.

## Run it

Requirements: macOS, Xcode 26+, Homebrew.

```sh
brew install uv ffmpeg xcodegen
export MODEL_API_KEY=...            # from dev.meta.ai
make test                           # offline
make smoke                          # one live call
make dev                            # API on :8000
cp ios/Config/Local.example.xcconfig ios/Config/Local.xcconfig   # set your team id + backend URL
make ios
```
