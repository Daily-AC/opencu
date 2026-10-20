import assert from 'node:assert/strict';
import { mkdtemp, mkdir, readFile, rm, writeFile } from 'node:fs/promises';
import { createHash } from 'node:crypto';
import path from 'node:path';
import test from 'node:test';
import { AgentDesktopRuntime, agentDesktopHelper } from '../src/agent-desktop.mjs';

const failure = code => Object.assign(new Error(code), { code });
const object = result => JSON.parse(result.content[0].text);

function fixture(t, options = {}) {
  const calls = [], runtimes = [], hosts = [];
  let hostFailure;
  const runtime = new AgentDesktopRuntime({ root: '/fixture', platform: 'win32',
    availability: async () => ({ available: true }),
    runtimeFactory: config => {
      const lane = config.spawnEngine ? 'child' : 'parent';
      const item = { config, lane, closed: false, response: undefined, close: async () => { item.closed = true; calls.push([lane, 'close']); },
        call: async (method, args) => { assert.equal(item.closed, false); calls.push([lane, method, args]); return item.response ?? { content: [{ type: 'text', text: lane }] }; } };
      runtimes.push(item); return item;
    },
    hostFactory: ({ onFailure }) => {
      hostFailure = onFailure;
      const host = { closed: false,
        start: async () => { if (options.startError) throw failure(options.startError); await options.wait; return { process: {}, sessionId: 2, hostPid: 45 }; },
        close: async () => { host.closed = true; if (options.closeError) throw failure(options.closeError); } };
      hosts.push(host); return host;
    }, ...options.config });
  t.after(() => runtime.close().catch(() => {}));
  return { runtime, calls, runtimes, hosts, fail: code => hostFailure(failure(code)),
    control: action => runtime.call('agent_desktop', { action }) };
}

test('all app operations switch together, then tool stop returns to a fresh parent', async t => {
  const f = fixture(t);
  await f.runtime.call('list_apps');
  assert.equal(object(await f.control('start')).state, 'running');
  assert.equal(f.runtimes[0].closed, true);
  assert.equal(f.runtimes[1].config.allowRestart, false);
  await assert.rejects(f.runtime.call('click', { app: 'Fixture', element_index: 1 }), { code: 'OBSERVATION_REQUIRED' });
  for (const method of ['get_app_state', 'list_apps', 'activate_app', 'click', 'run_actions']) await f.runtime.call(method, { app: 'Fixture' });
  assert.deepEqual(f.calls.filter(c => c[0] === 'child').map(c => c[1]), ['get_app_state', 'list_apps', 'activate_app', 'click', 'run_actions']);
  await f.control('start'); assert.equal(f.hosts.length, 1);
  assert.equal(object(await f.control('stop')).state, 'inactive');
  assert.equal(f.hosts[0].closed, true); assert.equal(f.runtimes[1].closed, true);
  await assert.rejects(f.runtime.call('activate_app', { app: 'Fixture' }), { code: 'OBSERVATION_REQUIRED' });
  await f.runtime.call('get_app_state', { app: 'Fixture' });
  assert.equal(f.calls.at(-1)[0], 'parent');
  await f.control('start'); assert.equal(f.hosts.length, 2);
});

for (const source of ['host close', 'physical Escape', 'late Escape during parent retirement']) {
  test(`${source} stops the entire MCP connection and cannot be cleared by switching`, async t => {
    const f = fixture(t);
    if (source === 'late Escape during parent retirement') {
      f.runtimes[0].close = async () => f.runtimes[0].config.onPersonStop(failure('USER_STOPPED'));
      await assert.rejects(f.control('start'), { code: 'USER_STOPPED' });
    } else {
      await f.control('start');
      if (source === 'host close') f.fail('USER_STOPPED');
      else f.runtimes[1].config.onPersonStop(failure('USER_STOPPED'));
    }
    await assert.rejects(f.control('start'), { code: 'USER_STOPPED' });
    await assert.rejects(f.runtime.call('list_apps'), { code: 'USER_STOPPED' });
    assert.equal(object(await f.control('stop')).stoppedByPerson, true);
    await assert.rejects(f.runtime.call('get_app_state', { app: 'Fixture' }), { code: 'USER_STOPPED' });
    await assert.rejects(f.control('start'), { code: 'USER_STOPPED' });
    assert.equal(object(await f.control('status')).stoppedByPerson, true);
  });
}

for (const code of ['AGENT_DESKTOP_UNAVAILABLE', 'AGENT_DESKTOP_SIGN_IN_REQUIRED', 'AGENT_DESKTOP_AUTH_FAILED']) {
  test(`${code} preserves refusal and never falls back to the parent`, async t => {
    const f = fixture(t, { startError: code });
    await assert.rejects(f.control('start'), { code });
    await assert.rejects(f.runtime.call('get_app_state', { app: 'Fixture' }), { code });
    await assert.rejects(f.control('start'), { code });
    assert.equal(f.hosts.length, 1); assert.equal(f.hosts[0].closed, true);
    assert.equal(f.calls.some(c => c[1] === 'get_app_state'), false);
  });
}

test('host loss and failed logoff never authorize parent input', async t => {
  const f = fixture(t, { closeError: 'AGENT_DESKTOP_CLEANUP_FAILED' });
  await f.control('start'); f.fail('AGENT_DESKTOP_LOST');
  await assert.rejects(f.runtime.call('click', {}), { code: 'AGENT_DESKTOP_LOST' });
  await assert.rejects(f.control('stop'), { code: 'AGENT_DESKTOP_CLEANUP_FAILED' });
  await assert.rejects(f.runtime.call('list_apps'), { code: 'AGENT_DESKTOP_LOST' });
  assert.equal(f.runtimes.length, 2);
});

test('startup serializes app requests; no early parent or child call', async t => {
  let resume; const wait = new Promise(resolve => { resume = resolve; });
  const f = fixture(t, { wait });
  const start = f.control('start');
  const state = f.runtime.call('get_app_state', { app: 'Fixture' });
  await new Promise(resolve => setImmediate(resolve));
  assert.equal(f.calls.some(c => c[1] === 'get_app_state'), false);
  resume(); await start; await state;
  assert.equal(f.calls.at(-1)[0], 'child');
});

test('no credential or endpoint options enter lifecycle operations', async t => {
  const f = fixture(t);
  for (const key of ['password', 'userName', 'server', 'sessionId', 'token', 'enginePath']) {
    await assert.rejects(f.runtime.call('agent_desktop', { action: 'start', [key]: 'fixture-only' }), { code: 'INVALID_ARGUMENT' });
  }
  assert.equal(f.hosts.length, 0);
});

test('macOS keeps ordinary routing and explicitly refuses the shared lifecycle tool', async t => {
  const f = fixture(t, { config: { platform: 'darwin' } });
  for (const action of ['start', 'stop', 'status']) await assert.rejects(f.control(action), { code: 'UNSUPPORTED_ON_MACOS' });
  await f.runtime.call('click', { app: 'Fixture', element_index: 1 });
  assert.equal(f.calls.at(-1)[0], 'parent'); assert.equal(f.hosts.length, 0);
});

test('missing setup and tampered local helper fail before execution', async t => {
  await mkdir(new URL('../.cache/', import.meta.url), { recursive: true });
  const root = await mkdtemp(path.resolve('.cache/agent-desktop-test-'));
  t.after(() => rm(root, { recursive: true, force: true }));
  await assert.rejects(agentDesktopHelper(root), e => e.code === 'AGENT_DESKTOP_UNAVAILABLE' && e.message.includes('opencu setup agent-desktop'));
  await mkdir(path.join(root, 'scripts/agent-desktop'), { recursive: true });
  await mkdir(path.join(root, '.build/win/agent-desktop'), { recursive: true });
  await writeFile(path.join(root, 'package.json'), '{"version":"0.4.0"}');
  const receipt = { version: '0.4.0', sources: {}, files: {} };
  for (const [group, folder, names] of [['sources', 'scripts/agent-desktop', ['Host.cs', 'setup.ps1']], ['files', '.build/win/agent-desktop', ['OpenCU.AgentDesktop.exe', 'OpenCU.Rdp.dll']]]) {
    for (const name of names) {
      await writeFile(path.join(root, folder, name), 'fixture');
      receipt[group][name] = createHash('sha256').update('fixture').digest('hex');
    }
  }
  await writeFile(path.join(root, '.build/win/agent-desktop/receipt.json'), JSON.stringify(receipt));
  assert.match(await agentDesktopHelper(root), /OpenCU.AgentDesktop.exe$/);
  await writeFile(path.join(root, '.build/win/agent-desktop/OpenCU.Rdp.dll'), 'changed');
  await assert.rejects(agentDesktopHelper(root), { code: 'AGENT_DESKTOP_UNAVAILABLE' });
});

test('host forbids password APIs, disables credential prompts before Connect, and does not reconnect', async () => {
  const source = await readFile(new URL('../scripts/agent-desktop/Host.cs', import.meta.url), 'utf8');
  assert.doesNotMatch(source, /ClearTextPassword|PortablePassword|CredRead|CredWrite|LogonUser|WTSQueryUserToken|\.UserName\s*=/);
  for (const property of ['AllowPromptingForCredentials', 'PromptForCredentials', 'PromptForCredsOnClient', 'AllowCredentialSaving', 'EnableAutoReconnect', 'RedirectClipboard']) {
    const position = source.indexOf(`${property} = false;`);
    assert.ok(position >= 0 && position < source.indexOf('rdp.Connect();'), property);
  }
  assert.doesNotMatch(source, /\.Reconnect\s*\(/);
  const setup = await readFile(new URL('../scripts/agent-desktop/setup.ps1', import.meta.url), 'utf8');
  assert.match(setup, /-Verb RunAs/);
  assert.doesNotMatch(setup, /Get-Credential|Read-Host|ConvertTo-SecureString/);
});
