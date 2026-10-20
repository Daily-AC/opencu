import { spawn } from 'node:child_process';
import { access } from 'node:fs/promises';
import { createInterface } from 'node:readline';
import path from 'node:path';
import { setTimeout as pause } from 'node:timers/promises';
import { CoordinateState } from './coordinate-state.mjs';

const personStops = new Set(['STOPPED_BY_PERSON', 'USER_STOPPED']);
const inputs = new Set(['click', 'drag', 'paste', 'press_key', 'type_text', 'scroll', 'set_value', 'select_text', 'perform_secondary_action']);

export function toolError(error) {
  const code = error.code ?? 'RUNTIME_ERROR';
  return { isError: true, content: [{ type: 'text', text: `${code}: ${error.message}` }], _meta: {
    'opencu/error': code,
    ...(error.details ? { 'opencu/errorDetails': error.details } : {}),
  } };
}

export function defaultEnginePath(root, platform = process.platform) {
  if (platform === 'win32') return path.join(root, '.build/win/opencu-engine.exe');
  return path.join(root, '.build/OpenCU.app/Contents/MacOS/opencu-engine');
}

export class OpenCURuntime {
  #child;
  #started;
  #pending = new Map();
  #nextID = 1;
  #tail = Promise.resolve();
  #closing = false;
  #failure;
  #personStop;
  #retiring;
  #retiringChild;
  #needsObservation = false;
  #requestTimeoutMs;
  #coordinates = new CoordinateState();
  #lastText = new Map();
  #scopeRequest = 0;
  #platform;
  #spawnEngine;
  #allowRestart;
  #onPersonStop;

  constructor({ root, enginePath, requestTimeoutMs = 90_000, platform = process.platform,
    spawnEngine, allowRestart = true, onPersonStop } = {}) {
    this.#requestTimeoutMs = requestTimeoutMs;
    this.#platform = platform;
    this.enginePath = enginePath ?? defaultEnginePath(root);
    this.#spawnEngine = spawnEngine;
    this.#allowRestart = allowRestart;
    this.#onPersonStop = onPersonStop;
  }

  async #start() {
    try { if (!this.#spawnEngine) await access(this.enginePath); }
    catch { throw new Error(`OpenCU engine is missing. Run npm run ${process.platform === 'win32' ? 'build:win' : 'build'}, or use the prepared OpenCU release.`); }
    this.#active();
    if (this.#personStop) throw this.#personStop;
    const child = this.#child = this.#spawnEngine ? await this.#spawnEngine()
      : spawn(this.enginePath, ['serve'], { stdio: ['pipe', 'pipe', 'pipe'], windowsHide: true });
    child.stderr.on('data', () => {});
    const fail = error => { if (this.#child === child) this.#fail(error); };
    child.stdin.on('error', () => fail(new Error('OpenCU engine input closed; no operation was retried.')));
    child.on('error', fail);
    child.on('exit', () => fail(new Error('OpenCU engine exited; no operation was retried.')));
    const lines = createInterface({ input: child.stdout });
    lines.on('line', line => {
      try {
        const message = JSON.parse(line);
        if (child !== this.#child && child !== this.#retiringChild) return;
        // Even a late reply from the retiring engine must preserve a person's stop.
        if (personStops.has(message.error?.code)) {
          this.#personStop ??= Object.assign(new Error(message.error.message), { code: message.error.code });
          this.#onPersonStop?.(this.#personStop);
        }
        const request = this.#pending.get(message.id);
        if (!request) return;
        if (!message.error && !Object.hasOwn(message, 'result')) {
          fail(new Error('OpenCU returned an invalid response.')); return;
        }
        this.#pending.delete(message.id);
        clearTimeout(request.timer);
        if (message.error) {
          request.reject(Object.assign(new Error(message.error.message), { code: message.error.code, details: message.error.data }));
        } else request.resolve(message.result);
      } catch { fail(new Error('OpenCU returned invalid JSON.')); }
    });
  }

  #active(signal) {
    if (this.#closing) throw new Error('OpenCU is closing; no further input was sent.');
    if (this.#failure) throw this.#personStop ?? this.#failure;
    if (signal?.aborted) throw new Error('The request was cancelled. Earlier input may already have run; inspect state before retrying.');
  }

  #fail(error) {
    this.#failure ??= error;
    for (const { reject, timer } of this.#pending.values()) { clearTimeout(timer); reject(error); }
    this.#pending.clear();
  }

  async #request(method, params, signal) {
    this.#active(signal);
    await this.#retiring;
    this.#active(signal);
    this.#started ??= this.#start();
    await this.#started;
    this.#active(signal);
    const id = this.#nextID++;
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        const error = new Error('OpenCU engine timed out. Input may already have run. Read fresh state before further input; no operation was retried.');
        if (!this.#allowRestart) this.#failure ??= error;
        const child = this.#child;
        this.#child = undefined;
        this.#started = undefined;
        this.#needsObservation = true;
        this.#coordinates = new CoordinateState();
        this.#lastText.clear();
        this.#retiringChild = child;
        // Reap the old process before any replacement can send input. Preserve
        // normal held-key cleanup, and keep listening for a late stop result.
        this.#retiring = this.#shutdown(child).then(() => { this.#retiringChild = undefined; });
        for (const pending of this.#pending.values()) { clearTimeout(pending.timer); pending.reject(error); }
        this.#pending.clear();
      }, this.#requestTimeoutMs);
      this.#pending.set(id, { resolve, reject, timer });
      this.#child.stdin.write(JSON.stringify({ id, method, params }) + '\n');
    });
  }

  async #observe(method, args, signal) {
    const { app, includeScreenshot = false, waitForText, waitTimeoutMs = 5000, scope } = args;
    const scopeOptions = scope === undefined ? {} : { scope, scopeRequest: String(++this.#scopeRequest) };
    const deadline = Date.now() + waitTimeoutMs;
    let result;
    let retries = 0;
    for (;;) {
      try { result = await this.#request(method, { app, includeScreenshot, ...scopeOptions }, signal); }
      catch (error) {
        if (!['NO_ACCESSIBLE_WINDOW', 'SCREENSHOT_FAILED', 'WINDOW_CHANGED'].includes(error.code) || retries++ >= 2) throw error;
        await pause(150 * retries);
        method = 'get_app_state';
        continue;
      }
      this.#needsObservation = false;
      const scopeGone = scope !== undefined && result.scopeRoot?.startsWith('gone:');
      if (!waitForText || !scopeGone && result.text.split('\n').some(line => /^\s*\[\d+\] /.test(line) && line.includes(waitForText))) return result;
      if (Date.now() >= deadline) {
        const error = new Error('The expected text did not appear. Inspect the returned state before continuing. No additional input was sent.');
        error.code = 'WAIT_TIMEOUT'; error.lastState = result; throw error;
      }
      await pause(150);
      method = 'get_app_state';
    }
  }

  #stateResult(state, { disableDiff = false, waitForText } = {}) {
    const key = state.app.id;
    const previous = this.#lastText.get(key);
    const scope = state.scopeRoot ?? null;
    const unchanged = !disableDiff && !waitForText && previous?.text === state.text && previous.scope === scope;
    this.#lastText.set(key, { text: state.text, scope });
    const content = [{ type: 'text', text: unchanged ? `${state.text.split('\n').slice(0, 3).join('\n')}\nNo accessibility changes.` : state.text }];
    if (state.screenshot) content.push({ type: 'image', data: state.screenshot.data, mimeType: state.screenshot.mimeType });
    return { content, _meta: { 'opencu/app': state.app, 'opencu/engine': 'independent' } };
  }

  async call(method, args, signal) {
    this.#active(signal);
    const run = this.#tail.then(async () => {
      await this.#retiring;
      this.#active(signal);
      if (this.#personStop && !this.#child) throw this.#personStop;
      if (method === 'list_apps') {
        return { content: [{ type: 'text', text: JSON.stringify(await this.#request(method, {}, signal)) }] };
      }
      if (!inputs.has(method) && !['get_app_state', 'activate_app', 'run_actions'].includes(method)) throw new Error('Unknown OpenCU tool');
      // Preserve the person's stop even when local coordinate validation would
      // otherwise mask it. Text reads keep the same connection and remain usable.
      if (this.#personStop && (inputs.has(method) || ['activate_app', 'run_actions'].includes(method)
          || this.#personStop.code === 'STOPPED_BY_PERSON' && method === 'get_app_state' && args.includeScreenshot)) {
        throw Object.assign(new Error(this.#personStop.message), { code: this.#personStop.code });
      }
      if (this.#needsObservation && (inputs.has(method) || ['activate_app', 'run_actions'].includes(method))) {
        throw Object.assign(new Error('The engine timed out and must restart. Read fresh app state before input; no operation was retried.'), { code: 'OBSERVATION_REQUIRED' });
      }
      if (args.scope !== undefined) {
        if (this.#platform !== 'win32') throw Object.assign(new Error('scope is Windows-only for now.'), { code: 'INVALID_ARGUMENT' });
        if (!Number.isSafeInteger(args.scope) || args.scope < 1) throw Object.assign(new Error('scope must be a positive integer.'), { code: 'INVALID_ARGUMENT' });
      }
      this.#coordinates.before(method, args);
      let options = args;
      let completed = 0;
      if (inputs.has(method) || method === 'run_actions') {
        const { app, scope, ...parameters } = args;
        const actions = method === 'run_actions' ? args.actions : [{ method, ...parameters }];
        options = method === 'run_actions' ? args : {
          app, scope, includeScreenshot: method === 'drag' || ['click', 'scroll'].includes(method) && args.element_index === undefined,
        };
        if (actions.some(action => !inputs.has(action.method) && action.method !== 'wait')) throw new Error('Unknown input operation in batch; no input was sent.');
        if (actions.some(action => action.method === 'wait' && (!Number.isInteger(action.ms) || action.ms < 1 || action.ms > 15000))) {
          throw Object.assign(new Error('wait.ms must be an integer from 1 to 15000; no input was sent.'), { code: 'INVALID_ARGUMENT' });
        }
        for (const [index, { method: action, ...params }] of actions.entries()) {
          try {
            const result = await this.#request(action, { ...params, app }, signal);
            completed++;
            if (result.outcome === 'unknown') {
              // An AX timeout can mean that the action replaced its own window.
              // Stop the batch; no automatic observation, retry or later input.
              this.#lastText.clear();
              return this.#coordinates.after(method, args, {
                content: [{ type: 'text', text: result.message }],
                _meta: { 'opencu/app': result.app, 'opencu/engine': 'independent',
                  'opencu/actionOutcome': 'unknown', 'opencu/actionsAttempted': completed },
              });
            }
          }
          catch (error) {
            error.message = `Action ${index + 1} failed: ${error.message} Earlier actions may have run.${personStops.has(error.code) || error.code === 'PERSON_ACTIVE' ? '' : ' Read state before retrying.'}`;
            throw error;
          }
        }
      }
      let response;
      try {
        if (completed) await pause(100); // Let queued native input reach its app.
        response = this.#stateResult(await this.#observe(method === 'activate_app' ? method : 'get_app_state', options, signal), options);
      } catch (error) {
        if (completed) error.message = `All ${completed} actions returned, but their final observation failed. Do not repeat them; inspect state. ${error.message}`;
        response = toolError(error);
        if (error.lastState) {
          const state = this.#stateResult(error.lastState, { disableDiff: true });
          response = { ...state, ...response, _meta: { ...state._meta, ...response._meta },
            content: [...response.content, ...state.content] };
        }
      }
      return this.#coordinates.after(method, args, response);
    });
    this.#tail = run.catch(() => {});
    return run;
  }

  async close() {
    if (this.#closing) return;
    this.#closing = true;
    await this.#retiring;
    await this.#shutdown(this.#child);
  }

  async #shutdown(child) {
    if (!child || child.exitCode !== null || child.signalCode !== null) return;
    // Wait for close, not just exit: drain late stdout (including stop errors)
    // before allowing a replacement process.
    const closed = new Promise(resolve => child.once('close', resolve));
    child.stdin.end();
    // A held input is capped at 30 seconds. Preserve its normal release on EOF.
    const timer = setTimeout(() => child.kill('SIGTERM'), 35_000);
    timer.unref();
    await closed;
    clearTimeout(timer);
  }
}
