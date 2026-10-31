import {spawnSync} from 'node:child_process';
import {existsSync, mkdirSync} from 'node:fs';
import {resolve} from 'node:path';
mkdirSync('out', {recursive: true});
const chrome = process.env.REMOTION_BROWSER_EXECUTABLE || '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';
const browser = existsSync(chrome) ? [`--browser-executable=${chrome}`] : [];
function run(args) {
  const result = spawnSync(resolve('node_modules/.bin/remotion'), [...args, ...browser, '--concurrency=2'], {stdio: 'inherit'});
  if (result.status !== 0) process.exit(result.status ?? 1);
}
if (process.argv.includes('--stills')) {
  for (const [id, frame] of [['TitleCard', 90], ['Pipeline', 245], ['MetaStack', 90], ['TwoClocks', 70], ['TwoClocks', 299], ['FirstWeek', 149]]) {
    run(['still', 'src/index.ts', id, `out/${id}-${frame}.png`, `--frame=${frame}`]);
  }
} else {
  run(['render', 'src/index.ts', 'DemoGraphics', 'out/setecho-demo-graphics.mp4', '--codec=h264', '--crf=18']);
  for (const id of ['TitleCard', 'Pipeline', 'MetaStack', 'TwoClocks', 'FirstWeek']) {
    run(['render', 'src/index.ts', id, `out/${id}.mp4`, '--codec=h264', '--crf=18']);
  }
  // His words only once they're in props/coach-quote.json, never the placeholder.
  if (existsSync('props/coach-quote.json')) {
    run(['render', 'src/index.ts', 'CoachQuote', 'out/CoachQuote.mp4', '--codec=h264', '--crf=18', '--props=props/coach-quote.json']);
  }
  for (const [name, props] of [['logging', null], ['check-in', 'props/check-in.json'], ['coach-reply', 'props/coach-reply.json']]) {
    run(['render', 'src/index.ts', 'LowerThird', `out/lower-third-${name}.mov`, '--codec=prores', '--prores-profile=4444', '--pixel-format=yuva444p10le', '--image-format=png', ...(props ? [`--props=${props}`] : [])]);
  }
}
