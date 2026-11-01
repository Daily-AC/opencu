import test from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { mkdirSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
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
