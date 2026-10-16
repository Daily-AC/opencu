import assert from 'node:assert/strict';
import { readFile, readdir } from 'node:fs/promises';
import path from 'node:path';
import test from 'node:test';

const root = new URL('../', import.meta.url);

test('the only macOS pixel-capture chain is guarded before SCK enumeration and capture', async () => {
  const directory = new URL('native/Sources/OpenCU/', root);
  const sources = await Promise.all((await readdir(directory)).filter(name => name.endsWith('.swift')).map(async name =>
    [name, await readFile(new URL(name, directory), 'utf8')]));
  const captureFiles = sources.filter(([, source]) => /SCShareableContent\.|SCScreenshotManager\.|SCStream\(/.test(source));
  assert.deepEqual(captureFiles.map(([name]) => name), ['MacObserver.swift']);
  for (const [name, source] of sources) {
    assert.doesNotMatch(source, /CGWindowListCreateImage|CGDisplayCreateImage|CGDisplayStream|\/usr\/sbin\/screencapture/, name);
  }
  const observer = captureFiles[0][1];
  const body = observer.slice(observer.indexOf('private func capture('), observer.indexOf('private func windowPresentation('));
  const firstGuard = body.indexOf('try EngineResponsibility.requireCapture()');
  const enumeration = body.indexOf('SCShareableContent.excludingDesktopWindows');
  const secondGuard = body.indexOf('try EngineResponsibility.requireCapture()', firstGuard + 1);
  const capture = body.indexOf('SCScreenshotManager.captureImage');
  assert.ok(firstGuard >= 0 && firstGuard < enumeration && enumeration < secondGuard && secondGuard < capture);
  assert.doesNotMatch(body, /CGRequestScreenCaptureAccess|SCContentSharingPicker/);
  // The Node transport must only request/forward images from the native engine.
  for (const name of await readdir(new URL('src/', root))) {
    if (!name.endsWith('.mjs')) continue;
    const source = await readFile(new URL(path.join('src', name), root), 'utf8');
    assert.doesNotMatch(source, /screencapture|CGWindowListCreateImage|CGDisplayCreateImage|SCScreenshotManager|ScreenCaptureKit/, name);
  }
});
