#!/usr/bin/env node
import { McpServer } from '@modelcontextprotocol/sdk/server/mcp.js';
import { StdioServerTransport } from '@modelcontextprotocol/sdk/server/stdio.js';
import { z } from 'zod';
import path from 'node:path';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { toolError } from './opencu-runtime.mjs';
import { AgentDesktopRuntime, agentDesktopSetupCommand } from './agent-desktop.mjs';
import { normalizeArguments } from './tool-arguments.mjs';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const { version } = JSON.parse(readFileSync(path.join(root, 'package.json'), 'utf8'));
const server = new McpServer(
  { name: 'opencu', version },
  { instructions: 'Control desktop applications with the independent OpenCU engine. Read get_app_state before input. Use observed element indexes; request screenshots before coordinate input. Actions normally return updated state, and run_actions executes a short known sequence before one final read. An unconfirmed accessibility action instead returns an unknown-outcome notice and stops the batch; explicitly read get_app_state before continuing. Use paste for Unicode or multiline text. Verify the actual result before reporting success. Activate an app only when foreground focus is needed. Do not operate the same app concurrently from different sessions. Respect user authorization and your host approval rules. Input is never automatically replayed. On STOPPED_BY_PERSON the person stopped this macOS connection: never reconnect or retry on your own; wait for explicit permission. Text-only state may continue only outside agent desktop mode. On macOS, input normally runs in the background. agent_desktop start automatically opens a virtual display and watch-only preview. An explicit get_app_state asks the person before moving each exact window; denied/expired windows remain read-only. Do not call activate_app in desktop mode. Mac desktop close/Stop latches the whole connection; only status/cleanup remain available. macOS pauses while locked, and opaque foreground-only apps remain unsupported. On Windows, agent_desktop start opens a visible separate session after one-time setup; all app tools then run there while the person uses their own desktop. Closing that window permanently stops this connection. Never bypass a stop by switching desktops or reconnecting. Ordinary Windows input requires verified foreground focus within its selected session. Exception: only in an agent desktop whose parent is locked, indexed single-left unmodified click, set_value via ValuePattern, and listed perform_secondary_action use control patterns without foreground or synthetic input; other input returns SCREEN_LOCKED. A pattern success with no observed accessibility change is an unknown outcome; read get_app_state and do not replay. If the target is not foreground, input and activate_app can bring it forward only after 10 seconds without human keyboard or mouse activity; otherwise they return PERSON_ACTIVE without changing foreground or sending input. Stop on PERSON_ACTIVE and never retry it. Windows supports drag and plain-text paste, but not select_text. Physical Escape latches USER_STOPPED on Windows: never reconnect or retry without explicit permission. OpenCU runs locally, respects OS permissions, and requires no account or particular agent identity.' },
);
const runtime = new AgentDesktopRuntime({ root });

const app = z.string().min(1).describe('App name or full app path; macOS bundle ID; Windows process name, window title fragment, or Start-menu shortcut name');
const element_index = z.number().int().describe('Element index from the latest returned app state');
const duration = z.number().finite().min(0).max(30).optional().describe('Seconds to hold before releasing, from 0 to 30. Windows press_key defaults to 0.05 seconds when omitted; explicit 0 remains allowed.');
const scope = z.number().int().min(1).optional().describe('Windows only for now: element index from the latest returned state. Read only its retained subtree, renumbered from [1], including after actions. If it disappears, return the whole window with a notice. macOS returns INVALID_ARGUMENT.');
const stateOptions = {
  scope,
  disableDiff: z.boolean().optional(),
  includeScreenshot: z.boolean().optional().describe('Default false. Use true for visual content or coordinate input; omit for indexed controls, menus, dialogs and text editing.'),
  waitForText: z.string().min(1).optional().describe('Wait for exact, case-sensitive text in element lines only (within scope when supplied), excluding headers and window summaries, without UI actions. Use only a known expected label during a real load; omit on ordinary reads.'),
  waitTimeoutMs: z.number().int().min(0).max(15000).optional().describe('Polling deadline for waitForText; defaults to 5000 ms. Native call timeouts remain separate.'),
};
const point = {
  element_index: element_index.optional(),
  x: z.number().finite().optional().describe('X pixel coordinate in the most recently returned app-window screenshot; requires a screenshot after the last UI action.'),
  y: z.number().finite().optional().describe('Y pixel coordinate in that same app-window screenshot.'),
};
const definitions = {
  get_app_state: {
    description: 'Start here: read the requested app by name or platform-specific identifier; it launches if needed. A locked Windows agent desktop can launch without OpenCU activating the window. Windows elevation-required launches return LAUNCH_FAILED with guidance for the person; OpenCU never elevates the program. Text normally suffices for menus, dialogs, indexed controls and text editing. Request an image for visual content or coordinates. For separately saved edits, create and verify the destination copy before editing because apps may autosave the source. Verify the saved result and any required source preservation before reporting completion; an action success only confirms input was sent.',
    schema: { app, ...stateOptions }, readOnly: true,
  },
  click: {
    description: 'Click an observed control, including buttons and checkboxes, or a fresh screenshot coordinate. In a locked Windows agent desktop, use a single left indexed click without modifiers or duration. Returns updated state: indexed clicks return text; coordinate clicks also return a new screenshot for the next action. On macOS, clicking a menu bar item or submenu lists its items without displaying a menu; clicking a listed menu item runs its command.',
    schema: { app, ...point, mouse_button: z.enum(['left', 'right', 'middle', 'l', 'r', 'm']).optional(), click_count: z.number().int().min(1).max(3).optional(), key: z.string().trim().min(1).optional().describe('Modifier chord held during the click, such as Shift or super.'), duration },
  },
  drag: {
    description: 'Drag inside the fresh app-window screenshot and return a new screenshot and state. To crop a side while preserving height: zoom out for margins, Select All, then move only the middle left/right selection handle horizontally. Keep the existing top/bottom selection edges; verify dimensions in Inspector. Window borders resize the window.',
    schema: { app, from_x: z.number().finite(), from_y: z.number().finite(), to_x: z.number().finite(), to_y: z.number().finite() },
  },
  paste: {
    description: 'Paste text, Markdown, or HTML into the focused field (Windows: plain text only). Prefer this for Unicode or multiline text. Verify focus and the resulting value. Restores the previous clipboard unless another app changed it during the operation.',
    schema: { app, text: z.string(), format: z.enum(['text', 'md', 'html']) },
  },
  press_key: {
    description: 'Send a key or key combination to the app, using xdotool-style syntax such as Return or ctrl+a. super is Command on macOS and the Windows key on Windows. Windows holds an omitted duration for 50 ms so frame-polled games can detect taps. If state warns of native IME mode, letter keys may reach the input method; type_text and paste are unaffected.',
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
    description: 'Set a value only on an element explicitly marked settable in the current tree, then return app state. Use click for buttons and checkboxes. In a locked-parent Windows agent desktop this requires ValuePattern; RangeValue is not available there. Verify the resulting value; web application input handlers may behave differently from typing or pasting.',
    schema: { app, element_index, value: z.string() },
  },
  select_text: {
    description: 'Not yet supported on Windows. Select matching text, or place the cursor beside it, in an observed editable element.',
    schema: { app, element_index, text: z.string(), prefix: z.string().optional(), suffix: z.string().optional(), selection_type: z.enum(['text', 'cursor_before', 'cursor_after']).optional() },
  },
  perform_secondary_action: {
    description: 'Perform an accessibility action exposed by the latest app state. Do not invent action names. A locked-parent Windows agent desktop calls the listed pattern directly without pointer fallback. On macOS, AXShowMenu and AXScrollToVisible are omitted from listings because nearly every element supports them.',
    schema: { app, element_index, action: z.string().min(1) },
  },
};

for (const definition of Object.values(definitions)) {
  if (!definition.readOnly) definition.schema.scope = scope;
}

definitions.run_actions = {
  description: 'Run a short known sequence and return its final state. Single-action tools already return text state; use this for several known actions or an inline final screenshot. Example: focus an observed field, select all, paste, then inspect the result. Stop when new information or approval is needed. Accepts {"method":"wait","ms":N} for 1–15000 ms on both platforms; wait sends no input and honours person stops. Coordinate input must be first (including before any wait) and use a fresh screenshot. Stops on error or an unknown accessibility action outcome without replay; earlier actions may have run. An unknown outcome requires an explicit get_app_state before continuing. A locked pattern that refreshes indexes stops the remaining batch and returns fresh state; choose subsequent actions from that state.',
  schema: {
    app,
    actions: z.array(z.discriminatedUnion('method', Object.entries(definitions)
      .filter(([name, definition]) => !definition.readOnly && name !== 'activate_app')
      .map(([method, definition]) => z.object({
        method: z.literal(method),
        ...Object.fromEntries(Object.entries(definition.schema).filter(([key]) => !['app', 'scope'].includes(key))),
      }).strict()).concat([z.object({ method: z.literal('wait'), ms: z.number().int().min(1).max(15000) }).strict()]))).min(1).max(16),
    ...stateOptions,
  },
};

definitions.list_apps = {
  description: 'Discover app names and running state when the target is unknown. If the task names an app, start with get_app_state directly.',
  schema: {}, readOnly: true,
};
definitions.activate_app = {
  description: 'Bring the requested app forward and return its state. Use when foreground interaction is required. On Windows, changing foreground requires 10 seconds without human keyboard or mouse activity; otherwise PERSON_ACTIVE is returned with no foreground change or input. Inspect the returned window before input and do not compete with user activity.',
  schema: { app, ...Object.fromEntries(Object.entries(stateOptions).filter(([key]) => key !== 'scope')) },
};
definitions.agent_desktop = {
  description: `Start, stop or inspect a visible agent workspace. Windows: a separate child session for all app tools; the view is watch-only until clicked and returns to watch-only on deactivation. While the parent is locked, reads/screenshots and supported indexed single-left unmodified click (no duration), set_value via ValuePattern, and listed perform_secondary_action remain available; other input returns SCREEN_LOCKED. Status reports parentLocked; the child is invisible behind the lock screen and nothing is replayed on unlock. Stop logs off child apps, so unsaved work can be lost. First-time enablement: ${agentDesktopSetupCommand(process.platform === 'win32' ? root : undefined)}. Updates prepare helpers without elevation; never supply credentials. macOS: automatically opens a virtual monitor in the same session with an always watch-only preview. Only explicit get_app_state asks local per-window consent (60 seconds); denied/expired or nonmovable windows stay reduced/read-only. Already-present same-process windows inherit admission; other processes need approval. Moves require a quiet pointer/foreground; keep hands off for 2 seconds after Move once. An interrupted move returns AGENT_DISPLAY_PERSON_ACTIVE and undoes only that move; do not retry automatically. Background-capable windows only, no activate_app; app launch may appear on the person's display. macOS pauses while locked and requires fresh state after unlock. Stop/EOF restores eligible moved windows and leaves apps/unsaved content open; windows that left the display are left alone. Both platforms: close or person Stop permanently latches the connection (Windows also physical Escape in the interactive view; macOS also menu Stop/system Stop Sharing). Only status/cleanup remain; never restart or reconnect around a person stop. EOF cleans up; failures never fall back or replay input.`,
  schema: { action: z.enum(['start', 'stop', 'status']) },
};

for (const [name, definition] of Object.entries(definitions)) {
  const observedAction = !definition.readOnly && !['run_actions', 'activate_app', 'agent_desktop'].includes(name);
  server.registerTool(name, {
    description: definition.description + (observedAction && !['click', 'drag', 'scroll'].includes(name) ? ' Returns the updated accessibility state after the action; a separate text-only get_app_state is normally unnecessary. Request a new screenshot before later coordinate input.' : ''),
    inputSchema: name === 'agent_desktop' ? z.strictObject(definition.schema) : definition.schema,
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
