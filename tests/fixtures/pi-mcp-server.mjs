import { appendFileSync, readFileSync } from 'node:fs';
import { Server } from '@modelcontextprotocol/sdk/server/index.js';
import { StdioServerTransport } from '@modelcontextprotocol/sdk/server/stdio.js';
import { CallToolRequestSchema, ListToolsRequestSchema } from '@modelcontextprotocol/sdk/types.js';

const config = JSON.parse(readFileSync(process.argv[2], 'utf8'));
const log = event => appendFileSync(config.log, JSON.stringify(event) + '\n');
log({ event: 'start', pid: process.pid, args: process.argv.slice(3) });
process.stderr.write('fixture diagnostics must not reach pi stdout\n');
const server = new Server({ name: 'pi-fixture', version: '1' }, {
  capabilities: { tools: {} }, instructions: config.instructions,
});
server.setRequestHandler(ListToolsRequestSchema, async request => {
  log({ event: 'list', params: request.params });
  const index = Number(request.params?.cursor ?? 0);
  return {
    tools: config.tools.slice(index, index + 1),
    ...(index + 1 < config.tools.length ? { nextCursor: String(index + 1) } : {}),
  };
});
server.setRequestHandler(CallToolRequestSchema, async request => {
  log({ event: 'call', ...request.params });
  if (request.params.arguments?.disconnect) process.exit(0);
  return config.results.shift() ?? { content: [{ type: 'text', text: 'fixture result' }] };
});
process.stdin.once('end', () => {
  log({ event: 'end' });
  process.exit(0);
});
await server.connect(new StdioServerTransport());
