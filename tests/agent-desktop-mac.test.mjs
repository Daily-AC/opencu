import assert from 'node:assert/strict';
import test from 'node:test';
import { AgentDesktopRuntime } from '../src/agent-desktop.mjs';

const fault = code => Object.assign(new Error(code), { code });
const json = reply => JSON.parse(reply.content[0].text);
const deferred = () => { let resolve, reject; const promise = new Promise((a, b) => { resolve = a; reject = b; }); return { promise, resolve, reject }; };
function fixture(t, options = {}) {
  const workers = [], calls = [];
  let waiting;
  const runtime = new AgentDesktopRuntime({ platform: 'darwin', root: '/fixture', runtimeFactory: config => {
    let phase = 'inactive', stopped = false;
    const worker = { config, closed: false,
      async desktopControl(action) {
        calls.push([config.agentDesktop, action]);
        if (action === 'start') {
          if (options.startError) throw fault(options.startError);
          phase = 'running';
        }
        if (action === 'stop') {
          waiting?.reject(fault(stopped ? 'STOPPED_BY_PERSON' : 'ENGINE_ERROR'));
          phase = stopped ? 'stopped' : 'inactive';
          if (options.stopWait) await options.stopWait.promise;
        }
        return { state: phase, stoppedByPerson: stopped, parentLocked: false,
          cleanup: { ok: !options.cleanupError }, preview: { running: phase === 'running' } };
      },
      async call(method, args) {
        assert.equal(worker.closed, false);
        calls.push([config.agentDesktop, method, args]);
        if (options.wait && config.agentDesktop) { waiting = deferred(); return await waiting.promise; }
        return { content: [{ type: 'text', text: config.agentDesktop ? 'desktop' : 'normal' }] };
      },
      stopByPerson() {
        stopped = true; phase = 'stopped';
        config.onDesktopEvent?.({ state: phase, generation: 2, stoppedByPerson: true });
      },
      async close() { worker.closed = true; waiting?.reject(fault('ENGINE_DISCONNECTED')); calls.push([config.agentDesktop, 'close']); },
    };
    workers.push(worker); return worker;
  } });
  t.after(() => runtime.close().catch(() => {}));
  return { runtime, workers, calls, control: action => runtime.call('agent_desktop', { action }) };
}

test('macOS keeps action-only schema and selects one non-restarting native owner', async t => {
  const f = fixture(t);
  await f.runtime.call('get_app_state', { app: 'Fixture' });
  assert.equal(f.calls[0][0], false);
  assert.equal(json(await f.control('start')).state, 'running');
  assert.equal(f.workers[0].closed, true);
  assert.equal(f.workers[1].config.allowRestart, false);
  for (const method of ['list_apps', 'get_app_state', 'click', 'run_actions']) await f.runtime.call(method, { app: 'Fixture' });
  await f.control('start'); assert.equal(f.workers.length, 2);
  await assert.rejects(f.runtime.call('agent_desktop', { action: 'start', consent: true }), { code: 'INVALID_ARGUMENT' });
  assert.equal(json(await f.control('stop')).state, 'inactive');
  await f.runtime.call('get_app_state', { app: 'Fixture' });
  assert.equal(f.calls.at(-1)[0], false);
  assert.equal(json(await f.control('stop')).state, 'inactive');
});

test('status and stop bypass a pending macOS consent call without replay', async t => {
  const f = fixture(t, { wait: true });
  await f.control('start');
  const pending = f.runtime.call('get_app_state', { app: 'Fixture' });
  const rejected = assert.rejects(pending);
  await new Promise(resolve => setImmediate(resolve));
  assert.equal(json(await f.control('status')).state, 'running');
  assert.equal(json(await f.control('stop')).state, 'inactive');
  await rejected;
  assert.equal(f.calls.filter(call => call[1] === 'get_app_state').length, 1);
});

test('idle native close event permanently latches the whole MCP connection', async t => {
  const f = fixture(t);
  await f.control('start');
  f.workers[1].stopByPerson();
  for (const method of ['list_apps', 'get_app_state', 'click', 'activate_app', 'run_actions']) {
    await assert.rejects(f.runtime.call(method, { app: 'Fixture' }), { code: 'STOPPED_BY_PERSON' });
  }
  assert.equal(json(await f.control('status')).stoppedByPerson, true);
  assert.equal(json(await f.control('stop')).state, 'stopped');
  await assert.rejects(f.control('start'), { code: 'STOPPED_BY_PERSON' });
  assert.equal(f.workers.length, 2);
});

test('failed macOS startup and cleanup cannot fall back to normal app input', async t => {
  const f = fixture(t, { startError: 'AGENT_DISPLAY_SPI_UNAVAILABLE', cleanupError: true });
  await assert.rejects(f.control('start'), { code: 'AGENT_DISPLAY_SPI_UNAVAILABLE' });
  await assert.rejects(f.runtime.call('click', { app: 'Fixture', element_index: 1 }), { code: 'AGENT_DISPLAY_SPI_UNAVAILABLE' });
  await assert.rejects(f.control('stop'), { code: 'AGENT_DESKTOP_CLEANUP_FAILED' });
  await assert.rejects(f.runtime.call('list_apps'), { code: 'AGENT_DESKTOP_CLEANUP_FAILED' });
  assert.equal(f.workers.length, 2);
});

test('MCP close interrupts a pending desktop operation rather than waiting for its consent', async t => {
  const f = fixture(t, { wait: true });
  await f.control('start');
  const pending = f.runtime.call('get_app_state', { app: 'Fixture' });
  const rejected = assert.rejects(pending);
  await new Promise(resolve => setImmediate(resolve));
  await f.runtime.close(); await rejected;
  assert.ok(f.workers.every(worker => worker.closed));
});


test('app calls cannot escape to a retiring worker during tool stop', async t => {
  const stopWait = deferred();
  const f = fixture(t, { stopWait });
  await f.control('start');
  const stopping = f.control('stop');
  await new Promise(resolve => setImmediate(resolve));
  await assert.rejects(f.runtime.call('get_app_state', { app: 'Fixture' }), { code: 'AGENT_DESKTOP_UNAVAILABLE' });
  stopWait.resolve(); await stopping;
  await assert.rejects(f.runtime.call('activate_app', { app: 'Fixture' }), { code: 'OBSERVATION_REQUIRED' });
  await f.runtime.call('get_app_state', { app: 'Fixture' });
  assert.equal(f.calls.filter(call => call[0] && call[1] === 'get_app_state').length, 0);
});

// Real JSON-lines transport against a disposable Node process; never the GUI engine.
import { spawn } from 'node:child_process';
import { OpenCURuntime } from '../src/opencu-runtime.mjs';
async function transportFixture(t) {
  const calls = [], events = [];
  const script = `
    const { createInterface } = require('node:readline');
    let waiting, reads = 0, observedApp;
    const send = (id, result) => process.stdout.write(JSON.stringify({ id, result }) + '\\n');
    const state = (text, app = 'fixture') => ({ app: { id: app }, text, agentDesktop: { windowState: app === 'reduced' ? 'reduced' : 'admitted' } });
    createInterface({input:process.stdin}).on('line', line => {
      const q=JSON.parse(line); process.stderr.write(line+'\\n');
      if(q.method==='agent_desktop_start') return send(q.id,{state:'running'});
      if(q.method==='agent_desktop_status') {
        send(q.id,{state:'running',consent:waiting?{}:null});
        if(q.params.emitReturn) setTimeout(()=>process.stdout.write(JSON.stringify({event:'agent_desktop',state:'running',generation:4,stoppedByPerson:false,parentLocked:false})+'\\n'),10);
        return;
      }
      if(q.method==='agent_desktop_stop'||q.method==='agent_desktop_cancel') {
        if(waiting) { process.stdout.write(JSON.stringify({id:waiting,error:{code:'ENGINE_ERROR',message:'cancelled'}})+'\\n'); waiting=null; }
        return send(q.id,{state:'inactive',cleanup:{ok:true}});
      }
      if(q.method==='get_app_state') {
        if(q.params.app==='pending') { waiting=q.id; return; }
        observedApp = q.params.app;
        return send(q.id,state(++reads===1?'[1] Loading':'[1] Ready', q.params.app));
      }
      if(q.method==='click' && (q.params.app==='reduced' || q.params.app!==observedApp)) {
        return process.stdout.write(JSON.stringify({id:q.id,error:{code:q.params.app==='reduced'?'AGENT_DESKTOP_CONSENT_REQUIRED':'OBSERVATION_REQUIRED',message:'fixture native admission'}})+'\\n');
      }
      send(q.id,{ok:true});
    });
  `;
  let child;
  const runtime = new OpenCURuntime({ root: '/fixture', platform: 'darwin', agentDesktop: true, allowRestart: false,
    requestTimeoutMs: 2000, onDesktopEvent: event => events.push(event),
    spawnEngine: async () => {
      child = spawn(process.execPath, ['-e', script], { stdio: ['pipe', 'pipe', 'pipe'] });
      let buffer = '';
      child.stderr.on('data', bytes => { buffer += bytes; let newline; while ((newline = buffer.indexOf('\n')) >= 0) { calls.push(JSON.parse(buffer.slice(0, newline))); buffer = buffer.slice(newline + 1); } });
      return child;
    } });
  t.after(() => runtime.close());
  await runtime.desktopControl('start');
  return { runtime, calls, events };
}

test('actual desktop transport marks only the first explicit observation as consent eligible', async t => {
  const f = await transportFixture(t);
  await f.runtime.call('get_app_state', { app: 'fixture', waitForText: 'Ready', waitTimeoutMs: 1000 });
  await f.runtime.call('run_actions', { app: 'fixture', actions: [{ method: 'press_key', key: 'Tab' }] });
  assert.deepEqual(f.calls.filter(call => call.method === 'get_app_state').map(call => call.params.desktopExplicitObservation), [true, false, false]);
});

test('actual control lane responds during consent and cancellation identifies the original request', async t => {
  const f = await transportFixture(t);
  const controller = new AbortController();
  const pending = f.runtime.call('get_app_state', { app: 'pending' }, controller.signal);
  const cancelled = pending.then(result => assert.equal(result._meta['opencu/error'], 'ENGINE_ERROR'));
  while (!f.calls.some(call => call.params.app === 'pending')) await new Promise(resolve => setTimeout(resolve, 5));
  assert.ok((await f.runtime.desktopControl('status')).consent);
  controller.abort(); await cancelled;
  const read = f.calls.find(call => call.params.app === 'pending');
  const cancel = f.calls.find(call => call.method === 'agent_desktop_cancel');
  assert.equal(cancel.params.requestID, String(read.id));
  assert.equal(f.calls.filter(call => call.params.app === 'pending').length, 1);
  assert.equal((await f.runtime.desktopControl('stop')).cleanup.ok, true);
});

test('asynchronous geometry changes require fresh coordinates without guessing admission', async t => {
  const f = await transportFixture(t);
  await f.runtime.call('get_app_state', { app: 'fixture' });
  await f.runtime.desktopControl('status', { emitReturn: true });
  while (!f.events.length) await new Promise(resolve => setTimeout(resolve, 5));
  await assert.rejects(f.runtime.call('click', { app: 'fixture', x: 1, y: 1 }), { code: 'OBSERVATION_REQUIRED' });
  assert.equal(f.calls.filter(call => call.method === 'click').length, 0);
});


test('a reduced read does not invent missing consent for a different admitted app', async t => {
  const f = await transportFixture(t);
  await f.runtime.call('get_app_state', { app: 'fixture' });
  await f.runtime.call('get_app_state', { app: 'reduced' });
  await assert.rejects(f.runtime.call('click', { app: 'reduced', element_index: 1 }), { code: 'AGENT_DESKTOP_CONSENT_REQUIRED' });
  // The native action boundary decides whether fixture's observation is stale;
  // the reduced app must not block that request with someone else's consent error.
  await assert.rejects(f.runtime.call('click', { app: 'fixture', element_index: 1 }), { code: 'OBSERVATION_REQUIRED' });
  assert.equal(f.calls.filter(call => call.method === 'click' && call.params.app === 'fixture').length, 1);
});
