# Host integration

This contract is for programs that start OpenCU on behalf of an agent, for
example a remote-control service that relays an agent's tool calls to a device.
The interface is OpenCU's MCP server over stdio. A host discovers it, launches
it in the person's desktop session, keeps one connection per agent session and
relays MCP messages without interpreting the tools. OpenCU can then add or change
tools without a host release.

Status: defined for Windows from v0.3.0. On macOS, local agents start
`bin/opencu` directly; a macOS install manifest is not defined yet.

## Discovery

OpenCU is installed when this per-user manifest exists:

- Windows: `%LOCALAPPDATA%\OpenCU\opencu.json`

```json
{
  "name": "opencu",
  "version": "0.3.1",
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
  work from session 0, a locked or disconnected session, or another user's
  session; it reports `SCREEN_LOCKED` there.
- Connect stdin and stdout as the MCP stream and read stderr as diagnostics.
  Create no console window.
- OpenCU opens no network port. It exits when stdin closes.

## Session lifetime

- Keep one connection for each agent session and reuse it for every call in that
  session. Element indexes, screenshot coordinates and the stop state belong to
  the connection; a new connection starts without them.
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
`USER_STOPPED: ...`; the code is also in `_meta["opencu/error"]`. Two codes
need host action:

- `USER_STOPPED` (Windows, physical Esc) and `STOPPED_BY_PERSON` (macOS, menu
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

OpenCU has no approval step, allowlist or blocklist. The host decides which
calls to allow. `annotations.readOnlyHint` marks tools that send no input, but
`get_app_state` can launch the requested app. A useful approval summary is the
tool name plus its `app` argument.

## Compatibility

While OpenCU is 0.x, tools and their schemas can change in any release; hosts
that relay them dynamically need no update. Changes to discovery, launch,
session lifetime or the stop rules above are announced in release notes and in
this document.
