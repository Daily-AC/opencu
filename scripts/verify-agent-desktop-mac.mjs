#!/usr/bin/env node
// LIVE acceptance only. Check authorization before any subprocess or filesystem mutation.
if (!process.argv.includes('--owner-present') || process.platform !== 'darwin') {
  console.error('Refusing GUI acceptance. On an authorized idle Mac run: node scripts/verify-agent-desktop-mac.mjs --owner-present');
  process.exit(2);
}
import assert from 'node:assert/strict';
import { spawn, execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { createInterface } from 'node:readline';
import { createInterface as questions } from 'node:readline/promises';
import { mkdir, mkdtemp, readFile, writeFile, copyFile, rm } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { setTimeout as pause } from 'node:timers/promises';
import { applicationSerialNumbers, applicationPID } from './agent-display-probe-support.mjs';
import { assertDisplayAdded, assertDisplayRemoved } from './agent-desktop-acceptance-support.mjs';
import { imageSize } from '../src/coordinate-state.mjs';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const exec = promisify(execFile);
const command = async (file, args) => (await exec(file, args, { timeout: 60_000 })).stdout.trim();
const terminal = questions({ input: process.stdin, output: process.stdout });
const labels = [
  'start: visible preview, one display, no admitted windows, foreground/pointer unchanged',
  'consent: decline reduced; two exact windows require separate approvals',
  'Stage Manager: indexed/coordinate/CJK/shortcut/menu effects; foreground/pointer unchanged',
  'manual return: input revoked and cleanup leaves the window there',
  'tool stop: exact restoration, apps open, fresh removal, idempotence',
  'preview window: start amid pointer activity; close/minimize hide, menu shows, keep on top, clean view, full screen; Stop latches',
  'EOF: pending consent and idle leave no host, stream, display or worker',
  'idle: an unused desktop returns its window and stops itself; the next app call is told',
];
const report = { checks: Object.fromEntries(labels.map(label => [label, 'NOT RUN'])), startedAt: new Date().toISOString(), calls: [], samples: [], cleanupErrors: [] };
await mkdir(path.join(root, '.cache/agent-desktop-mac'), { recursive: true });
const run = await mkdtemp(path.join(root, '.cache/agent-desktop-mac/run-'));
const temporary = path.join(run, 'temporary'); await mkdir(temporary);
const fixtures = [], clients = [];
const displayBaselines = new Map();
let pointer, pointerProcess, sampleTimer, sampling, activeGuard, failure;
let pointerClosing = false, pointerAt = 0;
const abort = reason => {
  if (failure) return;
  failure = reason instanceof Error ? reason : new Error(String(reason));
  for (const client of clients) for (const [id, request] of client.pending) {
    if (request.method === 'tools/call') client.child.stdin.write(JSON.stringify({ jsonrpc: '2.0', method: 'notifications/cancelled', params: { requestId: id, reason: failure.message } }) + '\n');
  }
};
for (const signal of ['SIGINT', 'SIGTERM', 'SIGHUP']) process.on(signal, () => { abort(signal); terminal.close(); for (const client of clients) client.child.stdin.end(); });
function active() { if (failure) throw failure; }
async function ask(message) {
  active();
  const answer = await terminal.question(`${message}\nType yes when ready (anything else aborts): `);
  assert.equal(answer.trim().toLowerCase(), 'yes', 'Owner did not confirm');
}
async function until(check, label, timeout = 10_000, cleanup = false) {
  const deadline = performance.now() + timeout;
  while (performance.now() < deadline) {
    if (!cleanup) active();
    if (await check()) return;
    await pause(100);
  }
  throw new Error(`Timed out: ${label}`);
}
// The person keeps using the pointer elsewhere; OpenCU must not treat that as interference.
function pointerTravel(since) {
  const points = report.samples.filter(value => value.at >= since && value.pointer).map(value => value.pointer);
  return points.length < 2 ? 0 : Math.max(...points.map(point => Math.hypot(point.x - points[0].x, point.y - points[0].y)));
}
function sameFrame(a, b) { return ['x', 'y', 'width', 'height'].every(key => Math.abs(a[key] - b[key]) <= 1); }
// --only 6,7,8 reruns selected checks against the same build; the rest are reported as SKIPPED.
const only = process.argv.includes('--only') ? new Set(process.argv[process.argv.indexOf('--only') + 1].split(',').map(Number)) : null;
async function check(index, operation) {
  if (only && !only.has(index + 1)) { report.checks[labels[index]] = 'SKIPPED'; return; }
  try { await operation(); report.checks[labels[index]] = 'PASS'; console.log(`PASS ${index + 1}. ${labels[index]}`); }
  catch (error) { report.checks[labels[index]] = `FAIL: ${error.message}`; console.error(`FAIL ${index + 1}. ${labels[index]}: ${error.message}`); throw error; }
}

// Actual MCP over the installed entry point. A raw EOF stays EOF; unlike some
// client transports we do not escalate it to SIGTERM after only two seconds.
class MCP {
  constructor() {
    this.next = 1; this.pending = new Map();
    this.child = spawn(path.join(root, 'bin/opencu'), [], { stdio: ['pipe', 'pipe', 'pipe'] });
    this.done = new Promise(resolve => this.child.once('close', resolve));
    this.child.stdin.on('error', () => {});
    this.child.stderr.on('data', bytes => report.calls.push({ stderr: bytes.toString() }));
    this.child.on('error', error => this.fail(error));
    this.child.once('close', () => this.fail(new Error('MCP EOF')));
    createInterface({ input: this.child.stdout }).on('line', line => {
      try {
        const result = JSON.parse(line), request = this.pending.get(result.id);
        if (!request) return;
        this.pending.delete(result.id); clearTimeout(request.timer);
        if (result.error) request.reject(new Error(JSON.stringify(result.error)));
        else request.resolve(result.result);
      } catch (error) { this.fail(error); }
    });
    clients.push(this);
  }
  fail(error) { for (const item of this.pending.values()) { clearTimeout(item.timer); item.reject(error); } this.pending.clear(); }
  request(method, params) {
    const id = this.next++;
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => { this.pending.delete(id); reject(new Error(`MCP timeout: ${method}`)); }, 110_000);
      this.pending.set(id, { resolve, reject, timer, method });
      this.child.stdin.write(JSON.stringify({ jsonrpc: '2.0', id, method, params }) + '\n');
    });
  }
  async initialize() {
    await this.request('initialize', { protocolVersion: '2025-03-26', capabilities: {}, clientInfo: { name: 'opencu-owner-fixture', version: '1' } });
    this.child.stdin.write(JSON.stringify({ jsonrpc: '2.0', method: 'notifications/initialized' }) + '\n');
  }
  async call(name, args = {}, allowError = false) {
    active();
    const result = await this.request('tools/call', { name, arguments: args });
    report.calls.push({ name, args, result: { ...result, content: result.content?.map(item => item.type === 'image' ? { type: 'image', ...imageSize(Buffer.from(item.data, 'base64')) } : item) } });
    if (!allowError) assert.ok(!result.isError, result.content?.map(item => item.text ?? '').join('\n'));
    return result;
  }
  async desktop(action) { return JSON.parse((await this.call('agent_desktop', { action })).content[0].text); }
  async eof() {
    this.child.stdin.end();
    let timer;
    try { await Promise.race([this.done, new Promise((_, reject) => { timer = setTimeout(() => reject(new Error('MCP did not clean up within 45 seconds of EOF')), 45_000); })]); }
    finally { clearTimeout(timer); }
  }
}
async function freshDisplays() {
  const result = JSON.parse(await command(path.join(root, '.build/OpenCU.app/Contents/MacOS/opencu-engine'), ['--online-displays']));
  assert.equal(result.schemaVersion, 1); assert.ok(Array.isArray(result.displays)); return result.displays;
}
async function fixtureState(fixture) { return JSON.parse(await readFile(fixture.statePath, 'utf8')); }
async function metadata(windowID) { return JSON.parse(await command(fixtures[0].executable, ['--window-metadata', String(windowID)])); }
async function pidFor(fixture) {
  const asns = applicationSerialNumbers(await command('/usr/bin/lsappinfo', ['find', `bundleid=${fixture.bundleID}`]));
  assert.ok(asns.length <= 1, 'Fixture bundle identity is ambiguous');
  if (!asns.length) return;
  return applicationPID(await command('/usr/bin/lsappinfo', ['info', '-only', 'pid', asns[0]]));
}
async function makeFixture(name, sourceBinary) {
  const bundleID = `dev.opencu.test.agent-desktop.${path.basename(run).toLowerCase()}.${name}`;
  const app = path.join(temporary, `Fixture ${name}.app`), contents = path.join(app, 'Contents');
  await mkdir(path.join(contents, 'MacOS'), { recursive: true });
  const executable = path.join(contents, 'MacOS/OpenCUFixture'); await copyFile(sourceBinary, executable);
  await writeFile(path.join(contents, 'Info.plist'), `<?xml version="1.0"?><plist version="1.0"><dict><key>CFBundleIdentifier</key><string>${bundleID}</string><key>CFBundleExecutable</key><string>OpenCUFixture</string><key>CFBundleName</key><string>OpenCU Fixture ${name}</string><key>CFBundlePackageType</key><string>APPL</string><key>NSHighResolutionCapable</key><true/></dict></plist>`);
  await command('/usr/bin/codesign', ['--force', '--sign', '-', app]);
  const fixture = { app, executable, bundleID, statePath: path.join(temporary, `${name}.json`) }; fixtures.push(fixture);
  await command('/usr/bin/open', ['-g', '-n', '-a', app, '--args', '--output', fixture.statePath, '--stage-managed', '--background']);
  await until(async () => { fixture.pid ??= await pidFor(fixture); try { return fixture.pid && (await fixtureState(fixture)).visibleWindows === 1; } catch (error) { if (error.code !== 'ENOENT') throw error; return false; } }, 'fixture launch');
  fixture.original = await fixtureState(fixture); return fixture;
}
async function sample() {
  if (sampling) return sampling;
  sampling = (async () => {
    const value = { at: performance.now(), front: (await exec('/usr/bin/lsappinfo', ['front'], { timeout: 1000 })).stdout.trim(), pointer };
    report.samples.push(value);
    if (activeGuard) {
      if (performance.now() - pointerAt > 2000) abort('Pointer sampler stopped reporting during fixture work');
      if (value.front !== activeGuard.front) abort('Foreground changed during automatic fixture work');
      if (!pointer || Math.hypot(pointer.x - activeGuard.pointer.x, pointer.y - activeGuard.pointer.y) > 1) abort('Pointer changed during automatic fixture work');
    }
    return value;
  })();
  try { return await sampling; } finally { sampling = undefined; }
}
async function guarded(operation) {
  active(); const baseline = await sample(); assert.ok(baseline.pointer);
  activeGuard = baseline;
  try { const value = await operation(); await sample(); active(); return value; }
  finally { activeGuard = undefined; }
}
async function consent(client, fixture, approve) {
  const name = fixture.app.split('Fixture ')[1];
  const since = performance.now();
  console.log(approve
    ? `>>> In the OpenCU consent card for Fixture ${name}, click the first button (Move once / 挪过来一次) within 60 seconds, then immediately keep moving the mouse around your own screen for about 5 seconds without clicking.`
    : `>>> In the OpenCU consent card for Fixture ${name}, click the second button (Keep here / 留在原处) within 60 seconds. Do not click the first button (Move once / 挪过来一次) or the preview.`);
  const pending = client.call('get_app_state', { app: fixture.app, includeScreenshot: !approve, disableDiff: true });
  // Attach error handling immediately while polling the independent control lane.
  pending.catch(() => {});
  await until(async () => (await client.desktop('status')).consent != null, 'visible pending consent');
  const reply = await pending;
  assert.equal(reply._meta?.['opencu/agentDesktop']?.windowState, approve ? 'admitted' : 'reduced');
  if (approve) {
    await pause(3000);
    report.moveTravel ??= []; report.moveTravel.push(pointerTravel(since));
    assert.ok(report.moveTravel.at(-1) > 40, 'Move the mouse after Move once: this check needs pointer activity during the move');
  }
  console.log(`Consent result: ${approve ? 'moved' : 'reduced'}.`);
  return reply;
}
async function startDesktop(client) {
  const before = await freshDisplays();
  const status = await client.desktop('start');
  assertDisplayAdded(before, await freshDisplays(), status.displayID);
  displayBaselines.set(status.displayID, before);
  return status;
}
async function assertGone(status, workerGone = false) {
  await until(async () => !(await freshDisplays()).some(display => display.id === status.displayID), 'fresh process display removal', 15_000, true);
  assertDisplayRemoved(displayBaselines.get(status.displayID), await freshDisplays(), status.displayID);
  if (status.preview.windowID != null) assert.equal((await metadata(status.preview.windowID)).present, false, 'Host window still exists');
  if (workerGone) await until(async () => { try { process.kill(status.workerPID, 0); return false; } catch (error) { if (error.code === 'ESRCH') return true; throw error; } }, 'worker exit (stream owner gone)', 15_000, true);
}
function text(reply) { return reply.content.filter(item => item.type === 'text').map(item => item.text).join('\n'); }
function index(reply, match) {
  const lines = text(reply).split('\n').filter(line => line.includes(match));
  assert.equal(lines.length, 1, `Expected exactly one ${match}`); return Number(lines[0].match(/^\s*\[(\d+)\]/)[1]);
}

try {
  await ask('This live run creates a virtual display and disposable fixture windows. Enable Stage Manager and ensure OpenCU permissions are already granted. Keep personal apps untouched.');
  assert.equal(await command('/usr/bin/defaults', ['read', 'com.apple.WindowManager', 'GloballyEnabled']), '1', 'Owner must enable Stage Manager');
  const binary = path.join(temporary, 'fixture-binary'), monitor = path.join(temporary, 'pointer-monitor');
  await command('/usr/bin/xcrun', ['swiftc', path.join(root, 'tests/fixtures/OpenCUFixture.swift'), '-framework', 'AppKit', '-o', binary]);
  await command('/usr/bin/xcrun', ['swiftc', path.join(root, 'tests/fixtures/OpenCUPointerMonitor.swift'), '-o', monitor]);
  pointerProcess = spawn(monitor, [], { stdio: ['ignore', 'pipe', 'pipe'] });
  createInterface({ input: pointerProcess.stdout }).on('line', line => {
    try {
      pointer = JSON.parse(line); pointerAt = performance.now();
      if (activeGuard && Math.hypot(pointer.x - activeGuard.pointer.x, pointer.y - activeGuard.pointer.y) > 1) abort('Physical pointer moved during automatic fixture work');
    } catch (error) { abort(error); }
  });
  pointerProcess.on('error', abort);
  pointerProcess.once('close', () => { if (!pointerClosing) abort('Pointer sampler exited unexpectedly'); });
  pointerProcess.stderr.on('data', bytes => abort(bytes.toString()));
  await until(async () => pointer != null, 'pointer sampler');
  sampleTimer = setInterval(() => sample().catch(abort), 50);
  const initialDisplays = await freshDisplays();
  assert.equal(initialDisplays.length, 1, 'External monitors are untested; run this acceptance with one physical display');
  await ask('Compilation is complete. Fixtures will now launch in the background. After yes, keep hands off the mouse and leave the foreground unchanged until the next question.');
  const a = await guarded(() => makeFixture('declined', binary)), b = await guarded(() => makeFixture('returned', binary)), c = await guarded(() => makeFixture('restored', binary));
  const client = new MCP(); await client.initialize();
  let started, beforeStop, returnedFrame;
  await check(0, async () => {
    await ask('Ready to start automatically. After typing yes, leave the pointer and foreground unchanged.');
    started = await guarded(() => startDesktop(client));
    assert.equal(started.state, 'running'); assert.equal(started.windows.length, 0);
    assert.ok(started.preview.running && started.preview.frames > 0);
    assert.equal(started.preview.interactive, false);
    const displays = await freshDisplays(); assert.equal(displays.length, initialDisplays.length + 1);
    assert.ok(displays.some(display => display.id === started.displayID));
    for (const fixture of fixtures) assert.ok(sameFrame((await fixtureState(fixture)).windowFrame, fixture.original.windowFrame), 'OpenCU must not relocate before consent');
    assert.equal((await metadata(started.preview.windowID)).layer, 0, 'The preview must open as an ordinary window, not kept on top');
    await ask('Verify the OpenCU preview window visibly shows the agent display. Confirm keyboard focus stayed in this terminal: typing here still works.');
  });
  await check(1, async () => {
    const declined = await consent(client, a, false);
    assert.equal(declined.content.some(item => item.type === 'image'), false);
    assert.ok(sameFrame((await fixtureState(a)).windowFrame, a.original.windowFrame));
    await client.call('get_app_state', { app: a.app });
    assert.equal((await client.desktop('status')).consent, null, 'Decline must not re-offer');
    assert.equal((await client.call('click', { app: a.app, element_index: 1 }, true))._meta['opencu/error'], 'AGENT_DESKTOP_CONSENT_REQUIRED');
    await consent(client, b, true);
    await until(async () => (await fixtureState(b)).screenID === started.displayID, 'fixture display after approved move');
    assert.ok(sameFrame((await fixtureState(c)).windowFrame, c.original.windowFrame), 'Second window moved before its consent');
    await consent(client, c, true);
    await until(async () => (await fixtureState(c)).screenID === started.displayID, 'second fixture display after approved move');
    const status = await client.desktop('status');
    assert.deepEqual(status.windows.map(window => window.windowID).sort(), [b.original.windowNumber, c.original.windowNumber].sort());
  });
  await check(2, async () => {
    await ask('Ready for automatic background input to Fixture restored. Leave pointer and foreground unchanged after yes.');
    await guarded(async () => {
      let reply = await client.call('get_app_state', { app: c.app, includeScreenshot: true, disableDiff: true });
      const image = reply.content.find(item => item.type === 'image'); assert.ok(image);
      const bytes = Buffer.from(image.data, 'base64'), size = imageSize(bytes); assert.ok(size);
      const before = await fixtureState(c), scale = size.width / before.windowFrame.width, p = before.probeInWindow;
      const x = (p.x + p.width * 0.75) * scale, y = (before.windowFrame.height - p.y - p.height / 2) * scale;
      const png = path.join(run, 'fixture-window.png'); await writeFile(png, bytes);
      const pixel = JSON.parse(await command(c.executable, ['--inspect-image', png, String(Math.round(x)), String(Math.round(y))]));
      assert.ok(pixel.b > pixel.r + 0.2 && pixel.b > pixel.g, 'Known blue fixture canvas is missing');
      reply = await client.call('click', { app: c.app, element_index: index(reply, 'ID="counterButton"') });
      await until(async () => (await fixtureState(c)).clicks === before.clicks + 1, 'indexed counter');
      await client.call('get_app_state', { app: c.app, includeScreenshot: true });
      reply = await client.call('click', { app: c.app, x, y });
      await until(async () => (await fixtureState(c)).probe.eventCount >= before.probe.eventCount + 2, 'coordinate pair');
      const events = (await fixtureState(c)).probe.events.filter(event => event.sequence > before.probe.eventCount);
      for (const kind of ['mouseDown', 'mouseUp']) {
        const event = events.find(event => event.kind === kind);
        assert.ok(event && Math.abs(event.x - p.width * 0.75) <= 1 && Math.abs(event.y - p.height / 2) <= 1, `Wrong ${kind} coordinates`);
      }
      reply = await client.call('get_app_state', { app: c.app, disableDiff: true });
      await client.call('click', { app: c.app, element_index: index(reply, 'ID="notes"') });
      await client.call('press_key', { app: c.app, key: 'super+a' });
      await until(async () => (await fixtureState(c)).selection.notes.length === before.notes.length, 'shortcut selection');
      reply = await client.call('type_text', { app: c.app, text: '后台中文 😀 café 世界' });
      await until(async () => (await fixtureState(c)).notes === '后台中文 😀 café 世界', 'exact CJK content');
      reply = await client.call('click', { app: c.app, element_index: index(reply, 'Menu Bar Item title="Edit"') });
      reply = await client.call('click', { app: c.app, element_index: index(reply, 'Menu Item title="Fixture Actions"') });
      await client.call('click', { app: c.app, element_index: index(reply, 'Menu Item title="Add fixture click"') });
      await until(async () => (await fixtureState(c)).clicks === before.clicks + 2, 'nested menu counter');
      assert.equal((await fixtureState(c)).menuTracking.length, 0, 'Background menu was displayed');
    });
  });
  await check(3, async () => {
    // The fixture moves its own window back, outside OpenCU, as the person would
    // with the app's Window menu. Asking the person to find that menu proved error-prone.
    await writeFile(b.statePath + '.command', 'move-to-main-display');
    await until(async () => (await fixtureState(b)).screenID !== started.displayID, 'fixture returned to the main display');
    returnedFrame = (await fixtureState(b)).windowFrame;
    assert.notEqual((await fixtureState(b)).screenID, started.displayID);
    await client.call('get_app_state', { app: b.app });
    assert.equal((await client.call('click', { app: b.app, element_index: 1 }, true))._meta['opencu/error'], 'AGENT_DESKTOP_CONSENT_REQUIRED');
    beforeStop = await client.desktop('status');
    const stopped = await client.desktop('stop'); assert.equal(stopped.cleanup.ok, true);
    assert.ok(sameFrame((await fixtureState(b)).windowFrame, returnedFrame), 'Cleanup overwrote the manual return');
  });
  await check(4, async () => {
    assert.ok(sameFrame((await fixtureState(c)).windowFrame, c.original.windowFrame), 'Original frame/size not restored');
    for (const fixture of fixtures) assert.equal(await pidFor(fixture), fixture.pid, 'App should remain running');
    assert.equal((await fixtureState(c)).notes, '后台中文 😀 café 世界', 'Unsaved fixture content was lost');
    await assertGone(beforeStop);
    const again = await client.desktop('stop'); assert.equal(again.state, 'inactive');
    assert.deepEqual((await freshDisplays()).map(item => item.id).sort(), initialDisplays.map(item => item.id).sort());
  });
  await check(5, async () => {
    await ask('After yes, start moving the mouse around your own screen (without clicking) and keep moving until the next question. The agent desktop starts once your movement is seen.');
    const asked = performance.now();
    await until(async () => pointerTravel(asked) > 40, 'pointer movement before start', 30_000);
    const since = performance.now();
    const status = await startDesktop(client);
    report.startTravel = pointerTravel(since);
    assert.ok(report.startTravel > 10, 'Keep moving the mouse during start: this check needs pointer activity');
    // A hidden window leaves the window list; follow the preview's current window number.
    const current = async () => metadata((await client.desktop('status')).preview.windowID);
    const shown = async () => (await current()).onScreen === true;
    const running = async () => {
      await pause(1500);
      const current = await client.desktop('status');
      assert.equal(current.state, 'running'); assert.equal(current.stoppedByPerson, false);
    };
    await ask('Bring the OpenCU agent desktop / OpenCU agent 桌面 window forward (if it is hidden, use Show agent desktop / 显示 agent 桌面 from the black-and-white V-shaped OpenCU arrow icon in the menu bar, not the purple macOS screen-sharing indicator). Then click the red close button among the three buttons at the top left of that window itself (not the Stop / 停止 button), then type yes here.');
    await until(async () => !(await shown()), 'preview hidden by close'); await running();
    await ask('Click the black-and-white V-shaped OpenCU arrow icon in the menu bar (not the purple macOS screen-sharing indicator) and choose Show agent desktop / 显示 agent 桌面, then type yes here.');
    await until(shown, 'preview shown from the menu bar');
    await ask('Click the yellow minimize button of the preview window, then type yes here.');
    await until(async () => !(await shown()), 'preview minimized'); await running();
    await ask('Show it again from the menu bar (Show agent desktop / 显示 agent 桌面), then type yes here.');
    await until(shown, 'preview shown again from the menu bar');
    await ask('Click the pin button (Keep on top / 置顶) at the right end of the preview title bar, then type yes here.');
    await until(async () => (await current()).layer > 0, 'preview kept on top');
    await ask('Click the pin button (Keep on top / 置顶) again to turn it off, then type yes here.');
    await until(async () => (await current()).layer === 0, 'preview ordinary again');
    await ask('Click the Clean view / 纯净模式 button next to the pin. Check that only the picture remains and that the title bar disappears when the pointer leaves the window and returns on hover. Then hover and click Clean view / 纯净模式 again to turn it off. Type yes if both looked right.');
    const screen = (await freshDisplays()).find(display => display.main).frame;
    let full = false;
    const watcher = setInterval(() => current().then(value => {
      if (value.onScreen && value.frame?.Width >= screen.width - 1 && value.frame?.Height >= screen.height - 1) full = true;
    }).catch(() => {}), 300);
    try {
      await ask('Click the green button of the preview to make it full screen and check that it shows a sharp agent desktop picture. Then leave full screen: move the pointer to the top edge and click the green button again. Come back here and type yes.');
    } finally { clearInterval(watcher); }
    assert.ok(full, 'The preview never filled the screen');
    await until(async () => (await current()).frame?.Width < screen.width - 1, 'preview left full screen'); await running();
    await ask('Click the Stop / 停止 button at the bottom of the preview, then type yes here.');
    await until(async () => (await client.desktop('status')).stoppedByPerson === true, 'person stop from the preview');
    for (const [name, args] of [['get_app_state', { app: a.app }], ['agent_desktop', { action: 'start' }]]) {
      assert.equal((await client.call(name, args, true))._meta['opencu/error'], 'STOPPED_BY_PERSON');
    }
    const stopped = await client.desktop('stop'); assert.equal(stopped.cleanup.ok, true); assert.equal(stopped.state, 'stopped');
    await assertGone(status); await client.eof();
  });
  await check(6, async () => {
    await ask('The previous MCP connection is permanently stopped. Authorize two NEW disposable verification connections solely for the pending-consent and idle EOF checks (this is not a reconnect of the stopped connection).');
    for (const pendingConsent of [true, false]) {
      const fresh = new MCP(); await fresh.initialize(); const status = await startDesktop(fresh);
      let pending;
      if (pendingConsent) {
        console.log('Leave this consent card unanswered: the test will end MCP stdin.');
        pending = fresh.call('get_app_state', { app: a.app }).catch(error => ({ error: error.message }));
        await until(async () => (await fresh.desktop('status')).consent != null, 'pending consent before EOF');
      }
      await fresh.eof(); await pending; await assertGone(status, true);
    }
  });
  await check(7, async () => {
    await ask('Last check: one NEW disposable connection starts the agent desktop, moves Fixture restored once, then makes no calls. About 5 minutes later the desktop should close itself and return that window. You may use the Mac normally while waiting, but do not lock it.');
    const fresh = new MCP(); await fresh.initialize(); const status = await startDesktop(fresh);
    await consent(fresh, c, true);
    await until(async () => (await fixtureState(c)).screenID === status.displayID, 'fixture moved before idling');
    const idleFrom = performance.now();
    console.log('Waiting for the idle stop (about 5 minutes; no tool calls are made)...');
    while ((await freshDisplays()).some(display => display.id === status.displayID)) {
      active();
      assert.ok(performance.now() - idleFrom < 7 * 60_000, 'The idle desktop did not stop within 7 minutes');
      await pause(5000);
    }
    report.idleStopSeconds = Math.round((performance.now() - idleFrom) / 1000);
    assert.ok(report.idleStopSeconds >= 290, `Stopped after only ${report.idleStopSeconds} s`);
    await until(async () => (await fixtureState(c)).screenID !== status.displayID, 'window returned by the idle stop');
    assert.ok(sameFrame((await fixtureState(c)).windowFrame, c.original.windowFrame), 'Idle stop did not restore the original frame');
    assert.equal((await fresh.call('get_app_state', { app: c.app }, true))._meta['opencu/error'], 'AGENT_DESKTOP_IDLE_STOPPED');
    assert.equal((await fresh.desktop('status')).state, 'inactive');
    await assertGone(status); await fresh.eof();
  });
} catch (error) { abort(error); }
finally {
  activeGuard = undefined; clearInterval(sampleTimer); if (sampling) await sampling.catch(() => {});
  for (const client of clients) {
    try { if (client.child.exitCode == null && client.child.signalCode == null) await client.eof(); }
    catch (error) { report.cleanupErrors.push(error.message); }
  }
  pointerClosing = true; pointerProcess?.kill('SIGTERM');
  for (const fixture of fixtures) {
    try {
      const pid = await pidFor(fixture);
      if (pid && pid === fixture.pid) {
        process.kill(pid, 'SIGTERM');
        await until(async () => !(await pidFor(fixture)), 'fixture exit', 5000, true);
      }
    } catch (error) { report.cleanupErrors.push(error.message); }
  }
  terminal.close();
  report.error = failure?.message; report.finishedAt = new Date().toISOString();
  report.maxSampleGapMs = Math.max(0, ...report.samples.slice(1).map((value, index) => value.at - report.samples[index].at));
  report.ok = !failure && !report.cleanupErrors.length && Object.values(report.checks).every(result => result === 'PASS' || (only && result === 'SKIPPED'));
  // Preserve fixture evidence, remove disposable executable bundles.
  for (const fixture of fixtures) {
    try { await copyFile(fixture.statePath, path.join(run, `${fixture.bundleID}.json`)); } catch {}
  }
  if (!report.cleanupErrors.length) await rm(temporary, { recursive: true, force: true });
  await writeFile(path.join(run, 'report.json'), JSON.stringify(report, null, 2) + '\n');
  for (const [label, value] of Object.entries(report.checks)) if (value !== 'PASS') console.error(`FAIL ${label}: ${value}`);
  if (failure) console.error(failure.message);
  for (const error of report.cleanupErrors) console.error(`FAIL cleanup: ${error}`);
  console.log(`Fixture-only evidence: ${path.join(run, 'report.json')}`);
  process.exitCode = report.ok ? 0 : 1;
}
