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
  const sources=['Json','Core','Protocol','Framing','Arguments'].map(n=>`native-android/src/dev/opencu/android/${n}.java`);
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

import os from 'node:os';
import { rmSync, writeFileSync } from 'node:fs';
const androidJar=path.join(process.env.ANDROID_HOME??process.env.ANDROID_SDK_ROOT??path.join(os.homedir(),'Library/Android/sdk'),'platforms/android-34/android.jar');
const androidMockJar=path.join(path.dirname(androidJar),'optional/android.test.mock.jar');
const hostClasspath=[androidJar,androidMockJar].join(path.delimiter);
const javaFiles=dir=>readdirSync(dir,{recursive:true}).filter(f=>String(f).endsWith('.java')).map(f=>path.join(dir,String(f)));

test('Android engine host checks: decisions run against a scripted phone', () => {
  const out=path.join(root,'.build/android/engine-tests');
  rmSync(out,{recursive:true,force:true});mkdirSync(out,{recursive:true});
  writeFileSync(path.join(out,'BuildInfo.java'),'package dev.opencu.android; public final class BuildInfo { public static final String VERSION = "host-test"; public static final String COMPANION_CERT = ""; }\n');
  const sources=[...javaFiles(path.join(root,'native-android/src')),...javaFiles(path.join(root,'native-android/test/host')),
    path.join(root,'native-android/test/dev/opencu/android/EngineTests.java'),path.join(out,'BuildInfo.java')];
  const compile=spawnSync(path.join(java,'bin/javac'),['--release','11','-encoding','UTF-8','-nowarn','-XDsuppressNotes','-cp',hostClasspath,'-d',out,...sources],{cwd:root,encoding:'utf8'});
  assert.equal(compile.status,0,compile.error?.message??compile.stderr);
  const run=spawnSync(path.join(java,'bin/java'),['-cp',`${out}${path.delimiter}${hostClasspath}`,'dev.opencu.android.EngineTests'],{cwd:root,encoding:'utf8',timeout:180000});
  assert.equal(run.status,0,run.stdout+run.stderr);
  assert.match(run.stdout,/Android engine host checks passed: \d+/);
  console.log(run.stdout.trim());
});

import { mkdtempSync, copyFileSync } from 'node:fs';
/** Runs a copy of the launcher against the local fake adb; no device or adb is involved. */
function launchWithFakeAdb(env, args=[]) {
  const dir=mkdtempSync(path.join(os.tmpdir(),'opencu-launch-'));
  try {
    mkdirSync(path.join(dir,'native-android'),{recursive:true});mkdirSync(path.join(dir,'.build/android'),{recursive:true});
    copyFileSync(path.join(root,'native-android/launcher.mjs'),path.join(dir,'native-android/launcher.mjs'));
    writeFileSync(path.join(dir,'.build/android/opencu-android.jar'),'synthetic engine bytes; never executed');
    const device=path.join(dir,'device');mkdirSync(device);
    const r=spawnSync(process.execPath,[path.join(dir,'native-android/launcher.mjs'),...args],{input:'',encoding:'utf8',timeout:30000,
      env:{...process.env,ANDROID_SERIAL:'',ADB:path.join(root,'native-android/test/launcher/fake-adb.mjs'),FAKE_ADB_ROOT:device,...env}});
    const calls=readFileSync(path.join(device,'calls.jsonl'),'utf8').trim().split('\n').map(line=>JSON.parse(line));
    return {...r,calls};
  } finally { rmSync(dir,{recursive:true,force:true}); }
}

test('Android launcher sends every adb call of one launch to one device', () => {
  const r=launchWithFakeAdb({FAKE_ADB_SERIAL:'phone-1',FAKE_ADB_STAT:'2000 644 regular file'});
  assert.equal(r.status,0,r.stderr);
  assert.match(r.stdout,/"launched"/);
  const [first,...later]=r.calls;
  assert.deepEqual(first,['get-serialno']);
  assert.ok(later.length>=3,JSON.stringify(r.calls));
  for(const call of later)assert.deepEqual(call.slice(0,2),['-s','phone-1'],JSON.stringify(call));
  const given=launchWithFakeAdb({FAKE_ADB_STAT:'2000 644 regular file'},['--serial','phone-2']);
  assert.equal(given.status,0,given.stderr);
  for(const call of given.calls)assert.deepEqual(call.slice(0,2),['-s','phone-2'],JSON.stringify(call));
});

test('Android launcher refuses a cached engine jar that shell does not own exclusively', () => {
  for(const stat of ['2000 666 regular file','2000 664 regular file','0 644 regular file','2000 644 symbolic link','2000 4644 regular file','2000 755 regular file','']){
    const r=launchWithFakeAdb({FAKE_ADB_SERIAL:'phone-1',FAKE_ADB_STAT:stat});
    assert.notEqual(r.status,0,`launched with "${stat}"`);
    assert.doesNotMatch(r.stdout,/launched/,stat);
    assert.match(r.stderr.split('\n')[0],/^UNSAFE_ENGINE_JAR: /,stat);
  }
  for(const stat of ['2000 644 regular file','2000 640 regular file','2000 600 regular file','2000 444 regular file']){
    const r=launchWithFakeAdb({FAKE_ADB_SERIAL:'phone-1',FAKE_ADB_STAT:stat});
    assert.equal(r.status,0,`${stat}: ${r.stderr}`);
    assert.match(r.stdout,/"launched"/,stat);
  }
});

test('Android engine never uses the clipboard', () => {
  const sourceRoot=path.join(root,'native-android/src');
  for(const file of javaFiles(sourceRoot)){
    const source=readFileSync(file,'utf8');
    assert.doesNotMatch(source,/ClipData|ClipDescription|ClipboardManager|IClipboard|CLIPBOARD_SERVICE|ACTION_PASTE|PrimaryClip|"clipboard"/,file);
  }
});

import { javacAndroidArgs } from '../scripts/android-toolchain.mjs';
test('Android build rejects Java APIs that Android lacks', () => {
  const dir=mkdtempSync(path.join(os.tmpdir(),'opencu-api-probe-'));
  try {
    // ProcessHandle exists in the host JDK but not on Android.
    writeFileSync(path.join(dir,'Probe.java'),'class Probe { long pid() { return ProcessHandle.current().pid(); } }\n');
    const r=spawnSync(path.join(java,'bin/javac'),[...javacAndroidArgs,'-d',dir,path.join(dir,'Probe.java')],{encoding:'utf8'});
    assert.notEqual(r.status,0,'a Java API missing on Android compiled with the build arguments');
    assert.match(r.stderr,/cannot find symbol[\s\S]*ProcessHandle/);
  } finally { rmSync(dir,{recursive:true,force:true}); }
});

// Second device round, item 6a: a dropped adb connection read as ENGINE_START_FAILED.
test('Android launcher reports DEVICE_UNAVAILABLE when adb finds no phone, before anything is sent', () => {
  const r=launchWithFakeAdb({});
  assert.notEqual(r.status,0);
  assert.doesNotMatch(r.stdout,/launched/);
  assert.match(r.stderr.trim().split('\n').pop(),/^DEVICE_UNAVAILABLE: adb cannot reach the phone \(error: no devices\/emulators found\); the engine was not started and nothing was sent$/);
});

test('Android launcher reports DEVICE_UNAVAILABLE for an offline phone, before anything is sent', () => {
  const r=launchWithFakeAdb({FAKE_ADB_OFFLINE:'1',FAKE_ADB_STAT:'2000 644 regular file'},['--serial','phone-1']);
  assert.notEqual(r.status,0);
  assert.doesNotMatch(r.stdout,/launched/);
  assert.match(r.stderr.trim().split('\n').pop(),/^DEVICE_UNAVAILABLE: adb cannot reach the phone phone-1 \(error: device offline\); the engine was not started/);
});

test('Android launcher reports DEVICE_UNAVAILABLE when the connection drops while the engine runs', () => {
  const r=launchWithFakeAdb({FAKE_ADB_SERIAL:'phone-1',FAKE_ADB_STAT:'2000 644 regular file',FAKE_ADB_LAUNCH_EXIT:'255',FAKE_ADB_STATE_AFTER_LAUNCH:'offline'});
  assert.notEqual(r.status,0);
  assert.match(r.stdout,/"launched"/);
  assert.match(r.stderr.trim().split('\n').pop(),/^DEVICE_UNAVAILABLE: adb cannot reach the phone phone-1 \(error: device offline\); the connection ended while the engine was running; a call in progress may or may not have reached the phone/);
  for(const call of r.calls.slice(1))assert.deepEqual(call.slice(0,2),['-s','phone-1'],JSON.stringify(call));
});

test('Android launcher adds no device line when the engine fails on a reachable phone', () => {
  const r=launchWithFakeAdb({FAKE_ADB_SERIAL:'phone-1',FAKE_ADB_STAT:'2000 644 regular file',FAKE_ADB_LAUNCH_EXIT:'1'});
  assert.equal(r.status,1);
  assert.doesNotMatch(r.stderr,/DEVICE_UNAVAILABLE/);
});
