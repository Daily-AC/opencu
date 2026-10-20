import { spawn } from 'node:child_process';
import { createHash } from 'node:crypto';
import { readFile } from 'node:fs/promises';
import { createInterface } from 'node:readline';
import path from 'node:path';
import { OpenCURuntime } from './opencu-runtime.mjs';

export const agentDesktopSetupCommand = root => root
  ? `& '${path.win32.join(root, 'bin', 'opencu.cmd').replaceAll("'", "''")}' setup agent-desktop`
  : '& "$env:LOCALAPPDATA\\OpenCU\\bin\\opencu.cmd" setup agent-desktop';
const error = (code, message) => Object.assign(new Error(message), { code });
const stopped = () => error('USER_STOPPED', 'The person stopped the agent desktop. Do not restart or reconnect without their explicit permission.');
const reply = state => ({ content: [{ type: 'text', text: JSON.stringify(state) }] });
const sha = bytes => createHash('sha256').update(bytes).digest('hex');

// Validate the local derivative of the hash-pinned release, not an arbitrary exe
// supplied by an MCP caller. Setup runs the system compiler offline.
export async function agentDesktopHelper(root) {
  try {
    const source = path.join(root, 'scripts/agent-desktop');
    const receipt = JSON.parse(await readFile(path.join(root, '.build/win/agent-desktop/receipt.json'), 'utf8'));
    const version = JSON.parse(await readFile(path.join(root, 'package.json'), 'utf8')).version;
    if (receipt.version !== version) throw new Error('version changed');
    for (const name of ['Host.cs', 'setup.ps1']) {
      if (receipt.sources?.[name] !== sha(await readFile(path.join(source, name)))) throw new Error('source changed');
    }
    for (const name of ['OpenCU.AgentDesktop.exe', 'OpenCU.Rdp.dll']) {
      if (receipt.files?.[name] !== sha(await readFile(path.join(root, '.build/win/agent-desktop', name)))) throw new Error('helper changed');
    }
    return path.join(root, '.build/win/agent-desktop/OpenCU.AgentDesktop.exe');
  } catch {
    throw Object.assign(error('AGENT_DESKTOP_UNAVAILABLE', `Agent desktop helper preparation is required; start prepares it automatically when Windows child sessions are enabled. For first-time enablement, run in PowerShell: ${agentDesktopSetupCommand(root)}`), { setupRequired: true });
  }
}

// Keep structured helper diagnostics even when the process exits unsuccessfully.
export function parseAgentDesktopOutput(stdout, exitCode, stderr = '') {
  let result;
  try { result = JSON.parse(stdout); }
  catch { throw error('AGENT_DESKTOP_UNAVAILABLE', stderr.trim() || `Agent desktop helper returned invalid JSON (exit ${exitCode}).`); }
  if (result.event === 'failure' || exitCode !== 0) {
    throw Object.assign(error(result.code ?? 'AGENT_DESKTOP_UNAVAILABLE', result.message ?? `Agent desktop helper exited with code ${exitCode}.`),
      { setupRequired: result.setupRequired === true });
  }
  return result;
}

export async function runAgentDesktopHelper(command, args, { timeoutMs = 10_000 } = {}) {
  return await new Promise((resolve, reject) => {
    const child = spawn(command, args, { windowsHide: true, stdio: ['ignore', 'pipe', 'pipe'] });
    let stdout = '', stderr = '';
    const timer = setTimeout(() => { child.kill(); reject(error('AGENT_DESKTOP_UNAVAILABLE', 'Agent desktop helper timed out.')); }, timeoutMs);
    const collect = (stream, add) => stream.on('data', chunk => {
      add(chunk); if (stdout.length + stderr.length > 1024 * 1024) { child.kill(); reject(error('AGENT_DESKTOP_UNAVAILABLE', 'Agent desktop diagnostic output exceeded its limit.')); }
    });
    collect(child.stdout, chunk => { stdout += chunk; }); collect(child.stderr, chunk => { stderr += chunk; });
    child.once('error', cause => { clearTimeout(timer); reject(error('AGENT_DESKTOP_UNAVAILABLE', cause.message)); });
    child.once('close', code => {
      clearTimeout(timer);
      try { resolve(parseAgentDesktopOutput(stdout, code, stderr)); } catch (cause) { reject(cause); }
    });
  });
}

export async function agentDesktopAvailability(root, platform = process.platform) {
  if (platform !== 'win32') return { available: false, code: 'UNSUPPORTED_ON_MACOS' };
  try {
    const helper = await agentDesktopHelper(root);
    return await runAgentDesktopHelper(helper, ['probe']);
  } catch (cause) {
    return { available: false, code: cause.code ?? 'AGENT_DESKTOP_UNAVAILABLE', message: cause.message,
      setupRequired: cause.setupRequired === true,
      ...(cause.setupRequired ? { setupCommand: agentDesktopSetupCommand(root) } : {}) };
  }
}

const preparations = new Map();
export async function prepareAgentDesktop(root, { availability = agentDesktopAvailability, run = runAgentDesktopHelper } = {}) {
  const capability = await availability(root);
  if (capability.available) return capability;
  if (!capability.setupRequired) throw error(capability.code ?? 'AGENT_DESKTOP_UNAVAILABLE', capability.message);
  // Same-process callers share preparation; the script also holds an installation
  // mutex across processes. Preparation never connects a child or replays input.
  if (!preparations.has(root)) preparations.set(root, (async () => {
    await run(path.win32.join(process.env.SystemRoot ?? 'C:\\Windows', 'System32/WindowsPowerShell/v1.0/powershell.exe'),
      ['-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', path.join(root, 'scripts/agent-desktop/setup.ps1'), '-Root', root, '-PrepareOnly'],
      { timeoutMs: 90_000 });
    const prepared = await availability(root);
    if (!prepared.available) throw error(prepared.code ?? 'AGENT_DESKTOP_UNAVAILABLE', prepared.message ?? 'Prepared helper is not available.');
    return prepared;
  })().finally(() => preparations.delete(root)));
  return await preparations.get(root);
}

export class NativeAgentDesktop {
  #root;
  #child;
  #closing = false;
  #failure;
  #onFailure;
  #loggedOff = false;
  #cleanupError;
  constructor({ root, onFailure }) { this.#root = root; this.#onFailure = onFailure; }
  async start() {
    await prepareAgentDesktop(this.#root);
    const helper = await agentDesktopHelper(this.#root);
    const child = this.#child = spawn(helper, ['host', String(process.pid)], {
      stdio: ['pipe', 'pipe', 'pipe'], windowsHide: true,
    });
    child.stderr.resume();
    child.stdin.on('error', () => {});
    const lines = createInterface({ input: child.stdout });
    return await new Promise((resolve, reject) => {
      const fail = cause => {
        if (this.#closing) { reject(cause); return; }
        this.#failure ??= cause;
        this.#onFailure(this.#failure);
        reject(this.#failure);
      };
      const timer = setTimeout(() => {
        fail(error('AGENT_DESKTOP_UNAVAILABLE', 'Agent desktop startup timed out. No input was replayed.'));
        child.stdin.end();
      }, 60_000);
      const clear = () => clearTimeout(timer);
      child.once('error', cause => { clear(); fail(cause); });
      child.once('close', () => {
        clear(); lines.close();
        fail(error('AGENT_DESKTOP_LOST', 'The agent desktop host exited. No reconnect or parent-desktop fallback was attempted.'));
      });
      lines.on('line', line => {
        let message;
        try { message = JSON.parse(line); } catch { fail(error('AGENT_DESKTOP_LOST', 'Invalid host protocol.')); return; }
        if (message.event === 'ready') {
          clear();
          if (!Number.isSafeInteger(message.sessionId) || message.sessionId <= 0 || message.hostPid !== child.pid) {
            fail(error('AGENT_DESKTOP_AUTH_FAILED', 'Invalid child identity.')); child.stdin.end(); return;
          }
          resolve({ process: child, sessionId: message.sessionId, hostPid: child.pid });
        } else if (message.event === 'failure') {
          if (message.code === 'USER_STOPPED') this.#onFailure(stopped());
          if (message.code === 'AGENT_DESKTOP_CLEANUP_FAILED') this.#cleanupError = error(message.code, message.message);
          clear(); fail(error(message.code ?? 'AGENT_DESKTOP_LOST', message.message));
        } else if (message.event === 'closed') {
          this.#loggedOff = message.loggedOff === true;
        } else if (message.error?.code === 'USER_STOPPED') {
          // Observe late engine replies even while its runtime is retiring.
          this.#onFailure(stopped()); fail(stopped());
        }
      });
    });
  }
  async close() {
    this.#closing = true;
    const child = this.#child;
    if (!child) return;
    if (child.exitCode === null && child.signalCode === null) await new Promise(resolve => {
      const timer = setTimeout(() => child.kill(), 40_000);
      child.once('close', () => { clearTimeout(timer); resolve(); });
      child.stdin.end();
    });
    if (!this.#loggedOff) throw this.#cleanupError ?? error('AGENT_DESKTOP_CLEANUP_FAILED', 'Child logoff was not confirmed. Inspect Windows sessions; no parent-desktop fallback is allowed.');
  }
}

// One router per MCP connection; there is deliberately no target-session option.
export class AgentDesktopRuntime {
  #options;
  #parent;
  #childRuntime;
  #host;
  #factory;
  #tail = Promise.resolve();
  #state = 'inactive';
  #identity;
  #failure;
  #personStop;
  #fresh = false;
  #closing = false;
  constructor(options = {}) {
    this.#options = options;
    this.#factory = options.runtimeFactory ?? (config => new OpenCURuntime(config));
    this.#parent = this.#newRuntime();
  }
  #latch = cause => {
    if (['USER_STOPPED', 'STOPPED_BY_PERSON'].includes(cause.code)) {
      this.#personStop ??= cause;
      if (this.#state !== 'inactive') { this.#state = 'stopped'; this.#failure = this.#personStop; }
    }
  };
  #newRuntime(extra = {}) {
    return this.#factory({ ...this.#options, onPersonStop: this.#latch, ...extra });
  }
  #hostFailed = cause => {
    this.#latch(cause);
    if (!this.#personStop && !cause.message.includes('App tools are blocked')) {
      cause.message += ' App tools are blocked; call agent_desktop with {"action":"stop"} to finish cleanup before using them again. No input was replayed.';
    }
    this.#failure ??= cause;
    this.#state = this.#personStop ? 'stopped' : 'failed';
  };
  async call(method, args = {}, signal) {
    const run = this.#tail.then(async () => {
      if (this.#closing) throw new Error('OpenCU is closing.');
      if (signal?.aborted) throw new Error('Request cancelled; no operation was retried.');
      if (method === 'agent_desktop') return await this.#control(args);
      // Preserve existing macOS/parent read-after-stop behavior until this
      // connection attempts to switch desktops. Desktop stops block all routes.
      if (this.#state !== 'inactive' && this.#personStop) throw this.#personStop;
      if (this.#failure) throw this.#failure;
      if (this.#fresh && !['list_apps', 'get_app_state'].includes(method)) {
        throw error('OBSERVATION_REQUIRED', 'The desktop changed. Read fresh app state before input.');
      }
      try {
        const result = await (this.#childRuntime ?? this.#parent).call(method, args, signal);
        this.#latch({ code: result._meta?.['opencu/error'], message: result.content?.[0]?.text });
        if (this.#state !== 'inactive' && this.#personStop) throw this.#personStop;
        if (this.#failure) throw this.#failure;
        if (method === 'get_app_state' && !result.isError) this.#fresh = false;
        return result;
      } catch (cause) {
        this.#latch(cause);
        throw this.#failure ?? cause;
      }
    });
    this.#tail = run.catch(() => {});
    return run;
  }
  async #control(args) {
    if (Object.keys(args).some(key => key !== 'action') || !['start', 'stop', 'status'].includes(args.action)) {
      throw error('INVALID_ARGUMENT', 'agent_desktop accepts only action: start, stop or status. No credentials or connection parameters are accepted.');
    }
    if ((this.#options.platform ?? process.platform) !== 'win32') throw error('UNSUPPORTED_ON_MACOS', 'Agent desktop is not available on macOS yet.');
    if (args.action === 'status') {
      const availability = this.#options.availability ?? agentDesktopAvailability;
      return reply({ state: this.#state, ...this.#identity, stoppedByPerson: !!this.#personStop,
        error: this.#failure?.code, availability: await availability(this.#options.root) });
    }
    if (args.action === 'stop') {
      if (this.#state === 'inactive') return reply({ state: 'inactive', stoppedByPerson: !!this.#personStop });
      try { await this.#disposeDesktop(); }
      catch (cause) { this.#hostFailed(cause); throw cause; }
      if (this.#personStop) {
        this.#state = 'stopped'; this.#failure = this.#personStop;
      } else {
        this.#state = 'inactive'; this.#failure = undefined;
        await this.#parent?.close(); this.#parent = this.#newRuntime();
      }
      this.#identity = undefined; this.#fresh = true;
      return reply({ state: this.#state, stoppedByPerson: !!this.#personStop });
    }
    if (this.#personStop) throw this.#personStop;
    if (this.#failure) throw this.#failure;
    if (this.#state === 'running') return reply({ state: 'running', ...this.#identity });
    this.#state = 'starting';
    this.#fresh = true;
    await this.#parent.close();
    if (this.#personStop) { this.#state = 'stopped'; throw this.#personStop; }
    const factory = this.#options.hostFactory ?? (config => new NativeAgentDesktop(config));
    this.#host = factory({ root: this.#options.root, onFailure: this.#hostFailed });
    try {
      const { process: child, ...identity } = await this.#host.start();
      if (this.#failure) throw this.#failure;
      this.#identity = identity;
      this.#childRuntime = this.#newRuntime({ spawnEngine: async () => child, allowRestart: false });
      this.#state = 'running';
      return reply({ state: 'running', ...identity });
    } catch (cause) {
      this.#hostFailed(cause);
      try { await this.#disposeDesktop(); } catch { /* Keep the startup refusal; routing stays failed. */ }
      throw this.#failure;
    }
  }
  async #disposeDesktop() {
    // Host marks intentional close before stdout EOF can be mistaken for a crash.
    try { await this.#host?.close(); }
    finally { await this.#childRuntime?.close(); }
    this.#childRuntime = undefined; this.#host = undefined;
  }
  async close() {
    this.#closing = true;
    await this.#disposeDesktop();
    await this.#parent?.close();
  }
}
