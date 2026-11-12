import assert from 'node:assert/strict';
import { chmod, mkdir, mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import test from 'node:test';
import { fileURLToPath } from 'node:url';
import { AGENT_ENV_KEYS, OpenCURuntime, normalizeAgentColor, resolveAgentEnv } from '../src/opencu-runtime.mjs';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');

test('resolveAgentEnv applies hub/socket defaults, expands tilde, and sanitizes optional agent identity', () => {
  assert.deepEqual(AGENT_ENV_KEYS, [
    'OPENCU_AGENT_ID',
    'OPENCU_AGENT_NAME',
    'OPENCU_AGENT_COLOR',
    'OPENCU_HUB_DIR',
    'OPENCU_EVENT_SOCK',
    'OPENCU_CAPTURE_OVERLAY',
  ]);

  const defaults = resolveAgentEnv({ HOME: '/tmp/opencu-home', PATH: '/usr/bin' });
  assert.equal(defaults.OPENCU_HUB_DIR, path.join('/tmp/opencu-home', '.opencu', 'hub'));
  assert.equal(defaults.OPENCU_EVENT_SOCK, path.join('/tmp/opencu-home', '.ibuki-pet', 'opencu.sock'));
  assert.equal(Object.hasOwn(defaults, 'OPENCU_AGENT_ID'), false);
  assert.equal(Object.hasOwn(defaults, 'OPENCU_AGENT_NAME'), false);
  assert.equal(Object.hasOwn(defaults, 'OPENCU_AGENT_COLOR'), false);
  assert.equal(Object.hasOwn(defaults, 'OPENCU_CAPTURE_OVERLAY'), false);

  const custom = resolveAgentEnv({
    HOME: '/tmp/opencu-home',
    OPENCU_AGENT_ID: '  agent-alpha\n\r ',
    OPENCU_AGENT_NAME: '  Coder\u202EAssistantWithAVeryLongNameExceedingTwentyFour  ',
    OPENCU_AGENT_COLOR: ' #38bdf8 ',
    OPENCU_HUB_DIR: '~/my-hub',
    OPENCU_EVENT_SOCK: '~/ibuki/custom.sock',
    OPENCU_CAPTURE_OVERLAY: ' true ',
  });
  assert.equal(custom.OPENCU_AGENT_ID, 'agent-alpha');
  assert.equal([...custom.OPENCU_AGENT_NAME].length <= 24, true);
  assert.equal(custom.OPENCU_AGENT_COLOR, '#38BDF8');
  assert.equal(custom.OPENCU_HUB_DIR, path.join('/tmp/opencu-home', 'my-hub'));
  assert.equal(custom.OPENCU_EVENT_SOCK, path.join('/tmp/opencu-home', 'ibuki', 'custom.sock'));
  assert.equal(custom.OPENCU_CAPTURE_OVERLAY, '1');

  assert.equal(normalizeAgentColor('#f69'), '#FF6699');
  assert.equal(normalizeAgentColor('invalid-color'), undefined);

  const fallbackInvalid = resolveAgentEnv({
    HOME: '/tmp/opencu-home',
    OPENCU_AGENT_NAME: '   ',
    OPENCU_AGENT_COLOR: 'rgb(255,0,0)',
    OPENCU_CAPTURE_OVERLAY: '0',
  });
  assert.equal(Object.hasOwn(fallbackInvalid, 'OPENCU_AGENT_NAME'), false);
  assert.equal(Object.hasOwn(fallbackInvalid, 'OPENCU_AGENT_COLOR'), false);
  assert.equal(Object.hasOwn(fallbackInvalid, 'OPENCU_CAPTURE_OVERLAY'), false);
});

test('OpenCURuntime forwards multi-agent identity, capture overlay, and companion socket env to the spawned engine', async t => {
  const dir = await mkdtemp(path.join(tmpdir(), 'opencu-multi-env-'));
  t.after(async () => { await rm(dir, { recursive: true, force: true }); });

  const envDump = path.join(dir, 'spawned-env.json');
  const engine = path.join(dir, 'mock-engine');
  await mkdir(dir, { recursive: true });
  await writeFile(engine, `#!${process.execPath}
import { writeFileSync } from 'node:fs';
import { createInterface } from 'node:readline';
writeFileSync(${JSON.stringify(envDump)}, JSON.stringify({
  OPENCU_AGENT_ID: process.env.OPENCU_AGENT_ID ?? null,
  OPENCU_AGENT_NAME: process.env.OPENCU_AGENT_NAME ?? null,
  OPENCU_AGENT_COLOR: process.env.OPENCU_AGENT_COLOR ?? null,
  OPENCU_HUB_DIR: process.env.OPENCU_HUB_DIR ?? null,
  OPENCU_EVENT_SOCK: process.env.OPENCU_EVENT_SOCK ?? null,
  OPENCU_CAPTURE_OVERLAY: process.env.OPENCU_CAPTURE_OVERLAY ?? null,
}));
const rl = createInterface({ input: process.stdin });
rl.on('line', line => {
  const req = JSON.parse(line);
  process.stdout.write(JSON.stringify({ id: req.id, result: [] }) + '\\n');
});
`);
  await chmod(engine, 0o700);

  const runtime = new OpenCURuntime({
    root,
    enginePath: engine,
    env: {
      ...process.env,
      HOME: dir,
      OPENCU_AGENT_ID: 'swarm-worker-2',
      OPENCU_AGENT_NAME: 'Reviewer',
      OPENCU_AGENT_COLOR: '#a78bfa',
      OPENCU_CAPTURE_OVERLAY: '1',
    },
  });
  t.after(() => runtime.close());

  const res = await runtime.call('list_apps', {});
  assert.equal(res.isError ?? false, false);

  const captured = JSON.parse(await readFile(envDump, 'utf8'));
  assert.deepEqual(captured, {
    OPENCU_AGENT_ID: 'swarm-worker-2',
    OPENCU_AGENT_NAME: 'Reviewer',
    OPENCU_AGENT_COLOR: '#A78BFA',
    OPENCU_HUB_DIR: path.join(dir, '.opencu', 'hub'),
    OPENCU_EVENT_SOCK: path.join(dir, '.ibuki-pet', 'opencu.sock'),
    OPENCU_CAPTURE_OVERLAY: '1',
  });
});

test('WorkerLauncher guards launchd bootstrap with inter-process lock and CompanionBroadcaster stays secret-free', async () => {
  const launcher = await readFile(path.join(root, 'native/Sources/OpenCU/WorkerLauncher.swift'), 'utf8');
  assert.match(launcher, /AgentConfig\.forwardedEnvironmentKeys/);
  assert.match(launcher, /AgentConfig\.launchdLockPath/);

  const presence = await readFile(path.join(root, 'native/Sources/OpenCU/PresenceController.swift'), 'utf8');
  assert.match(presence, /NSWindow\.Level = \.statusBar/);
  assert.match(presence, /AgentConfig\.captureOverlayEnabled\(\) \? \.readOnly : \.none/);

  const broadcaster = await readFile(path.join(root, 'native/Sources/OpenCU/CompanionBroadcaster.swift'), 'utf8');
  assert.match(broadcaster, /SOCK_DGRAM/);
  assert.match(broadcaster, /cg_points_top_left/);
  assert.doesNotMatch(broadcaster, /args\["text"\]|args\["value"\]|args\["key"\]|NSPasteboard|kAXTitleAttribute|kAXValueAttribute/);
});
