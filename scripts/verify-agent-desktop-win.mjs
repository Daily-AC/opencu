#!/usr/bin/env node
// Run FROM A FOREGROUND TERMINAL on an authorized idle Windows desktop.
// The parent fixture and launcher need foreground rights to test nonactivation.
// Disposable fixtures only; do not run this suite from a headless shell.
// Parent stimuli are SendInput, NOT evidence of hardware/physical Escape behavior.
// Lock/unlock remains manual: the suite cannot unlock without a password and must
// never obtain one. --locked-parent pauses for manual lock/unlock and checks
// pattern delivery, retained reads/capture and synthetic-input refusal.
import assert from 'node:assert/strict';
import { spawn, execFileSync } from 'node:child_process';
import { cp, mkdir, mkdtemp, readFile, rename, rm, writeFile } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { setTimeout as pause } from 'node:timers/promises';
import { Client } from '@modelcontextprotocol/sdk/client/index.js';
import { StdioClientTransport } from '@modelcontextprotocol/sdk/client/stdio.js';
import { agentDesktopAvailability, agentDesktopHelper, prepareAgentDesktop } from '../src/agent-desktop.mjs';

if (process.platform !== 'win32') throw new Error('Windows-only acceptance; no desktop was touched.');
if (!process.argv.includes('--allow-desktop')) throw new Error('Run with --allow-desktop FROM A FOREGROUND TERMINAL on an authorized idle Windows desktop; a headless launcher cannot test foreground theft.');
const lockedParent = process.argv.includes('--locked-parent');
const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
await mkdir(path.join(root, '.cache'), { recursive: true });
const area = await mkdtemp(path.join(root, '.cache/agent-desktop-acceptance-'));
const temporary = path.join(area, 'temporary'); await mkdir(temporary);
const parentExe = path.join(temporary, 'OpenCU-Parent-Fixture.exe');
const childExe = path.join(temporary, 'OpenCU-Child-Fixture.exe');
const lockedLaunchExe = path.join(temporary, 'OpenCU-Locked-Launch-Fixture.exe');
const report = { test: 'windows-agent-desktop', ok: false, checks: [],
  parentStimulus: 'SendInput in parent session; not hardware input',
  manualFollowups: ['deliberate click enables interaction; deactivation returns to watch-only; physical Escape still stops',
    'locked parent: --locked-parent checks patterns and refused typing; separately verify lock mid-action, physical Escape and disconnect/logoff', 'smart-card sign-in', 'host crash during startup',
    'external minimize, covered or partly off-screen viewport, GPU/video', 'unsupported Windows editions/policies'] };
let client, parent;
const check = (name, data = {}) => { report.checks.push({ name, ...data }); console.log(name); };
async function waitFor(fn, description, ms = 20000) {
  const until = Date.now() + ms;
  while (Date.now() < until) { const result = await fn(); if (result) return result; await pause(75); }
  throw new Error(`Timed out: ${description}`);
}
async function waitForParentLock(locked) {
  const until = Date.now() + 180000;
  while (Date.now() < until) {
    const status = await control('status');
    assert.equal(status.state, 'running', 'Manual lock/unlock must keep the same child');
    if (status.parentLocked === locked) return status;
    await pause(500);
  }
  throw new Error(`Timed out waiting for manual parent ${locked ? 'lock' : 'unlock'}; nothing was retried.`);
}
async function state(exe) { try { return JSON.parse(await readFile(`${exe}.json`, 'utf8')); } catch { return null; } }
async function command(exe, value) {
  const file = `${exe}.command`;
  await writeFile(`${file}.tmp`, value); await rename(`${file}.tmp`, file);
  await waitFor(async () => { try { await readFile(file); return false; } catch { return true; } }, 'fixture command');
}
async function call(name, args = {}, refusal) {
  const result = await client.callTool({ name, arguments: args }, undefined, { timeout: 150000 });
  if (refusal) assert.equal(result._meta?.['opencu/error'], refusal, JSON.stringify(result));
  else assert.ok(!result.isError, JSON.stringify(result));
  return result;
}
const text = result => result.content.filter(c => c.type === 'text').map(c => c.text).join('\n');
const control = async action => JSON.parse(text(await call('agent_desktop', { action })));
const index = (result, label) => {
  const line = text(result).split('\n').find(line => line.includes(`title=${JSON.stringify(label)}`));
  assert.ok(line, `Missing fixture element ${label}`); return Number(line.match(/^\s*\[(\d+)\]/)[1]);
};
try {
  // Exercise the same non-elevating preparation used by first start after an
  // update. Disabled machines refuse with the real one-time setup command.
  const capability = await prepareAgentDesktop(root);
  assert.equal(capability.available, true, JSON.stringify(capability)); check('setup-check', capability);
  const helper = await agentDesktopHelper(root);
  const ipc = JSON.parse(execFileSync(helper, ['self-test'], { windowsHide: true, encoding: 'utf8', timeout: 15000 }));
  assert.equal(ipc.ok, true); check('real-pipe-authentication', ipc);
  const compiler = path.join(process.env.WINDIR, 'Microsoft.NET/Framework64/v4.0.30319/csc.exe');
  execFileSync(compiler, ['/nologo', '/target:winexe', '/platform:x64', `/out:${parentExe}`,
    '/reference:System.Windows.Forms.dll', '/reference:System.Drawing.dll', '/reference:System.Web.Extensions.dll',
    path.join(root, 'tests/fixtures/AgentDesktopFixture.cs')], { windowsHide: true, stdio: 'pipe' });
  await cp(parentExe, childExe);
  if (lockedParent) await cp(parentExe, lockedLaunchExe);
  parent = spawn(parentExe, ['parent'], { windowsHide: false, stdio: 'ignore' });
  const baseline = await waitFor(async () => { const s = await state(parentExe); return s?.foreground && s; }, 'parent foreground; launch this script FROM A FOREGROUND TERMINAL, not a headless shell');
  await command(parentExe, 'monitor');
  client = new Client({ name: 'opencu-agent-desktop-acceptance', version: '1' });
  const transport = new StdioClientTransport({ command: process.execPath, args: [path.join(root, 'src/server.mjs')], stderr: 'pipe' });
  transport.stderr.resume(); await client.connect(transport);
  assert.equal((await control('status')).state, 'inactive');
  const started = await control('start');
  assert.equal(started.state, 'running'); assert.notEqual(started.sessionId, baseline.sessionId);
  check('start-child-session', { childSession: started.sessionId, parentSession: baseline.sessionId });
  assert.equal((await state(parentExe)).foreignForeground, 0, 'Opening host stole parent foreground');
  check('nonactivating-open-from-foreground-launcher');
  const first = await call('get_app_state', { app: childExe, includeScreenshot: true, disableDiff: true });
  assert.ok(first.content.some(c => c.type === 'image'), 'Child WGC screenshot is required');
  const child = await waitFor(() => state(childExe), 'child fixture');
  assert.equal(child.sessionId, started.sessionId);
  const inventory = text(await call('list_apps'));
  assert.ok(!inventory.includes(`"pid":${baseline.pid}`), 'Parent window leaked into child inventory');
  check('child-launch-capture-and-inventory');
  // Keep the actual parent cursor over the inactive preview while the child
  // monitor fences input. These are SendInput moves, NOT Hyper-V hardware input.
  await command(parentExe, `hover:${started.hostPid}`);
  await waitFor(async () => (await state(parentExe))?.hoverMoves >= 5, 'pointer over watch-only view');
  const watched = await call('run_actions', { app: childExe, actions: [{ method: 'wait', ms: 1000 }], disableDiff: true });
  await call('click', { app: childExe, element_index: index(watched, 'Increment fixture') });
  await command(parentExe, 'hover-stop');
  const hovered = await state(parentExe);
  assert.equal(hovered.foreignForeground, 0); assert.equal(hovered.injectedFailures, 0);
  assert.ok(hovered.hoverMoves >= 5);
  check('watch-only-hover-does-not-interrupt', { stimulus: 'parent SendInput mouse moves; no clicks or hardware input', moves: hovered.hoverMoves });
  await command(parentExe, `park:${started.hostPid}`);
  const parkedBefore = await waitFor(async () => { const s = await state(parentExe); return s?.parked && s; }, 'stationary parent pointer over view');
  report.parkedPointer = { before: parkedBefore };
  for (let round = 0; round < 3; round++) {
    let current = await call('get_app_state', { app: childExe, disableDiff: true });
    await call('click', { app: childExe, element_index: index(current, 'Increment fixture') });
    current = await call('get_app_state', { app: childExe, disableDiff: true });
    await call('click', { app: childExe, element_index: index(current, 'Fixture text') });
  }
  await pause(250); // Let loopback pointer updates and fixture observations arrive.
  const parkedAfter = await state(parentExe);
  report.parkedPointer.after = parkedAfter; // Preserve evidence even when refused.
  assert.deepEqual(parkedAfter.cursor, parkedBefore.parkedCursor, 'Child clicks moved the parked parent pointer');
  assert.equal(parkedAfter.unexpectedCursor, 0);
  assert.equal(parkedAfter.foreignForeground, 0);
  assert.equal(parkedAfter.injectedFailures, 0);
  check('watch-only-server-pointer-isolation', { stimulus: 'one parent SendInput move, then no parent mouse input', before: parkedBefore.parkedCursor, after: parkedAfter.cursor });
  await command(parentExe, 'begin');
  for (let round = 0; round < 6; round++) {
    let current = await call('get_app_state', { app: childExe, disableDiff: true });
    await call('click', { app: childExe, element_index: index(current, 'Increment fixture') });
    // A click result is a diff against the previous state; unchanged fields are
    // absent from it, so look the text field up in a full state.
    current = await call('get_app_state', { app: childExe, disableDiff: true });
    await call('click', { app: childExe, element_index: index(current, 'Fixture text') });
    await call('type_text', { app: childExe, text: `agent-${round};` });
    await pause(600);
  }
  const parentAfter = await waitFor(async () => { const s = await state(parentExe); return s?.chunks === 20 && s.text === s.expected && s; }, '20 parent chunks');
  const childAfter = await state(childExe);
  Object.assign(report, { parentAfter, childAfter }); // kept in result.json even if an assertion below fails
  assert.equal(parentAfter.foreignForeground, 0); assert.equal(parentAfter.injectedFailures, 0);
  assert.equal(parentAfter.unexpectedCursor, 0); assert.equal(parentAfter.clicks, 0);
  assert.equal(childAfter.clicks, 10); // One hover, three parked-pointer, six concurrent checks.
  assert.equal(childAfter.text, Array.from({ length: 6 }, (_, i) => `agent-${i};`).join(''));
  check('concurrent-input-isolation', { parent: parentAfter, child: childAfter });
  if (lockedParent) {
    // Complete all parent stimuli before inviting manual interaction. Locking
    // changes parent foreground/cursor, so finish that monitor too.
    await command(parentExe, 'end');
    await call('get_app_state', { app: childExe, disableDiff: true });
    const before = await state(childExe);
    console.log('MANUAL: lock the parent with Win+L now. Keep it locked until the checks finish (up to three minutes to lock). No password is collected.');
    const locked = await waitForParentLock(true);
    assert.equal(locked.sessionId, started.sessionId);
    assert.equal(locked.hostPid, started.hostPid);
    let current = await call('get_app_state', { app: childExe, includeScreenshot: true, disableDiff: true });
    assert.ok(current.content.some(c => c.type === 'image'), 'Locked child screenshot is required');
    const clicked = await call('click', { app: childExe, element_index: index(current, 'Increment fixture') });
    assert.notEqual(clicked._meta?.['opencu/actionOutcome'], 'unknown', text(clicked));
    assert.equal(typeof clicked._meta?.['opencu/pattern'], 'string');
    assert.match(text(clicked), new RegExp(`Clicks: ${before.clicks + 1}`));
    await waitFor(async () => (await state(childExe))?.clicks === before.clicks + 1, 'exactly one locked pattern click');
    assert.equal((await control('status')).parentLocked, true, 'Parent unlocked during click');
    current = await call('get_app_state', { app: childExe, disableDiff: true });
    const value = 'locked pattern value';
    const valued = await call('set_value', { app: childExe, element_index: index(current, 'Fixture text'), value });
    assert.notEqual(valued._meta?.['opencu/actionOutcome'], 'unknown', text(valued));
    assert.equal(valued._meta?.['opencu/pattern'], 'Value.SetValue');
    assert.ok(text(valued).includes(value), 'Fresh state must show the new value');
    await waitFor(async () => (await state(childExe))?.text === value, 'locked ValuePattern text');
    assert.equal((await control('status')).parentLocked, true, 'Parent unlocked during set_value');
    const refused = await call('type_text', { app: childExe, text: 'MUST-NOT-APPEAR' }, 'SCREEN_LOCKED');
    assert.match(text(refused), /indexed.*set_value.*perform_secondary_action/);
    await pause(250);
    const after = await state(childExe);
    assert.equal(after.clicks, before.clicks + 1);
    assert.equal(after.text, value);
    assert.equal(after.sessionId, started.sessionId);
    assert.equal((await control('status')).parentLocked, true, 'Parent unlocked before refusal check finished');
    check('locked-parent-patterns-and-refused-typing', { before, after, locked,
      patterns: { click: clicked._meta?.['opencu/pattern'], setValue: valued._meta?.['opencu/pattern'] } });
    // Fresh executable identity: this must launch through get_app_state while
    // locked, never through activate_app. Session logoff cleans it up as usual.
    const launched = await call('get_app_state', { app: lockedLaunchExe, includeScreenshot: true, disableDiff: true });
    const launchState = await waitFor(() => state(lockedLaunchExe), 'locked child launch');
    assert.equal(launchState.sessionId, started.sessionId);
    assert.equal(launchState.clicks, 0); assert.equal(launchState.text, '');
    assert.ok(launched.content.some(c => c.type === 'image'), 'Locked launched fixture screenshot is required');
    assert.equal((await control('status')).parentLocked, true, 'Parent unlocked during launch check');
    check('locked-parent-launch-without-activation-request', { fixture: launchState });
    console.log('MANUAL: locked checks passed. Unlock the parent now (up to three minutes). No input will be replayed.');
    const unlocked = await waitForParentLock(false);
    assert.equal(unlocked.sessionId, started.sessionId);
    assert.equal(unlocked.hostPid, started.hostPid);
    await pause(500);
    const afterUnlock = await state(childExe);
    assert.equal(afterUnlock.clicks, after.clicks);
    assert.equal(afterUnlock.text, after.text, 'Refused typing was replayed after unlock');
    check('manual-unlock-keeps-child-without-replay', { unlocked });
  }
  const stopped = await control('stop'); assert.equal(stopped.state, 'inactive');
  assert.equal((await agentDesktopAvailability(root)).existingChildSession, null, 'Tool stop left a child session');
  check('tool-stop-logs-off');
  // Reusing the same connection after a tool stop is intentional, not after a
  // person stop. Task RunEx must work more than once (HKCU Run did not).
  const restarted = await control('start'); assert.equal(restarted.state, 'running');
  check('second-explicit-start');
  // Send the normal WM_CLOSE path only to the exact host PID returned by this
  // connection, after checking its fixed title. No app-name-wide termination.
  const script = `$p=Get-Process -Id ${restarted.hostPid}; if($p.MainWindowTitle -ne 'OpenCU agent desktop'){throw 'Unexpected host'}; if(!$p.CloseMainWindow()){throw 'Cannot close host'}`;
  execFileSync(path.join(process.env.WINDIR, 'System32/WindowsPowerShell/v1.0/powershell.exe'),
    ['-NoProfile', '-NonInteractive', '-EncodedCommand', Buffer.from(script, 'utf16le').toString('base64')], { windowsHide: true, stdio: 'pipe' });
  await waitFor(async () => (await control('status')).stoppedByPerson, 'host-close latch');
  for (const [name, args] of [['agent_desktop', { action: 'start' }], ['list_apps', {}], ['get_app_state', { app: childExe }]]) {
    await call(name, args, 'USER_STOPPED');
  }
  await control('stop');
  assert.equal((await agentDesktopAvailability(root)).existingChildSession, null, 'Window close left a child session');
  await call('agent_desktop', { action: 'start' }, 'USER_STOPPED');
  check('window-close-latches-entire-connection');
  assert.equal((await state(parentExe)).foreignForeground, 0);
  await command(parentExe, 'end');
  report.ok = true;
} catch (cause) { report.error = cause.stack; process.exitCode = 1; }
finally {
  if (client) {
    try { await call('agent_desktop', { action: 'stop' }); } catch (cause) { report.cleanupError = cause.message; report.ok = false; process.exitCode = 1; }
    await client.close();
  }
  if (parent && parent.exitCode === null) {
    try { await command(parentExe, 'close'); } catch { parent.kill(); }
    await waitFor(() => parent.exitCode !== null, 'parent fixture exit').catch(() => parent.kill());
  }
  // Child fixture ends through session logoff. Retain files on failure for review.
  if (report.ok) await rm(temporary, { recursive: true, force: true });
  await writeFile(path.join(area, 'result.json'), JSON.stringify(report, null, 2) + '\n');
  console.log(JSON.stringify({ ok: report.ok, report: path.join(area, 'result.json') }));
}
