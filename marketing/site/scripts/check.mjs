import {readFileSync, existsSync} from 'node:fs';
import {resolve, dirname} from 'node:path';
import {fileURLToPath} from 'node:url';
const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const html = readFileSync(resolve(root, 'dist/index.html'), 'utf8');
const references = [...html.matchAll(/(?:src|href)="([^"]+)"/g)].map(match => match[1]);
const missing = references.filter(value => !/^(?:https?:|#)/.test(value) && !existsSync(resolve(root, 'dist', value)));
if (missing.length) throw new Error(`Missing assets: ${missing.join(', ')}`);
const ids = new Set([...html.matchAll(/\bid="([^"]+)"/g)].map(match => match[1]));
for (const ref of references.filter(value => value.startsWith('#') && value.length > 1)) {
  if (!ids.has(ref.slice(1))) throw new Error(`Broken anchor: ${ref}`);
}
for (const name of ['mark.svg', 'wordmark.svg', 'lockup.svg']) {
  const svg = readFileSync(resolve(root, 'dist/assets', name), 'utf8');
  if (/<(?:image|text)\b/.test(svg) || !svg.includes('<path')) throw new Error(`${name} must remain outlined vector geometry`);
}
if (!html.includes('synthetic') || !html.includes('prototype')) throw new Error('Keep prototype and synthetic-data disclosures.');
console.log(`Validated ${references.length} local/anchor references, vector outlines and prototype disclosures.`);
