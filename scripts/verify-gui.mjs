#!/usr/bin/env node
// Real desktop acceptance using two disposable, locally built AppKit apps.
// Requires the user's existing Accessibility and Screen Recording grants.
import assert from 'node:assert/strict';
import { spawn, execFileSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { mkdir, readFile, writeFile, copyFile } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { setTimeout as pause } from 'node:timers/promises';
import { Client } from '@modelcontextprotocol/sdk/client/index.js';
import { StdioClientTransport } from '@modelcontextprotocol/sdk/client/stdio.js';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const area = path.join(root, '.cache/opencu-gui-acceptance');
await mkdir(area, { recursive: true });
const owned = [];
const checks = [];
let client;
let sequence = 0;
let tree = '';
const report = { timestamp: new Date().toISOString(), test: 'independent-background-gui', checks };
const engine = path.join(root, '.build/OpenCU.app/Contents/MacOS/opencu-engine');
report.engine_sha256 = createHash('sha256').update(await readFile(engine)).digest('hex');

async function buildFixture(name, identifier, executable) {
  const app = path.join(area, name + '.app');
  const contents = path.join(app, 'Contents');
  await mkdir(path.join(contents, 'MacOS'), { recursive: true });
  await writeFile(path.join(contents, 'Info.plist'), `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>CFBundleIdentifier</key><string>${identifier}</string>
<key>CFBundleExecutable</key><string>OpenCUFixture</string><key>CFBundleName</key><string>${name}</string>
<key>CFBundlePackageType</key><string>APPL</string><key>NSHighResolutionCapable</key><true/>
<key>LSMinimumSystemVersion</key><string>14.0</string></dict></plist>`);
  await copyFile(executable, path.join(contents, 'MacOS/OpenCUFixture'));
  execFileSync('/usr/bin/codesign', ['--force', '--sign', '-', '--identifier', identifier, app], { stdio: 'pipe' });
  return app;
}

async function readState(file) {
  return JSON.parse(await readFile(file, 'utf8'));
}

async function waitUntil(predicate, label) {
  for (let attempt = 0; attempt < 50; attempt++) {
    try { if (await predicate()) return; } catch {}
    await pause(100);
  }
  throw new Error('Timed out: ' + label);
}

async function stop(child) {
  if (!child || child.exitCode !== null || child.signalCode !== null) return;
  const done = new Promise(resolve => child.once('exit', resolve));
  child.kill('SIGTERM');
  await done;
}

try {
  const executable = path.join(area, 'OpenCUFixture');
  execFileSync('/usr/bin/xcrun', ['swiftc', path.join(root, 'tests/fixtures/OpenCUFixture.swift'),
    '-target', 'arm64-apple-macosx14.0', '-framework', 'AppKit', '-o', executable], { stdio: 'pipe' });
  const app = await buildFixture('OpenCU Test Target', 'dev.opencu.test.target', executable);
  const sentinelApp = await buildFixture('OpenCU Foreground Sentinel', 'dev.opencu.test.sentinel', executable);
  const targetFile = path.join(area, 'target.json');
  const sentinelFile = path.join(area, 'sentinel.json');
  const target = spawn(path.join(app, 'Contents/MacOS/OpenCUFixture'), ['--output', targetFile], { stdio: 'ignore' });
  owned.push(target);
  await waitUntil(async () => (await readState(targetFile)).frontmostPID === target.pid, 'target launch');
  const sentinel = spawn(path.join(sentinelApp, 'Contents/MacOS/OpenCUFixture'), ['--output', sentinelFile], { stdio: 'ignore' });
  owned.push(sentinel);
  await waitUntil(async () => (await readState(targetFile)).frontmostPID === sentinel.pid, 'sentinel foreground');
  await pause(500);
  const baseline = await readState(targetFile);
  const sentinelBaseline = await readState(sentinelFile);
  const activationBaseline = baseline.activations.length;
  const caffeinate = spawn('/usr/bin/caffeinate', ['-d', '-i', '-w', String(target.pid)], { stdio: 'ignore' });
  owned.push(caffeinate);
  client = new Client({ name: 'ordinary-opencu-gui-client', version: '1.0' });
  const transport = new StdioClientTransport({ command: path.join(root, 'bin/opencu'), stderr: 'pipe' });
  transport.stderr.resume();
  await client.connect(transport);

  async function intactForeground() {
    await pause(120);
    const state = await readState(targetFile);
    const front = await readState(sentinelFile);
    assert.notEqual(state.frontmostPID, target.pid, 'target displaced the foreground app');
    assert.notEqual(front.frontmostPID, target.pid);
    assert.ok(state.activations.slice(activationBaseline).every(a => a.pid !== target.pid), 'target took foreground focus during the operation');
    assert.equal(front.text, sentinelBaseline.text, 'keyboard input reached the foreground app');
    assert.equal(front.notes, sentinelBaseline.notes);
    assert.equal(front.probe.eventCount, sentinelBaseline.probe.eventCount, 'pointer input reached the foreground app');
    return state;
  }

  const index = identifier => {
    const line = tree.split('\n').find(line => line.includes('ID=' + JSON.stringify(identifier)));
    assert.ok(line, 'Missing observed fixture element ' + identifier);
    return Number(line.match(/^\s*\[(\d+)\]/)[1]);
  };

  async function call(name, args = {}) {
    const result = await client.callTool({ name, arguments: { app, ...args } }, undefined, { timeout: 90000 });
    const text = result.content.filter(c => c.type === 'text').map(c => c.text).join('\n');
    const image = result.content.find(c => c.type === 'image');
    sequence++;
    await writeFile(path.join(area, `call-${sequence}.json`), JSON.stringify({ name, args, result }));
    if (image) await writeFile(path.join(area, `call-${sequence}.png`), Buffer.from(image.data, 'base64'));
    assert.ok(!result.isError, text);
    if (text.includes('[1]')) tree = text;
    await intactForeground();
    return result;
  }

  await call('get_app_state', { includeScreenshot: true, disableDiff: true });
  assert.match(tree, /Screenshot: 1400 x 1564 pixels/);
  checks.push('background full-window screenshot');
  await call('click', { element_index: index('counterButton') });
  assert.equal((await readState(targetFile)).clicks, 1);
  checks.push('background AXPress');
  await call('set_value', { element_index: index('slider'), value: '37.5' });
  assert.equal((await readState(targetFile)).slider, 37.5);
  await call('perform_secondary_action', { element_index: index('slider'), action: 'AXIncrement' });
  assert.ok((await readState(targetFile)).slider > 37.5);
  checks.push('typed AX value and exposed secondary action');

  await call('click', { element_index: index('notes'), duration: 0.06 });
  await call('run_actions', { actions: [{ method: 'press_key', key: 'super+a' },
    { method: 'type_text', text: '后台中文 😀 世界' }] });
  assert.equal((await readState(targetFile)).notes, '后台中文 😀 世界');
  checks.push('background physical click, shortcut and Unicode typing');
  const clipboardBefore = execFileSync(executable, ['--clipboard-digest'], { encoding: 'utf8' }).trim();
  await call('run_actions', { actions: [{ method: 'press_key', key: 'super+a' },
    { method: 'paste', format: 'text', text: '你好 😀 世界\nSecond line' }] });
  assert.equal((await readState(targetFile)).notes, '你好 😀 世界\nSecond line');
  const clipboardAfter = execFileSync(executable, ['--clipboard-digest'], { encoding: 'utf8' }).trim();
  assert.equal(clipboardAfter, clipboardBefore, 'clipboard contents were not restored');
  checks.push('successful paste preserves all original clipboard items and types');
  await call('select_text', { element_index: index('notes'), text: '世界' });
  assert.deepEqual((await readState(targetFile)).selection.notes, { location: 6, length: 2 });
  checks.push('background paste and UTF-16 text selection');

  await call('click', { element_index: index('inputProbe'), duration: 0.35, key: 'Shift' });
  const mouse = (await readState(targetFile)).probe.events;
  const down = mouse.findLast(e => e.kind === 'mouseDown');
  const up = mouse.findLast(e => e.kind === 'mouseUp');
  assert.ok(down && up && down.shift && up.shift);
  assert.ok(Math.abs(down.x - 330) < 1 && Math.abs(down.y - 95) < 1);
  assert.ok(up.time - down.time >= 0.32 && up.time - down.time < 1);
  report.mouse_hold_ms = (up.time - down.time) * 1000;
  await call('press_key', { key: 'x', duration: 0.25 });
  const keys = (await readState(targetFile)).probe.events;
  const keyDown = keys.findLast(e => e.kind === 'keyDown');
  const keyUp = keys.findLast(e => e.kind === 'keyUp');
  assert.equal(keyDown.characters, 'x');
  assert.ok(keyUp.time - keyDown.time >= 0.23 && keyUp.time - keyDown.time < 1);
  report.key_hold_ms = (keyUp.time - keyDown.time) * 1000;
  checks.push('background pointer coordinates, modifiers and input hold durations');

  await call('get_app_state', { includeScreenshot: true });
  await call('drag', { from_x: 240, from_y: 918, to_x: 480, to_y: 948 });
  const marker = (await readState(targetFile)).probe.marker;
  assert.ok(Math.abs(marker.x - 220) < 1 && Math.abs(marker.y - 120) < 1);
  checks.push('background coordinate drag');
  await call('scroll', { element_index: index('scrollArea'), direction: 'down', pages: 1 });
  assert.ok((await readState(targetFile)).scroll.y > 20);
  checks.push('background pixel scroll');
  const menuItem = label => {
    const line = tree.split('\n').find(line => line.includes(label));
    assert.ok(line, 'Missing fixture menu entry ' + label);
    return Number(line.match(/^\s*\[(\d+)\]/)[1]);
  };
  // didEndTracking follows the menu's short fade-out after AX reports it closed.
  const menusClosed = () => waitUntil(async () => {
    const tracking = (await readState(targetFile)).menuTracking;
    return tracking.filter(e => e.event === 'begin').length === tracking.filter(e => e.event === 'end').length;
  }, 'background menu closed');
  await call('click', { element_index: index('notes') });
  await call('click', { element_index: menuItem('Menu Bar Item title="Edit"') });
  await menusClosed();
  await call('click', { element_index: menuItem('Menu Item title="Select All"') });
  assert.equal((await readState(targetFile)).selection.notes.length, '你好 😀 世界\nSecond line'.length);
  await call('click', { element_index: menuItem('Menu Bar Item title="Edit"') });
  await menusClosed();
  const opened = (await readState(targetFile)).menuTracking.length;
  await call('click', { element_index: menuItem('Menu Item title="Fixture Actions"') });
  assert.equal((await readState(targetFile)).menuTracking.length, opened, 'listing a submenu opened a menu');
  await call('click', { element_index: menuItem('Menu Item title="Add fixture click"') });
  assert.equal((await readState(targetFile)).clicks, 2);
  await menusClosed();
  checks.push('background menus close after reading; listed and nested commands run before the call returns');
  await intactForeground();
  checks.push('target never became foreground; no input delivered to foreground sentinel');
  await client.close();
  client = undefined;
  await waitUntil(async () => !(await readState(targetFile)).appActive, 'synthetic app activation released on disconnect');
  checks.push('disconnect releases synthetic activation');
  report.ok = true;
} catch (error) {
  report.ok = false;
  report.error = error.message;
  process.exitCode = 1;
} finally {
  await client?.close();
  for (const child of owned.reverse()) await stop(child);
  await writeFile(path.join(area, 'report.json'), JSON.stringify(report, null, 2) + '\n');
  console.log(JSON.stringify(report, null, 2));
}
