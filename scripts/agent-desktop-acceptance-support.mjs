import assert from 'node:assert/strict';
const ids = displays => displays.map(display => display.id).sort((a, b) => a - b);
export function assertDisplayAdded(before, after, id) {
  assert.ok(!before.some(display => display.id === id), 'Agent display already existed');
  assert.deepEqual(ids(after), [...ids(before), id].sort((a, b) => a - b), 'Exactly the owned display must be added; no physical display may disappear or be replaced');
}
export function assertDisplayRemoved(baseline, after, id) {
  assert.ok(!after.some(display => display.id === id), 'Owned display still exists');
  assert.deepEqual(ids(after), ids(baseline), 'Only the owned display may be removed; the complete baseline must remain');
}
