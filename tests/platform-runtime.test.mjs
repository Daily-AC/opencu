import assert from 'node:assert/strict';
import path from 'node:path';
import test from 'node:test';
import { defaultEnginePath, toolError } from '../src/opencu-runtime.mjs';

test('platform choice retains macOS path and selects the standalone Windows executable', () => {
  assert.equal(defaultEnginePath('/checkout', 'darwin'), path.join('/checkout', '.build/OpenCU.app/Contents/MacOS/opencu-engine'));
  assert.equal(defaultEnginePath('/checkout', 'win32'), path.join('/checkout', '.build/win/opencu-engine.exe'));
  assert.equal(defaultEnginePath('/checkout', 'linux'), path.join('/checkout', '.build/linux/opencu-engine'));
});
test('stable native safety codes survive the MCP error envelope', () => {
  for (const code of ['PERSON_ACTIVE', 'ELEVATED_TARGET', 'SCREEN_LOCKED', 'STALE_SCREENSHOT', 'SAFETY_MONITOR_UNAVAILABLE']) {
    const result = toolError(Object.assign(new Error('fixture refusal'), { code }));
    assert.equal(result.isError, true);
    assert.equal(result._meta['opencu/error'], code);
  }
});
