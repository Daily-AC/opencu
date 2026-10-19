#!/usr/bin/env node
// Run manually on an idle, unlocked Windows desktop. This takes the foreground.
// All desktop reads/actions go through MCP. The fixture's private command file
// moves its own windows, holds a fixture-only foreground lock, hashes the
// clipboard without changing it, and closes that fixture.
import assert from 'node:assert/strict';
import { spawn, execFileSync } from 'node:child_process';
import { createHash, randomUUID } from 'node:crypto';
import { createServer } from 'node:http';
import { access, mkdir, mkdtemp, readFile, rename, writeFile, rm } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { setTimeout as pause } from 'node:timers/promises';
import { Client } from '@modelcontextprotocol/sdk/client/index.js';
import { StdioClientTransport } from '@modelcontextprotocol/sdk/client/stdio.js';

// The fixture polls for this file; publish it whole so it never reads a partial write.
async function writeCommand(file, command) {
  await writeFile(`${file}.tmp`, command);
  await rename(`${file}.tmp`, file);
}

if (process.platform !== 'win32') throw new Error('Windows-only acceptance; no desktop was touched.');
const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const token = randomUUID();
const title = `OpenCU Fixture ${token}`;
const area = path.join(root, '.cache', `windows-acceptance-${token}`);
const temporaryRoot = path.join(root, '.cache', 'windows-temp');
await mkdir(temporaryRoot, { recursive: true });
const temp = await mkdtemp(path.join(temporaryRoot, 'opencu-win-'));
const profile = path.join(temp, 'chrome-profile');
const output = path.join(temp, 'fixture.json');
const commandFile = path.join(temp, 'command.txt');
const checks = [];
const report = { test: 'windows-foreground-fixtures', timestamp: new Date().toISOString(), checks, ok: false };
const owned = [];
const connections = [];
let client, http;
let tree = '', sequence = 0;
await mkdir(area, { recursive: true });

function powershell(script) {
  return execFileSync('powershell.exe', ['-NoLogo', '-NoProfile', '-NonInteractive', '-EncodedCommand', Buffer.from("$ProgressPreference='SilentlyContinue'; " + script, 'utf16le').toString('base64')], { windowsHide: true, encoding: 'utf8', timeout: 15000 }).trim();
}
const quote = s => `'${s.replaceAll("'", "''")}'`;
// Exact private marker, not executable name alone: never kill the user's browser.
function privateProcesses(marker) {
  const raw = powershell(`@(Get-CimInstance Win32_Process | Where-Object { $_.ProcessId -ne $PID -and $_.CommandLine -and $_.CommandLine.Contains(${quote(marker)}) } | Select-Object -ExpandProperty ProcessId) | ConvertTo-Json -Compress`);
  return raw ? [JSON.parse(raw)].flat() : [];
}
async function waitFor(fn, message, milliseconds = 12000) {
  const until = Date.now() + milliseconds;
  while (Date.now() < until) { if (await fn()) return; await pause(100); }
  throw new Error(`Timed out: ${message}`);
}
async function fixtureState(file = output) {
  // The fixture owns this file; a timer write can overlap our read.
  for (let attempt = 0; ; attempt++) {
    try { return JSON.parse(await readFile(file, 'utf8')); }
    catch (error) { if (attempt === 5) throw error; await pause(20); }
  }
}
async function fixtureCommand(command, file = commandFile) {
  await waitFor(async () => { try { await access(file); return false; } catch { return true; } }, 'fixture command idle');
  await writeCommand(file, command);
  await waitFor(async () => { try { await access(file); return false; } catch { return true; } }, `fixture command ${command}`);
  await pause(150);
}
function index(label) {
  const line = tree.split('\n').find(line => line.includes(`title=${JSON.stringify(label)}`));
  assert.ok(line, `Missing fixture control: ${label}`);
  return Number(line.match(/^\s*\[(\d+)\]/)?.[1]);
}
async function call(name, app, args = {}, errorCode, timeout = 90000) {
  const result = await client.callTool({ name, arguments: { app, ...args } }, undefined, { timeout });
  const text = result.content.filter(c => c.type === 'text').map(c => c.text).join('\n');
  await writeFile(path.join(area, `call-${++sequence}.json`), JSON.stringify({ name, app, args, result }, null, 2));
  if (errorCode) {
    assert.equal(result.isError, true, 'Expected refusal');
    assert.equal(result._meta?.['opencu/error'], errorCode, text);
  } else {
    assert.ok(!result.isError, text);
    if (/\[\d+\]/.test(text)) tree = text;
  }
  return result;
}
async function imageState(app) {
  const result = await call('get_app_state', app, { includeScreenshot: true, disableDiff: true });
  const image = result.content.find(c => c.type === 'image');
  assert.ok(image, 'Expected a window PNG');
  const png = Buffer.from(image.data, 'base64');
  const imageFile = path.join(area, `screenshot-${sequence}.png`);
  await writeFile(imageFile, png);
  report.lastFixtureImage = path.basename(imageFile);
  assert.equal(png.subarray(1, 4).toString(), 'PNG');
  return { width: png.readUInt32BE(16), height: png.readUInt32BE(20) };
}
try {
  report.engine_sha256 = createHash('sha256').update(await readFile(path.join(root, '.build/win/opencu-engine.exe'))).digest('hex');
  const fixture = spawn('powershell.exe', ['-NoLogo', '-NoProfile', '-NonInteractive', '-STA', '-ExecutionPolicy', 'Bypass', '-File', path.join(root, 'tests/fixtures/OpenCUFixture.ps1'), '-Output', output, '-CommandFile', commandFile, '-Title', title], { windowsHide: true, stdio: ['ignore', 'ignore', 'pipe'] });
  owned.push({ child: fixture, marker: commandFile });
  let fixtureError = ''; fixture.stderr.on('data', b => { fixtureError += b; });
  fixture.on('error', e => { fixtureError += e.message; });
  await waitFor(async () => {
    if (fixture.exitCode !== null) throw new Error(`Fixture exited: ${fixtureError}`);
    try { return (await fixtureState()).pid === fixture.pid; } catch { return false; }
  }, 'fixture start', 30000);
  report.fixtureWindow = JSON.parse(powershell(`Get-Process -Id ${fixture.pid} | Select-Object Id,MainWindowTitle,@{n='hwnd';e={$_.MainWindowHandle.ToInt64()}} | ConvertTo-Json -Compress`));
  client = new Client({ name: 'opencu-windows-fixture-client', version: '1.0' });
  connections.push(client);
  const transport = new StdioClientTransport({ command: process.execPath, args: [path.join(root, 'src/server.mjs')], stderr: 'pipe' });
  transport.stderr?.resume(); await client.connect(transport);
  const size = await imageState(title);
  const initial = await fixtureState();
  assert.deepEqual(size, { width: initial.width, height: initial.height });
  index('Fixture notes'); index('Fixture counter');
  checks.push('tree read and physical-size window PNG');
  assert.ok(!tree.includes('OpenCU-Fixture-Secret-7391'));
  assert.ok(tree.includes('[protected]'), 'Password control must be identified without its content');
  checks.push('native password text is redacted');
  await fixtureCommand('cover');
  await imageState(title);
  const marker = await fixtureState();
  const coveredImage = path.join(area, report.lastFixtureImage);
  const rgb = powershell(`Add-Type -AssemblyName System.Drawing; $image=[Drawing.Bitmap]::new(${quote(coveredImage)}); try { $p=$image.GetPixel(${marker.markerX},${marker.markerY}); Write-Output ([string]$p.R+','+$p.G+','+$p.B) } finally { $image.Dispose() }`);
  assert.equal(rgb, '255,0,255', 'Covered target must contain its own magenta marker, not the lime cover');
  checks.push('covered-window capture preserves target pixels');
  await fixtureCommand('uncover');

  await call('click', title, { element_index: index('Fixture counter') });
  assert.equal((await fixtureState()).clicks, 1);
  checks.push('indexed click');
  await call('click', title, { element_index: index('Fixture notes'), duration: 0.05 });
  await call('run_actions', title, { actions: [{ method: 'press_key', key: 'ctrl+a' }, { method: 'type_text', text: 'Windows 中文 😀' }] });
  report.unicode = await fixtureState();
  assert.equal(report.unicode.notes, 'Windows 中文 😀');
  checks.push('key chord and Unicode typing');
  const holding = call('press_key', title, { key: 'Shift', duration: 3 }).then(value => ({ value }), error => ({ error }));
  await pause(700);
  await fixtureCommand('indicator');
  const indicatorState = await fixtureState();
  const held = await holding; if (held.error) throw held.error;
  report.indicator = { visible: indicatorState.indicatorVisible, affinity: indicatorState.indicatorAffinity, readable: indicatorState.indicatorReadable };
  assert.equal(report.indicator.visible, true); assert.equal(report.indicator.readable, true); assert.equal(report.indicator.affinity, 17);
  checks.push('visible operation indicator is excluded from capture');
  await fixtureCommand('indicator-cover');
  await call('get_app_state', title, { disableDiff: true });
  await call('press_key', title, { key: 'Shift', duration: 0.1 });
  await imageState(title);
  await fixtureCommand('indicator');
  const underneath = await fixtureState();
  assert.equal(underneath.indicatorVisible, true, 'Indicator must remain visible during capture');
  const indicatorImage = path.join(area, report.lastFixtureImage);
  const underneathRgb = powershell(`Add-Type -AssemblyName System.Drawing; $image=[Drawing.Bitmap]::new(${quote(indicatorImage)}); try { $p=$image.GetPixel(${underneath.markerX},${underneath.markerY}); Write-Output ([string]$p.R+','+$p.G+','+$p.B) } finally { $image.Dispose() }`);
  assert.equal(underneathRgb, '255,0,255', 'Capture must contain target pixels beneath the visible indicator');
  checks.push('target pixels remain intact beneath the visible indicator');

  await call('press_key', title, { key: 'Escape' });
  checks.push('engine-injected Escape does not trigger the physical stop latch');


  await fixtureCommand('digest');
  const baseline = await fixtureState(); assert.equal(baseline.error, '');
  const pasteText = `粘贴 😀\r\nSecond line ${token}`;
  await call('run_actions', title, { actions: [{ method: 'press_key', key: 'ctrl+a' }, { method: 'paste', format: 'text', text: pasteText }] });
  assert.equal((await fixtureState()).notes.replaceAll('\r\n', '\n'), pasteText.replaceAll('\r\n', '\n'));
  await fixtureCommand('digest');
  assert.equal((await fixtureState()).clipboardDigest, baseline.clipboardDigest);
  checks.push('plain-text paste and original clipboard digest restored');

  await call('set_value', title, { element_index: index('Fixture slider'), value: '37' });
  assert.equal((await fixtureState()).slider, 37);
  await call('perform_secondary_action', title, { element_index: index('Fixture checkbox'), action: 'Toggle' });
  assert.equal((await fixtureState()).checked, true);
  checks.push('RangeValue and exposed secondary action');
  await call('scroll', title, { element_index: index('Fixture scroll area'), direction: 'down', pages: 1 });
  await waitFor(async () => { const s = await fixtureState(); return s.scroll > 0 || s.wheel > 0; }, 'fixture received scrolling');
  checks.push('scroll');

  await imageState(title);
  const point = await fixtureState();
  await call('click', title, { x: point.x, y: point.y });
  assert.equal((await fixtureState()).clicks, 2);
  checks.push('fresh screenshot coordinate click');
  await imageState(title);
  await fixtureCommand('move');
  await waitFor(async () => (await fixtureState()).moves === 1, 'fixture moved after capture');
  await call('click', title, { x: point.x, y: point.y }, 'STALE_SCREENSHOT');
  assert.equal((await fixtureState()).clicks, 2);
  checks.push('engine refuses moved-window coordinates before input');
  await imageState(title);
  const dragPoint = await fixtureState();
  const dragged = await call('drag', title, { from_x: dragPoint.dragFromX, from_y: dragPoint.dragFromY,
    to_x: dragPoint.dragToX, to_y: dragPoint.dragToY });
  assert.ok(dragged.content.some(c => c.type === 'image'), 'Drag returns a fresh screenshot');
  await waitFor(async () => (await fixtureState()).drags === 1, 'fixture received drag release');
  const dragResult = await fixtureState();
  assert.equal(dragResult.dragDownX, 20);
  assert.equal(dragResult.dragUpX - dragResult.dragDownX, dragPoint.dragDistance);
  assert.equal(dragResult.dragUpY, dragResult.dragDownY);
  assert.equal(dragResult.dragHeld, true);
  assert.ok(dragResult.dragMoves > 1, 'Multiple moves while the left button was held');
  checks.push('fresh screenshot drag holds left button along path and releases at endpoint');
  await imageState(title);
  await call('select_text', title, { element_index: index('Fixture notes'), text: 'fixture' }, 'UNSUPPORTED_ON_WINDOWS');
  checks.push('unsupported text selection refused');

  await call('get_app_state', title, { disableDiff: true });
  await call('click', title, { x: 1, y: 1 }, 'SCREENSHOT_REQUIRED');
  checks.push('text-only observation refuses coordinate input with SCREENSHOT_REQUIRED');

  report.modalDialog = { handler: 'WinForms synchronous ShowDialog', boundMs: 15000, cases: [] };
  for (const method of ['click', 'perform_secondary_action', 'run_actions']) {
    await call('get_app_state', title, { disableDiff: true });
    const element_index = index('Fixture open modal');
    const action = { method: 'perform_secondary_action', element_index, action: 'Invoke' };
    const args = method === 'click' ? { element_index }
      : method === 'run_actions' ? { actions: [action] } : { element_index, action: 'Invoke' };
    const started = performance.now();
    await call(method, title, args, undefined, 15000);
    const elapsedMs = Math.round(performance.now() - started);
    assert.ok(elapsedMs < 15000, `Modal opening must return promptly: ${elapsedMs} ms`);
    await call('get_app_state', title, { disableDiff: true }, undefined, 15000);
    assert.ok(tree.includes(`${title} Modal`), 'Fresh observation lists the modal dialog');
    index('Fixture modal OK');
    assert.equal((await fixtureState()).modalOpen, true);
    const value = `modal-result-${method}`;
    await call('set_value', title, { element_index: index('Fixture modal value'), value });
    await call('click', title, { element_index: index('Fixture modal OK') }, undefined, 15000);
    await waitFor(async () => {
      const s = await fixtureState();
      return !s.modalOpen && s.modalValue === value && s.modalCompletions === report.modalDialog.cases.length + 1;
    }, 'modal OK recorded value and closed dialog');
    await call('get_app_state', title, { disableDiff: true });
    assert.ok(!tree.includes('Fixture modal OK'), 'Closed dialog is absent from fresh state');
    report.modalDialog.cases.push({ method, elapsedMs, value, closed: true });
    checks.push(`${method} opens a synchronous modal promptly; fresh state, value input and indexed OK work on the same connection`);
  }

  await fixtureCommand('owned');
  const family = await fixtureState();
  assert.equal(family.foregroundPid, fixture.pid);
  assert.notEqual(family.foregroundHwnd, family.mainHwnd);
  assert.equal(family.foregroundRootOwner, family.mainRootOwner);
  report.ownedForeground = { sameProcess: true, sameRootOwner: true, distinctHwnd: true };
  await call('get_app_state', title, { disableDiff: true });
  await call('click', title, { element_index: index('Fixture counter') });
  assert.equal((await fixtureState()).clicks, 3);
  await call('activate_app', title);
  assert.equal((await fixtureState()).foregroundHwnd, family.foregroundHwnd);
  checks.push('owned foreground overlay permits main-window indexed click and activation without stealing focus');
  await call('press_key', title, { key: 'Shift', duration: 0.1 });
  await call('type_text', title, { text: 'Overlay 中文 😀' });
  assert.equal((await fixtureState()).overlayNotes, 'Overlay 中文 😀');
  assert.equal((await fixtureState()).notes, pasteText);
  checks.push('keyboard and literal Unicode input use the foreground family focus');
  await imageState(title);
  const overlayPoint = await fixtureState();
  await call('click', title, { x: overlayPoint.x, y: overlayPoint.y });
  assert.equal((await fixtureState()).overlayClicks, 1);
  assert.equal((await fixtureState()).clicks, 3);
  checks.push('coordinate hit testing accepts the owned overlay at the main-window point');

  const otherTitle = `OpenCU Other Fixture ${token}`;
  const otherOutput = path.join(temp, 'other.json');
  const otherCommand = path.join(temp, 'other-command.txt');
  const other = spawn('powershell.exe', ['-NoLogo', '-NoProfile', '-NonInteractive', '-STA', '-ExecutionPolicy', 'Bypass', '-File', path.join(root, 'tests/fixtures/OpenCUFixture.ps1'), '-Output', otherOutput, '-CommandFile', otherCommand, '-Title', otherTitle, '-Background'], { windowsHide: true, stdio: 'ignore' });
  owned.push({ child: other, marker: otherCommand });
  await waitFor(async () => {
    if (other.exitCode !== null) throw new Error('Background fixture exited');
    try { return JSON.parse(await readFile(otherOutput, 'utf8')).pid === other.pid; } catch { return false; }
  }, 'background fixture start', 30000);
  assert.equal((await fixtureState()).foregroundHwnd, family.foregroundHwnd);
  // Before creating a cold connection, let prior synthetic input age out of
  // GetLastInputInfo; its startup baseline cannot attribute events from an
  // earlier connection. This is preparation, never a retry of refused input.
  await pause(10500);
  const idleBefore = await fixtureState();
  assert.ok(idleBefore.idleMs >= 10000, 'Desktop must be idle for 10 seconds; no input is retried');
  const primaryClient = client;
  client = new Client({ name: 'opencu-windows-foreign-fixture-client', version: '1.0' });
  connections.push(client);
  const coldTransport = new StdioClientTransport({ command: process.execPath, args: [path.join(root, 'src/server.mjs')], stderr: 'pipe' });
  coldTransport.stderr?.resume(); await client.connect(coldTransport);
  await call('get_app_state', otherTitle, { disableDiff: true });
  assert.equal((await fixtureState()).foregroundHwnd, family.foregroundHwnd);
  checks.push('cold connection reads a different-process background window without taking foreground');
  // The fixture still holds LockSetForegroundWindow. On an idle desktop the
  // contract permits foreground-lock acquisition (AttachThreadInput, as
  // wanctl's Focus does), with no synthetic Alt or fixture-side activation.
  const beforeActivation = await fixtureState(otherOutput);
  assert.notEqual(beforeActivation.foregroundPid, other.pid);
  await call('get_app_state', otherTitle, { disableDiff: true });
  await call('click', otherTitle, { element_index: index('Fixture counter') });
  await waitFor(async () => (await fixtureState(otherOutput)).clicks === 1, 'background fixture indexed click');
  const acquired = await fixtureState(otherOutput);
  assert.equal(acquired.foregroundPid, other.pid);
  assert.equal(acquired.foregroundRootOwner, acquired.mainRootOwner);
  assert.equal((await fixtureState()).clicks, 3, 'Input must not reach the previous foreground fixture');
  report.idleForegroundAcquisition = {
    idleThresholdMs: 10000, idleBeforeConnectionMs: idleBefore.idleMs,
    launchedInBackground: true, foregroundLockHeld: true,
    beforeForegroundPid: beforeActivation.foregroundPid, targetPid: other.pid,
    afterForegroundPid: acquired.foregroundPid, verifiedTargetFamily: true,
    indexedClicksBefore: beforeActivation.clicks, indexedClicksAfter: acquired.clicks,
  };
  checks.push('idle cold connection takes the foreground lock, brings a background fixture forward and delivers an indexed click');

  // Exercise both tagged keyboard and pointer input, then immediately switch
  // families. Polling LASTINPUTINFO after SendInput would wrongly refuse this.
  await call('press_key', otherTitle, { key: 'Escape' });
  const otherSize = await imageState(otherTitle);
  const otherPoint = await fixtureState(otherOutput);
  assert.ok(otherPoint.x < otherSize.width && otherPoint.y < otherSize.height);
  await call('click', otherTitle, { x: otherPoint.x, y: otherPoint.y });
  // Minimize alone need not yield foreground. Explicitly activate a different
  // fixture through the primary engine before testing background restoration.
  await fixtureCommand('minimize', otherCommand);
  assert.equal((await fixtureState(otherOutput)).minimized, true);
  const coldClient = client;
  client = primaryClient;
  await call('activate_app', title);
  client = coldClient;
  await waitFor(async () => (await fixtureState()).foregroundPid === fixture.pid, 'primary fixture foreground');
  const minimizedBackground = await fixtureState(otherOutput);
  assert.equal(minimizedBackground.minimized, true);
  assert.equal(minimizedBackground.foregroundPid, fixture.pid);
  assert.notEqual(minimizedBackground.foregroundPid, other.pid);
  const afterSynthetic = await fixtureState(otherOutput);
  assert.ok(afterSynthetic.idleMs < 10000, 'Synthetic input must still be recent for this regression');
  await call('activate_app', otherTitle);
  await waitFor(async () => {
    const s = await fixtureState(otherOutput);
    return !s.minimized && s.foregroundPid === other.pid && s.foregroundRootOwner === s.mainRootOwner;
  }, 'minimized background fixture restored and activated');
  assert.equal((await fixtureState(otherOutput)).clicks, 2);
  report.idleForegroundAcquisition.syntheticInputIdleMs = afterSynthetic.idleMs;
  report.idleForegroundAcquisition.minimizedRestoredByActivateApp = true;
  checks.push('recent engine keyboard and mouse input permits minimized-window activation without PERSON_ACTIVE or the Escape latch');
  // SW_SHOWMINIMIZED explicitly keeps this window active while minimizing it;
  // verify the precondition instead of relying on a desktop's minimize policy.
  await fixtureCommand('minimize-foreground', otherCommand);
  const minimizedForeground = await fixtureState(otherOutput);
  assert.equal(minimizedForeground.minimized, true);
  assert.equal(minimizedForeground.foregroundPid, other.pid);
  assert.equal(minimizedForeground.foregroundHwnd, minimizedForeground.mainHwnd);
  await call('activate_app', otherTitle);
  await waitFor(async () => {
    const s = await fixtureState(otherOutput);
    return !s.minimized && s.foregroundHwnd === s.mainHwnd;
  }, 'minimized foreground fixture restored');
  const restoredForeground = await fixtureState(otherOutput);
  assert.equal(restoredForeground.clicks, 2);
  assert.equal(restoredForeground.foregroundPid, other.pid);
  assert.equal(restoredForeground.foregroundRootOwner, restoredForeground.mainRootOwner);
  report.minimizedForegroundRestoration = {
    beforeMinimized: minimizedForeground.minimized, afterMinimized: restoredForeground.minimized,
    beforeForegroundHwnd: minimizedForeground.foregroundHwnd,
    afterForegroundHwnd: restoredForeground.foregroundHwnd,
    targetHwnd: restoredForeground.mainHwnd,
    clicksBefore: minimizedForeground.clicks, clicksAfter: restoredForeground.clicks,
  };
  checks.push('activate_app restores an iconic window that already holds foreground');
  await client.close(); client = primaryClient;
  await writeCommand(otherCommand, 'close');
  await waitFor(() => other.exitCode !== null, 'background fixture closed');

  await fixtureCommand('overlay-close');
  await call('get_app_state', title, { disableDiff: true });
  const interrupted = call('press_key', title, { key: 'Shift', duration: 3 }, 'WINDOW_FOCUS_CHANGED')
    .then(value => ({ value }), error => ({ error }));
  await pause(700);
  await fixtureCommand('unowned');
  const stopped = await interrupted; if (stopped.error) throw stopped.error;
  checks.push('unrelated foreground transition stops in-flight input and releases held keys');
  const unrelated = await fixtureState();
  assert.equal(unrelated.foregroundPid, fixture.pid);
  assert.notEqual(unrelated.foregroundRootOwner, unrelated.mainRootOwner);
  await call('get_app_state', title, { disableDiff: true });
  await call('click', title, { element_index: index('Fixture counter') });
  await waitFor(async () => (await fixtureState()).clicks === 4, 'main fixture receives reacquired indexed click');
  const reacquired = await fixtureState();
  assert.equal(reacquired.foregroundPid, fixture.pid);
  assert.equal(reacquired.foregroundHwnd, reacquired.mainHwnd);
  assert.equal(reacquired.foregroundRootOwner, reacquired.mainRootOwner);
  assert.equal(reacquired.overlayClicks, unrelated.overlayClicks);
  assert.equal(reacquired.overlayNotes, unrelated.overlayNotes);
  // Also exercise activate_app from the unrelated window, not just a no-op
  // activation after the indexed click has already acquired foreground.
  await fixtureCommand('overlay-activate');
  const unrelatedAgain = await fixtureState();
  assert.equal(unrelatedAgain.error, '', 'fixture overlay-activate');
  assert.equal(unrelatedAgain.foregroundHwnd, unrelated.foregroundHwnd);
  assert.notEqual(unrelatedAgain.foregroundRootOwner, unrelatedAgain.mainRootOwner);
  await call('activate_app', title);
  await waitFor(async () => (await fixtureState()).foregroundHwnd === reacquired.mainHwnd, 'main fixture activated from unrelated window');
  const activated = await fixtureState();
  assert.equal(activated.foregroundPid, fixture.pid);
  assert.equal(activated.foregroundRootOwner, activated.mainRootOwner);
  assert.equal(activated.clicks, 4);
  assert.equal(activated.overlayClicks, unrelated.overlayClicks);
  assert.equal(activated.overlayNotes, unrelated.overlayNotes);
  report.unrelatedForegroundAcquisition = {
    beforeForegroundHwnd: unrelated.foregroundHwnd, targetHwnd: reacquired.mainHwnd,
    afterClickForegroundHwnd: reacquired.foregroundHwnd,
    afterActivateForegroundHwnd: activated.foregroundHwnd,
    clicksBefore: unrelated.clicks, clicksAfter: activated.clicks,
    unrelatedClicksBefore: unrelated.overlayClicks, unrelatedClicksAfter: activated.overlayClicks,
    unrelatedNotesUnchanged: activated.overlayNotes === unrelated.overlayNotes,
  };
  checks.push('idle input and activate_app acquire the target family from an unrelated same-process window without sending it input');
  await fixtureCommand('overlay-close');

  await fixtureCommand('owned-overlapped');
  const overlapped = await fixtureState();
  assert.equal(overlapped.foregroundPid, fixture.pid);
  assert.equal(overlapped.foregroundOwner, overlapped.mainHwnd);
  assert.notEqual(overlapped.foregroundRootOwner, overlapped.mainRootOwner);
  await call('get_app_state', title, { disableDiff: true });
  await call('click', title, { element_index: index('Fixture counter') });
  await call('activate_app', title);
  assert.equal((await fixtureState()).clicks, 5);
  assert.equal((await fixtureState()).foregroundHwnd, overlapped.foregroundHwnd);
  checks.push('owned non-popup window is accepted through the actual owner chain');
  await fixtureCommand('overlay-close');

  await fixtureCommand('close');
  await waitFor(() => fixture.exitCode !== null, 'fixture closed');

  const chromeCandidates = [process.env.OPENCU_TEST_CHROME,
    process.env.PROGRAMFILES && path.join(process.env.PROGRAMFILES, 'Google/Chrome/Application/chrome.exe'),
    process.env['PROGRAMFILES(X86)'] && path.join(process.env['PROGRAMFILES(X86)'], 'Google/Chrome/Application/chrome.exe'),
    process.env.LOCALAPPDATA && path.join(process.env.LOCALAPPDATA, 'Google/Chrome/Application/chrome.exe')].filter(Boolean);
  let chrome;
  for (const candidate of chromeCandidates) { try { await access(candidate); chrome = candidate; break; } catch {} }
  assert.ok(chrome, 'Install Chrome or set OPENCU_TEST_CHROME to its executable');
  const chromeTitle = `OpenCU Chrome ${token}`;
  http = createServer((req, res) => {
    res.setHeader('Content-Type', 'text/html; charset=utf-8');
    res.end(`<!doctype html><meta charset="utf-8"><title>${chromeTitle}</title><h1>OpenCU Chrome page text</h1><p>这是一次本地页面验收</p><a href="#result" onclick="document.querySelector('output').textContent='Fixture link clicked'">Fixture test link</a><output></output><input aria-label="Fixture web notes" oninput="document.querySelector('output').textContent=this.value"><input aria-label="Fixture web password" type="password" value="OpenCU-Web-Secret-2917"><div style="height:1600px">Scroll fixture</div>`);
  });
  await new Promise(resolve => http.listen(0, '127.0.0.1', resolve));
  const url = `http://127.0.0.1:${http.address().port}/`;
  const browser = spawn(chrome, [`--user-data-dir=${profile}`, '--no-first-run', '--no-default-browser-check', '--mute-audio', '--disable-background-networking', '--disable-extensions', '--new-window', url], { windowsHide: true, stdio: 'ignore' });
  owned.push({ child: browser, marker: profile });
  browser.on('error', e => { report.browserError = e.message; });
  // A first launch on a fresh profile can take well over a few seconds.
  for (let attempt = 0; ; attempt++) {
    await pause(1000);
    try {
      await call('get_app_state', chromeTitle, { waitForText: 'OpenCU Chrome page text', waitTimeoutMs: 15000, disableDiff: true });
      break;
    } catch (error) {
      if (!String(error.message).includes('APP_NOT_FOUND') || attempt >= 20) throw error;
    }
  }
  index('Fixture test link');
  assert.ok(!tree.includes('OpenCU-Web-Secret-2917'));
  checks.push('web password value is redacted');
  checks.push('Chrome native UIA reaches local page text and links without accessibility flags');
  await call('click', chromeTitle, { element_index: index('Fixture test link') });
  await call('get_app_state', chromeTitle, { waitForText: 'Fixture link clicked', disableDiff: true });
  checks.push('Chrome indexed link action');
  await call('click', chromeTitle, { element_index: index('Fixture web notes'), duration: 0.05 });
  await call('type_text', chromeTitle, { text: 'Web 中文 😀' });
  await call('get_app_state', chromeTitle, { waitForText: 'value="Web 中文 😀"', disableDiff: true });
  assert.match(tree, /Text title="Web 中文 😀"/, 'The web input handler must update its output element');
  checks.push('Chrome literal Unicode typing preserves spaces and dispatches input');

  report.ok = true;
} catch (error) {
  report.error = error.stack ?? String(error); process.exitCode = 1;
} finally {
  for (const connection of connections) {
    try { await connection.close(); } catch (e) { report.closeError = String(e); report.ok = false; }
  }
  if (http) await new Promise(resolve => http.close(resolve));
  const cleanupErrors = [];
  for (const { child, marker } of owned.reverse()) {
    try {
      for (const pid of privateProcesses(marker)) {
        // Verify the private marker before killing this PID and its descendants.
        try { execFileSync('taskkill.exe', ['/PID', String(pid), '/T', '/F'], { windowsHide: true, stdio: 'pipe' }); } catch {}
      }
      await waitFor(() => privateProcesses(marker).length === 0, 'all private processes exited');
      if (child.exitCode === null && child.signalCode === null) await waitFor(() => child.exitCode !== null || child.signalCode !== null, 'owned process exit');
    } catch (e) { cleanupErrors.push(String(e)); }
  }
  if (cleanupErrors.length) { report.cleanupErrors = cleanupErrors; report.ok = false; }
  else { checks.push('all temporary fixture and browser processes closed'); await rm(temp, { recursive: true, force: true }); }
  if (!report.ok) process.exitCode = 1;
  await writeFile(path.join(area, 'report.json'), JSON.stringify(report, null, 2) + '\n');
  console.log(JSON.stringify({ ...report, evidence: area }, null, 2));
}
