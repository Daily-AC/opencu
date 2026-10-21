import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import test from 'node:test';
const read = path => readFile(new URL(`../${path}`, import.meta.url), 'utf8');

// Check the actual UI call sites as well as the Swift preference/Bundle tests.
test('all literal presence and desktop UI keys exist in both bundle tables', async () => {
  const quoted = '"(?:[^"\\\\]|\\\\.)*"';
  const tables = await Promise.all(['en', 'zh-Hans'].map(async language => {
    const raw = await read(`native/Resources/${language}.lproj/Presence.strings`);
    const entries = [...raw.matchAll(new RegExp(`(${quoted})\\s*=\\s*(${quoted})\\s*;`, 'g'))]
      .map(match => [JSON.parse(match[1]), JSON.parse(match[2])]);
    assert.equal(new Set(entries.map(([key]) => key)).size, entries.length, `Duplicate ${language} keys`);
    return new Map(entries);
  }));
  assert.deepEqual([...tables[0].keys()].sort(), [...tables[1].keys()].sort());
  for (const name of ['AgentDesktopWindow', 'PresenceController', 'PermissionSetup', 'AgentDisplaySPI']) {
    const source = await read(`native/Sources/OpenCU/${name}.swift`);
    for (const match of source.matchAll(new RegExp(`\\.(?:text|format)\\((${quoted})`, 'g'))) {
      const key = JSON.parse(match[1]);
      for (const table of tables) assert.ok(table.has(key), `${name}: missing ${key}`);
    }
  }
  const window = await read('native/Sources/OpenCU/AgentDesktopWindow.swift');
  assert.doesNotMatch(window, /NSButton\(title: "|NSTextField\((?:wrappingLabelWithString|labelWithString): "|panel\.title = "/);
  assert.match(window, /func status\(_ status: AgentDesktopStatusText\)/);
  const controller = await read('native/Sources/OpenCU/AgentDesktopController.swift');
  assert.doesNotMatch(controller, /window\.status\("/);
  assert.match(controller, /self\.window\.status\(error\.code == "SCREEN_LOCKED" \? \.locked : \.confirmation\)/);
});

test('owner acceptance prompts identify both labels and positions without changing protocol assertions', async () => {
  const script = await read('scripts/verify-agent-desktop-mac.mjs');
  assert.match(script, /first button \(Move once \/ 挪过来一次\)/);
  assert.match(script, /second button \(Keep here \/ 留在原处\)/);
  assert.match(script, /Stop \/ 停止/);
  assert.match(script, /OpenCU agent desktop \/ OpenCU agent 桌面/);
  assert.match(script, /'STOPPED_BY_PERSON'/);
});
