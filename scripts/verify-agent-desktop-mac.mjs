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
  'idle host close: permanent person stop and confirmed cleanup',
  'EOF: pending consent and idle leave no host, stream, display or worker',
];
const report = { checks: Object.fromEntries(labels.map(label => [label, 'NOT RUN'])), startedAt: new Date().toISOString(), calls: [], samples: [], cleanupErrors: [] };
await mkdir(path.join(root, '.cache/agent-desktop-mac'), { recursive: true });
const run = await mkdtemp(path.join(root, '.cache/agent-desktop-mac/run-'));
const temporary = path.join(run, 'temporary'); await mkdir(temporary);
const fixtures = [], clients = [];
let pointer, pointerProcess, sampleTimer, sampling, activeGuard, failure;
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
function sameFrame(a, b) { return ['x', 'y', 'width', 'height'].every(key => Math.abs(a[key] - b[key]) <= 1); }
async function check(index, operation) {
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
    const value = { at: performance.now(), front: await command('/usr/bin/lsappinfo', ['front']), pointer };
    report.samples.push(value);
    if (activeGuard) {
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
  console.log(`In the OpenCU consent card for Fixture ${fixture.app.split('Fixture ')[1]}, click ${approve ? 'Move once' : 'Keep here'} within 60 seconds. Do not click the preview.`);
  const pending = client.call('get_app_state', { app: fixture.app, includeScreenshot: false, disableDiff: true });
  // Attach error handling immediately while polling the independent control lane.
  pending.catch(() => {});
  await until(async () => (await client.desktop('status')).consent != null, 'visible pending consent');
  const reply = await pending;
  assert.equal(reply._meta?.['opencu/agentDesktop']?.windowState, approve ? 'admitted' : 'reduced');
  return reply;
}
async function assertGone(status, workerGone = false) {
  await until(async () => !(await freshDisplays()).some(display => display.id === status.displayID), 'fresh process display removal', 15_000, true);
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
      pointer = JSON.parse(line);
      if (activeGuard && Math.hypot(pointer.x - activeGuard.pointer.x, pointer.y - activeGuard.pointer.y) > 1) abort('Physical pointer moved during automatic fixture work');
    } catch (error) { abort(error); }
  });
  pointerProcess.stderr.on('data', bytes => abort(bytes.toString()));
  await until(async () => pointer != null, 'pointer sampler');
  sampleTimer = setInterval(() => sample().catch(abort), 50);
  const a = await guarded(() => makeFixture('declined', binary)), b = await guarded(() => makeFixture('returned', binary)), c = await guarded(() => makeFixture('restored', binary));
  const initialDisplays = await freshDisplays();
  const client = new MCP(); await client.initialize();
  let started, beforeStop, returnedFrame;
  await check(0, async () => {
    await ask('Ready to start automatically. After typing yes, leave the pointer and foreground unchanged.');
    started = await guarded(() => client.desktop('start'));
    assert.equal(started.state, 'running'); assert.equal(started.windows.length, 0);
    assert.ok(started.preview.running && started.preview.frames > 0);
    assert.equal(started.preview.interactive, false);
    const displays = await freshDisplays(); assert.equal(displays.length, initialDisplays.length + 1);
    assert.ok(displays.some(display => display.id === started.displayID));
    for (const fixture of fixtures) assert.ok(sameFrame((await fixtureState(fixture)).windowFrame, fixture.original.windowFrame), 'OpenCU must not relocate before consent');
    await ask('Verify the small OpenCU preview visibly shows the agent display. Confirm it appeared without taking foreground.');
  });
  await check(1, async () => {
    const declined = await consent(client, a, false);
    assert.equal(declined.content.some(item => item.type === 'image'), false);
    assert.ok(sameFrame((await fixtureState(a)).windowFrame, a.original.windowFrame));
    await client.call('get_app_state', { app: a.app });
    assert.equal((await client.desktop('status')).consent, null, 'Decline must not re-offer');
    assert.equal((await client.call('click', { app: a.app, element_index: 1 }, true))._meta['opencu/error'], 'AGENT_DESKTOP_CONSENT_REQUIRED');
    await consent(client, b, true);
    assert.equal((await fixtureState(b)).screenID, started.displayID);
    assert.ok(sameFrame((await fixtureState(c)).windowFrame, c.original.windowFrame), 'Second window moved before its consent');
    await consent(client, c, true);
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
    await ask('Manually drag Fixture returned OFF the agent display onto your physical desktop (use macOS display navigation/Mission Control; the preview is watch-only). Do not move Fixture restored.');
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
    const status = await client.desktop('start');
    await ask('No tool call is in flight. Close the OpenCU agent desktop window using its close button, then type yes here.');
    await until(async () => (await client.desktop('status')).stoppedByPerson === true, 'idle person-stop event');
    for (const [name, args] of [['get_app_state', { app: a.app }], ['agent_desktop', { action: 'start' }]]) {
      assert.equal((await client.call(name, args, true))._meta['opencu/error'], 'STOPPED_BY_PERSON');
    }
    const stopped = await client.desktop('stop'); assert.equal(stopped.cleanup.ok, true); assert.equal(stopped.state, 'stopped');
    await assertGone(status); await client.eof();
  });
  await check(6, async () => {
    for (const pendingConsent of [true, false]) {
      const fresh = new MCP(); await fresh.initialize(); const status = await fresh.desktop('start');
      let pending;
      if (pendingConsent) {
        console.log('Leave this consent card unanswered: the test will end MCP stdin.');
        pending = fresh.call('get_app_state', { app: a.app }).catch(error => ({ error: error.message }));
        await until(async () => (await fresh.desktop('status')).consent != null, 'pending consent before EOF');
      }
      await fresh.eof(); await pending; await assertGone(status, true);
    }
  });
} catch (error) { abort(error); }
finally {
  activeGuard = undefined; clearInterval(sampleTimer); if (sampling) await sampling.catch(() => {});
  for (const client of clients) {
    try { if (client.child.exitCode == null && client.child.signalCode == null) await client.eof(); }
    catch (error) { report.cleanupErrors.push(error.message); }
  }
  pointerProcess?.kill('SIGTERM');
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
  report.ok = !failure && !report.cleanupErrors.length && Object.values(report.checks).every(result => result === 'PASS');
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
