#!/usr/bin/env node
// LIVE, opt-in reviewer probe. Never invoked by npm test or the native tests.
import assert from 'node:assert/strict';
import { spawn, execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { createInterface } from 'node:readline';
import { createHash } from 'node:crypto';
import { mkdir, mkdtemp, readFile, writeFile, rm } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { setTimeout as pause } from 'node:timers/promises';
import { Client } from '@modelcontextprotocol/sdk/client/index.js';
import { StdioClientTransport } from '@modelcontextprotocol/sdk/client/stdio.js';
import { applicationSerialNumbers, applicationPID, windowMovementWarnings } from './agent-display-probe-support.mjs';

const exec = promisify(execFile);
const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const prefix = 'experimental_agent_display_';
const checks = ['Stage Manager enabled', 'fixture launched without activation', 'display created and original layout preserved',
  'target moved to agent display', 'full screenshot and rendered fixture pixels', 'indexed click effect',
  'coordinate click delivery', 'shortcut and Unicode typing', 'menu item effect without menu tracking',
  'original target frame restored', 'display removed; original arrangement preserved', 'destroy is idempotent',
  'fixture exited', 'frontmost app unchanged in samples and fixture events'];

// This transport exists only in the probe. Experimental operations are never
// exposed as MCP tools and the ordinary MCP adapter is used for all input.
class DirectEngine {
  constructor(log) {
    this.next = 1;
    this.pending = new Map();
    this.tail = Promise.resolve();
    this.child = spawn(path.join(root, 'bin/opencu'), ['engine'], { stdio: ['pipe', 'pipe', 'pipe'], detached: true });
    this.done = new Promise(resolve => this.child.once('close', resolve));
    this.child.stderr.on('data', data => log.push(data.toString()));
    this.child.on('error', error => this.fail(error));
    this.child.on('exit', () => this.fail(new Error('Direct engine exited')));
    this.child.stdin.on('error', error => this.fail(error));
    createInterface({ input: this.child.stdout }).on('line', line => {
      try {
        const response = JSON.parse(line), pending = this.pending.get(response.id);
        if (!pending) return;
        this.pending.delete(response.id);
        clearTimeout(pending.timer);
        if (response.error) pending.reject(Object.assign(new Error(response.error.message), { code: response.error.code }));
        else pending.resolve(response.result);
      } catch (error) { this.fail(error); }
    });
  }
  fail(error) {
    this.failure ??= error;
    for (const pending of this.pending.values()) { clearTimeout(pending.timer); pending.reject(error); }
    this.pending.clear();
  }
  request(method, params = {}) {
    const request = this.tail.then(() => {
      if (this.failure) throw this.failure;
      const id = this.next++;
      return new Promise((resolve, reject) => {
        const timer = setTimeout(() => {
          this.fail(new Error(`Direct engine timed out during ${method}; no replay`));
          this.child.stdin.end();
        }, 10_000);
        this.pending.set(id, { resolve, reject, timer });
        this.child.stdin.write(JSON.stringify({ id, method: prefix + method, params }) + '\n');
      });
    });
    this.tail = request.catch(() => {});
    return request;
  }
  async close() {
    this.child.stdin.end();
    for (const [timeout, signal] of [[7000, 'SIGTERM'], [5000, 'SIGKILL']]) {
      if (await Promise.race([this.done.then(() => true), pause(timeout).then(() => false)])) return;
      try { process.kill(-this.child.pid, signal); } catch (error) { if (error.code !== 'ESRCH') throw error; }
    }
    await this.done;
  }
}

const area = path.join(root, '.cache/agent-display');
await mkdir(area, { recursive: true });
const run = await mkdtemp(path.join(area, 'run-'));
const temporary = path.join(run, 'fixture');
const fixtureBundleID = `dev.opencu.test.agent-display.${path.basename(run).toLowerCase()}`;
const report = { timestamp: new Date().toISOString(), run, checks: Object.fromEntries(checks.map(c => [c, 'NOT RUN'])),
  baselineSamples: [], frontmost: [], samplingErrors: [], direct: [], fixtureStates: [], fixtureDiscovery: [],
  windowMovementWarnings: [], cleanupErrors: [], engineStderr: [], mcpStderr: [] };
let failure, initialFront, timer, sampling, direct, client, transport, fixture, tree = '', sequence = 0;
let candidateFront, stableSince;
let before, originalFixture;
const cancelled = new AbortController();
const abort = reason => { failure ??= reason instanceof Error ? reason : new Error(reason); cancelled.abort(failure); };
for (const signal of ['SIGINT', 'SIGTERM', 'SIGHUP']) process.on(signal, () => abort(`Interrupted by ${signal}`));
function active() { if (failure) throw failure; }
async function guarded(operation) {
  active();
  let listener;
  try {
    const interrupted = new Promise((_, reject) => {
      listener = () => reject(failure);
      cancelled.signal.addEventListener('abort', listener, { once: true });
    });
    const result = await Promise.race([operation(), interrupted]);
    active();
    return result;
  } finally { cancelled.signal.removeEventListener('abort', listener); }
}
async function command(file, args) { return guarded(() => exec(file, args, { signal: cancelled.signal, timeout: 60_000 })); }
async function sample() {
  if (sampling) return sampling; // Never run overlapping lsappinfo processes.
  sampling = (async () => {
    const started = performance.now();
    try {
      const { stdout } = await exec('/usr/bin/lsappinfo', ['front'], { timeout: 1000 });
      const front = stdout.trim();
      assert.match(front, /^ASN:/, 'lsappinfo did not identify a foreground app');
      const value = { elapsedMs: started, completedMs: performance.now(), front };
      if (initialFront === undefined) {
        report.baselineSamples.push(value);
        if (front !== candidateFront) { candidateFront = front; stableSince = value.completedMs; }
      } else {
        report.frontmost.push(value);
        if (front !== initialFront) abort('Frontmost application changed; no further probe actions will be sent');
      }
    } catch (error) { report.samplingErrors.push(error.message); abort(error); }
  })();
  try { await sampling; } finally { sampling = undefined; }
}
async function establishBaseline() {
  await until(async () => {
    await sample();
    return report.baselineSamples.at(-1).completedMs - stableSince >= 1000;
  }, 'frontmost application stable for one second');
  initialFront = candidateFront;
  report.baseline = { front: initialFront, stableSinceMs: stableSince, recordedMs: performance.now() };
  const identities = await Promise.all(['name', 'bundleid'].map(key =>
    command('/usr/bin/lsappinfo', ['info', '-only', key, initialFront])));
  report.baseline.identity = identities.map(value => value.stdout.trim()).join('\n');
  const dialog = report.baseline.identity.match(/\b(UserNotificationCenter|SecurityAgent)\b/i);
  if (dialog) throw new Error(`System dialog is frontmost (${dialog[1]}). Close it before running the probe; no fixture or agent display was created.`);
}
async function state(label) {
  const value = JSON.parse(await readFile(path.join(temporary, 'state.json'), 'utf8'));
  report.fixtureStates.push({ label, time: new Date().toISOString(), value });
  if (originalFixture && (value.frontmostPID !== originalFixture.frontmostPID ||
      value.activations.some(event => event.pid !== originalFixture.frontmostPID))) {
    report.foregroundEventChanged = true;
    abort('Fixture observed a foreground change; no further probe actions will be sent');
  }
  return value;
}
async function until(predicate, label, cleanup = false) {
  for (let i = 0; i < 50; i++) {
    if (!cleanup) active();
    if (await predicate()) return;
    await pause(100);
  }
  throw new Error(`Timed out: ${label}`);
}
async function experiment(method, params = {}, cleanup = false) {
  if (!cleanup) active();
  try {
    const result = await direct.request(method, params);
    report.direct.push({ method, params, result, time: new Date().toISOString() });
    if (!cleanup) active();
    return result;
  } catch (error) {
    report.direct.push({ method, params, error: error.message, code: error.code });
    throw error;
  }
}
async function check(label, operation) {
  try { const ran = await operation(); report.checks[label] = ran === false ? 'NOT RUN' : 'PASS'; }
  catch (error) { report.checks[label] = `FAIL: ${error.message}`; throw error; }
}
function sameFrame(a, b) { return a && b && ['x', 'y', 'width', 'height'].every(k => Math.abs(a[k] - b[k]) <= 1); }
function layout(displays) { return displays.map(({ id, frame, main, mirrored }) => ({ id, frame, main, mirrored })).sort((a, b) => a.id - b.id); }
function recordWindowMovement(first, second, exclude = []) {
  report.windowMovementWarnings.push(...windowMovementWarnings(first, second, exclude));
}
const index = identifier => entry(line => line.includes('ID=' + JSON.stringify(identifier)), identifier);
function entry(predicate, label) {
  const lines = tree.split('\n').filter(predicate);
  assert.equal(lines.length, 1, `Expected one observed ${label}:\n${tree}`);
  return Number(lines[0].match(/^\s*\[(\d+)\]/)[1]);
}
const menu = label => entry(line => line.includes(label), label);
let app, executable;
async function call(name, args = {}) {
  active();
  const result = await client.callTool({ name, arguments: { app, ...args } }, undefined,
    { timeout: 20_000, signal: cancelled.signal });
  const n = ++sequence;
  await writeFile(path.join(run, `mcp-${n}.json`), JSON.stringify({ name, args, result }, null, 2));
  const text = result.content.filter(c => c.type === 'text').map(c => c.text).join('\n');
  const image = result.content.find(c => c.type === 'image');
  let imagePath;
  if (image) {
    imagePath = path.join(run, `mcp-${n}.png`);
    await writeFile(imagePath, Buffer.from(image.data, 'base64'));
  }
  active();
  assert.ok(!result.isError, text);
  if (text.includes('[1]')) tree = text;
  await state(`after ${name}`);
  return { result, text, imagePath };
}
async function findFixturePID() {
  // A unique bundle ID scopes discovery/cleanup to this run, including when
  // launch is interrupted before the fixture writes its first state file.
  const { stdout } = await exec('/usr/bin/lsappinfo', ['find', `bundleid=${fixtureBundleID}`], { timeout: 1000 });
  const discovery = { time: new Date().toISOString(), findOutput: stdout };
  report.fixtureDiscovery.push(discovery);
  const asns = applicationSerialNumbers(stdout);
  assert.ok(asns.length <= 1, 'Multiple processes registered for this fixture run');
  if (!asns.length) return;
  const info = await exec('/usr/bin/lsappinfo', ['info', '-only', 'pid', asns[0]], { timeout: 1000 });
  discovery.pidOutput = info.stdout;
  return applicationPID(info.stdout);
}
async function stopFixture() {
  if (!fixture) return;
  // open's PID is not the app PID. Let the launch request finish before cleanup
  // even after Ctrl-C, then discover a late registration if needed.
  await fixture.launch.catch(() => {});
  let pid;
  for (let attempt = 0; attempt < (fixture.pid ? 1 : 50); attempt++) {
    pid = await findFixturePID();
    if (pid) break;
    await pause(100);
  }
  if (!pid) return;
  for (const signal of ['SIGTERM', 'SIGKILL']) {
    try { process.kill(pid, signal); } catch (error) { if (error.code !== 'ESRCH') throw error; }
    for (let attempt = 0; attempt < 30; attempt++) {
      try { process.kill(pid, 0); } catch (error) { if (error.code === 'ESRCH') return; throw error; }
      const running = await findFixturePID();
      // LaunchServices may unregister an app before its process finishes.
      if (running) assert.equal(running, pid, 'Fixture process identity changed during cleanup');
      await pause(100);
    }
  }
  throw new Error(`Fixture PID ${pid} did not exit after SIGKILL`);
}

try {
  await sample();
  active();
  timer = setInterval(sample, 50);
  await establishBaseline();
  report.platform = (await command('/usr/bin/sw_vers', [])).stdout.trim();
  report.engineSHA256 = createHash('sha256').update(await readFile(path.join(root, '.build/OpenCU.app/Contents/MacOS/opencu-engine'))).digest('hex');
  await check(checks[0], async () => {
    report.stageManager = (await command('/usr/bin/defaults', ['read', 'com.apple.WindowManager', 'GloballyEnabled'])).stdout.trim();
    assert.equal(report.stageManager, '1', 'Enable Stage Manager manually before this probe');
  });
  direct = new DirectEngine(report.engineStderr);
  before = await experiment('status');
  report.before = before;
  await mkdir(temporary, { recursive: true });
  app = path.join(temporary, 'OpenCU Agent Display Fixture.app');
  const contents = path.join(app, 'Contents');
  await mkdir(path.join(contents, 'MacOS'), { recursive: true });
  executable = path.join(contents, 'MacOS/OpenCUFixture');
  await command('/usr/bin/xcrun', ['swiftc', path.join(root, 'tests/fixtures/OpenCUFixture.swift'),
    '-target', 'arm64-apple-macosx14.0', '-framework', 'AppKit', '-o', executable]);
  await writeFile(path.join(contents, 'Info.plist'), `<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict><key>CFBundleIdentifier</key><string>${fixtureBundleID}</string>
<key>CFBundleExecutable</key><string>OpenCUFixture</string><key>CFBundleName</key><string>OpenCU Agent Display Fixture</string>
<key>CFBundlePackageType</key><string>APPL</string><key>NSHighResolutionCapable</key><true/>
<key>LSMinimumSystemVersion</key><string>14.0</string></dict></plist>`);
  await command('/usr/bin/codesign', ['--force', '--sign', '-', app]);
  await check(checks[1], async () => {
    active();
    fixture = { bundleID: fixtureBundleID };
    fixture.launch = new Promise((resolve, reject) => {
      // No --stdin/--stdout/--stderr redirection through LaunchServices.
      const launcher = spawn('/usr/bin/open', ['-g', '-n', '-a', app, '--args',
        '--output', path.join(temporary, 'state.json'), '--stage-managed', '--background'], { stdio: 'inherit' });
      launcher.once('error', reject);
      launcher.once('close', code => code === 0 ? resolve() : reject(new Error(`open exited with ${code}`)));
    });
    await fixture.launch;
    await until(async () => {
      fixture.pid ??= await findFixturePID();
      if (!fixture.pid) return false;
      try { return (await state('launch')).visibleWindows === 1; }
      catch (error) { if (error.code === 'ENOENT') return false; throw error; }
    }, 'fixture launch');
    report.fixture = { bundleID: fixtureBundleID, pid: fixture.pid };
    originalFixture = await state('original');
    assert.notEqual(originalFixture.frontmostPID, fixture.pid);
    await sample(); active();
  });
  let created, moved;
  await check(checks[2], async () => {
    created = await experiment('create');
    assert.ok(created.agentDisplayID);
    assert.deepEqual(layout(created.displays.filter(d => d.id !== created.agentDisplayID)), layout(before.displays));
    assert.equal(created.displays.find(d => d.id === created.agentDisplayID).main, false);
    recordWindowMovement(before, created, [fixture.pid]);
    report.windowMovementWarnings.push(...(created.windowMovementWarnings ?? []).filter(w => w.pid !== fixture.pid));
  });
  await check(checks[3], async () => {
    moved = await experiment('move_window', { app });
    assert.deepEqual(moved.target.displayIDs, [created.agentDisplayID]);
    assert.equal(moved.target.windowID, originalFixture.windowNumber);
    await until(async () => (await state('moved')).screenID === created.agentDisplayID, 'fixture screen update');
  });
  client = new Client({ name: 'opencu-agent-display-probe', version: '1.0' });
  transport = new StdioClientTransport({ command: path.join(root, 'bin/opencu'), stderr: 'pipe' });
  transport.stderr.on('data', data => report.mcpStderr.push(data.toString()));
  await guarded(() => client.connect(transport));
  await check(checks[4], async () => {
    const capture = await call('get_app_state', { includeScreenshot: true, disableDiff: true });
    assert.ok(capture.imagePath, 'No screenshot returned');
    const current = await experiment('status');
    assert.equal(current.target.windowServerOnScreen, true);
    assert.ok(sameFrame(current.target.frame, current.target.windowServerFrame), 'WindowServer still presents a thumbnail/transformed window');
    const fixtureState = await state('screenshot');
    const scale = created.backingScale, probe = fixtureState.probeInWindow;
    const x = Math.round((probe.x + probe.width * 0.75) * scale);
    const y = Math.round((fixtureState.windowFrame.height - probe.y - probe.height * 0.5) * scale);
    const pixels = JSON.parse((await command(executable, ['--inspect-image', capture.imagePath, String(x), String(y)])).stdout);
    report.screenshotPixels = pixels;
    assert.equal(pixels.width, Math.round(current.target.frame.width * scale));
    assert.equal(pixels.height, Math.round(current.target.frame.height * scale));
    assert.ok(pixels.b > pixels.r + 0.2 && pixels.b > pixels.g, 'Expected blue fixture canvas pixel missing');
  });
  await check(checks[5], async () => {
    await call('click', { element_index: index('counterButton') });
    await until(async () => (await state('indexed click')).clicks === 1, 'AXPress counter');
  });
  await check(checks[6], async () => {
    await call('get_app_state', { includeScreenshot: true, disableDiff: true });
    const value = await state('before coordinate click'), p = value.probeInWindow;
    const local = { x: p.width * 0.75, y: p.height * 0.5 };
    const x = (p.x + local.x) * created.backingScale;
    const y = (value.windowFrame.height - p.y - p.height + local.y) * created.backingScale;
    await call('click', { x, y });
    await until(async () => (await state('coordinate click')).probe.eventCount > value.probe.eventCount, 'pointer delivery');
    const events = (await state('coordinate effect')).probe.events.filter(e => e.sequence > value.probe.eventCount);
    for (const kind of ['mouseDown', 'mouseUp']) {
      const event = events.find(e => e.kind === kind);
      assert.ok(event && Math.abs(event.x - local.x) <= 1 && Math.abs(event.y - local.y) <= 1, `Incorrect ${kind} coordinates`);
    }
    report.coordinateClick = { x, y, expectedLocal: local, events };
  });
  const text = '后台中文 😀 café 世界';
  await check(checks[7], async () => {
    await call('click', { element_index: index('notes'), duration: 0.06 });
    await call('press_key', { key: 'super+a' });
    await until(async () => (await state('shortcut')).selection.notes.length === originalFixture.notes.length, 'Cmd+A selection');
    await call('type_text', { text });
    await until(async () => (await state('Unicode')).notes === text, 'exact Unicode content');
  });
  await check(checks[8], async () => {
    await call('click', { element_index: menu('Menu Bar Item title="Edit"') });
    await call('click', { element_index: menu('Menu Item title="Fixture Actions"') });
    await call('click', { element_index: menu('Menu Item title="Add fixture click"') });
    await until(async () => (await state('menu')).clicks === 2, 'menu counter');
    const value = await state('menu effect');
    assert.equal(value.menuTracking.length, 0, 'A background menu was displayed');
    assert.ok(value.menuActions.includes('Add fixture click'));
  });
} catch (error) {
  abort(error);
} finally {
  // Stop input before touching geometry. No automatic retry of any input.
  try { await client?.close(); } catch (error) { report.cleanupErrors.push(`MCP close: ${error.message}`); }
  if (direct) {
    try {
      await check(checks[9], async () => {
        const restored = await experiment('restore', {}, true);
        if (restored.target) {
          assert.equal(restored.restorePending, false);
          assert.ok(sameFrame(restored.target.frame, restored.target.originalFrame));
          await until(async () => {
            const value = await state('restored');
            return sameFrame(value.windowFrame, originalFixture.windowFrame) && value.screenID === originalFixture.screenID;
          }, 'fixture restoration', true);
        } else return false;
      });
    } catch (error) { report.cleanupErrors.push(`Restore: ${error.message}`); }
    try {
      await check(checks[10], async () => {
        const destroyed = await experiment('destroy', {}, true);
        assert.equal(destroyed.ok, true, JSON.stringify(destroyed.cleanupErrors));
        assert.equal(destroyed.agentDisplayID, null);
        assert.deepEqual(layout(destroyed.displays), layout(before.displays));
        recordWindowMovement(before, destroyed, fixture ? [fixture.pid] : []);
        report.after = destroyed;
      });
      await check(checks[11], async () => {
        const again = await experiment('destroy', {}, true);
        assert.equal(again.ok, true);
        assert.deepEqual(layout(again.displays), layout(before.displays));
      });
    } catch (error) { report.cleanupErrors.push(`Destroy: ${error.message}`); }
    try { await direct.close(); } catch (error) { report.cleanupErrors.push(`Engine exit: ${error.message}`); }
  }
  try { await check(checks[12], async () => { if (!fixture) return false; await stopFixture(); }); }
  catch (error) { report.cleanupErrors.push(`Fixture exit: ${error.message}`); }
  if (sampling) await sampling;
  await sample();
  clearInterval(timer);
  if (sampling) await sampling;
  const changed = report.foregroundEventChanged || report.frontmost.some(s => s.front !== initialFront);
  report.checks[checks[13]] = changed ? 'FAIL: frontmost app changed' : report.samplingErrors.length ? 'FAIL: foreground sampling failed' : report.frontmost.length > 1 ? 'PASS' : 'NOT RUN';
  report.sampling = { requestedIntervalMs: 50, count: report.frontmost.length,
    maxStartGapMs: Math.max(0, ...report.frontmost.slice(1).map((s, i) => s.elapsedMs - report.frontmost[i].elapsedMs)) };
  report.error = failure?.message;
  report.ok = !failure && !report.cleanupErrors.length && Object.values(report.checks).every(v => v === 'PASS');
  await rm(temporary, { recursive: true, force: true });
  await writeFile(path.join(run, 'report.json'), JSON.stringify(report, null, 2) + '\n');
  await writeFile(path.join(area, 'latest.json'), JSON.stringify({ report: path.join(run, 'report.json') }, null, 2) + '\n');
  for (const [name, value] of Object.entries(report.checks)) console.log(`${value === 'PASS' ? 'PASS' : value.startsWith('FAIL') ? 'FAIL' : 'SKIP'}  ${name}${value.startsWith('FAIL') ? `: ${value.slice(6)}` : ''}`);
  if (failure) console.error(failure.message);
  for (const error of report.cleanupErrors) console.error(error);
  for (const warning of report.windowMovementWarnings) console.warn(`WARN  ${warning.ownerName} (PID ${warning.pid}), window ${warning.windowID} moved; cause unattributed`);
  console.log(`Evidence: ${path.join(run, 'report.json')}`);
  process.exitCode = report.ok ? 0 : 1;
}
