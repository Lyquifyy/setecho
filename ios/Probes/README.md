# Probes (M0 gates, throwaway)

A separate app target, `Probes`, bundle id `com.getsetecho.probes`. It shares the design system
with the app but ships nothing. Delete it once M2 is done.

## Install on the iPhone

```sh
make ios            # regenerates the project and opens Xcode
```

In Xcode pick the **Probes** scheme and your phone, then Run. The first run asks for the
microphone, and the Health probe asks for read access to eight Health types.

## Hand tests

**G2 Audio** (phone, AirPods, DJI receiver)
1. Start Spotify on the AirPods.
2. Plug the DJI receiver into the phone. Open Probes → Audio. The Route card should show the
   receiver as the input (`usbAudio`) and the AirPods as the output (`bluetoothA2DP`).
3. Tap **Record 5 seconds** and talk. Music must stay full quality the whole time.
4. Tap **Speak test callout**. Music dips, the sentence plays, music returns to full volume.
5. Tap **Play back** to hear the recording, then **Send to Mac** (AirDrop) and run
   `uv run python -m scripts.voice_probe ~/Downloads/probe-*.wav` in `backend/`.

Pass: full-quality music throughout, a clean duck and restore, a clear transcript.
Fallback (plan): the iPhone mic, open only during rest.

**G3 Apple Health** (phone only)
1. Open Probes → Apple Health → **Read 7 days**. Allow all eight types.
2. Compare each day with MacroFactor (kcal, P/C/F), Withings (weight) and Garmin (steps, sleep).
3. Check the Sources card names the real apps.

Pass: the numbers match the source apps. Fallback: missing sleep or steps are asked by voice.

**G6 WhatsApp share** (phone only)
1. Open Probes → WhatsApp share → **Share image + text** → WhatsApp → your own chat.
2. Look at what arrived: image with the text as caption, two messages, or text dropped.
3. Try **Fallback** too, and paste the text under the photo.

Pass: both arrive in one message. Fallback: image via share sheet, text pasted from the clipboard.

Outputs you want to keep go in `ios/Probes/output/` (gitignored).
