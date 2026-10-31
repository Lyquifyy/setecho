# Setecho — submission write-up (draft)

Paste into the Cerebral Valley form on Wed Nov 4. Keep every number traceable to `backend/scripts/evidence.py`
or the README; fill the bracketed ones from the session exports before posting.

**Tagline:** Train with your coach. Skip the paperwork.

**One line:** Setecho is an iPhone app for athletes who train under a human coach. It logs every workout from
the athlete's voice and the phone's camera, fills in the weekly check-in the coach asks for, sends it to
WhatsApp in his exact format, and turns his reply into plan changes the athlete approves.

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
- Training: the same program day, 55–68 min by hand over my last four (median 64), 53 min for 18 sets with
  Setecho, none typed. [Replace with `scripts/evidence.py` output once the weekend's exports are in.]
- Works with any coach's material: the import reads a second coach's program and form the same way.

## Use of Meta AI tooling

| Model | Role |
|---|---|
| Muse Spark 1.3 | Reads the coach's spreadsheet, form and rules into structured data (strict JSON schema); drafts the check-in with tool calls, every number traced; turns replies into proposed changes against an enumerated plan; holds the between-set and check-in-morning conversations at low reasoning effort. |
| Muse Voice Transcribe 1.0 | Hears the athlete hands-free in the gym and on check-in morning (realtime WebSocket relay through the backend, file mode as fallback), and transcribes the coach's voice notes. |
| SAM 3.1 | Tracks the weight plate, dumbbell, stack or the athlete's hands through each measured set so code can count reps and measure the slowdown. |

Every runtime model is Meta's, Standard tier. Meta has no text-to-speech, so the voice is Apple's on-device
synthesizer behind one swappable component.

## Technical depth

- **Validators between the model and the user.** A line from Spark is spoken only if every number in it is in
  the facts code computed or in the athlete's words, it gives no advice and rates nothing; a refused line is
  asked again once, then falls back to a template. The coach-reply validator keeps only changes whose quote is
  in the transcript and whose path exists in the plan; before/after values are computed by code.
- **Measurement in code:** OpenCV, NumPy and SciPy on SAM's per-frame masks with the video's real timestamps
  (iPhone video has a variable frame rate); the phone's own pose count is the silent fallback and is tested
  against the same fixtures as the backend.
- **Stateless backend** (FastAPI on Fly.io) that holds only the API key; the phone owns every record as JSON and
  media files. 730 offline backend tests on saved model output, 310 iOS tests.
- **Hands-free by design:** sets start on the athlete's word, the camera locks onto him in a busy gym, and every
  voice action is said back and undoable.

## What it can't do yet

SAM's count lands after the set, often within a minute and sometimes nearer two. It is most reliable on
plate-loaded lifts; on cables and dumbbells it can miss, and the phone's count or the athlete's spoken number
then stands. Effort is an estimate, always labelled, calibrated against spoken RPE. One athlete, one coach,
iPhone, English.

## Built during the hackathon

Every line was written between the kickoff (12:24 PM ET, Oct 26) and the deadline. [N] commits over ten days;
the README has the day-by-day timeline. Repo: https://github.com/Lyquifyy/setecho
