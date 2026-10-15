import assert from 'node:assert/strict';
import test from 'node:test';
import { applicationSerialNumbers, applicationPID, windowMovementWarnings } from '../scripts/agent-display-probe-support.mjs';

test('fixture discovery accepts the named ASN returned by live lsappinfo find', () => {
  // Observed during the authorized fixture-only launch on 2026-10-15.
  const output = 'ASN:0x0-0x250c80a3-"OpenCU_Launch_Diagnosis":\n';
  assert.deepEqual(applicationSerialNumbers(output), ['ASN:0x0-0x250c80a3:']);
  assert.deepEqual(applicationSerialNumbers('ASN:0x0-0x250c80a3:\n'), ['ASN:0x0-0x250c80a3:']);
  assert.deepEqual(applicationSerialNumbers('ASN:0x0:0x250c80a3:\n'), ['ASN:0x0:0x250c80a3:']);
  assert.equal(applicationPID('"pid"=70840\n'), 70840);
  assert.equal(applicationPID('    pid = 70840 type="Foreground"\n'), 70840);
});

test('unknown discovery output cannot masquerade as an absent fixture during cleanup', () => {
  assert.deepEqual(applicationSerialNumbers('\n'), []);
  assert.throws(() => applicationSerialNumbers('LaunchServices unavailable'), /Unrecognized/);
  assert.throws(() => applicationPID('"pid"=0'), /Could not resolve/);
  assert.throws(() => applicationPID(''), /Could not resolve/);
  assert.equal(applicationSerialNumbers('ASN:0x0-0x1-"One":\nASN:0x0-0x2-"Two":').length, 2);
});

test('other-app movement is owner-attributed evidence, not a failed display-layout assertion', () => {
  const before = { windowFrames: [{ id: 140, pid: 1066, ownerName: 'Fixture Other App',
    frame: { x: 16, y: 350, width: 77, height: 104 } }] };
  const after = { windowFrames: [{ ...before.windowFrames[0],
    frame: { x: -118, y: 458, width: 102, height: 114 } }] };
  const [warning] = windowMovementWarnings(before, after);
  assert.equal(warning.ownerName, 'Fixture Other App');
  assert.equal(warning.windowID, 140);
  assert.equal(warning.pid, 1066);
  assert.deepEqual(warning.before, before.windowFrames[0].frame);
  assert.deepEqual(warning.after, after.windowFrames[0].frame);
  assert.match(warning.reason, /cannot be attributed/);
  assert.deepEqual(windowMovementWarnings(before, after, [1066]), []);
  assert.deepEqual(windowMovementWarnings(before, before), []);
  assert.deepEqual(windowMovementWarnings(before, { windowFrames: [] }), []);
  assert.deepEqual(windowMovementWarnings(before, { windowFrames: [{ ...after.windowFrames[0], pid: 999 }] }), []);
});
