import {readFile, copyFile, mkdir, writeFile} from 'node:fs/promises';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const source = path.resolve(root, '../../brand/dist');
const destination = path.join(root, 'public/brand');
await mkdir(destination, {recursive: true});
for (const name of ['mark.svg', 'wordmark.svg', 'lockup.svg']) {
  await copyFile(path.join(source, name), path.join(destination, name));
}
// Canonical path geometry only. No font dependency or hand-redrawn logo in the renderer.
const svg = await readFile(path.join(source, 'mark.svg'), 'utf8');
const viewBox = /viewBox="([^"]+)"/.exec(svg)?.[1];
const paths = [...svg.matchAll(/<path\b([^>]+)>/g)].map((match) => {
  const attributes = Object.fromEntries([...match[1].matchAll(/([\w-]+)="([^"]*)"/g)].map((x) => [x[1], x[2]]));
  return {d: attributes.d, transform: attributes.transform ?? ""};
});
if (!viewBox || !paths.length || paths.some((p) => !p.d)) throw new Error('Canonical brand mark must contain a viewBox and outlined paths. Run brand generation first.');
await writeFile(path.join(root, 'src/brand-paths.json'), JSON.stringify({viewBox, paths}, null, 2) + '\n');
console.log('Synced canonical SVG geometry and wordmark from brand/dist.');
