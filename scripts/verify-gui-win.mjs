#!/usr/bin/env node
// Run manually on an idle, unlocked Windows desktop. This takes the foreground.
// All desktop reads/actions go through MCP. The fixture's private command file
// only moves its own window (to simulate external geometry changes), hashes the
// clipboard without changing it, and closes that fixture.
import assert from 'node:assert/strict';
import { spawn, execFileSync } from 'node:child_process';
import { createHash, randomUUID } from 'node:crypto';
import { createServer } from 'node:http';
import { access, mkdir, mkdtemp, readFile, writeFile, rm } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { setTimeout as pause } from 'node:timers/promises';
import { Client } from '@modelcontextprotocol/sdk/client/index.js';
import { StdioClientTransport } from '@modelcontextprotocol/sdk/client/stdio.js';

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
let client, http;
let tree = '', sequence = 0;
await mkdir(area, { recursive: true });

function powershell(script) {
  return execFileSync('powershell.exe', ['-NoLogo', '-NoProfile', '-NonInteractive', '-EncodedCommand', Buffer.from(script, 'utf16le').toString('base64')], { windowsHide: true, encoding: 'utf8', timeout: 15000 }).trim();
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
async function fixtureState() {
  // The fixture owns this file; a timer write can overlap our read.
  for (let attempt = 0; ; attempt++) {
    try { return JSON.parse(await readFile(output, 'utf8')); }
    catch (error) { if (attempt === 5) throw error; await pause(20); }
  }
}
async function fixtureCommand(command) {
  await waitFor(async () => { try { await access(commandFile); return false; } catch { return true; } }, 'fixture command idle');
  await writeFile(commandFile, command);
  await waitFor(async () => { try { await access(commandFile); return false; } catch { return true; } }, `fixture command ${command}`);
  await pause(150);
}
function index(label) {
  const line = tree.split('\n').find(line => line.includes(`title=${JSON.stringify(label)}`));
  assert.ok(line, `Missing fixture control: ${label}`);
  return Number(line.match(/^\s*\[(\d+)\]/)?.[1]);
}
async function call(name, app, args = {}, errorCode) {
  const result = await client.callTool({ name, arguments: { app, ...args } }, undefined, { timeout: 90000 });
  const text = result.content.filter(c => c.type === 'text').map(c => c.text).join('\n');
  await writeFile(path.join(area, `call-${++sequence}.json`), JSON.stringify({ name, args, result }, null, 2));
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
  client = new Client({ name: 'opencu-windows-fixture-client', version: '1.0' });
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
  assert.equal((await fixtureState()).notes, 'Windows 中文 😀');
  checks.push('key chord and Unicode typing');
  const holding = call('press_key', title, { key: 'Shift', duration: 3 }).then(value => ({ value }), error => ({ error }));
  await pause(700);
  const indicator = powershell(`Add-Type -TypeDefinition 'using System; using System.Runtime.InteropServices; public class OpenCUIndicatorProbe { [DllImport("user32.dll",CharSet=CharSet.Unicode)] public static extern IntPtr FindWindow(string cls,string title); [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr w); [DllImport("user32.dll")] public static extern bool GetWindowDisplayAffinity(IntPtr w,out uint a); }'; $w=[OpenCUIndicatorProbe]::FindWindow('OpenCUOperationIndicator',$null); [uint32]$a=0; $ok=[OpenCUIndicatorProbe]::GetWindowDisplayAffinity($w,[ref]$a); @{visible=[OpenCUIndicatorProbe]::IsWindowVisible($w);affinity=$a;affinityReadable=$ok} | ConvertTo-Json -Compress`);
  const held = await holding; if (held.error) throw held.error;
  const indicatorState = JSON.parse(indicator);
  assert.equal(indicatorState.visible, true); assert.equal(indicatorState.affinityReadable, true); assert.equal(indicatorState.affinity, 17);
  checks.push('visible operation indicator is excluded from capture');
  await call('press_key', title, { key: 'Escape' });
  checks.push('engine-injected Escape does not trigger the physical stop latch');


  await fixtureCommand('digest');
  const baseline = await fixtureState(); assert.equal(baseline.error, '');
  await call('run_actions', title, { actions: [{ method: 'press_key', key: 'ctrl+a' }, { method: 'paste', format: 'text', text: '粘贴 😀\r\nSecond line' }] });
  assert.equal((await fixtureState()).notes.replaceAll('\r\n', '\n'), '粘贴 😀\nSecond line');
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
  await call('drag', title, { from_x: 1, from_y: 1, to_x: 2, to_y: 2 }, 'UNSUPPORTED_ON_WINDOWS');
  checks.push('unsupported operation refused');

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
    res.end(`<!doctype html><meta charset="utf-8"><title>${chromeTitle}</title><h1>OpenCU Chrome page text</h1><p>这是一次本地页面验收</p><a href="#result" onclick="document.querySelector('output').textContent='Fixture link clicked'">Fixture test link</a><output></output><input aria-label="Fixture web password" type="password" value="OpenCU-Web-Secret-2917"><div style="height:1600px">Scroll fixture</div>`);
  });
  await new Promise(resolve => http.listen(0, '127.0.0.1', resolve));
  const url = `http://127.0.0.1:${http.address().port}/`;
  const browser = spawn(chrome, [`--user-data-dir=${profile}`, '--no-first-run', '--no-default-browser-check', '--mute-audio', '--disable-background-networking', '--disable-extensions', '--new-window', url], { windowsHide: true, stdio: 'ignore' });
  owned.push({ child: browser, marker: profile });
  browser.on('error', e => { report.browserError = e.message; });
  await pause(2500);
  await call('get_app_state', chromeTitle, { waitForText: 'OpenCU Chrome page text', waitTimeoutMs: 15000, disableDiff: true });
  index('Fixture test link');
  assert.ok(!tree.includes('OpenCU-Web-Secret-2917'));
  checks.push('web password value is redacted');
  checks.push('Chrome native UIA reaches local page text and links without accessibility flags');
  await call('click', chromeTitle, { element_index: index('Fixture test link') });
  await call('get_app_state', chromeTitle, { waitForText: 'Fixture link clicked', disableDiff: true });
  checks.push('Chrome indexed link action');
  report.ok = true;
} catch (error) {
  report.error = error.stack ?? String(error); process.exitCode = 1;
} finally {
  try { await client?.close(); } catch (e) { report.closeError = String(e); report.ok = false; }
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
