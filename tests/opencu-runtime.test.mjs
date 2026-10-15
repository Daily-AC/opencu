import assert from 'node:assert/strict';
import { chmod, cp, mkdir, mkdtemp, readFile, rm, symlink, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import test from 'node:test';
import { fileURLToPath } from 'node:url';
import { Client } from '@modelcontextprotocol/sdk/client/index.js';
import { StdioClientTransport } from '@modelcontextprotocol/sdk/client/stdio.js';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const state = { app: { id: 'dev.opencu.fixture', displayName: 'Fixture', pid: 123 }, text: 'App: "Fixture"\nWindow: "Fixture"\n1 button Press\n2 text field Value="initial"' };

async function fixture(t, results = []) {
  const dir = await mkdtemp(path.join(tmpdir(), 'opencu-test-'));
  let client;
  t.after(async () => { await client?.close(); await rm(dir, { recursive: true, force: true }); });
  await cp(path.join(root, 'src'), path.join(dir, 'src'), { recursive: true });
  await symlink(path.join(root, 'node_modules'), path.join(dir, 'node_modules'), 'dir');
  await writeFile(path.join(dir, 'package.json'), '{"type":"module"}');
  const binary = path.join(dir, '.build/OpenCU.app/Contents/MacOS/opencu-engine');
  await mkdir(path.dirname(binary), { recursive: true });
  await writeFile(path.join(dir, 'results.json'), JSON.stringify(results));
  const callsFile = path.join(dir, 'calls.jsonl');
  const pidFile = path.join(dir, 'engine.pid');
  await writeFile(binary, `#!${process.execPath}
import {appendFileSync,readFileSync,writeFileSync} from 'node:fs';
import {createInterface} from 'node:readline';
if (process.argv.slice(2).join(' ') !== 'serve') process.exit(99);
const results=JSON.parse(readFileSync(${JSON.stringify(path.join(dir, 'results.json'))},'utf8'));
writeFileSync(${JSON.stringify(pidFile)},String(process.pid));
const lines=createInterface({input:process.stdin});
lines.on('line',line=>{
 const q=JSON.parse(line);
 appendFileSync(${JSON.stringify(callsFile)},line+'\\n');
 const explicit=results.shift();
 const reply=explicit ?? {result:q.method==='list_apps' ? [] : q.method==='get_app_state' || q.method==='activate_app' ? ${JSON.stringify(state)} : {ok:true}};
 process.stdout.write(JSON.stringify({id:q.id,...reply})+'\\n');
});
`);
  await chmod(binary, 0o700);
  client = new Client({ name: 'unaffiliated-test-agent', version: '1' });
  const transport = new StdioClientTransport({ command: process.execPath, args: [path.join(dir, 'src/server.mjs')], stderr: 'pipe', env: { HOME: dir } });
  transport.stderr.resume();
  await client.connect(transport);
  return {
    call: (name, args = {}, meta) => client.callTool({ name, arguments: args, ...(meta ? { _meta: meta } : {}) }, undefined, { timeout: 10000 }),
    tools: () => client.listTools(), close: () => client.close(),
    calls: async () => (await readFile(callsFile, 'utf8').catch(() => '')).trim().split('\n').filter(Boolean).map(JSON.parse),
    pid: async () => Number(await readFile(pidFile, 'utf8')),
  };
}

test('an arbitrary MCP client works with no account, turn metadata or official installation', async t => {
  const f = await fixture(t);
  assert.equal((await f.tools()).tools.length, 13);
  const result = await f.call('get_app_state', { app: 'Fixture' }, { 'example.test/caller': 'ordinary-client' });
  assert.equal(result.isError ?? false, false);
  assert.equal(result._meta['opencu/app'].id, state.app.id);
  assert.deepEqual((await f.calls())[0], { id: 1, method: 'get_app_state', params: { app: 'Fixture', includeScreenshot: false } });
  const pid = await f.pid();
  await f.close();
  assert.throws(() => process.kill(pid, 0), { code: 'ESRCH' });
});

test('extended input and Unicode survive both standalone and batch transport', async t => {
  const f = await fixture(t);
  await f.call('click', { app: 'Fixture', element_index: 1, key: 'Shift', duration: 0.35 });
  await f.call('run_actions', { app: 'Fixture', actions: [
    { method: 'press_key', key: 'super+a', duration: 0 },
    { method: 'paste', format: 'text', text: '独立引擎\nUnicode ✓' },
  ] });
  const calls = await f.calls();
  assert.deepEqual(calls.map(x => x.method), ['click', 'get_app_state', 'press_key', 'paste', 'get_app_state']);
  assert.equal(calls[0].params.key, 'Shift');
  assert.equal(calls[0].params.duration, 0.35);
  assert.equal(calls[3].params.text, '独立引擎\nUnicode ✓');
});

test('a failed action stops the batch and is never replayed', async t => {
  const f = await fixture(t, [{ result: { ok: true } }, { error: { code: 'WINDOW_FOCUS_CHANGED', message: 'Window changed' } }]);
  const result = await f.call('run_actions', { app: 'Fixture', actions: [
    { method: 'press_key', key: 'Tab' }, { method: 'paste', text: 'fixture', format: 'text' }, { method: 'press_key', key: 'Return' },
  ] });
  assert.equal(result.isError, true);
  assert.match(result.content[0].text, /^WINDOW_FOCUS_CHANGED: Action 2 failed.*Earlier actions may have run/);
  assert.deepEqual((await f.calls()).map(x => x.method), ['press_key', 'paste']);
});

const unknownAction = {
  ok: true, outcome: 'unknown', app: state.app,
  message: 'The app did not confirm the action. Read state before continuing; do not repeat the action automatically.',
};

test('an unconfirmed AXPress is non-error and requires an explicit new observation', async t => {
  const f = await fixture(t, [{ result: state }, { result: unknownAction }]);
  await f.call('get_app_state', { app: 'Fixture' });
  const result = await f.call('click', { app: 'Fixture', element_index: 1 });
  assert.equal(result.isError ?? false, false);
  assert.equal(result.content[0].text, unknownAction.message);
  assert.equal(result._meta['opencu/actionOutcome'], 'unknown');
  assert.equal(result._meta['opencu/actionsAttempted'], 1);
  assert.deepEqual((await f.calls()).map(x => x.method), ['get_app_state', 'click']);
  const refreshed = await f.call('get_app_state', { app: 'Fixture' });
  assert.equal(refreshed.content[0].text, state.text, 'Required read must not be hidden by the old diff');
});

test('an unknown AX action stops a batch without retrying or sending later input', async t => {
  const f = await fixture(t, [{ result: { ok: true } }, { result: unknownAction }]);
  const result = await f.call('run_actions', { app: 'Fixture', actions: [
    { method: 'press_key', key: 'Tab' },
    { method: 'perform_secondary_action', element_index: 1, action: 'AXConfirm' },
    { method: 'type_text', text: 'must-not-type' },
  ] });
  assert.equal(result.isError ?? false, false);
  assert.equal(result.content[0].text, unknownAction.message);
  assert.equal(result._meta['opencu/actionsAttempted'], 2);
  assert.deepEqual((await f.calls()).map(x => x.method), ['press_key', 'perform_secondary_action']);
});

test('capture recovery retries observations without replaying completed input', async t => {
  const f = await fixture(t, [{ result: { ok: true } }, { error: { code: 'SCREENSHOT_FAILED', message: 'Capture temporarily unavailable' } }, { result: state }]);
  const result = await f.call('press_key', { app: 'Fixture', key: 'Return' });
  assert.equal(result.isError ?? false, false);
  assert.deepEqual((await f.calls()).map(x => x.method), ['press_key', 'get_app_state', 'get_app_state']);
});

test('permission failures are actionable and never retried', async t => {
  const f = await fixture(t, [{ error: { code: 'ACCESSIBILITY_PERMISSION_REQUIRED', message: 'Run opencu setup' } }]);
  const result = await f.call('get_app_state', { app: 'Fixture' });
  assert.equal(result.isError, true);
  assert.equal(result._meta['opencu/error'], 'ACCESSIBILITY_PERMISSION_REQUIRED');
  assert.match(result.content[0].text, /^ACCESSIBILITY_PERMISSION_REQUIRED: /);
  assert.equal((await f.calls()).length, 1);
});

test('a failed final observation distinguishes already completed input', async t => {
  const f = await fixture(t, [{ result: { ok: true } }, { error: { code: 'SCREEN_LOCKED', message: 'macOS is locked' } }]);
  const result = await f.call('run_actions', { app: 'Fixture', actions: [{ method: 'press_key', key: 'Return' }], includeScreenshot: true });
  assert.equal(result.isError, true);
  assert.match(result.content[0].text, /^SCREEN_LOCKED: All 1 actions returned.*Do not repeat/);
  assert.equal((await f.calls()).length, 2);
});

test('missed expected text returns the observed state without claiming readiness', async t => {
  const f = await fixture(t);
  const result = await f.call('get_app_state', { app: 'Fixture', waitForText: 'Ready', waitTimeoutMs: 0 });
  assert.equal(result.isError, true);
  assert.ok(result.content.some(item => item.text.includes('Value="initial"')));
  assert.match(result.content[0].text, /^WAIT_TIMEOUT: /);
  assert.equal(result._meta['opencu/error'], 'WAIT_TIMEOUT');
  assert.ok(result.content.some(item => item.text.includes('expected text did not appear')));
  assert.equal((await f.calls()).length, 1);
});

test('invalid input and a later coordinate action reject the entire sequence', async t => {
  const f = await fixture(t);
  for (const args of [
    { app: 'Fixture', actions: [{ method: 'press_key', key: 'a' }, { method: 'click', x: 10, y: 10 }] },
    { app: 'Fixture', actions: [{ method: 'press_key', key: 'a', duration: 31 }] },
    { app: 'Fixture', actions: [{ method: 'click', element_index: 1, x: 10, y: 10 }] },
    { app: 'Fixture', actions: [{ method: 'arbitrary-code', code: 'noop' }] },
  ]) assert.equal((await f.call('run_actions', args)).isError, true);
  assert.equal((await f.calls()).length, 0);
});

test('unchanged observations can be expanded again with disableDiff', async t => {
  const f = await fixture(t);
  await f.call('get_app_state', { app: 'Fixture' });
  const second = await f.call('get_app_state', { app: 'Fixture' });
  assert.match(second.content[0].text, /No accessibility changes/);
  const third = await f.call('get_app_state', { app: 'Fixture', disableDiff: true });
  assert.equal(third.content[0].text, state.text);
});


test('person stop preserves its code, halts the batch and never retries a screenshot', async t => {
  const stop = { error: { code: 'STOPPED_BY_PERSON', message: 'The person stopped OpenCU. Do not reconnect or retry on your own.' } };
  const f = await fixture(t, [stop, { result: state }]);
  const result = await f.call('run_actions', { app: 'Fixture', actions: [
    { method: 'press_key', key: 'Tab' }, { method: 'press_key', key: 'Return' },
  ] });
  assert.equal(result._meta['opencu/error'], 'STOPPED_BY_PERSON');
  assert.match(result.content[0].text, /^STOPPED_BY_PERSON: /);
  assert.doesNotMatch(result.content[0].text, /Read state before retrying/);
  const screenshot = await f.call('get_app_state', { app: 'Fixture', includeScreenshot: true });
  assert.equal(screenshot._meta['opencu/error'], 'STOPPED_BY_PERSON');
  for (const [method, args] of [
    ['click', { x: 10, y: 10 }], ['paste', { text: 'fixture', format: 'text' }], ['activate_app', {}],
  ]) {
    const refused = await f.call(method, { app: 'Fixture', ...args });
    assert.equal(refused._meta['opencu/error'], 'STOPPED_BY_PERSON');
    assert.match(refused.content[0].text, /^STOPPED_BY_PERSON: /);
  }
  const text = await f.call('get_app_state', { app: 'Fixture' });
  assert.equal(text.isError ?? false, false);
  assert.deepEqual((await f.calls()).map(x => x.method), ['press_key', 'get_app_state']);
});


test('all engine codes are visible in agent text as well as metadata', async t => {
  const codes = ['SCREEN_RECORDING_PERMISSION_REQUIRED', 'STALE_ELEMENT', 'WINDOW_ID_UNAVAILABLE',
    'BACKGROUND_REMOTE_FOCUS', 'PERSON_ACTIVE', 'USER_STOPPED', 'FUTURE_ENGINE_CODE'];
  const f = await fixture(t, codes.map(code => ({ error: { code, message: 'Fixture refusal' } })));
  for (const code of codes) {
    const result = await f.call('get_app_state', { app: 'Fixture' });
    assert.equal(result.content[0].text, `${code}: Fixture refusal`);
    assert.equal(result._meta['opencu/error'], code);
  }
  assert.equal((await f.calls()).length, codes.length);
});
