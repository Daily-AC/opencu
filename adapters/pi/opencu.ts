import type { ExtensionAPI, ToolDefinition } from '@earendil-works/pi-coding-agent';
import { Client } from '@modelcontextprotocol/sdk/client/index.js';
import { StdioClientTransport } from '@modelcontextprotocol/sdk/client/stdio.js';
import type { ImageContent, TextContent } from '@modelcontextprotocol/sdk/types.js';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

export function serverCommand(env = process.env, extensionURL = import.meta.url) {
  if (env.OPENCU_ARGS !== undefined && !env.OPENCU_COMMAND) {
    throw new Error('OPENCU_ARGS requires OPENCU_COMMAND.');
  }
  const args = env.OPENCU_ARGS === undefined ? [] : JSON.parse(env.OPENCU_ARGS);
  if (!Array.isArray(args) || args.some(arg => typeof arg !== 'string')) {
    throw new Error('OPENCU_ARGS must be a JSON array of strings.');
  }
  return env.OPENCU_COMMAND
    ? { command: env.OPENCU_COMMAND, args }
    : {
        command: process.execPath,
        args: [path.resolve(path.dirname(fileURLToPath(extensionURL)), '../../src/server.mjs')],
      };
}

export default function opencu(pi: ExtensionAPI) {
  let client: Client | undefined;
  let ready: Promise<void> | undefined;
  let shutdown: Promise<void> | undefined;
  let closing = false;
  let failure: Error | undefined;
  let instructions = '';
  let tail = Promise.resolve();
  // Pi marks thrown errors correctly but otherwise replaces their content with text.
  const errors = new Map<string, { content: (TextContent | ImageContent)[]; details: unknown }>();

  function active() {
    if (failure) throw failure;
    if (closing) throw new Error('OpenCU connection is closed; no operation was sent.');
  }

  function connect() {
    active();
    ready ??= (async () => {
      const transport = new StdioClientTransport({ ...serverCommand(), stderr: 'pipe' });
      transport.stderr?.resume(); // Drain diagnostics without writing to pi's protocol/UI.
      client = new Client({ name: 'opencu-pi', version: '0.2.0' });
      client.onclose = () => {
        if (!closing) failure ??= new Error('OpenCU disconnected. No operation was retried; automatic reconnection is disabled.');
      };
      await client.connect(transport);
      instructions = client.getInstructions() ?? '';
      let cursor: string | undefined;
      do {
        const page = await client.listTools(cursor ? { cursor } : {});
        active();
        for (const tool of page.tools) {
          pi.registerTool({
            name: tool.name,
            label: tool.name,
            description: tool.description ?? '',
            // Pi validates JSON schemas directly; no schema conversion is needed.
            parameters: tool.inputSchema as ToolDefinition['parameters'],
            executionMode: 'sequential',
            execute(toolCallId, params, signal) {
              const run = tail.then(async () => {
                await connect();
                active();
                const result = await client!.callTool(
                  { name: tool.name, arguments: params }, undefined,
                  // run_actions can contain sixteen 30-second holds plus observation.
                  { signal, timeout: 600_000 },
                );
                const content = result.content.filter(block => block.type === 'text' || block.type === 'image');
                const details = { _meta: result._meta };
                if (result.isError) {
                  const text = content.filter(block => block.type === 'text').map(block => block.text).join('\n');
                  const error = new Error(text || 'OpenCU tool failed.');
                  if (result._meta?.['opencu/error'] === 'USER_STOPPED' || /\bUSER_STOPPED\b/.test(text)) {
                    // Latch the human stop before any queued call can run.
                    failure = error;
                  }
                  errors.set(toolCallId, { content, details });
                  throw error;
                }
                return { content, details };
              });
              tail = run.then(() => {}, () => {});
              return run;
            },
          });
        }
        cursor = page.nextCursor;
      } while (cursor);
    })().catch(async error => {
      failure ??= error instanceof Error ? error : new Error(String(error));
      await client?.close();
      throw failure;
    });
    return ready;
  }

  pi.on('session_start', async () => { await connect(); });
  pi.on('before_agent_start', async event => {
    await (ready ?? connect());
    return instructions ? { systemPrompt: `${event.systemPrompt}\n\n${instructions}` } : undefined;
  });
  pi.on('tool_result', event => {
    const original = errors.get(event.toolCallId);
    if (!original) return;
    errors.delete(event.toolCallId);
    return { ...original, isError: true };
  });
  pi.on('session_shutdown', () => {
    closing = true;
    shutdown ??= (async () => {
      await ready?.catch(() => {});
      await client?.close();
      errors.clear();
    })();
    return shutdown;
  });
}
