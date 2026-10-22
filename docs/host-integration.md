# Host integration

This contract is for programs that start OpenCU on behalf of an agent, for
example a remote-control service that relays an agent's tool calls to a device.
The interface is OpenCU's MCP server over stdio. A host discovers it, launches
it in the person's desktop session, keeps one connection per agent session and
relays MCP messages without interpreting the tools. OpenCU can then add or change
tools without a host release.

Status: defined for Windows from v0.3.0 and Linux from v0.6.0. On macOS, local agents start
`bin/opencu` directly; a macOS install manifest is not defined yet.

## Discovery

OpenCU is installed when this per-user manifest exists:

- Windows: `%LOCALAPPDATA%\OpenCU\opencu.json`

```json
{
  "name": "opencu",
  "version": "0.5.0",
  "platform": "win32",
  "mcp": {
    "command": "C:\\Users\\me\\AppData\\Local\\OpenCU\\node\\node.exe",
    "args": ["C:\\Users\\me\\AppData\\Local\\OpenCU\\src\\server.mjs"]
  }
}
```

Paths are absolute. Launch exactly `mcp.command` with `mcp.args`, without a
shell. Do not rely on any other file or the directory layout; they can change
between releases. Read the manifest as the signed-in user: `%LOCALAPPDATA%`
belongs to that user, not to a service account.

If the manifest is missing or unreadable, report that OpenCU is not installed
and show the person this command, which installs or updates it for the current
user without administrator rights:

```powershell
irm https://github.com/Daily-AC/opencu/releases/latest/download/install.ps1 | iex
```

The script downloads the release's Windows package, refuses it unless its
SHA-256 matches the value embedded in the script, and writes the manifest last.
The package is not code-signed.

## Launch

- Start the process in the signed-in user's interactive session on
  `winsta0\default`, with that user's normal, non-elevated token. OpenCU cannot
  operate its parent-desktop engine from session 0, a locked or disconnected
  session, or another user's session; it reports `SCREEN_LOCKED` there. An already
  running agent-desktop child remains readable/capturable when the parent locks;
  only its supported indexed control patterns can act, as described below.
- Connect stdin and stdout as the MCP stream and read stderr as diagnostics.
  Create no console window.
- OpenCU opens no network port. It exits when stdin closes.

## Linux (0.6.0)

`install.sh` from the release installs for the current user without root:

```sh
curl -fsSL https://github.com/Daily-AC/opencu/releases/latest/download/install.sh | sh
```

It refuses an archive whose SHA-256 differs from the value embedded in the
script, installs into `${XDG_DATA_HOME:-$HOME/.local/share}/opencu` (or
`$OPENCU_HOME`) and writes `opencu.json` there last, with the same `mcp.command`
and `mcp.args` fields as on Windows. `OPENCU_LOCAL_ARCHIVE` installs a
downloaded archive without network access. A container image can instead
extract the archive anywhere and run `<dir>/bin/opencu`.

Launch it as the desktop's user with `DISPLAY` set, for example
`docker exec -i -u her -e DISPLAY=:1 desktop /home/her/.local/share/opencu/bin/opencu`.
Other session variables are optional: OpenCU finds the accessibility bus and
the session's environment itself. Relay tools unchanged as above; Linux lists
no `agent_desktop`. A person stop (`USER_STOPPED`) follows the Windows rules.
An MCP client that reconnects automatically after a crash should have that
turned off for OpenCU, and its per-call timeout should exceed 125 seconds; in dsh:

```yaml
- id: mcp-opencu
  name: '@deepseek-ai/dsh-mcp-client'
  config:
    serverName: opencu
    transport: stdio
    command: /home/her/.local/share/opencu/bin/opencu
    env: { DISPLAY: ':1' }
    toolCallTimeoutMs: 130000
    reconnect: { enabled: false }
```

See the [Linux engine contract](linux-engine-contract.md) for behavior and limits.

## Session lifetime

- Keep one connection for each agent session and reuse it for every call in that
  session. Element indexes, screenshot coordinates and the stop state belong to
  the connection; a new connection starts without them.
- From v0.3.2, a 90-second engine request timeout does not kill the MCP session.
  That call returns `RUNTIME_ERROR`; its input outcome remains unknown and no
  action is replayed. OpenCU retires the old engine (EOF, up to 35 seconds for
  cleanup, then termination), waits for process/output closure, and lets a later
  call start a fresh engine internally. Hosts keep the same MCP connection.
  The next call may wait for that cleanup; allow more than 125 seconds for a
  call that can include cleanup plus a new engine request. Host cancellation
  does not establish that input was cancelled.
- After timeout, old element indexes, screenshots and diffs are discarded.
  The agent must explicitly call `get_app_state` again before input or activation
  (`OBSERVATION_REQUIRED` otherwise); `list_apps` alone is insufficient.
  Coordinate input additionally needs a fresh screenshot (`SCREENSHOT_REQUIRED`
  on both platforms). Do not replay the timed-out action or an interrupted batch.
- Engine replacement is forbidden once this MCP connection has seen
  `USER_STOPPED` or `STOPPED_BY_PERSON`, even in a late old-engine response.
  Ordinary `PERSON_ACTIVE` is not a permanent stop, but still requires the
  interaction described below. Other process/stream failures remain terminal;
  automatic replacement is limited to engine request timeouts.
- Close the connection when the agent session ends, and after an idle period;
  ten minutes is a reasonable default.
- Do not let two connections operate the same app at the same time.

## Relaying calls

- `initialize`: pass the returned `instructions` to the agent. They contain the
  usage rules the tools rely on. `serverInfo.version` is the OpenCU version.
- `tools/list`: pass names, descriptions, input schemas and annotations to the
  agent unchanged. Do not keep a copy of the tool list in the host.
- `tools/call`: forward arguments unchanged and return every content item (text
  and PNG images), `isError` and `_meta` unchanged.
- Never replay a call. If the process exits or the stream breaks during a call,
  report that the outcome is unknown and let the agent observe again.

## Errors and stopping

Tool errors begin with a stable code followed by a colon, for example
`USER_STOPPED: ...`; the code is also in `_meta["opencu/error"]`. These stops
need host action:

- `USER_STOPPED` (Windows, physical Esc or closing/minimizing the agent desktop) and `STOPPED_BY_PERSON` (macOS, menu
  Stop): the person stopped OpenCU. The latch lives on the connection, so a
  reconnect would silently clear it. The host must refuse further OpenCU calls
  for that agent session, without reconnecting, until the person explicitly
  allows it again.
- `PERSON_ACTIVE` (Windows): someone used the keyboard or mouse during the call,
  held a key/button, or used input within the last 10 seconds when foreground
  activation was needed.
  The agent should ask the person before continuing rather than retry.

Other codes are documented in the [Windows contract](windows-engine-contract.md#stable-error-codes)
and the [engine contract](independent-engine-contract.md).

## Authorization

The host decides which tasks/calls to allow; OpenCU has no app allowlist or
blocklist. macOS agent desktop additionally requires the local window consent
described below. `annotations.readOnlyHint` marks tools that send no input, but
`get_app_state` can launch the requested app. A useful approval summary is the
tool name plus its `app` argument.

## Windows agent desktop (0.4.0)

Relay the new `agent_desktop` lifecycle tool dynamically like other tools. It
accepts only `action: start | stop | status`; no credentials or session selector.
For one-time enablement the person runs this from normal PowerShell:
`& "$env:LOCALAPPDATA\OpenCU\bin\opencu.cmd" setup agent-desktop`.
Errors use the actual installation path. Only this explicit command may request
UAC, preceded by an explanation of the Windows PowerShell prompt. On first start
after an update, missing/stale helpers are rebuilt offline and the installation's
ordinary-user task is registered automatically, only if child sessions are already
enabled. The automatic path refuses disabled child sessions and never elevates.
Missing setup returns `AGENT_DESKTOP_UNAVAILABLE`; automatic sign-in failure returns
`AGENT_DESKTOP_SIGN_IN_REQUIRED`. Never collect or forward a session password.

Start opens a visible window and routes every app tool to the child-session
engine. The normal foreground rules still apply inside that session. Tool stop
logs off its apps and may lose unsaved work; only confirmed cleanup permits return
to the parent. Switching invalidates all observations and requires a new state
read. The person's host-close/Escape stop survives stop/start and mode changes for
the entire MCP connection; host approvals must not reconnect around it.

Child transport failures/timeouts do not replace its engine, reconnect RDP, or
fall back to the parent's desktop. Parent-engine timeout recovery above is unchanged.
Status/cleanup are available after failure; errors explain that `agent_desktop`
with `{"action":"stop"}` is required before app tools can resume. This is not a
person-stop reset. While the parent screen is locked, the child stays alive for
reads/screenshots and the supported indexed control patterns introduced below;
other input returns `SCREEN_LOCKED`. Five VM trials could not activate a child
window while locked; the earlier unrestricted-input success report is unreliable.
Nobody at the machine can see the child then. `status.parentLocked` (inside the
tool's JSON text) reports the measured lock state. The native child guard checks
that parent before input; it preserves USER_STOPPED precedence and reports partial
input honestly if locking occurs during a call. SCREEN_LOCKED from an input is not
a terminal host failure: reads remain allowed, and unlock permits subsequent
explicit input under the normal rules, with no replay/reconnect.

Only in the locked-parent Windows child, a single left indexed `click` with no
modifiers/duration, `set_value` via ValuePattern (not RangeValue), and listed
`perform_secondary_action` use supported control patterns without foreground or
synthetic input. Click selects SelectionItem.Select, Invoke, Toggle,
ExpandCollapse, then a nonempty MSAA default action, using capabilities rather
than control names. Missing patterns return `UNSUPPORTED_ACTION`. Coordinate or
modified/multiple clicks, typing, keys, scroll, drag, paste, activation and batch
waits remain `SCREEN_LOCKED`. `get_app_state` may launch a child app without an
activation request. A fresh pattern observation stops remaining batch steps;
unknown outcomes require an explicit read, never replay. The 2026-10-21 Windows
11 VM release acceptance measured Invoke/Value.SetValue, refused typing and
nonactivating locked launch; other providers are not implied by that evidence.
See the [unchanged v0.4.0 fixture evidence](../evidence/opencu-windows-agent-desktop-2026-10-21-v0.4.0.json).

Console/remote disconnect and logoff still end the child. A caller can stop it
while locked by ending MCP stdin; after unlocking the person can press the host's
Stop button or click the view and press Escape. Closing the host only minimizes it. Lock/error validation remains manual
without collecting an unlock password. The feature is not a file/account sandbox;
macOS uses the virtual-display lifecycle below.

When Windows reports childSessionsEnabled=false, doctor/availability explicitly
requires one-time setup and gives the installed launcher command. Missing derived
helpers on an already-enabled machine still prepare automatically. A successful
probe reports `existingChildSession: null` when none exists, not a DWORD sentinel.
See the [Windows contract](windows-engine-contract.md#agent-desktop-040) and
[focus/cursor investigation](windows-agent-desktop-input-findings.md).

## macOS agent desktop (0.4.1)

Keep the same strict action-only schema and existing tool annotations. macOS
start automatically creates a nonactivating watch-only preview and a virtual
display. It does not use a sharing picker or introduce a second login session.
Normal per-window screenshots remain unchanged. The macOS 15+ periodic capture
confirmation may take foreground, approximately monthly per executable location;
OpenCU refuses or interrupts the current input with `AGENT_DISPLAY_PERSON_ACTIVE`
if it does; an already running desktop and its windows remain. This also applies
to foreground SecurityAgent/UserNotificationCenter prompts. Status stays running
and may report `inputPause`; dismiss the prompt and explicitly read state before
continuing. Preview uses the existing Screen Recording grant
and independently verified worker responsibility.

Only explicit `get_app_state` may show a local 60-second per-window Move once / Keep
here card. Agent arguments cannot approve it. A decline/expiry returns text-only
reduced state (`_meta["opencu/agentDesktop"].windowState`); mutations are refused with
`AGENT_DESKTOP_CONSENT_REQUIRED`. Internal reads and batch final reads never prompt.
Do not replay an input after consent or after a timeout. A host may cancel the
pending tool; its approval cannot subsequently move the window. Lock/cancel/tool
stop are not declines: another explicit read may ask. Nonmovable windows return
reduced text-only state (including final reads) and the specific move refusal in
`opencu/agentDesktop.consent`. A new already-present window of an admitted process
inherits admission without movement or restoration. An already-present window of
another process gets an Allow this window card on an explicit read; no implicit
read shows it. Consent is a person-facing check, not protection from other local
automation running as the same user. Status/stop use a
control lane and remain callable while the normal tool is waiting. Allow at least
90 seconds for a call awaiting local consent; cancellation is not approval.

All mutating app tools are restricted to exact admitted windows on that display.
Read-only inventory/state outside it is necessary for choosing a consent target.
`activate_app` is refused; opaque/foreground-only apps remain unsupported. An app
may initially launch on the person's display. The preview never forwards input.
This is narrower than Windows' session isolation and click-to-interact behavior.

Tool stop restores the admitted windows' saved frames and sizes, leaves apps and
unsaved documents open, and confirms virtual-display removal in a fresh process.
Windows leaving the agent display by any means lose admission for that desktop
lifetime and are left there. The person returns all windows with host/menu-bar
Stop, or one through the app's own Window > Move to display command; the invisible
monitor cannot be dragged through the preview. Closing or minimizing the preview
only puts it in the Dock. Its Stop button and menu-bar Stop send a native event and
permanently latch `STOPPED_BY_PERSON` even while idle. All app tools/start are then refused; only
status/cleanup remain available. A macOS preview Stop Sharing action (SCK's
`userStopped` error) uses this same latch. Other stream deaths use
`AGENT_DESKTOP_LOST` and cleanup, never stream restart. Tool stop cannot clear that latch. MCP EOF cleans
up without another tool call. Failed cleanup retains diagnostics and blocks normal
routing. No worker replacement, stream restart, display recreation or action replay
is allowed in desktop mode. Normal macOS mode's existing recovery is unchanged.

Hosts should stop the desktop when the task no longer needs it. A macOS desktop
with no tool call for 5 minutes (no pending consent, not locked) stops itself like
a tool stop; the next app call returns `AGENT_DESKTOP_IDLE_STOPPED` with no input
sent, until `agent_desktop` is called again. The person may keep using the Mac
during start and relocation; a move stops only if the person starts using that
window (its app comes forward or a mouse button is held over it). A move
interrupted by `AGENT_DISPLAY_PERSON_ACTIVE` rolls back only
that window, keeps the desktop/other admissions and permits another consent on a
later explicit read. Never replay it automatically. Failed restoration remains a
cleanup error; an interrupted start removes its resources and fails cleanly.
`OBSERVATION_REQUIRED` means an admitted window needs a fresh read;
`AGENT_DESKTOP_CONSENT_REQUIRED` means its admission is actually missing.

Unlike Windows, macOS pauses while locked: `parentLocked: true`, `ready: false`,
`SCREEN_LOCKED`; ownership survives for cleanup and a fresh observation is required
after unlock. External monitors remain untested. Layout changes fail and clean up
with `AGENT_DISPLAY_LAYOUT_CHANGED`. There is one display per connection/GUI
session; a second owner gets `AGENT_DISPLAY_BUSY`. Status reports the native worker,
preview health, pending consent, restoration records, generation and cleanup result;
it does not invent a Windows session ID.

## Compatibility

While OpenCU is 0.x, tools and their schemas can change in any release; hosts
that relay them dynamically need no update. Changes to discovery, launch,
session lifetime or the stop rules above are announced in release notes and in
this document.
