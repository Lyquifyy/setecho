import React from 'react';
import {AbsoluteFill, Img, Sequence, interpolate, spring, staticFile, useCurrentFrame, useVideoConfig} from 'remotion';
import brand from './brand-paths.json';
import {baseStyle, theme as t} from './theme';

const clamp = {extrapolateLeft: 'clamp', extrapolateRight: 'clamp'} as const;
const appear = (frame: number, delay = 0) => interpolate(frame, [delay, delay + 20], [0, 1], clamp);
const rise = (frame: number, delay = 0) => 24 * (1 - appear(frame, delay));
const labelStyle = {fontSize: 27, color: t.secondary, lineHeight: 1.5};
const logo = (width = 238) => <Img src={staticFile('brand/lockup.svg')} style={{width}} />;

export const LogoDraw: React.FC<{size?: number; white?: boolean}> = ({size = 240, white = false}) => {
  const frame = useCurrentFrame();
  const draw = appear(frame, 3);
  const fill = appear(frame, 30);
  const color = white ? t.surface : t.cobalt;
  return <svg width={size} height={size} viewBox={brand.viewBox} aria-label="Setecho mark" style={{overflow: 'visible'}}>
    {brand.paths.map((p, i) => <path key={i} d={p.d} transform={p.transform}
      pathLength={1} fill={color} fillOpacity={fill} stroke={color} strokeWidth={5}
      strokeLinejoin="round" strokeDasharray={1} strokeDashoffset={1 - draw} />)}
  </svg>;
};

export const TitleCard: React.FC = () => {
  const frame = useCurrentFrame();
  return <AbsoluteFill style={{...baseStyle, background: t.page, justifyContent: 'center', alignItems: 'center'}}>
    <div style={{display: 'flex', alignItems: 'center', gap: 38, marginBottom: 70}}>
      <LogoDraw size={176}/>
      <Img src={staticFile('brand/wordmark.svg')} style={{width: 630, opacity: appear(frame, 22)}}/>
    </div>
    <div style={{fontSize: 91, fontWeight: 650, letterSpacing: '-3px', opacity: appear(frame, 36), transform: `translateY(${rise(frame, 36)}px)`}}>The prep that logs itself.</div>
    <div style={{...labelStyle, marginTop: 34, opacity: appear(frame, 48)}}>Your coach’s plan. Less paperwork between you and it.</div>
    <div style={{position: 'absolute', bottom: 66, fontSize: 24, color: t.secondary, opacity: appear(frame, 52)}}>getsetecho.com</div>
  </AbsoluteFill>;
};

export type LowerThirdProps = {title: string; detail: string; preview: boolean};
export const LowerThird: React.FC<LowerThirdProps> = ({title, detail, preview}) => {
  const frame = useCurrentFrame();
  const {fps, durationInFrames} = useVideoConfig();
  const entered = spring({frame, fps, config: {damping: 25, stiffness: 160, mass: .8}});
  const out = interpolate(frame, [durationInFrames - 18, durationInFrames - 1], [1, 0], clamp);
  return <AbsoluteFill style={{...baseStyle, background: preview ? t.page : 'transparent'}}>
    {preview && <div style={{position: 'absolute', left: 112, top: 106}}>
      {logo()}
      <h1 style={{fontSize: 82, maxWidth: 1030, lineHeight: 1.05, marginTop: 105, fontWeight: 650}}>Make room for<br/>the real demo.</h1>
      <p style={{...labelStyle, maxWidth: 900}}>A reusable overlay for your gym footage,<br/>check-in recording and coach reply walkthrough.</p>
    </div>}
    <div style={{position: 'absolute', left: 112, bottom: 92, maxWidth: 1450, display: 'flex', alignItems: 'center', gap: 28,
      padding: '30px 42px 30px 30px', borderRadius: t.radius, background: t.surface,
      boxShadow: '0 14px 38px rgba(23,29,54,.10)', opacity: out,
      transform: `translateY(${(1 - entered) * 60 + (1 - out) * 24}px)`}}>
      <Img src={staticFile('brand/mark.svg')} style={{width: 68, height: 68}}/>
      <div><div style={{fontSize: 39, lineHeight: 1.15, fontWeight: 650}}>{title}</div>
      <div style={{fontSize: 27, lineHeight: 1.4, color: t.secondary, marginTop: 9}}>{detail}</div></div>
    </div>
  </AbsoluteFill>;
};

const stages = [
  {name: 'Voice', detail: 'You say the set.', icon: 'voice'},
  {name: 'Log', detail: 'The set is saved.', icon: 'log'},
  {name: 'WhatsApp\ncheck-in', detail: 'Review, then share.', icon: 'message'},
  {name: 'Coach reply', detail: 'Your coach decides.', icon: 'reply'},
  {name: 'Plan update', detail: 'Only after you approve.', icon: 'plan'},
] as const;

function StageIcon({kind, active}: {kind: string; active: boolean}) {
  const color = active ? t.cobalt : t.secondary;
  const attributes = {fill: 'none', stroke: color, strokeWidth: 2.5, strokeLinecap: 'round', strokeLinejoin: 'round'} as const;
  return <svg width={48} height={48} viewBox="0 0 48 48" {...attributes}>
    {kind === 'voice' && <><path d="M9 21v6M16 14v20M24 7v34M32 14v20M39 21v6"/></>}
    {kind === 'log' && <><rect x="10" y="7" width="28" height="34" rx="4"/><path d="m16 24 5 5 11-12M18 7v-3M30 7v-3"/></>}
    {kind === 'message' && <path d="M9 9h30v24H22L9 41V9ZM16 18h16M16 25h10"/>}
    {kind === 'reply' && <><path d="M18 13 7 24l11 11M8 24h20c8 0 12 4 12 12V16"/></>}
    {kind === 'plan' && <><rect x="8" y="7" width="32" height="34" rx="4"/><path d="M15 16h18M15 24h8m2 9 4 4 8-9"/></>}
  </svg>;
}

export const Pipeline: React.FC = () => {
  const frame = useCurrentFrame();
  // Approval is its own visible dwell before the final plan update ever activates.
  const selected = frame < 60 ? 0 : frame < 114 ? 1 : frame < 180 ? 2 : frame < 282 ? 3 : 4;
  const approval = frame >= 222 && frame < 282;
  const completed = frame >= 282;
  return <AbsoluteFill style={{...baseStyle, background: t.page, padding: '82px 100px'}}>
    {logo()}
    <h1 style={{fontSize: 80, fontWeight: 650, letterSpacing: '-2.4px', lineHeight: 1.06, margin: '76px 0 22px'}}>One less thing to carry.</h1>
    <p style={{...labelStyle, fontSize: 31, margin: 0}}>From the set you just finished to the next plan your coach writes.</p>
    <div style={{position: 'relative', display: 'flex', gap: 24, marginTop: 85}}>
      {stages.map((stage, i) => {
        const isCurrent = selected === i;
        const done = selected > i;
        return <React.Fragment key={stage.name}>
          <div style={{flex: 1, height: 252, background: t.surface, borderRadius: t.radius, padding: 28,
            border: `2px solid ${isCurrent ? t.cobalt : t.surface}`, position: 'relative',
            boxShadow: isCurrent ? '0 14px 36px rgba(23,29,54,.08)' : 'none',
            transform: `translateY(${isCurrent ? -8 : 0}px)`}}>
            <StageIcon kind={stage.icon} active={isCurrent || done}/>
            <div style={{fontSize: 32, fontWeight: 650, whiteSpace: 'pre-line', lineHeight: 1.12, marginTop: 26}}>{stage.name}</div>
            <div style={{fontSize: 22, color: t.secondary, marginTop: 16, lineHeight: 1.3}}>{stage.detail}</div>
            {done && <div style={{position: 'absolute', top: 31, right: 26, color: t.cobalt, fontSize: 24}}>✓</div>}
          </div>
          {i < stages.length - 1 && <svg width="24" height="40" viewBox="0 0 24 40" style={{flex: '0 0 24px', margin: '110px -16px 0', zIndex: 1}}>
            <path d="M2 20h18m-7-7 7 7-7 7" fill="none" stroke={done ? t.cobalt : t.border} strokeWidth="2.5"/>
          </svg>}
        </React.Fragment>;
      })}
    </div>
    <div style={{display: 'flex', alignItems: 'center', gap: 24, marginTop: 68, minHeight: 70}}>
      {approval ? <div style={{background: t.yellow, padding: '18px 26px', borderRadius: 16, fontSize: 30, fontWeight: 600}}>Waiting for your approval</div>
        : completed ? <div style={{background: t.cobaltTint, color: t.cobalt, padding: '18px 26px', borderRadius: 16, fontSize: 30, fontWeight: 600}}>Approved · plan updated</div>
        : <div style={{fontSize: 30, color: t.secondary}}>Your coach stays in charge.</div>}
      {(approval || completed) && <div style={{fontSize: 26, color: t.secondary}}>His exact words. Changes you can review and revert.</div>}
    </div>
  </AbsoluteFill>;
};

export const MetaStack: React.FC = () => {
  const frame = useCurrentFrame();
  const models = [
    ['Muse Spark 1.3', 'Understands commands, imports the coach’s material and drafts the check-in.'],
    ['Voice Transcribe 1.0', 'Turns the athlete’s speech and the coach’s voice note into text.'],
    ['SAM 3.1', 'Tracks the set; code counts reps and measures how they slow.'],
  ];
  return <AbsoluteFill style={{...baseStyle, background: t.page, padding: '82px 112px'}}>
    {logo()}
    <h1 style={{fontSize: 80, lineHeight: 1.05, fontWeight: 650, letterSpacing: '-2.4px', margin: '65px 0 48px'}}>Built on Meta AI.</h1>
    <div style={{background: t.surface, borderRadius: t.radius, padding: '10px 44px'}}>
      {models.map(([name, description], i) => <div key={name} style={{display: 'flex', alignItems: 'center', gap: 50, padding: '35px 0', borderBottom: i < 2 ? `1px solid ${t.border}` : undefined,
        opacity: appear(frame, i * 12), transform: `translateY(${rise(frame, i * 12)}px)`}}>
        <div style={{fontSize: 39, color: t.cobalt, fontWeight: 650, flex: '0 0 460px'}}>{name}</div>
        <div style={{fontSize: 28, color: t.secondary, lineHeight: 1.35, maxWidth: 850}}>{description}</div>
      </div>)}
    </div>
    <div style={{fontSize: 29, lineHeight: 1.5, marginTop: 44, color: t.secondary}}>Numbers from code, Apple Health and the athlete.<br/>Spoken output from Apple’s on-device voice. Your coach makes the decisions.</div>
    <div style={{position: 'absolute', bottom: 45, right: 112, fontSize: 20, color: t.secondary}}>Motion graphics · illustrative workflow, no athlete data</div>
  </AbsoluteFill>;
};

export const DemoGraphics: React.FC = () => <AbsoluteFill>
  <Sequence from={0} durationInFrames={120}><TitleCard/></Sequence>
  <Sequence from={120} durationInFrames={150}><LowerThird title="Hands-free set logging" detail="Say it once. Keep your hands on the workout." preview/></Sequence>
  <Sequence from={270} durationInFrames={360}><Pipeline/></Sequence>
  <Sequence from={630} durationInFrames={210}><MetaStack/></Sequence>
</AbsoluteFill>;
