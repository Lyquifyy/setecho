# Setecho copy for judges

Assume the reader has never followed a bodybuilding training plan. Name what the app does before introducing gym terminology.

**Headline:** Your workout, logged hands-free.

**One-sentence explanation:** Setecho is an iPhone app that records workouts, takes progress photos hands-free and prepares WhatsApp updates for athletes with a human coach.

**Coach approval:** Your coach sets the plan. Setecho proposes changes from the coach's reply, and the plan changes only after you approve.

## Terms to explain on first use

| Term | Plain-language wording |
| --- | --- |
| Prep | Preparing for a bodybuilding competition |
| Check-in | A regular progress update sent to the coach: questionnaire answers, health and workout data, photos and selected exercise videos |
| Rep | One repetition of an exercise |
| Set | A group of repetitions of an exercise |
| Load | The weight lifted |
| Back-off set | A lighter set after a heavier one |
| Macros | Protein, carbohydrates and fat |
| RIR | Estimated repetitions remaining before the athlete could do no more |
| RPE | The athlete's rating of how hard a set felt |
| Velocity loss | How much repetitions slowed during a set |
| Spotter | In Setecho's copy, a hands-free training assistant that follows the human coach's plan |

Keep the coach's imported labels and exact quotes intact. Explain them around the quote rather than rewriting their words. Prefer everyday words in presentation titles: record a workout, take progress photos, send an update, review a coach's reply, approve plan changes.

## Presentation surfaces

- Website: `github-site/` is the production source; `site/` retains the launch snapshot. Both use the same headline and explanations.
- Logo intro and video titles: `motion/src/Scenes.tsx` and `motion/src/Root.tsx`.
- Video captions: `motion/props/`. Exported overlays must be rerendered when their wording changes.
- Social preview: `../brand/build.py` generates outlined text and the PNG. Regenerate and sync both sites after changing the headline.
- README: explain the athlete, coach and progress-update workflow before implementation details.

The 40-second video is an animated overview with fictional examples. It is not the final three-minute submission demo or a recording of the app in use. Use real product footage for those claims. Numbers remain sourced from code, health data or the athlete; SAM tracks movement and code counts repetitions. Do not describe Setecho as writing its own coaching plan.
