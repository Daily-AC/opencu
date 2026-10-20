#!/usr/bin/env node
import { spawn } from 'node:child_process';
import { access } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { agentDesktopAvailability } from '../src/agent-desktop.mjs';
const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const command = process.argv[2] ?? 'mcp';
if (['help', '--help', '-h'].includes(command)) {
  console.log('Usage: opencu.cmd [mcp|doctor|setup agent-desktop]\n  mcp     Run the MCP server on stdin/stdout (default).\n  doctor  Report engine, desktop and agent-desktop availability.\n  setup agent-desktop  Enable child sessions with an explicit UAC prompt; prepare the user-only helper offline.');
} else {
  if (process.platform !== 'win32') throw new Error('This launcher requires Windows. Use bin/opencu on macOS.');
  if (!['mcp', 'doctor', 'setup'].includes(command)) throw new Error(`Unknown command: ${command}`);
  if (command === 'setup' && (process.argv[3] !== 'agent-desktop' || process.argv.length !== 4)) throw new Error('Usage: opencu setup agent-desktop');
  const engine = path.join(root, '.build/win/opencu-engine.exe');
  try { await access(engine); } catch { throw new Error('Windows engine is missing. Run npm run build:win or copy the cross-compiled executable to .build/win/opencu-engine.exe.'); }
  const child = command === 'setup'
    ? spawn(path.join(process.env.WINDIR, 'System32/WindowsPowerShell/v1.0/powershell.exe'), ['-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', path.join(root, 'scripts/agent-desktop/setup.ps1'), '-Root', root], { stdio: 'inherit', windowsHide: true })
    : command === 'doctor'
      ? spawn(engine, ['--doctor'], { stdio: ['ignore', 'pipe', 'inherit'], windowsHide: true })
      : spawn(process.execPath, [path.join(root, 'src/server.mjs')], { stdio: 'inherit', windowsHide: true });
  if (command === 'doctor') {
    let output = '';
    child.stdout.on('data', chunk => { output += chunk; });
    child.once('close', async code => {
      if (code !== 0) return;
      try { console.log(JSON.stringify({ ...JSON.parse(output), agentDesktop: await agentDesktopAvailability(root) })); }
      catch (error) { console.error(error.message); process.exitCode = 1; }
    });
  }
  child.once('error', error => { console.error(error.message); process.exitCode = 1; });
  child.once('exit', code => { process.exitCode = code ?? 1; });
}
