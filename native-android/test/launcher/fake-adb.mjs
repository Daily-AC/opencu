#!/usr/bin/env node
// Local stand-in for adb used by the launcher tests. It never contacts a device: "/data/local/tmp/"
// is a directory under FAKE_ADB_ROOT, `shell -T` runs the command with the host's /bin/sh, and
// `stat` and `app_process` are scripted (FAKE_ADB_STAT is what stat prints; app_process exits
// with FAKE_ADB_LAUNCH_EXIT, default 0). `get-state` reports "device", or FAKE_ADB_STATE_AFTER_LAUNCH
// once app_process ran; FAKE_ADB_OFFLINE makes the phone offline for every command.
import { appendFileSync, copyFileSync, mkdirSync, writeFileSync, chmodSync, existsSync } from 'node:fs';
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
const launchedMarker = path.join(root, 'launched');
const offline = () => { console.error('error: device offline'); process.exit(1); };
if (rest[0] === 'get-state') {
  const state = process.env.FAKE_ADB_OFFLINE ? 'offline'
    : existsSync(launchedMarker) && process.env.FAKE_ADB_STATE_AFTER_LAUNCH ? process.env.FAKE_ADB_STATE_AFTER_LAUNCH : 'device';
  if (state === 'device') console.log('device');
  else { console.error(`error: device ${state}`); process.exit(1); }
} else if (process.env.FAKE_ADB_OFFLINE && rest[0] !== 'get-serialno') {
  offline();
} else if (rest[0] === 'get-serialno') {
  if (!process.env.FAKE_ADB_SERIAL) { console.error('error: no devices/emulators found'); process.exit(1); }
  console.log(process.env.FAKE_ADB_SERIAL);
} else if (rest[0] === 'push') {
  copyFileSync(rest[1], local(rest[2]));
} else if (rest[0] === 'shell' && rest[1] === '-T') {
  writeFileSync(path.join(bin, 'stat'), '#!/bin/sh\necho "$FAKE_ADB_STAT"\n');
  writeFileSync(path.join(bin, 'app_process'),
    `#!/bin/sh\ntouch '${launchedMarker}'\necho "{\\"launched\\":\\"$CLASSPATH\\"}"\nexit ${Number(process.env.FAKE_ADB_LAUNCH_EXIT ?? 0)}\n`);
  writeFileSync(path.join(bin, 'getprop'), process.env.FAKE_ADB_GETPROP_ERROR
    ? '#!/bin/sh\nexit 1\n'
    : '#!/bin/sh\ncase "$1" in ro.build.version.sdk) printf "%s\\n" "$FAKE_ADB_SDK";; ro.build.version.release) printf "%s\\n" "$FAKE_ADB_RELEASE";; *) exit 1;; esac\n');
  for (const tool of ['stat', 'app_process', 'getprop']) chmodSync(path.join(bin, tool), 0o755);
  const r = spawnSync('/bin/sh', ['-c', local(rest[2])], {
    stdio: 'inherit',
    env: { ...process.env, PATH: `${bin}:${process.env.PATH}` },
  });
  process.exit(r.status ?? 1);
} else {
  console.error('fake adb: unsupported ' + JSON.stringify(args));
  process.exit(2);
}
