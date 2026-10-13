import { spawn } from 'node:child_process';
import { access } from 'node:fs/promises';
import { createInterface } from 'node:readline';
import path from 'node:path';
import { setTimeout as pause } from 'node:timers/promises';
import { CoordinateState } from './coordinate-state.mjs';

const inputs = new Set(['click', 'drag', 'paste', 'press_key', 'type_text', 'scroll', 'set_value', 'select_text', 'perform_secondary_action']);

export function toolError(error) {
  return { isError: true, content: [{ type: 'text', text: error.message }], _meta: { 'opencu/error': error.code ?? 'RUNTIME_ERROR' } };
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
  #coordinates = new CoordinateState();
  #lastText = new Map();

  constructor({ root, enginePath } = {}) {
    this.enginePath = enginePath ?? defaultEnginePath(root);
  }

  async #start() {
    try { await access(this.enginePath); }
    catch { throw new Error(`OpenCU engine is missing. Run npm run ${process.platform === 'win32' ? 'build:win' : 'build'}, or use the prepared OpenCU release.`); }
    this.#active();
    this.#child = spawn(this.enginePath, ['serve'], { stdio: ['pipe', 'pipe', 'pipe'], windowsHide: true });
    this.#child.stderr.on('data', () => {});
    this.#child.stdin.on('error', () => this.#fail(new Error('OpenCU engine input closed; no operation was retried.')));
    this.#child.on('error', error => this.#fail(error));
    this.#child.on('exit', () => this.#fail(new Error('OpenCU engine exited; no operation was retried.')));
    const lines = createInterface({ input: this.#child.stdout });
    lines.on('line', line => {
      try {
        const message = JSON.parse(line);
        const request = this.#pending.get(message.id);
        if (!request) return;
        if (!message.error && !Object.hasOwn(message, 'result')) {
          this.#fail(new Error('OpenCU returned an invalid response.')); return;
        }
        this.#pending.delete(message.id);
        clearTimeout(request.timer);
        if (message.error) request.reject(Object.assign(new Error(message.error.message), { code: message.error.code }));
        else request.resolve(message.result);
      } catch { this.#fail(new Error('OpenCU returned invalid JSON.')); }
    });
  }

  #active(signal) {
    if (this.#closing) throw new Error('OpenCU is closing; no further input was sent.');
    if (this.#failure) throw this.#failure;
    if (signal?.aborted) throw new Error('The request was cancelled. Earlier input may already have run; inspect state before retrying.');
  }

  #fail(error) {
    this.#failure ??= error;
    for (const { reject, timer } of this.#pending.values()) { clearTimeout(timer); reject(error); }
    this.#pending.clear();
  }

  async #request(method, params, signal) {
    this.#active(signal);
    this.#started ??= this.#start();
    await this.#started;
    this.#active(signal);
    const id = this.#nextID++;
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        this.#fail(new Error('OpenCU engine timed out. Input may already have run. Reconnect and inspect state; no operation was retried.'));
        // Let in-flight input release its keys; block all later requests.
        this.#child.stdin.end();
      }, 90_000);
      this.#pending.set(id, { resolve, reject, timer });
      this.#child.stdin.write(JSON.stringify({ id, method, params }) + '\n');
    });
  }

  async #observe(method, args, signal) {
    const { app, includeScreenshot = false, waitForText, waitTimeoutMs = 5000 } = args;
    const deadline = Date.now() + waitTimeoutMs;
    let result;
    let retries = 0;
    for (;;) {
      try { result = await this.#request(method, { app, includeScreenshot }, signal); }
      catch (error) {
        if (!['NO_ACCESSIBLE_WINDOW', 'SCREENSHOT_FAILED', 'WINDOW_CHANGED'].includes(error.code) || retries++ >= 2) throw error;
        await pause(150 * retries);
        method = 'get_app_state';
        continue;
      }
      if (!waitForText || result.text.includes(waitForText)) return result;
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
    const unchanged = !disableDiff && !waitForText && this.#lastText.get(key) === state.text;
    this.#lastText.set(key, state.text);
    const content = [{ type: 'text', text: unchanged ? `${state.text.split('\n').slice(0, 3).join('\n')}\nNo accessibility changes.` : state.text }];
    if (state.screenshot) content.push({ type: 'image', data: state.screenshot.data, mimeType: state.screenshot.mimeType });
    return { content, _meta: { 'opencu/app': state.app, 'opencu/engine': 'independent' } };
  }

  async call(method, args, signal) {
    this.#active(signal);
    const run = this.#tail.then(async () => {
      this.#active(signal);
      if (method === 'list_apps') {
        return { content: [{ type: 'text', text: JSON.stringify(await this.#request(method, {}, signal)) }] };
      }
      if (!inputs.has(method) && !['get_app_state', 'activate_app', 'run_actions'].includes(method)) throw new Error('Unknown OpenCU tool');
      this.#coordinates.before(method, args);
      let options = args;
      let completed = 0;
      if (inputs.has(method) || method === 'run_actions') {
        const { app, ...parameters } = args;
        const actions = method === 'run_actions' ? args.actions : [{ method, ...parameters }];
        options = method === 'run_actions' ? args : {
          app, includeScreenshot: method === 'drag' || ['click', 'scroll'].includes(method) && args.element_index === undefined,
        };
        if (actions.some(action => !inputs.has(action.method))) throw new Error('Unknown input operation in batch; no input was sent.');
        for (const [index, { method: action, ...params }] of actions.entries()) {
          try { await this.#request(action, { ...params, app }, signal); completed++; }
          catch (error) {
            error.message = `Action ${index + 1} failed: ${error.message} Earlier actions may have run. Read state before retrying.`;
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
        response = error.lastState ? { ...this.#stateResult(error.lastState, { disableDiff: true }), isError: true } : toolError(error);
        if (error.lastState) response.content.push({ type: 'text', text: error.message });
      }
      return this.#coordinates.after(method, args, response);
    });
    this.#tail = run.catch(() => {});
    return run;
  }

  async close() {
    if (this.#closing) return;
    this.#closing = true;
    const child = this.#child;
    if (!child || child.exitCode !== null || child.signalCode !== null) return;
    child.stdin.end();
    // A held input is capped at 30 seconds. Preserve its normal release on EOF.
    const timer = setTimeout(() => child.kill('SIGTERM'), 35_000);
    timer.unref();
    await new Promise(resolve => child.once('exit', resolve));
    clearTimeout(timer);
  }
}
