import assert from 'node:assert/strict';
import { mkdir, mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import test from 'node:test';
import { Client } from '@modelcontextprotocol/sdk/client/index.js';
import { StdioClientTransport } from '@modelcontextprotocol/sdk/client/stdio.js';
import opencu, { serverCommand } from '../adapters/pi/opencu.ts';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const tools = [
  { name: 'list_apps', description: 'Discover fixture apps.', inputSchema: { type: 'object', properties: {} } },
  { name: 'get_app_state', description: 'Read a fixture window.', inputSchema: {
    type: 'object', properties: { app: { type: 'string', minLength: 1 }, includeScreenshot: { type: 'boolean' } }, required: ['app'],
  } },
];
const image = { type: 'image', mimeType: 'image/png', data: 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jRZkAAAAASUVORK5CYII=' };

function harness(t) {
  const registered = new Map();
  const handlers = new Map();
  opencu({
    registerTool: tool => registered.set(tool.name, tool),
    on: (name, handler) => handlers.set(name, handler),
  });
  const emit = (name, event = {}) => handlers.get(name)(event);
  t.after(() => emit('session_shutdown'));
  return { registered, emit, call: (name, params = {}, id = 'fixture-call', signal) => registered.get(name).execute(id, params, signal) };
}

async function fixture(t, results = []) {
  await mkdir(path.join(root, '.cache'), { recursive: true });
  const dir = await mkdtemp(path.join(root, '.cache/pi-adapter-'));
  const logFile = path.join(dir, 'events.jsonl');
  const config = path.join(dir, 'config.json');
  await writeFile(config, JSON.stringify({ log: logFile, instructions: 'Fixture OpenCU instructions.', tools, results }));
  const previous = { OPENCU_COMMAND: process.env.OPENCU_COMMAND, OPENCU_ARGS: process.env.OPENCU_ARGS };
  process.env.OPENCU_COMMAND = process.execPath;
  process.env.OPENCU_ARGS = JSON.stringify([path.join(root, 'tests/fixtures/pi-mcp-server.mjs'), config, 'argument with spaces', '中文']);
  const h = harness(t);
  t.after(async () => {
    for (const [key, value] of Object.entries(previous)) {
      if (value === undefined) delete process.env[key]; else process.env[key] = value;
    }
    await rm(dir, { recursive: true, force: true });
  });
  return { ...h, events: async () => (await readFile(logFile, 'utf8').catch(() => '')).trim().split('\n').filter(Boolean).map(JSON.parse) };
}

test('command selection uses pi Node and extension location, or literal override arguments', () => {
  const url = pathToFileURL(path.join(root, 'checkout with spaces/adapters/pi/opencu.ts')).href;
  assert.deepEqual(serverCommand({}, url), { command: process.execPath, args: [path.join(root, 'checkout with spaces/src/server.mjs')] });
  assert.deepEqual(serverCommand({ OPENCU_COMMAND: 'C:\\Program Files\\OpenCU\\bin\\opencu.cmd', OPENCU_ARGS: '["mcp","a b","中文"]' }), {
    command: 'C:\\Program Files\\OpenCU\\bin\\opencu.cmd', args: ['mcp', 'a b', '中文'],
  });
  assert.deepEqual(serverCommand({ OPENCU_COMMAND: '/some executable' }), { command: '/some executable', args: [] });
  for (const value of ['{}', '[1]', 'null']) assert.throws(() => serverCommand({ OPENCU_COMMAND: 'node', OPENCU_ARGS: value }), /JSON array of strings/);
  assert.throws(() => serverCommand({ OPENCU_COMMAND: 'node', OPENCU_ARGS: '[' }), SyntaxError);
  assert.throws(() => serverCommand({ OPENCU_ARGS: '[]' }), /requires OPENCU_COMMAND/);
});

test('session startup discovers every paginated tool and appends instructions to caller prompts', async t => {
  const f = await fixture(t);
  assert.deepEqual(await f.events(), []); // No child starts in the extension factory.
  await Promise.all([f.emit('session_start'), f.emit('session_start')]);
  assert.equal(f.registered.size, tools.length);
  for (const tool of tools) {
    const actual = f.registered.get(tool.name);
    assert.equal(actual.description, tool.description);
    assert.deepEqual(actual.parameters, tool.inputSchema);
    assert.equal(actual.executionMode, 'sequential');
  }
  const event = { systemPrompt: 'Voice assistant prompt.\nCaller appended text.' };
  const expected = { systemPrompt: event.systemPrompt + '\n\nFixture OpenCU instructions.' };
  assert.deepEqual(await f.emit('before_agent_start', event), expected);
  assert.deepEqual(await f.emit('before_agent_start', event), expected);
  const events = await f.events();
  assert.equal(events.filter(x => x.event === 'start').length, 1);
  assert.deepEqual(events[0].args, ['argument with spaces', '中文']);
  assert.deepEqual(events.filter(x => x.event === 'list').map(x => x.params?.cursor), [undefined, '1']);
});

test('forwards calls and PNG bytes, reuses one connection, and shuts down idempotently', async t => {
  const content = [{ type: 'text', text: 'Fixture state\nUnicode ✓' }, image];
  const f = await fixture(t, [{ content, _meta: { 'opencu/app': { id: 'fixture' } } }]);
  await f.emit('session_start');
  const args = { app: 'Fixture App', includeScreenshot: true };
  assert.deepEqual(await f.call('get_app_state', args), { content, details: { _meta: { 'opencu/app': { id: 'fixture' } } } });
  await f.call('list_apps');
  await f.call('get_app_state', { app: 'Fixture App' });
  await Promise.all([f.emit('session_shutdown'), f.emit('session_shutdown')]);
  await f.emit('session_shutdown');
  const events = await f.events();
  assert.equal(events.filter(x => x.event === 'start').length, 1);
  assert.equal(events.filter(x => x.event === 'end').length, 1);
  assert.deepEqual(events.filter(x => x.event === 'call').map(x => ({ name: x.name, arguments: x.arguments })), [
    { name: 'get_app_state', arguments: args }, { name: 'list_apps', arguments: {} }, { name: 'get_app_state', arguments: { app: 'Fixture App' } },
  ]);
  await assert.rejects(f.call('list_apps'), /connection is closed/);
});

test('isError throws original text and tool_result preserves original error text/images/metadata', async t => {
  const content = [{ type: 'text', text: 'Fixture observation failed.' }, image, { type: 'text', text: 'Earlier input may have run.' }];
  const meta = { 'opencu/error': 'WAIT_TIMEOUT' };
  const f = await fixture(t, [{ isError: true, content, _meta: meta }]);
  await f.emit('session_start');
  await assert.rejects(f.call('get_app_state', { app: 'Fixture' }, 'error-call'), { message: 'Fixture observation failed.\nEarlier input may have run.' });
  assert.deepEqual(await f.emit('tool_result', { toolCallId: 'error-call' }), { content, details: { _meta: meta }, isError: true });
  assert.equal(await f.emit('tool_result', { toolCallId: 'error-call' }), undefined);
  assert.equal(await f.emit('tool_result', { toolCallId: 'unrelated-call' }), undefined);
  await f.call('list_apps'); // Ordinary tool errors do not close or reset the connection.
});

for (const withMeta of [true, false]) {
  test(`USER_STOPPED latches the connection and blocks queued/later calls (${withMeta ? 'metadata' : 'text'} code)`, async t => {
    const text = withMeta ? 'A person stopped OpenCU with Escape.' : 'USER_STOPPED: A person pressed Escape.';
    const f = await fixture(t, [{ isError: true, content: [{ type: 'text', text }], ...(withMeta ? { _meta: { 'opencu/error': 'USER_STOPPED' } } : {}) }]);
    await f.emit('session_start');
    const pending = [f.call('get_app_state', { app: 'Fixture' }), f.call('list_apps')];
    for (const result of await Promise.allSettled(pending)) {
      assert.equal(result.status, 'rejected');
      assert.equal(result.reason.message, text);
    }
    await assert.rejects(f.call('list_apps'), { message: text });
    assert.match((await f.emit('before_agent_start', { systemPrompt: 'Caller' })).systemPrompt, /^Caller\n\nFixture/);
    await f.emit('session_shutdown');
    const events = await f.events();
    assert.equal(events.filter(x => x.event === 'start').length, 1);
    assert.equal(events.filter(x => x.event === 'call').length, 1);
  });
}

test('unexpected server exit never starts a replacement connection', async t => {
  const f = await fixture(t);
  await f.emit('session_start');
  await assert.rejects(f.call('list_apps', { disconnect: true }));
  await assert.rejects(f.call('list_apps'), /disconnected/);
  assert.equal((await f.events()).filter(x => x.event === 'start').length, 1);
});

test('shutdown before session startup starts no process', async t => {
  const f = await fixture(t);
  await f.emit('session_shutdown');
  await f.emit('session_shutdown');
  await assert.rejects(f.emit('session_start'), /connection is closed/);
  assert.deepEqual(await f.events(), []);
});

test('real OpenCU descriptors register unchanged without starting the native engine', async t => {
  const previous = { OPENCU_COMMAND: process.env.OPENCU_COMMAND, OPENCU_ARGS: process.env.OPENCU_ARGS };
  delete process.env.OPENCU_COMMAND;
  delete process.env.OPENCU_ARGS;
  t.after(() => {
    for (const [key, value] of Object.entries(previous)) {
      if (value === undefined) delete process.env[key]; else process.env[key] = value;
    }
  });
  const client = new Client({ name: 'pi-schema-test', version: '1' });
  t.after(() => client.close());
  const transport = new StdioClientTransport({ ...serverCommand({}), stderr: 'pipe' });
  transport.stderr.resume();
  await client.connect(transport);
  const expected = await client.listTools();
  const f = harness(t);
  await f.emit('session_start');
  assert.equal(f.registered.size, 14);
  for (const tool of expected.tools) {
    const actual = f.registered.get(tool.name);
    assert.equal(actual.description, tool.description);
    assert.deepEqual(actual.parameters, tool.inputSchema);
  }
  assert.deepEqual(await f.emit('before_agent_start', { systemPrompt: 'Caller prompt' }), {
    systemPrompt: 'Caller prompt\n\n' + client.getInstructions(),
  });
});
