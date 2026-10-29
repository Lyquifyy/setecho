# Product

<!-- impeccable:product-schema 1 -->

## Platform

ios

## Users

One athlete in a coached bodybuilding prep, training alone in a busy commercial gym, with a human coach who writes his program and reads a weekly WhatsApp check-in. During a session his hands are on a bar or dumbbells and his phone stands on a tripod 2–3 m away, facing him from the bench. He glances at it between reps and during rest, under gym lighting, with music in his AirPods. Mornings he also does a spoken check-in and four check-in photos at home.

## Product Purpose

Setecho takes the manual work out of a coached prep: sets log and count themselves, check-in photos take themselves, the WhatsApp check-in is half written before he says a word, and the coach's reply updates the plan once he approves it. Success in a session is that he lifts, talks and listens, and never has to check on it.

## Positioning

Setecho is the spotter, not the coach. It counts and measures every set (Meta SAM 3.1 on the phone's video), applies only the coach's own rules, and talks with him like a training partner (Muse Spark, on-device Apple speech). Every number comes from code, Apple Health or what he said, never from a model.

## Operating Context

- Session: hands-free, full-screen, zero taps after Start (a long press ends it). He arms a set by voice ("go"), lifts, says "done, 9" or lets the camera end it, and rests. The plan moves only when he moves.
- The screen is read from 2–3 m and must answer at a glance: where he is in today's plan, whether he's being heard, and what the last set measured.
- Audio: AirPods (or a DJI receiver) as the mic; the phone's own mic far away on the tripod is a known failure.
- Built for the Meta Global AI Developer Hackathon (Oct 26 – Nov 4, 2026); a demo video films the session screen (Camera A).

## Capabilities and Constraints

- Every runtime model is Meta's (Muse Spark, Voice Transcribe, SAM 3.1); speech is Apple's on-device voice.
- Never coaches on its own authority: no form, food or programming advice; suggestions apply the coach's confirmed rules and the athlete decides.
- Every voice action is said back and can be undone.
- Light mode only. The hands-free screens are half dark by design (Oct 29): his camera or a navy stage on top, a white sheet below. Never a dark theme.

## Brand Commitments

- Name Setecho; the wordmark is an image, never typed in a serif.
- Cobalt #2541D8 for actions and data sources, navy #171D36 for text, yellow #F0CD50 only for the next thing waiting on the athlete, white cards on #EEF2F9. SF Pro with tabular numbers.
- On the session screen the athlete asked to keep: the day's lifts across the very top (short names, a dot per set), and what's connected for audio.

## Evidence on Hand

- His real program sheet and coach instructions are private (backend/private/, gitignored); the app ships no real athlete numbers. Demo numbers in previews are synthetic.

## Product Principles

- He drives, Setecho follows: nothing moves on a timer or a guess.
- The ear carries the session; the screen is for a glance from the bench.
- Every number shows where it came from.
- The coach's plan stays the coach's plan.
- Not a generic fitness app and not a chat app: the lift leads, and talking shows as a live voice indicator, not message bubbles (as in Check-in morning).

## Accessibility & Inclusion

Readable from 2–3 m: nothing on the hands-free screens below 22 pt; every state named in text, never by colour alone; tap targets 44 pt; Reduce Motion respected.
