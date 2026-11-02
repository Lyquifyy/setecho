#!/bin/zsh
# Records the demo video's Setup footage: the real import flow on a simulator against the live backend,
# driven by SetechoUITests/SetupRecordingTests, one .mov per step (design/handoff-nov1-setup-recording.md).
#
#   ios/scripts/record_setup.sh [simulator name or UDID] [output folder]
#
# Defaults: the "Setecho Demo" simulator (created from an iPhone 17 Pro if missing) and design/footage/setup.
# The app's data is removed first so Today opens on its first run. Needs SETECHO_API_BASE in
# ios/Config/Local.xcconfig pointing at a backend with a key: the parsing on screen is live Muse Spark.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
DEVICE=${1:-"Setecho Demo"}
OUT=${2:-"$ROOT/design/footage/setup"}
DD=${DD:-/tmp/setecho-demo-dd}
BUNDLE=com.getsetecho.app
MARKERS="$OUT/markers"

if [[ "$DEVICE" =~ ^[0-9A-F-]{36}$ ]]; then
  UDID=$DEVICE
else
  UDID=$(xcrun simctl list devices available | grep -F "$DEVICE (" | sed -E 's/.*\(([0-9A-F-]{36})\).*/\1/' | head -1)
  if [[ -z "$UDID" ]]; then
    UDID=$(xcrun simctl create "$DEVICE" com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro)
    echo "Created $DEVICE ($UDID)"
  fi
fi

xcrun simctl bootstatus "$UDID" -b >/dev/null
xcrun simctl ui "$UDID" appearance light
xcrun simctl status_bar "$UDID" override --time 9:41 --dataNetwork wifi --wifiBars 3 --cellularBars 4 \
  --batteryState charged --batteryLevel 100
xcrun simctl uninstall "$UDID" "$BUNDLE" 2>/dev/null || true

mkdir -p "$OUT/raw"
rm -rf "$MARKERS" && mkdir -p "$MARKERS"
NAMES=(01-program 02-form 03-rules 04-today)
# simctl writes a frame only when the screen changes, so a still screen at the end of a step would be cut:
# each raw clip is finished at a constant 30 fps with its last frame held this long.
STOP_HOLD=${STOP_HOLD:-3}

# One recorder per clip, in step with the test's markers (SetupRecordingTests, "Markers for the host's recorder").
recorder() {
  for n in 1 2 3 4; do
    local file="$OUT/raw/${NAMES[$n]}.mov"
    until [[ -e "$MARKERS/clip-$n.start" ]]; do sleep 0.1; done
    xcrun simctl io "$UDID" recordVideo --codec h264 --force "$file" &
    local pid=$!
    sleep 2  # the recorder takes a moment before its first frame
    touch "$MARKERS/clip-$n.recording"
    echo "[record] clip $n started -> $file"
    until [[ -e "$MARKERS/clip-$n.end" ]]; do sleep 0.1; done
    sleep 3  # a few seconds past the step's last screen
    kill -INT "$pid"
    wait "$pid" || true
    touch "$MARKERS/clip-$n.stopped"
    echo "[record] clip $n stopped"
  done
}
recorder &
RECORDER=$!
trap 'kill $RECORDER 2>/dev/null || true; xcrun simctl status_bar "$UDID" clear' EXIT

cd "$ROOT/ios"
xcodegen generate >/dev/null
TEST_RUNNER_SETUP_MARKERS="$MARKERS" xcodebuild -project Setecho.xcodeproj -scheme SetechoUITests \
  -destination "platform=iOS Simulator,id=$UDID" -derivedDataPath "$DD" -quiet \
  -only-testing:SetechoUITests/SetupRecordingTests test 2>&1 | grep -v "^$" | grep -iv "warning:" || STATUS=$?
# A build or test failure before the last marker would leave the recorder waiting: don't.
sleep 1; kill "$RECORDER" 2>/dev/null || true
rm -rf "$MARKERS"

echo
echo "Clips in $OUT:"
for name in "${NAMES[@]}"; do
  raw="$OUT/raw/$name.mov"
  f="$OUT/$name.mov"
  if [[ -e "$raw" ]]; then
    ffmpeg -v error -y -i "$raw" -vf "fps=30,tpad=stop_mode=clone:stop_duration=$STOP_HOLD" \
      -c:v libx264 -preset slow -crf 16 -pix_fmt yuv420p -movflags +faststart "$f"
  fi
  if [[ -e "$f" ]]; then
    d=$(ffprobe -v error -show_entries format=duration -of default=nw=1:nk=1 "$f" 2>/dev/null || echo "?")
    printf "  %s  %.1f s\n" "$name.mov" "$d"
  else
    echo "  $name.mov  missing"
  fi
done
exit ${STATUS:-0}
