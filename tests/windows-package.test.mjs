import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import test from 'node:test';

test('Windows release packaging, manifest and installer offline checks', () => {
  const result = spawnSync('python3', [fileURLToPath(new URL('./windows-package.py', import.meta.url))], { encoding: 'utf8' });
  assert.equal(result.status, 0, result.error?.message ?? result.stdout + result.stderr);
});
