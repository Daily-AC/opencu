#!/usr/bin/env node
import { McpServer } from '@modelcontextprotocol/sdk/server/mcp.js';
import { StdioServerTransport } from '@modelcontextprotocol/sdk/server/stdio.js';
import { z } from 'zod';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { OpenCURuntime, toolError } from './opencu-runtime.mjs';
import { normalizeArguments } from './tool-arguments.mjs';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const server = new McpServer(
  { name: 'opencu', version: '0.2.0' },
  { instructions: 'Control desktop applications with the independent OpenCU engine. Read get_app_state before input. Use observed element indexes; request screenshots before coordinate input. Actions return updated state, and run_actions executes a short known sequence before one final read. Use paste for Unicode or multiline text. Verify the actual result before reporting success. Activate an app only when foreground focus is needed. Do not operate the same app concurrently from different sessions. Respect user authorization and your host approval rules. Input is never automatically replayed. On STOPPED_BY_PERSON the person stopped this macOS connection: never reconnect or retry on your own; wait for explicit permission. Text-only state may continue. On macOS, input normally runs in the background. On Windows, every input requires foreground focus; stop on PERSON_ACTIVE and never retry it. Windows phase 1 supports plain-text paste, but not drag or select_text. OpenCU runs locally, respects OS permissions, and requires no account or particular agent identity.' },
);
const runtime = new OpenCURuntime({ root });

const app = z.string().min(1).describe('App name or full app path; macOS bundle ID; Windows process name, window title fragment, or Start-menu shortcut name');
const element_index = z.number().int().describe('Element index from the latest returned app state');
const duration = z.number().finite().min(0).max(30).optional().describe('Seconds to hold before releasing, from 0 to 30.');
const stateOptions = {
  disableDiff: z.boolean().optional(),
  includeScreenshot: z.boolean().optional().describe('Default false. Use true for visual content or coordinate input; omit for indexed controls, menus, dialogs and text editing.'),
  waitForText: z.string().min(1).optional().describe('Wait for exact, case-sensitive text without UI actions. Use only a known expected label during a real load; omit on ordinary reads.'),
  waitTimeoutMs: z.number().int().min(0).max(15000).optional().describe('Polling deadline for waitForText; defaults to 5000 ms. Native call timeouts remain separate.'),
};
const point = {
  element_index: element_index.optional(),
  x: z.number().finite().optional().describe('X pixel coordinate in the most recently returned app-window screenshot; requires a screenshot after the last UI action.'),
  y: z.number().finite().optional().describe('Y pixel coordinate in that same app-window screenshot.'),
};
const definitions = {
  get_app_state: {
    description: 'Start here: read the requested app by name or platform-specific identifier; it launches if needed. Text normally suffices for menus, dialogs, indexed controls and text editing. Request an image for visual content or coordinates. For separately saved edits, create and verify the destination copy before editing because apps may autosave the source. Verify the saved result and any required source preservation before reporting completion; an action success only confirms input was sent.',
    schema: { app, ...stateOptions }, readOnly: true,
  },
  click: {
    description: 'Click an observed control, including buttons and checkboxes, or a fresh screenshot coordinate. Returns updated state: indexed clicks return text; coordinate clicks also return a new screenshot for the next action. On macOS, clicking a menu bar item or submenu lists its items without displaying a menu; clicking a listed menu item runs its command.',
    schema: { app, ...point, mouse_button: z.enum(['left', 'right', 'middle', 'l', 'r', 'm']).optional(), click_count: z.number().int().min(1).max(3).optional(), key: z.string().trim().min(1).optional().describe('Modifier chord held during the click, such as Shift or super.'), duration },
  },
  drag: {
    description: 'Not yet supported on Windows. Drag inside the fresh app-window screenshot and return a new screenshot and state. To crop a side while preserving height: zoom out for margins, Select All, then move only the middle left/right selection handle horizontally. Keep the existing top/bottom selection edges; verify dimensions in Inspector. Window borders resize the window.',
    schema: { app, from_x: z.number().finite(), from_y: z.number().finite(), to_x: z.number().finite(), to_y: z.number().finite() },
  },
  paste: {
    description: 'Paste text, Markdown, or HTML into the focused field (Windows: plain text only). Prefer this for Unicode or multiline text. Verify focus and the resulting value. Restores the previous clipboard unless another app changed it during the operation.',
    schema: { app, text: z.string(), format: z.enum(['text', 'md', 'html']) },
  },
  press_key: {
    description: 'Send a key or key combination to the app, using xdotool-style syntax such as Return or ctrl+a. super is Command on macOS and the Windows key on Windows.',
    schema: { app, key: z.string().min(1), duration },
  },
  type_text: {
    description: 'Type Unicode text into the observed app. Newlines may submit forms; use paste for multiline content. Verify the resulting value.',
    schema: { app, text: z.string() },
  },
  scroll: {
    description: 'Scroll an observed element or fresh screenshot coordinate. Returns current state: text for indexed input, plus a new screenshot for coordinate input.',
    schema: { app, ...point, direction: z.enum(['up', 'down', 'left', 'right', 'u', 'd', 'l', 'r']), pages: z.number().positive().optional() },
  },
  set_value: {
    description: 'Set a value only on an element explicitly marked settable in the current tree, then return app state. Use click for buttons and checkboxes. Verify the resulting value; web application input handlers may behave differently from typing or pasting.',
    schema: { app, element_index, value: z.string() },
  },
  select_text: {
    description: 'Not yet supported on Windows. Select matching text, or place the cursor beside it, in an observed editable element.',
    schema: { app, element_index, text: z.string(), prefix: z.string().optional(), suffix: z.string().optional(), selection_type: z.enum(['text', 'cursor_before', 'cursor_after']).optional() },
  },
  perform_secondary_action: {
    description: 'Perform an accessibility action exposed by the latest app state. Do not invent action names. On macOS, AXShowMenu and AXScrollToVisible are omitted from listings because nearly every element supports them.',
    schema: { app, element_index, action: z.string().min(1) },
  },
};

definitions.run_actions = {
  description: 'Run a short known sequence and return its final state. Single-action tools already return text state; use this for several known actions or an inline final screenshot. Example: focus an observed field, select all, paste, then inspect the result. Stop when new information or approval is needed. Coordinate input must be first and use a fresh screenshot. Stops on error without replay; earlier actions may have run.',
  schema: {
    app,
    actions: z.array(z.discriminatedUnion('method', Object.entries(definitions)
      .filter(([name, definition]) => !definition.readOnly && name !== 'activate_app')
      .map(([method, definition]) => z.object({
        method: z.literal(method),
        ...Object.fromEntries(Object.entries(definition.schema).filter(([key]) => key !== 'app')),
      }).strict()))).min(1).max(16),
    ...stateOptions,
  },
};

definitions.list_apps = {
  description: 'Discover app names and running state when the target is unknown. If the task names an app, start with get_app_state directly.',
  schema: {}, readOnly: true,
};
definitions.activate_app = {
  description: 'Bring the requested app forward and return its state. Use when foreground interaction is required. Inspect the returned window before input and do not compete with user activity.',
  schema: { app, ...stateOptions },
};

for (const [name, definition] of Object.entries(definitions)) {
  const observedAction = !definition.readOnly && !['run_actions', 'activate_app'].includes(name);
  server.registerTool(name, {
    description: definition.description + (observedAction && !['click', 'drag', 'scroll'].includes(name) ? ' Returns the updated accessibility state after the action; a separate text-only get_app_state is normally unnecessary. Request a new screenshot before later coordinate input.' : ''),
    inputSchema: definition.schema,
    annotations: { readOnlyHint: !!definition.readOnly, openWorldHint: true },
  }, async (args, extra) => {
    try {
      return await runtime.call(name, normalizeArguments(name, args), extra.signal);
    } catch (error) {
      return toolError(error);
    }
  });
}

const transport = new StdioServerTransport();
let shutdown;
const close = () => { shutdown ??= runtime.close().finally(() => process.exit(0)); };
server.server.onclose = close;
process.stdin.once('end', close);
for (const signal of ['SIGINT', 'SIGTERM']) {
  process.once(signal, close);
}
await server.connect(transport);
