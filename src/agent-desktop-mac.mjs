import { OpenCURuntime } from './opencu-runtime.mjs';

const failure = (code, message, details) => Object.assign(new Error(message), { code, details });
// Agents should stop the desktop when done; this returns windows if they forget.
const IDLE_MS = 5 * 60_000;
const reply = value => ({ content: [{ type: 'text', text: JSON.stringify(value) }] });

// One native owner, including observation/input/preview. No worker replacement in
// desktop mode. Status/stop bypass the ordinary call queue to interrupt consent.
export class MacAgentDesktopRuntime {
  #options;
  #factory;
  #normal;
  #desktop;
  #tail = Promise.resolve();
  #state = 'inactive';
  #personStop;
  #failure;
  #closing = false;
  #stopping;
  #lastStatus;
  #epoch = 0;
  #retiring;
  #fresh = false;
  #idleMs;
  #idleTimer;
  #lastUse = 0;
  #inFlight = 0;
  #idleStopped = false;
  constructor(options = {}) {
    this.#options = options;
    this.#idleMs = options.idleMs ?? IDLE_MS;
    this.#factory = options.runtimeFactory ?? (config => new OpenCURuntime(config));
    this.#normal = this.#runtime(false);
  }
  #latch = cause => {
    if (!['STOPPED_BY_PERSON', 'USER_STOPPED'].includes(cause?.code)) return;
    this.#personStop ??= cause;
    if (this.#state !== 'inactive') this.#state = 'stopped';
  };
  #event = event => {
    if (event.stoppedByPerson) this.#latch(failure('STOPPED_BY_PERSON', 'The person stopped this macOS connection. Never reconnect or restart without explicit permission.'));
    if (event.error && !this.#personStop) this.#failure ??= failure(event.error.code, event.error.message);
    this.#state = this.#personStop ? 'stopped' : event.state;
  };
  #runtime(desktop) {
    return this.#factory({ ...this.#options, platform: 'darwin', allowRestart: !desktop,
      agentDesktop: desktop, onPersonStop: this.#latch,
      ...(desktop ? { onDesktopEvent: this.#event } : {}) });
  }
  async call(method, args = {}, signal) {
    this.#inFlight++;
    try { return await this.#call(method, args, signal); }
    finally { this.#inFlight--; this.#lastUse = Date.now(); }
  }
  async #call(method, args, signal) {
    if (this.#idleStopped) {
      if (method !== 'agent_desktop') throw failure('AGENT_DESKTOP_IDLE_STOPPED', `The agent desktop closed after ${Math.round(this.#idleMs / 60_000)} idle minutes; its windows were returned and its display removed. No input was sent. Call agent_desktop start to use it again, or agent_desktop stop to continue without it.`);
      this.#idleStopped = false;
    }
    if (method === 'agent_desktop') {
      if (Object.keys(args).some(key => key !== 'action') || !['start', 'stop', 'status'].includes(args.action)) {
        throw failure('INVALID_ARGUMENT', 'agent_desktop accepts only action: start, stop or status.');
      }
      if (args.action === 'status') return await this.#status();
      if (args.action === 'stop') return await this.#stop();
    }
    const epoch = this.#epoch;
    const operation = this.#tail.then(async () => {
      if (this.#closing) throw failure('ENGINE_DISCONNECTED', 'OpenCU is closing.');
      if (signal?.aborted || epoch !== this.#epoch) throw failure('OBSERVATION_REQUIRED', 'The request was cancelled or the desktop changed. No operation was replayed.');
      // Preserve ordinary macOS text reads after a stop until desktop was attempted.
      if (this.#personStop && (method === 'agent_desktop' || this.#state !== 'inactive')) throw this.#personStop;
      if (this.#stopping) throw failure('AGENT_DESKTOP_UNAVAILABLE', 'Agent desktop cleanup is in progress. No app operation was sent.');
      if (this.#failure) throw this.#failure;
      if (this.#fresh && !['list_apps', 'get_app_state', 'agent_desktop'].includes(method)) throw failure('OBSERVATION_REQUIRED', 'The desktop changed. Read fresh app state before input.');
      if (method === 'agent_desktop') return await this.#start(signal);
      try {
        const result = await (this.#desktop ?? this.#normal).call(method, args, signal);
        if (this.#personStop && this.#state !== 'inactive') throw this.#personStop;
        if (this.#failure) throw this.#failure;
        if (method === 'get_app_state' && !result.isError) this.#fresh = false;
        return result;
      } catch (cause) {
        this.#latch(cause);
        throw this.#personStop ?? this.#failure ?? cause;
      }
    });
    this.#tail = operation.catch(() => {});
    return operation;
  }
  async #start(signal) {
    if (this.#state === 'running') return await this.#status();
    this.#state = 'starting'; this.#fresh = true;
    this.#retiring = this.#normal.close();
    await this.#retiring;
    if (this.#closing) throw failure('ENGINE_DISCONNECTED', 'OpenCU is closing.');
    if (this.#personStop) throw this.#personStop;
    this.#desktop = this.#runtime(true);
    try {
      const status = await this.#desktop.desktopControl('start', {}, signal);
      this.#lastStatus = status;
      if (this.#personStop) throw this.#personStop;
      if (this.#failure) throw this.#failure;
      this.#state = status.state;
      this.#watchIdle();
      return reply(status);
    } catch (cause) {
      this.#latch(cause);
      this.#failure ??= cause;
      this.#state = this.#personStop ? 'stopped' : 'failed';
      throw this.#personStop ?? this.#failure;
    }
  }
  async #status() {
    if (this.#desktop) {
      try {
        this.#lastStatus = await this.#desktop.desktopControl('status');
        return reply({ ...this.#lastStatus, state: this.#personStop ? 'stopped' : this.#lastStatus.state,
          stoppedByPerson: !!this.#personStop || this.#lastStatus.stoppedByPerson });
      } catch (cause) {
        throw failure(cause.code ?? 'AGENT_DESKTOP_LOST', cause.message, {
          lastStatus: this.#lastStatus, state: this.#state, stoppedByPerson: !!this.#personStop,
        });
      }
    }
    const status = await this.#normal.desktopControl('status');
    return reply({ ...status, state: this.#state, stoppedByPerson: !!this.#personStop });
  }
  #watchIdle() {
    clearInterval(this.#idleTimer);
    this.#idleTimer = setInterval(() => this.#checkIdle().catch(() => {}), Math.min(15_000, this.#idleMs / 4));
    this.#idleTimer.unref?.();
  }
  async #checkIdle() {
    if (this.#state !== 'running') { clearInterval(this.#idleTimer); return; }
    if (this.#inFlight || this.#stopping || this.#personStop || Date.now() - this.#lastUse < this.#idleMs) return;
    // A pending consent or a locked Mac is not idleness; restoring windows waits for unlock.
    const status = await this.#desktop.desktopControl('status');
    if (status.consent || status.parentLocked !== false || this.#inFlight || Date.now() - this.#lastUse < this.#idleMs) return;
    const result = JSON.parse((await this.#stop()).content[0].text);
    if (result.state === 'inactive') this.#idleStopped = true;
  }
  async #stop() {
    clearInterval(this.#idleTimer);
    if (this.#stopping) return await this.#stopping;
    this.#epoch++;
    const operation = async () => {
      // A start may be retiring the normal engine. Let it install its desktop
      // transport, then native stop cancels creation or consent out of band.
      if (!this.#desktop && this.#state === 'starting') await this.#retiring;
      if (!this.#desktop) return reply({ state: this.#state, stoppedByPerson: !!this.#personStop });
      const desktop = this.#desktop;
      const status = await desktop.desktopControl('stop');
      this.#lastStatus = status;
      if (status.stoppedByPerson) this.#latch(failure('STOPPED_BY_PERSON', 'The person stopped this macOS connection.'));
      if (status.cleanup?.ok !== true) {
        this.#failure = failure('AGENT_DESKTOP_CLEANUP_FAILED', 'Window restoration or display removal was not confirmed.', status.cleanup);
        throw this.#failure;
      }
      await this.#tail;
      if (this.#personStop) { this.#state = 'stopped'; return reply({ ...status, state: 'stopped', stoppedByPerson: true }); }
      await desktop.close();
      this.#desktop = undefined;
      this.#normal = this.#runtime(false);
      this.#failure = undefined;
      this.#state = 'inactive'; this.#fresh = true;
      return reply({ ...status, state: 'inactive', stoppedByPerson: false });
    };
    this.#stopping = operation();
    try { return await this.#stopping; } finally { this.#stopping = undefined; }
  }
  async close() {
    if (this.#closing) return;
    this.#closing = true; this.#epoch++;
    clearInterval(this.#idleTimer);
    // EOF is the ownership boundary and interrupts native consent independently
    // of the app-call queue. Native shutdown restores and confirms removal.
    await this.#desktop?.close();
    await this.#normal.close();
  }
}
