import test from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { mkdirSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { readFileSync, readdirSync } from 'node:fs';
import { createHash } from 'node:crypto';
const root=path.resolve(path.dirname(fileURLToPath(import.meta.url)),'..');
const java=process.env.JAVA_HOME??'/opt/homebrew/opt/openjdk@21';
test('Android production core: formatting, identity, arguments, waits, person stop and MCP framing',()=>{
  const out=path.join(root,'.build/android/offline-tests');mkdirSync(out,{recursive:true});
  const sources=['Json','Core','Protocol','Framing'].map(n=>`native-android/src/dev/opencu/android/${n}.java`);
  const compile=spawnSync(path.join(java,'bin/javac'),['--release','11','-encoding','UTF-8','-d',out,...sources,'native-android/test/dev/opencu/android/OfflineTests.java'],{cwd:root,encoding:'utf8'});
  assert.equal(compile.status,0,compile.error?.message??compile.stderr);
  const run=spawnSync(path.join(java,'bin/java'),['-cp',out,'dev.opencu.android.OfflineTests',path.join(root,'native-android/test/data')],{cwd:root,encoding:'utf8'});
  assert.equal(run.status,0,run.stderr);assert.match(run.stdout,/Android offline checks passed/);
  console.log(run.stdout.trim());
});

test('Android package manifest has the wanctl contract shape', () => {
  const pack = spawnSync(process.execPath, ['scripts/package-android.mjs'], { cwd: root, encoding: 'utf8' });
  assert.equal(pack.status, 0, pack.stderr);
  const manifest = JSON.parse(readFileSync(path.join(root, 'dist/opencu-android.json'), 'utf8'));
  assert.deepEqual(Object.keys(manifest).sort(), ['file', 'name', 'sha256', 'size', 'version']);
  assert.equal(manifest.name, 'opencu-android');
  assert.equal(manifest.file, 'opencu-android.jar');
  const jar = readFileSync(path.join(root, 'dist/opencu-android.jar'));
  assert.equal(manifest.size, jar.length);
  assert.match(manifest.sha256, /^[0-9a-f]{64}$/);
  assert.equal(manifest.sha256, createHash('sha256').update(jar).digest('hex'));
});

test('Android engine source stays app-agnostic', () => {
  const sourceRoot = path.join(root, 'native-android/src');
  const files = readdirSync(sourceRoot, {recursive: true})
    .filter(file => String(file).endsWith('.java'))
    .map(file => path.join(sourceRoot, String(file)));
  for (const file of files) {
    const source = readFileSync(file, 'utf8');
    assert.doesNotMatch(source, /com\.android\./, file);
    assert.doesNotMatch(source, /com\.coloros|com\.oplus/, file);
    assert.doesNotMatch(source, /:id\//, file);
    assert.doesNotMatch(source, /[\u3400-\u9fff]/, file);
  }
});
