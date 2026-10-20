import test from 'node:test';
import assert from 'node:assert/strict';
import { assertDisplayAdded, assertDisplayRemoved } from '../scripts/agent-desktop-acceptance-support.mjs';
const displays = (...ids) => ids.map(id => ({ id }));
test('live acceptance rejects extra, replaced, missing or duplicated displays', () => {
  assertDisplayAdded(displays(1), displays(2, 1), 2);
  assertDisplayRemoved(displays(1), displays(1), 2);
  for (const after of [displays(2), displays(2, 3), displays(1, 2, 3), displays(1, 2, 2)]) {
    assert.throws(() => assertDisplayAdded(displays(1), after, 2));
  }
  for (const after of [displays(), displays(3), displays(1, 2), displays(1, 3)]) {
    assert.throws(() => assertDisplayRemoved(displays(1), after, 2));
  }
});
