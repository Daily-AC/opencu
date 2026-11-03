#!/usr/bin/env node
import { mkdir, copyFile, stat, readFile } from 'node:fs/promises';
import { createHash } from 'node:crypto';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const source = path.join(root, '.build/android/opencu-android.jar');
const output = path.join(root, 'dist');
await mkdir(output, { recursive: true });
const target = path.join(output, 'opencu-android.jar');
try { await stat(source); } catch { throw new Error('Android engine missing; run npm run build:android first'); }
await copyFile(source, target);
const bytes = await readFile(target);
const manifest = {
  name: 'opencu-android',
  version: JSON.parse(await readFile(path.join(root, 'package.json'), 'utf8')).version,
  file: 'opencu-android.jar',
  size: bytes.length,
  sha256: createHash('sha256').update(bytes).digest('hex'),
};
await import('node:fs/promises').then(fs => fs.writeFile(path.join(output, 'opencu-android.json'), JSON.stringify(manifest) + '\n'));
// The optional companion app ships beside the engine; its certificate is pinned in this jar.
const companion = path.join(root, '.build/android/opencu-companion.apk');
await copyFile(companion, path.join(output, 'opencu-companion.apk'));
console.log(`Wrote dist/opencu-android.jar, dist/opencu-android.json (${bytes.length} bytes) and dist/opencu-companion.apk`);
