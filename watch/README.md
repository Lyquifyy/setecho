# Setecho watch app (Garmin Venu 4, Connect IQ)

Wrist sets and reps, haptics, and messages to the phone. No network, no models (AGENTS.md rule 1).

## One-time setup (human, about an hour)
1. Install the Connect IQ SDK Manager from https://developer.garmin.com/connect-iq/sdk/, then in it
   install the newest SDK and the **Venu 4** device files (both sizes).
2. Generate a developer key outside the repo:
   `openssl genrsa -out ~/.garmin/developer_key.pem 4096 && openssl pkcs8 -topk8 -inform PEM -outform DER -in ~/.garmin/developer_key.pem -out ~/.garmin/developer_key.der -nocrypt`
3. Check the device ids the SDK uses for the Venu 4 (`ls ~/Library/Application\ Support/Garmin/ConnectIQ/Devices | grep -i venu`)
   and fix `manifest.xml` if they differ from `venu4` / `venu4s`.

## Build and run
- `make watch` builds `watch/bin/SetechoWatch.prg` with `monkeyc`.
- `make watch-sim` opens the simulator and runs it.
- Sideload: connect the watch over USB (OpenMTP on macOS if it mounts as MTP) and copy the `.prg`
  into `GARMIN/APPS`. The app appears in the activity list as Setecho.

## G8 probe (HANDOFF.md §9)
On the phone, More → Gate probes → Watch. Connect through Garmin Connect, then do three sets each of
bench press, rows and curls. The screen lists every message with its delay. Pass: messages arrive
within 3 s and the counts match your hand count.
