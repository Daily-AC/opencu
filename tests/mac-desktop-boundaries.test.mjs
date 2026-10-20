import assert from 'node:assert/strict';
import { readFile, readdir, access } from 'node:fs/promises';
import test from 'node:test';
const source = name => readFile(new URL(`../native/Sources/OpenCU/${name}.swift`, import.meta.url), 'utf8');

test('desktop admission is checked at action boundaries, not every key pause', async () => {
  const main = await source('Main'), input = await source('InputController'), controller = await source('AgentDesktopController');
  const continuationHook = main.slice(main.indexOf('input.requireInputAllowed ='), main.indexOf('input.requirePointerAllowed ='));
  assert.match(continuationHook, /requireContinuation/);
  assert.doesNotMatch(continuationHook, /requireInput\(/);
  assert.ok(main.indexOf('desktop.requireInput(app, snapshot: snapshot)') < main.indexOf('input.perform(method:'));
  const continuation = controller.slice(controller.indexOf('func requireContinuation()'), controller.indexOf('func stop('));
  assert.doesNotMatch(continuation, /axRect|propose|requireAdmitted|validateLayout|externalReturns/);
  assert.match(input.slice(input.indexOf('private func mouseEvent(')), /requirePointerAllowed/);
});

test('normal workers do not construct desktop UI, and queued cancellation precedes dispatch', async () => {
  const main = await source('Main');
  const init = main.slice(main.indexOf('    init()'), main.indexOf('private func initializeDesktop'));
  assert.doesNotMatch(init, /AgentDesktopController\(|initializeDesktop\(/);
  assert.match(main, /if method == "agent_desktop_start" \{\s*initializeDesktop\(\)/);
  assert.ok(main.indexOf('try requestQueue.begin(requestID)') < main.indexOf('activeRequestID = requestID'));
  assert.match(main, /requestQueue.cancel\(id\)/);
  assert.ok(main.indexOf('let observedGeneration =') < main.indexOf('let state = try await observer.observe'));
  assert.ok(main.indexOf('try desktop.state.requireGeneration(observedGeneration)') < main.indexOf('desktop.observed(state.snapshot'));
});

test('retired consent-free display entry points are absent', async () => {
  const directory = new URL('../native/Sources/OpenCU/', import.meta.url);
  for (const name of await readdir(directory)) {
    if (name.endsWith('.swift')) assert.doesNotMatch(await readFile(new URL(name, directory), 'utf8'), /experimental_agent_display_/);
  }
  await assert.rejects(access(new URL('../scripts/probe-agent-display.mjs', import.meta.url)), { code: 'ENOENT' });
});

test('cleanup status never spawns metadata processes or reads AX on the main actor', async () => {
  const display = await source('AgentDisplay');
  const status = display.slice(display.indexOf('private func status('), display.indexOf('func create()'));
  assert.doesNotMatch(status, /FreshOnlineDisplays|axRect|windowRecords|displays\(\)/);
  assert.match(display, /lastFreshDisplays = freshSnapshot/);
  assert.match(display, /Task\.detached/);
  assert.match(display, /AXUIElementSetMessagingTimeout\(proposal.window, 0.25\)/);
});


test('system confirmations interrupt the current action without scheduling desktop teardown', async () => {
  const main = await source('Main'), controller = await source('AgentDesktopController');
  const hook = main.slice(main.indexOf('desktop.onInputPause ='), main.indexOf('func enqueue('));
  assert.match(hook, /activeTask\?\.cancel/);
  assert.ok(hook.indexOf('activeInterruption =') < hook.indexOf('activeTask?.cancel'));
  assert.doesNotMatch(hook, /scheduleDesktopCleanup|desktop\.stop\(/);
  assert.match(controller, /where !AgentDesktopAdmissionPolicy\.tearsDownDesktop\(error.code\)/);
  assert.match(main, /error is CancellationError, let pause = activeInterruption \{ throw pause \}/);
  assert.match(controller, /capture.onPersonStop =/);
});


test('same-process inheritance does not depend on the parent window being visible', async () => {
  const display = await source('AgentDisplay');
  const processAdmission = display.slice(display.indexOf('func hasAdmittedProcess('), display.indexOf('func admitWithoutMoving('));
  assert.doesNotMatch(processAdmission, /contains\(target\)|record.onScreen/);
  assert.match(processAdmission, /target.app.application == app.application/);
  assert.match(processAdmission, /agentFrame.contains\(frame\)/);
});
