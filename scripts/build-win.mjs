#!/usr/bin/env node
import { spawnSync } from 'node:child_process';
import { mkdir, copyFile } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const target = 'x86_64-pc-windows-gnu';
const env = { ...process.env };
// Same command works on the Mac cross toolchain and native Windows with MinGW.
env.CARGO_TARGET_X86_64_PC_WINDOWS_GNU_LINKER ??= 'x86_64-w64-mingw32-gcc';
const result = spawnSync('cargo', ['build', '--locked', '--release', '--target', target], {
  cwd: path.join(root, 'native-win'), env, stdio: 'inherit', windowsHide: true,
});
if (result.error) throw result.error;
if (result.status !== 0) process.exit(result.status ?? 1);
await mkdir(path.join(root, '.build/win'), { recursive: true });
await copyFile(path.join(root, 'native-win/target', target, 'release/opencu-engine.exe'), path.join(root, '.build/win/opencu-engine.exe'));
console.log('Built .build/win/opencu-engine.exe');
