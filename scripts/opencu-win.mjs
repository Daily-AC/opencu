#!/usr/bin/env node
import { spawn } from 'node:child_process';
import { access } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const command = process.argv[2] ?? 'mcp';
if (['help', '--help', '-h'].includes(command)) {
  console.log('Usage: opencu.cmd [mcp|doctor]\n  mcp     Run the MCP server on stdin/stdout (default).\n  doctor  Report the Windows engine and interactive desktop status.');
} else {
  if (process.platform !== 'win32') throw new Error('This launcher requires Windows. Use bin/opencu on macOS.');
  if (!['mcp', 'doctor'].includes(command)) throw new Error(`Unknown command: ${command}`);
  const engine = path.join(root, '.build/win/opencu-engine.exe');
  try { await access(engine); } catch { throw new Error('Windows engine is missing. Run npm run build:win or copy the cross-compiled executable to .build/win/opencu-engine.exe.'); }
  const child = command === 'doctor'
    ? spawn(engine, ['--doctor'], { stdio: 'inherit', windowsHide: true })
    : spawn(process.execPath, [path.join(root, 'src/server.mjs')], { stdio: 'inherit', windowsHide: true });
  child.once('error', error => { console.error(error.message); process.exitCode = 1; });
  child.once('exit', code => { process.exitCode = code ?? 1; });
}
