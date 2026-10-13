import assert from 'node:assert/strict';
import test from 'node:test';
import { normalizeArguments } from '../src/tool-arguments.mjs';

test('placeholder coordinates and modifier are dropped from an indexed click', () => {
  const args = normalizeArguments('click', { app: 'A', element_index: 20, x: 0, y: 0, key: 'NONE', duration: 0, mouse_button: 'left' });
  assert.deepEqual(args, { app: 'A', element_index: 20, duration: 0, mouse_button: 'left' });
});

test('real coordinates with an element index are still refused with guidance', () => {
  assert.throws(() => normalizeArguments('click', { app: 'A', element_index: 3, x: 10, y: 0 }), /omit x and y.*No actions were sent/);
});

test('a coordinate click at the origin is kept when no element index is given', () => {
  assert.deepEqual(normalizeArguments('click', { app: 'A', x: 0, y: 0 }), { app: 'A', x: 0, y: 0 });
});

test('a real modifier chord is kept', () => {
  assert.equal(normalizeArguments('click', { app: 'A', element_index: 1, key: 'shift' }).key, 'shift');
});

test('batched actions are normalized and checked one by one', () => {
  const args = normalizeArguments('run_actions', { app: 'A', actions: [{ method: 'scroll', element_index: 2, x: 0, y: 0, scrollY: 3 }, { method: 'press_key', key: 'NONE' }] });
  assert.deepEqual(args.actions, [{ method: 'scroll', element_index: 2, scrollY: 3 }, { method: 'press_key', key: 'NONE' }]);
  assert.throws(() => normalizeArguments('run_actions', { app: 'A', actions: [{ method: 'click' }] }), /Provide element_index or both x and y/);
});
