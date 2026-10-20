import assert from 'node:assert/strict';
import { chmod, cp, mkdir, mkdtemp, readFile, rm, symlink, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import test from 'node:test';
import { fileURLToPath } from 'node:url';
import { OpenCURuntime, toolError } from '../src/opencu-runtime.mjs';
import { Client } from '@modelcontextprotocol/sdk/client/index.js';
import { StdioClientTransport } from '@modelcontextprotocol/sdk/client/stdio.js';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const state = { app: { id: 'dev.opencu.fixture', displayName: 'Fixture', pid: 123 }, text: 'App: "Fixture"\nWindow: "Fixture"\n[1] button Press\n[2] text field Value="initial"' };

async function fixture(t, results = [], platform) {
  const dir = await mkdtemp(path.join(tmpdir(), 'opencu-test-'));
  let client;
  t.after(async () => { await client?.close(); await rm(dir, { recursive: true, force: true }); });
  await cp(path.join(root, 'src'), path.join(dir, 'src'), { recursive: true });
  if (platform) {
    const server = path.join(dir, 'src/server.mjs');
    await writeFile(server, (await readFile(server, 'utf8')).replace('new AgentDesktopRuntime({ root })', `new AgentDesktopRuntime({ root, platform: ${JSON.stringify(platform)} })`));
  }
  await symlink(path.join(root, 'node_modules'), path.join(dir, 'node_modules'), 'dir');
  await writeFile(path.join(dir, 'package.json'), '{"type":"module","version":"9.8.7-test"}');
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
 const send=()=>process.stdout.write(JSON.stringify({id:q.id,...reply})+'\\n');
 if(q.method==='wait') setTimeout(send,q.params.ms); else send();
});
`);
  await chmod(binary, 0o700);
  client = new Client({ name: 'unaffiliated-test-agent', version: '1' });
  const transport = new StdioClientTransport({ command: process.execPath, args: [path.join(dir, 'src/server.mjs')], stderr: 'pipe', env: { HOME: dir } });
  transport.stderr.resume();
  await client.connect(transport);
  return {
    call: (name, args = {}, meta) => client.callTool({ name, arguments: args, ...(meta ? { _meta: meta } : {}) }, undefined, { timeout: 10000 }),
    tools: () => client.listTools(), version: () => client.getServerVersion().version, close: () => client.close(),
    calls: async () => (await readFile(callsFile, 'utf8').catch(() => '')).trim().split('\n').filter(Boolean).map(JSON.parse),
    pid: async () => Number(await readFile(pidFile, 'utf8')),
  };
}

test('an arbitrary MCP client works with no account, turn metadata or official installation', async t => {
  const f = await fixture(t);
  assert.equal((await f.tools()).tools.length, 14);
  assert.equal(f.version(), '9.8.7-test', 'MCP version comes from the installed package.json');
  const result = await f.call('get_app_state', { app: 'Fixture' }, { 'example.test/caller': 'ordinary-client' });
  assert.equal(result.isError ?? false, false);
  assert.equal(result._meta['opencu/app'].id, state.app.id);
  assert.deepEqual((await f.calls())[0], { id: 1, method: 'get_app_state', params: { app: 'Fixture', includeScreenshot: false } });
  const pid = await f.pid();
  await f.close();
  assert.throws(() => process.kill(pid, 0), { code: 'ESRCH' });
});

test('capture safety refusals preserve diagnostics without retrying or granting coordinates', async t => {
  const data = { captureContext: { pid: 123, responsiblePID: 456, verifiedSelfResponsible: false,
    capturePolicy: 'verified-engine-and-existing-grant' } };
  const f = await fixture(t, [{ error: { code: 'CAPTURE_RESPONSIBILITY_UNVERIFIED',
    message: 'No capture API was called.', data } }]);
  const result = await f.call('get_app_state', { app: 'Fixture', includeScreenshot: true });
  assert.equal(result.isError, true);
  assert.equal(result._meta['opencu/error'], 'CAPTURE_RESPONSIBILITY_UNVERIFIED');
  assert.deepEqual(result._meta['opencu/errorDetails'], data);
  assert.equal(result.content.some(item => item.type === 'image'), false);
  assert.equal((await f.calls()).length, 1);
  const click = await f.call('click', { app: 'Fixture', x: 5, y: 5 });
  assert.equal(click.isError, true);
  assert.equal(click._meta['opencu/error'], 'SCREENSHOT_REQUIRED');
  assert.match(click.content[0].text, /^SCREENSHOT_REQUIRED: /);
  assert.equal((await f.calls()).length, 1, 'No coordinate action reaches the engine after refused capture');
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

// Real subprocesses exercise EOF, late output and exit events as well as the
// request timer. Only the timeout is shortened; no engine request is replayed.
async function restartingFixture(t, replies) {
  await mkdir(path.join(root, '.cache'), { recursive: true });
  const dir = await mkdtemp(path.join(root, '.cache/runtime-timeout-'));
  const binary = path.join(dir, 'engine.mjs');
  const script = `#!${process.execPath}
import { appendFileSync, readFileSync, writeFileSync } from 'node:fs';
import { createInterface } from 'node:readline';
const dir = ${JSON.stringify(dir)};
appendFileSync(dir + '/starts', process.pid + '\\n');
let late;
const lines = createInterface({ input: process.stdin });
lines.on('line', line => {
  const q = JSON.parse(line);
  appendFileSync(dir + '/calls', JSON.stringify(q) + '\\n');
  const replies = JSON.parse(readFileSync(dir + '/replies', 'utf8'));
  const reply = replies.shift();
  writeFileSync(dir + '/replies', JSON.stringify(replies));
  if (reply?.hang) {
    if (reply.stubborn) setInterval(() => {}, 1000);
    late = { id: q.id, ...reply.late }; return;
  }
  process.stdout.write(JSON.stringify({ id: q.id, ...(reply ?? { result: q.method === 'get_app_state' ? ${JSON.stringify(state)} : { ok: true } }) }) + '\\n');
});
lines.on('close', () => {
  // Exercise a result arriving after timeout, while the old engine retires.
  if (late) setTimeout(() => process.stdout.write(JSON.stringify(late) + '\\n'), 50);
});
`;
  await writeFile(binary, script);
  await chmod(binary, 0o700);
  await writeFile(path.join(dir, 'replies'), JSON.stringify(replies));
  const runtime = new OpenCURuntime({ enginePath: binary, requestTimeoutMs: 3000 });
  t.after(async () => { await runtime.close(); await rm(dir, { recursive: true, force: true }); });
  const lines = async file => (await readFile(path.join(dir, file), 'utf8').catch(() => '')).trim().split('\n').filter(Boolean);
  return {
    call: (method, args = {}) => runtime.call(method, { app: 'Fixture', ...args }).catch(toolError),
    calls: async () => (await lines('calls')).map(JSON.parse),
    starts: async () => (await lines('starts')).map(Number),
  };
}

test('a timed-out action is never replayed; the same runtime restarts with fresh observation and no old diff', async t => {
  await mkdir(path.join(root, '.cache'), { recursive: true });
  const f = await restartingFixture(t, [{ result: state }, { hang: true, late: { result: { ok: true } } }]);
  const initial = await f.call('get_app_state');
  assert.equal(initial.isError, undefined, JSON.stringify(initial));
  const timeout = await f.call('run_actions', { actions: [
    { method: 'click', element_index: 1 }, { method: 'type_text', text: 'must-not-run' },
  ] });
  assert.equal(timeout._meta['opencu/error'], 'RUNTIME_ERROR');
  assert.match(timeout.content[0].text, /timed out.*Input may already have run.*no operation was retried/);
  for (const [method, args] of [['click', { element_index: 1 }], ['click', { x: 1, y: 1 }], ['activate_app', {}]]) {
    assert.equal((await f.call(method, args))._meta['opencu/error'], 'OBSERVATION_REQUIRED');
  }
  const fresh = await f.call('get_app_state');
  assert.equal(fresh.isError, undefined);
  assert.equal(fresh.content[0].text, state.text, 'Old observation diff is discarded');
  assert.equal((await f.call('click', { x: 1, y: 1 }))._meta['opencu/error'], 'SCREENSHOT_REQUIRED');
  assert.equal((await f.call('click', { element_index: 1 })).isError, undefined);
  const starts = await f.starts();
  assert.equal(starts.length, 2);
  assert.throws(() => process.kill(starts[0], 0), { code: 'ESRCH' }, 'Old process exited before replacement');
  assert.deepEqual((await f.calls()).map(q => q.method), ['get_app_state', 'click', 'get_app_state', 'click', 'get_app_state']);
});

for (const code of ['USER_STOPPED', 'STOPPED_BY_PERSON']) {
  test(`${code} survives a later timeout without starting a replacement engine`, async t => {
    const f = await restartingFixture(t, [{ error: { code, message: 'Person stopped input' } }, { hang: true }]);
    assert.equal((await f.call('press_key', { key: 'Return' }))._meta['opencu/error'], code);
    assert.equal((await f.call('click', { x: 1, y: 1 }))._meta['opencu/error'], code);
    assert.equal((await f.starts()).length, 1);
    assert.match((await f.call('get_app_state')).content[0].text, /timed out/);
    for (const method of ['get_app_state', 'press_key', 'list_apps']) {
      assert.equal((await f.call(method, { key: 'Return' }))._meta['opencu/error'], code);
    }
    assert.equal((await f.starts()).length, 1);
    assert.deepEqual((await f.calls()).map(q => q.method), ['press_key', 'get_app_state']);
  });
}

test('a late USER_STOPPED from the timed-out engine prevents restart', async t => {
  const f = await restartingFixture(t, [{ hang: true, late: { error: { code: 'USER_STOPPED', message: 'Physical Escape' } } }]);
  assert.match((await f.call('get_app_state')).content[0].text, /timed out/);
  assert.equal((await f.call('get_app_state'))._meta['opencu/error'], 'USER_STOPPED');
  assert.equal((await f.starts()).length, 1);
});


test('a provider that ignores EOF is terminated before a replacement starts', async t => {
  const f = await restartingFixture(t, [{ hang: true, stubborn: true }]);
  assert.match((await f.call('get_app_state')).content[0].text, /timed out/);
  const oldPID = (await f.starts())[0];
  assert.doesNotThrow(() => process.kill(oldPID, 0), 'Old engine is still alive during cleanup grace');
  const fresh = await f.call('get_app_state');
  assert.equal(fresh.isError, undefined);
  assert.equal((await f.starts()).length, 2);
  assert.throws(() => process.kill(oldPID, 0), { code: 'ESRCH' });
  assert.deepEqual((await f.calls()).map(q => q.method), ['get_app_state', 'get_app_state']);
});


test('waitForText ignores all headers and summaries but matches numbered elements', async t => {
  const text = 'App: AppOnly\nWindow: TitleOnly\nCapture target: CaptureOnly\nWindow summary: SummaryOnly\nIME: WarningOnly\n[1] Text title="ElementOnly"';
  const f = await fixture(t, Array(6).fill({ result: { ...state, text } }));
  for (const waitForText of ['AppOnly', 'TitleOnly', 'CaptureOnly', 'SummaryOnly', 'WarningOnly']) {
    const result = await f.call('get_app_state', { app: 'Fixture', waitForText, waitTimeoutMs: 0 });
    assert.equal(result._meta['opencu/error'], 'WAIT_TIMEOUT');
  }
  assert.ok(!(await f.call('get_app_state', { app: 'Fixture', waitForText: 'ElementOnly', waitTimeoutMs: 0 })).isError);
});

test('scope is rejected before input on macOS', async t => {
  const f = await fixture(t, [], 'darwin');
  for (const [method, args] of [
    ['get_app_state', {}], ['click', { element_index: 2 }],
    ['run_actions', { actions: [{ method: 'type_text', text: 'never' }] }],
  ]) {
    const result = await f.call(method, { app: 'Fixture', scope: 1, ...args });
    assert.equal(result._meta['opencu/error'], 'INVALID_ARGUMENT');
    assert.match(result.content[0].text, /Windows-only/);
  }
  assert.deepEqual(await f.calls(), []);
});

test('scope reaches final reads and stays anchored across polling and retry', async t => {
  const scoped = { ...state, scopeRoot: 'live:root-9', text: '[1] Pane title="Panel"\n  [2] Text title="Ready"' };
  const f = await fixture(t, [
    { result: { ok: true } }, { result: scoped },
    { error: { code: 'SCREENSHOT_FAILED', message: 'fixture transient' } },
    { result: { ...scoped, text: '[1] Pane title="Panel"' } }, { result: scoped },
    { result: { ok: true } }, { result: scoped },
  ], 'win32');
  await f.call('click', { app: 'Fixture', element_index: 2, scope: 9 });
  const result = await f.call('get_app_state', { app: 'Fixture', scope: 1, waitForText: 'Ready' });
  assert.ok(!result.isError);
  await f.call('run_actions', { app: 'Fixture', scope: 1, actions: [{ method: 'type_text', text: 'x' }] });
  const calls = await f.calls();
  assert.equal(calls[0].params.scope, undefined, 'scope only controls the final read');
  assert.equal(calls[1].params.scope, 9);
  assert.equal(calls[6].params.scope, 1);
  assert.equal(calls[2].params.scopeRequest, calls[3].params.scopeRequest);
  assert.equal(calls[3].params.scopeRequest, calls[4].params.scopeRequest);
  assert.notEqual(calls[1].params.scopeRequest, calls[2].params.scopeRequest);
});

test('diff never crosses full, scoped, different root or gone-root states', async t => {
  const results = [undefined, 'live:a', 'live:b', 'live:b', 'gone:b', undefined].map(scopeRoot => ({ result: { ...state, scopeRoot } }));
  const f = await fixture(t, results, 'win32');
  for (let i = 0; i < results.length; i++) {
    const result = await f.call('get_app_state', { app: 'Fixture', ...(i > 0 && i < 5 ? { scope: 1 } : {}) });
    assert.equal(result.content[0].text.includes('No accessibility changes'), i === 3);
  }
});

test('a gone scope is a successful action final read with full fallback state', async t => {
  const fallback = { ...state, scopeRoot: 'gone:a', text: state.text + '\nScope element is gone; showing the whole window.' };
  const f = await fixture(t, [{ result: { ok: true } }, { result: fallback }], 'win32');
  const result = await f.call('click', { app: 'Fixture', element_index: 2, scope: 1 });
  assert.ok(!result.isError);
  assert.equal(result.content[0].text, fallback.text);
  assert.equal((await f.calls()).length, 2);
});


test('wait sends only a native wait and final read, and rejects invalid ms before input', async t => {
  const f = await fixture(t);
  const start = performance.now();
  const result = await f.call('run_actions', { app: 'Fixture', actions: [{ method: 'wait', ms: 80 }] });
  assert.ok(!result.isError);
  assert.ok(performance.now() - start >= 80);
  assert.deepEqual((await f.calls()).map(q => q.method), ['wait', 'get_app_state']);
  for (const ms of [0, -1, 15001, 1.5, '1', true, null]) {
    assert.ok((await f.call('run_actions', { app: 'Fixture', actions: [{ method: 'type_text', text: 'never' }, { method: 'wait', ms }] })).isError);
  }
  assert.equal((await f.calls()).length, 2);
  const tool = (await f.tools()).tools.find(t => t.name === 'run_actions');
  const wait = tool.inputSchema.properties.actions.items.oneOf?.find(s => s.properties.method.const === 'wait')
    ?? tool.inputSchema.properties.actions.items.anyOf.find(s => s.properties.method.const === 'wait');
  assert.equal(wait.properties.ms.minimum, 1);
  assert.equal(wait.properties.ms.maximum, 15000);
});

test('coordinates after wait refuse the entire batch without even waiting', async t => {
  const f = await fixture(t);
  const result = await f.call('run_actions', { app: 'Fixture', actions: [{ method: 'wait', ms: 1500 }, { method: 'click', x: 1, y: 1 }] });
  assert.equal(result._meta['opencu/error'], 'SCREENSHOT_REQUIRED');
  assert.deepEqual(await f.calls(), []);
});

for (const code of ['PERSON_ACTIVE', 'USER_STOPPED', 'STOPPED_BY_PERSON']) {
  test(`${code} during wait stops all following input`, async t => {
    const f = await fixture(t, [{ error: { code, message: 'Fixture person stop' } }]);
    const result = await f.call('run_actions', { app: 'Fixture', actions: [{ method: 'wait', ms: 1 }, { method: 'press_key', key: 'a' }] });
    assert.equal(result._meta['opencu/error'], code);
    assert.deepEqual((await f.calls()).map(q => q.method), ['wait']);
  });
  test(`${code} after wait still stops remaining input`, async t => {
    const f = await fixture(t, [{ result: { ok: true } }, { error: { code, message: 'Fixture person stop' } }]);
    const result = await f.call('run_actions', { app: 'Fixture', actions: [{ method: 'wait', ms: 1 }, { method: 'press_key', key: 'a' }, { method: 'type_text', text: 'never' }] });
    assert.equal(result._meta['opencu/error'], code);
    assert.deepEqual((await f.calls()).map(q => q.method), ['wait', 'press_key']);
  });
}


test('gone-scope fallback cannot satisfy waitForText with text outside the retained subtree', async t => {
  const fallback = { ...state, scopeRoot: 'gone:a', text: state.text + '\nScope element is gone; showing the whole window.\n[3] Text title="Outside ready"' };
  const f = await fixture(t, [{ result: fallback }], 'win32');
  const result = await f.call('get_app_state', { app: 'Fixture', scope: 1, waitForText: 'Outside ready', waitTimeoutMs: 0 });
  assert.equal(result._meta['opencu/error'], 'WAIT_TIMEOUT');
  assert.ok(result.content.some(c => c.text?.includes('Scope element is gone')));
});
