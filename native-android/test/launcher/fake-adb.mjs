#!/usr/bin/env node
// Local stand-in for adb used by the launcher tests. It never contacts a device: "/data/local/tmp/"
// is a directory under FAKE_ADB_ROOT, `shell -T` runs the command with the host's /bin/sh, and
// `stat` and `app_process` are scripted (FAKE_ADB_STAT is what stat prints).
import { appendFileSync, copyFileSync, mkdirSync, writeFileSync, chmodSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import path from 'node:path';
const root = process.env.FAKE_ADB_ROOT;
const args = process.argv.slice(2);
appendFileSync(path.join(root, 'calls.jsonl'), JSON.stringify(args) + '\n');
const rest = args[0] === '-s' ? args.slice(2) : args;
const tmp = path.join(root, 'data-local-tmp');
const bin = path.join(root, 'bin');
mkdirSync(tmp, { recursive: true });
mkdirSync(bin, { recursive: true });
const local = text => text.replaceAll('/data/local/tmp/', tmp + '/');
if (rest[0] === 'get-serialno') {
  if (!process.env.FAKE_ADB_SERIAL) { console.error('error: no devices/emulators found'); process.exit(1); }
  console.log(process.env.FAKE_ADB_SERIAL);
} else if (rest[0] === 'push') {
  copyFileSync(rest[1], local(rest[2]));
} else if (rest[0] === 'shell' && rest[1] === '-T') {
  writeFileSync(path.join(bin, 'stat'), '#!/bin/sh\necho "$FAKE_ADB_STAT"\n');
  writeFileSync(path.join(bin, 'app_process'), '#!/bin/sh\necho "{\\"launched\\":\\"$CLASSPATH\\"}"\n');
  for (const tool of ['stat', 'app_process']) chmodSync(path.join(bin, tool), 0o755);
  const r = spawnSync('/bin/sh', ['-c', local(rest[2])], {
    stdio: 'inherit',
    env: { ...process.env, PATH: `${bin}:${process.env.PATH}` },
  });
  process.exit(r.status ?? 1);
} else {
  console.error('fake adb: unsupported ' + JSON.stringify(args));
  process.exit(2);
}
