import {copyFileSync, mkdirSync} from 'node:fs';
import {resolve, dirname} from 'node:path';
import {fileURLToPath} from 'node:url';
const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const assets = resolve(root, 'dist/assets');
mkdirSync(assets, {recursive:true});
for (const name of ['mark.svg', 'wordmark.svg', 'lockup.svg', 'favicon.ico', 'apple-touch-icon.png', 'og.png']) {
  copyFileSync(resolve(root, '../../brand/dist', name), resolve(assets, name));
}
console.log('Synced canonical brand assets.');
