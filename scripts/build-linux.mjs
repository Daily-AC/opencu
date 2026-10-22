#!/usr/bin/env node
// Build the static Linux engine. On a non-Linux host this cross-compiles with
// cargo-zigbuild. OPENCU_LINUX_TARGET selects another musl target, for example
// aarch64-unknown-linux-musl for a local arm64 test container.
import { spawnSync } from 'node:child_process';
import { mkdir, copyFile, readFile, readdir, writeFile } from 'node:fs/promises';
import { createHash } from 'node:crypto';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const target = process.env.OPENCU_LINUX_TARGET ?? 'x86_64-unknown-linux-musl';
const cross = process.platform !== 'linux';
const result = spawnSync('cargo', [cross ? 'zigbuild' : 'build', '--locked', '--release', '--target', target], {
  cwd: path.join(root, 'native-linux'), stdio: 'inherit',
});
if (result.error) throw result.error;
if (result.status !== 0) process.exit(result.status ?? 1);
await mkdir(path.join(root, '.build/linux'), { recursive: true });
await copyFile(path.join(root, 'native-linux/target', target, 'release/opencu-engine'), path.join(root, '.build/linux/opencu-engine'));
const rust = async dir => (await readdir(path.join(root, dir), { recursive: true }))
  .filter(name => name.endsWith('.rs')).map(name => `${dir}/${name}`);
const sources = ['native-linux/Cargo.toml', 'native-linux/Cargo.lock', 'native-win/Cargo.toml', 'scripts/build-linux.mjs',
  ...await rust('native-linux/src'), 'native-win/src/lib.rs', 'native-win/src/observation.rs',
  'native-win/src/foreground.rs', 'native-win/src/locked_patterns.rs'];
const hash = async name => createHash('sha256').update(await readFile(path.join(root, name))).digest('hex');
const sourceFiles = {};
for (const name of sources.sort()) sourceFiles[name] = await hash(name);
await writeFile(path.join(root, '.build/linux/engine-manifest.json'), JSON.stringify({
  version: JSON.parse(await readFile(path.join(root, 'package.json'), 'utf8')).version, target,
  executable_sha256: await hash('.build/linux/opencu-engine'), source_files: sourceFiles,
}, null, 2) + '\n');
console.log(`Built .build/linux/opencu-engine (${target})`);
