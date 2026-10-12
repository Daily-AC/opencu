import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import test from 'node:test';
import { CoordinateState, imageSize } from '../src/coordinate-state.mjs';

const fixture = JSON.parse(await readFile(new URL('./fixtures/preview-window-response.json', import.meta.url), 'utf8'));
const app = 'com.apple.Preview';
const drag = { app, from_x: 100, from_y: 200, to_x: 400, to_y: 800 };
const observe = (guard, args = { app }, result = structuredClone(fixture.result)) => {
  guard.before('get_app_state', args);
  return guard.after('get_app_state', args, result);
};

test('a window screenshot defines bounds and an action expires its coordinates', () => {
  const guard = new CoordinateState();
  const state = observe(guard);
  assert.match(state.content.at(-1).text, /708 x 1054.*preview-coordinate-grid/);
  guard.before('drag', drag);
  assert.throws(() => guard.before('drag', drag), /fresh screenshot.*UI action.*No coordinate action was sent/);
  observe(guard);
  assert.doesNotThrow(() => guard.before('drag', drag));
});

test('closing an observed Inspector cannot reuse its screenshot through another app alias', () => {
  const guard = new CoordinateState();
  const inspector = structuredClone(fixture.inspector_result);
  inspector._meta = { 'opencu/app': { id: app } };
  observe(guard, { app: 'Preview' }, inspector);
  guard.before('click', { app, element_index: 6 });
  assert.throws(() => guard.before('drag', { ...drag, app: 'Preview' }), /fresh screenshot/);
});

test('negative, edge and out-of-range endpoints are rejected without consuming the screenshot', () => {
  const guard = new CoordinateState();
  observe(guard);
  for (const point of [{ from_x: -1 }, { from_x: 708 }, { to_x: 800 }, { to_y: 1054 }, { from_y: NaN }]) {
    assert.throws(() => guard.before('drag', { ...drag, ...point }), /outside the last screenshot \(708 x 1054 pixels.*No input was sent/);
  }
  assert.doesNotThrow(() => guard.before('drag', { ...drag, to_x: 707, to_y: 1053 }));
});

test('a coordinate action can supply the next fresh image, but a failed final capture cannot', () => {
  const guard = new CoordinateState();
  observe(guard);
  guard.before('drag', drag);
  guard.after('drag', drag, structuredClone(fixture.result));
  assert.doesNotThrow(() => guard.before('drag', drag));
  guard.after('drag', drag, { ...structuredClone(fixture.result), isError: true });
  assert.throws(() => guard.before('drag', drag), /fresh screenshot/);
});

test('a later coordinate action rejects the entire batch before consuming any state', () => {
  const guard = new CoordinateState();
  observe(guard);
  assert.throws(() => guard.before('run_actions', { app, actions: [
    { method: 'click', element_index: 6 }, { method: 'drag', ...drag },
  ] }), /Action 2 uses coordinates.*No actions were sent/);
  assert.doesNotThrow(() => guard.before('run_actions', { app, actions: [
    { method: 'click', x: 100, y: 200 }, { method: 'press_key', key: 'Escape' },
  ] }));
});

test('text-only reads, failed reads and separate connections cannot inherit an old screenshot', () => {
  for (const result of [
    { content: [{ type: 'text', text: 'Window: "General Info", App: Preview.' }] },
    { ...structuredClone(fixture.result), isError: true },
  ]) {
    const guard = new CoordinateState();
    observe(guard);
    observe(guard, { app }, result);
    assert.throws(() => guard.before('drag', drag), /fresh screenshot/);
  }
  observe(new CoordinateState());
  assert.throws(() => new CoordinateState().before('drag', drag), /No screenshot has been returned in this connection/);
});

test('a screenshot stays usable across app inventory reads but not another app or a failed mutation', () => {
  const guard = new CoordinateState();
  observe(guard);
  guard.before('list_apps', {});
  assert.throws(() => guard.before('drag', { ...drag, app: 'com.apple.finder' }), /different app identifier/);
  guard.before('press_key', { app, key: 'Escape' });
  guard.after('press_key', { app }, { isError: true });
  assert.throws(() => guard.before('drag', drag), /fresh screenshot/);
});

test('image sizes come from the PNG header and other or malformed headers fail closed', () => {
  const png = Buffer.from(fixture.result.content[1].data, 'base64');
  assert.deepEqual(imageSize(png), { width: 708, height: 1054 });
  const zeroWidth = Buffer.from('89504e470d0a1a0a0000000d494844520000000000000593', 'hex');
  const jpeg = Buffer.from('ffd8ffc0001108041e02c40301220002110103110100000000', 'hex');
  for (const bytes of [Buffer.alloc(0), png.subarray(0, 23), zeroWidth, jpeg]) {
    assert.equal(imageSize(bytes), undefined);
  }
});
