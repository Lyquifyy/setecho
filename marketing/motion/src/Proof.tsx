import React from 'react';
import {AbsoluteFill, Img, interpolate, staticFile, useCurrentFrame, useVideoConfig} from 'remotion';
import {baseStyle, theme as t} from './theme';

// Video graphics built only from measured numbers (README, "What it changed in the first week").
// Every value comes in as a prop, so a newly timed run changes the JSON, never the code.

const clamp = {extrapolateLeft: 'clamp', extrapolateRight: 'clamp'} as const;
const appear = (frame: number, delay = 0) => interpolate(frame, [delay, delay + 18], [0, 1], clamp);
const rise = (frame: number, delay = 0) => 20 * (1 - appear(frame, delay));

const clock = (seconds: number) => {
  const s = Math.max(0, Math.floor(seconds));
  return `${Math.floor(s / 60)}:${String(s % 60).padStart(2, '0')}`;
};

export type TwoClocksProps = {
  /** The typed check-in, in seconds. 1500 until he times one by hand. */
  manualSeconds: number;
  /** True once a typed check-in has been timed; until then the card describes his usual one. */
  manualTimed: boolean;
  /** The spoken check-in, start to finish, in seconds (Oct 30 practice run: 7:26). */
  setechoSeconds: number;
  /** [start, duration] of each of his answers, from the filming-mode manifest. Timings only. */
  talkSegments: [number, number][];
  /** Both clocks run at this many times real time, and the graphic says so. */
  speed: number;
};

/** Seconds he had spoken by `elapsed` seconds into the check-in. */
const talkedBy = (segments: [number, number][], elapsed: number) =>
  segments.reduce((sum, [at, length]) => sum + Math.min(length, Math.max(0, elapsed - at)), 0);

const START = 24; // frames before both clocks start

export const TwoClocks: React.FC<TwoClocksProps> = ({manualSeconds, manualTimed, setechoSeconds, talkSegments, speed}) => {
  const frame = useCurrentFrame();
  const {fps} = useVideoConfig();
  const elapsed = (Math.max(0, frame - START) / fps) * speed;
  const manual = Math.min(elapsed, manualSeconds);
  const spoken = Math.min(elapsed, setechoSeconds);
  const setechoDone = elapsed >= setechoSeconds;
  const manualDone = elapsed >= manualSeconds;
  const doneAt = START + (setechoSeconds / speed) * fps;
  const manualDoneAt = START + (manualSeconds / speed) * fps;
  const talked = talkedBy(talkSegments, spoken);
  const saved = Math.floor((manualSeconds - setechoSeconds) / 60);

  const card = (accent: boolean, delay: number): React.CSSProperties => ({
    flex: 1, background: t.surface, borderRadius: t.radius, padding: '44px 52px', position: 'relative',
    border: `2px solid ${accent && setechoDone ? t.cobalt : t.surface}`,
    opacity: appear(frame, delay), transform: `translateY(${rise(frame, delay)}px)`,
  });
  const eyebrow = (color: string): React.CSSProperties => ({fontSize: 24, fontWeight: 700, letterSpacing: '2.4px', color});
  const bar = (value: number, color: string) => (
    <div style={{height: 10, borderRadius: 5, background: t.page, marginTop: 34, overflow: 'hidden'}}>
      <div style={{height: '100%', width: `${(100 * value) / manualSeconds}%`, background: color, borderRadius: 5}}/>
    </div>
  );

  return <AbsoluteFill style={{...baseStyle, background: t.page, padding: '76px 100px'}}>
    <div style={{display: 'flex', justifyContent: 'space-between', alignItems: 'center', opacity: appear(frame, 0)}}>
      <Img src={staticFile('brand/lockup.svg')} style={{width: 210}}/>
      <div style={{fontSize: 22, color: t.secondary}}>Both clocks at {speed}× speed</div>
    </div>
    <h1 style={{fontSize: 70, fontWeight: 650, letterSpacing: '-2px', lineHeight: 1.05, margin: '54px 0 48px',
      opacity: appear(frame, 4), transform: `translateY(${rise(frame, 4)}px)`}}>My weekly check-in to my coach, two ways.</h1>
    <div style={{display: 'flex', gap: 40}}>
      <div style={card(false, 8)}>
        <div style={eyebrow(t.secondary)}>BY HAND</div>
        <div style={{fontSize: 34, fontWeight: 600, marginTop: 14}}>22 questions, typed into WhatsApp</div>
        <div style={{fontSize: 210, fontWeight: 650, letterSpacing: '-6px', lineHeight: 1, marginTop: 40, color: t.navy}}>{clock(manual)}</div>
        {bar(manual, t.secondary)}
        <div style={{display: 'flex', alignItems: 'center', fontSize: 26, color: t.secondary, marginTop: 26, height: 56}}>
          {manualDone ? (manualTimed ? 'Timed on my phone' : 'Typed through my whole 25-minute cardio session') : 'Every number looked up in five apps'}
        </div>
      </div>
      <div style={card(true, 12)}>
        <div style={eyebrow(t.cobalt)}>WITH SETECHO</div>
        <div style={{fontSize: 34, fontWeight: 600, marginTop: 14}}>Answered out loud, photos included</div>
        <div style={{fontSize: 210, fontWeight: 650, letterSpacing: '-6px', lineHeight: 1, marginTop: 40, color: t.cobalt}}>{clock(spoken)}</div>
        {bar(spoken, t.cobalt)}
        <div style={{display: 'flex', alignItems: 'center', gap: 22, marginTop: 26, height: 56}}>
          <div style={{fontSize: 26, color: t.secondary}}>Me talking</div>
          <div style={{fontSize: 34, fontWeight: 650, color: t.navy}}>{clock(talked)}</div>
          {setechoDone && <div style={{marginLeft: 'auto', background: t.cobaltTint, color: t.cobalt, fontSize: 26, fontWeight: 600,
            padding: '10px 20px', borderRadius: 14, opacity: appear(frame, doneAt)}}>✓ Ready to send</div>}
        </div>
      </div>
    </div>
    <div style={{position: 'absolute', bottom: 70, left: 100, right: 100, display: 'flex', alignItems: 'baseline', justifyContent: 'space-between'}}>
      <div style={{fontSize: 52, fontWeight: 650, letterSpacing: '-1.2px', color: t.cobalt,
        opacity: appear(frame, manualDoneAt), transform: `translateY(${rise(frame, manualDoneAt)}px)`}}>{saved} minutes back, every week.</div>
      <div style={{fontSize: 21, color: t.secondary, opacity: appear(frame, 20)}}>My real data, Oct 30 · talk time from Setecho's own recording</div>
    </div>
  </AbsoluteFill>;
};

export type FirstWeekRow = {label: string; detail: string; before: number; after: number};
export type FirstWeekProps = {rows: FirstWeekRow[]};

/** "My first week" end card: before and after as bars, the time saved as a chip. */
export const FirstWeek: React.FC<FirstWeekProps> = ({rows}) => {
  const frame = useCurrentFrame();
  return <AbsoluteFill style={{...baseStyle, background: t.page, padding: '82px 112px'}}>
    <Img src={staticFile('brand/lockup.svg')} style={{width: 210, opacity: appear(frame, 0)}}/>
    <h1 style={{fontSize: 80, fontWeight: 650, letterSpacing: '-2.4px', lineHeight: 1.05, margin: '58px 0 48px',
      opacity: appear(frame, 4), transform: `translateY(${rise(frame, 4)}px)`}}>My first week with Setecho.</h1>
    <div style={{display: 'flex', flexDirection: 'column', gap: 30}}>
      {rows.map((row, i) => {
        const delay = 14 + i * 16;
        const grow = interpolate(frame, [delay + 10, delay + 46], [0, 1], {...clamp, easing: (x) => 1 - (1 - x) ** 3});
        const shown = row.before + (row.after - row.before) * grow;
        const saved = Math.floor((row.before - row.after) / 60);
        const line = (who: string, value: number, width: number, color: string, strong: boolean) =>
          <div style={{display: 'flex', alignItems: 'center', gap: 24}}>
            <div style={{flex: '0 0 190px', fontSize: 24, fontWeight: strong ? 650 : 500, color: strong ? t.cobalt : t.secondary}}>{who}</div>
            <div style={{flex: 1, height: 22, borderRadius: 11, background: t.page}}>
              <div style={{height: '100%', width: `${width}%`, borderRadius: 11, background: color}}/>
            </div>
            <div style={{flex: '0 0 150px', textAlign: 'right', fontSize: 46, fontWeight: 650, color: strong ? t.cobalt : t.secondary}}>{clock(value)}</div>
          </div>;
        return <div key={row.label} style={{display: 'flex', alignItems: 'center', gap: 48, background: t.surface, borderRadius: t.radius,
          padding: '36px 48px', opacity: appear(frame, delay), transform: `translateY(${rise(frame, delay)}px)`}}>
          <div style={{flex: '0 0 400px'}}>
            <div style={{fontSize: 38, fontWeight: 650}}>{row.label}</div>
            <div style={{fontSize: 23, color: t.secondary, marginTop: 8, lineHeight: 1.35}}>{row.detail}</div>
          </div>
          <div style={{flex: 1, display: 'flex', flexDirection: 'column', gap: 16}}>
            {line('By hand', row.before, 100, t.border, false)}
            {line('With Setecho', shown, (100 * shown) / row.before, t.cobalt, true)}
          </div>
          <div style={{flex: '0 0 250px', textAlign: 'center', whiteSpace: 'nowrap', background: t.cobaltTint, color: t.cobalt, borderRadius: 20,
            padding: '22px 0', fontSize: 34, fontWeight: 700, opacity: appear(frame, delay + 46)}}>{saved} min back</div>
        </div>;
      })}
    </div>
    <div style={{position: 'absolute', bottom: 46, left: 112, fontSize: 21, color: t.secondary, opacity: appear(frame, 30)}}>
      By hand: my own workout log and my usual check-in. With Setecho: the app's own records, Oct 30.
    </div>
  </AbsoluteFill>;
};

export type CoachQuoteProps = {quote: string; attribution: string; footnote?: string};

/** His words as text on screen, never his voice (production plan: no coach audio). */
export const CoachQuote: React.FC<CoachQuoteProps> = ({quote, attribution, footnote}) => {
  const frame = useCurrentFrame();
  return <AbsoluteFill style={{...baseStyle, background: t.page, padding: '0 220px', justifyContent: 'center'}}>
    <div style={{fontSize: 200, lineHeight: 0.6, color: t.cobalt, fontWeight: 700, opacity: appear(frame, 0)}}>“</div>
    <div style={{fontSize: 62, fontWeight: 600, letterSpacing: '-1.3px', lineHeight: 1.28, marginTop: 0, whiteSpace: 'pre-line',
      opacity: appear(frame, 6), transform: `translateY(${rise(frame, 6)}px)`}}>{quote}</div>
    <div style={{fontSize: 30, color: t.secondary, marginTop: 44, opacity: appear(frame, 22)}}>{attribution}</div>
    {footnote && <div style={{position: 'absolute', left: 220, bottom: 90, display: 'flex', alignItems: 'center', gap: 16,
      fontSize: 27, fontWeight: 600, color: t.cobalt, opacity: appear(frame, 60)}}>
      <Img src={staticFile('brand/mark.svg')} style={{width: 40, height: 40}}/>{footnote}
    </div>}
  </AbsoluteFill>;
};
