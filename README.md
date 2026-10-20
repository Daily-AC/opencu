# OpenCU

OpenCU is a local computer-use engine with an MCP interface. On macOS it reads
and operates app windows through Accessibility, CoreGraphics and
ScreenCaptureKit, and it can work in a background app while you keep using the
one in front. It needs no account, model credentials or proprietary runtime: any
MCP client can start it, and the calling agent supplies the model and decides
what to do.

**Status (v0.4.0):** macOS source builds and an unsigned Windows x64 package.
On the development Mac, 9 of the last 10 runs of its 18-check background GUI
suite passed, and it has completed a handful of real tasks. It has not been
benchmarked at scale. Read [Limitations](#limitations) before relying on it.
The Windows engine uses foreground input. Version 0.4.0 adds an optional visible
[agent desktop](#windows-agent-desktop) to isolate that input in a child session;
its core session behavior was measured on Windows 11; the follow-up startup and
watch-only fixes still need Windows re-acceptance.

## What it does on macOS

- **Works in the background.** Input goes to the target app's process and window
  only. Your foreground app keeps the keyboard and your cursor does not move. If
  the target brings itself to the front, for example a browser opening a tab,
  OpenCU hands the foreground back to you.
- **Holds its own permissions.** You grant Accessibility and Screen Recording to
  OpenCU once. Whichever agent starts it, macOS attributes the work to OpenCU,
  not to your terminal or agent app.
- **Shows what it is doing.** A V-shaped agent cursor, a badge in the target's
  title bar describing the current action, and a V in the menu bar with **Stop**.
- **Reads menus without opening them**, and reads web content in Chrome-family
  browsers and Electron apps.

## Requirements

- Apple silicon Mac with macOS 14 or later. Developed on macOS 26.6 and also run
  on 15.6 in a VM; macOS 14 itself has not been tested.
- Node.js 22+ and Apple's Command Line Tools.

## Install

```sh
git clone https://github.com/Daily-AC/opencu.git
cd opencu
npm ci --ignore-scripts
npm run build
./bin/opencu setup
./bin/opencu doctor
```

There is no prebuilt macOS download. OpenCU is not notarized, so Gatekeeper would
block a downloaded build. The first `npm run build` creates a signing identity
for this Mac in `~/Library/Application Support/OpenCU/signing`, in its own
keychain; the login keychain is not modified. Every build is signed with it, so
permission grants survive rebuilds, and another app claiming OpenCU's bundle
identifier is refused. Deleting that directory means granting permissions again.

`opencu setup` opens a window in English or Simplified Chinese with live
Accessibility and Screen Recording status. Choose **Allow…** beside each one.
`opencu doctor` should then report both permissions and `ownPermissions: true`.
Screen Recording can need a new connection before it takes effect; text-only
reads work without it. If permissions are missing when an agent first calls
OpenCU, the setup window opens once by itself, without taking the foreground.

## Connect an agent

Add a stdio MCP server to your agent:

```json
{
  "mcpServers": {
    "opencu": {
      "command": "/absolute/path/to/opencu/bin/opencu"
    }
  }
}
```

OpenCU opens no network port. Each connection starts its own engine worker as a
launchd job, talking to the client over an authenticated local socket. The
worker exits when the client disconnects.

The pi coding agent can load OpenCU as an extension (tested with pi 0.83):
`pi -e ./adapters/pi/opencu.ts`. See the [pi adapter guide](adapters/pi/README.md).

## Tools

`list_apps`, `get_app_state`, `activate_app`, `click`, `drag`, `press_key`,
`type_text`, `paste`, `scroll`, `set_value`, `select_text`,
`perform_secondary_action`, `run_actions` and `agent_desktop` (Windows only for now).

Start with `get_app_state`. It takes a bundle identifier, app name or `.app`
path, launches the app in the background if needed, and returns indexed
Accessibility elements, plus a window PNG with `includeScreenshot: true`. Input
tools require a preceding observation of the same app and return the updated
state. Coordinates refer to the latest screenshot. `run_actions` runs up to 16
known actions and returns one final state. `activate_app` brings the target to
the front when a step needs it.

On Windows, zero-size elements are omitted unless focused, while their children
remain traversable. Pass `scope: <element index>` on a read, input tool or batch
to return only that retained subtree, numbered from `[1]`; a missing root falls
back to the whole window with a notice. `scope` is Windows-only for now.
`waitForText` searches numbered element lines, excluding headers and summaries.
Both platforms accept `{"method":"wait","ms":1500}` inside `run_actions`
(1–15000 ms, no input). Coordinates must precede every other action, including
wait. Windows `press_key` defaults to a 50 ms hold and state warns when an open
native IME may consume letter keys. v0.3.3 passed 40 fixture checks, including
the six new compact-state and wait cases, in three consecutive runs on a fresh
Windows 11 VM; a host-injected mouse move during a batch wait returned
`PERSON_ACTIVE` ([evidence](evidence/opencu-windows-gui-2026-10-20-v0.3.3.json)).
On a public chess site in an Edge app window, a read dropped from an estimated
33,000 characters (the omitted zero-size lines added back) to 19,900, and to
13,000 when scoped to the page document.


Errors begin with a stable code that the agent sees, for example
`STOPPED_BY_PERSON:`; the same code is in `_meta["opencu/error"]`. The full
behavior is in the [engine contract](docs/independent-engine-contract.md).

## Stopping it

The V appears in the menu bar while an agent is using OpenCU and disappears after
15 seconds without calls. Choose **Stop** from it. That connection then refuses
input, app activation and screenshots with `STOPPED_BY_PERSON`; text reads still
work. Stop applies to that connection only: input already delivered is not undone,
and a new connection starts unstopped. Agents are instructed to wait for your
permission and never to reconnect on their own, but Stop is not a barrier against
a client that ignores this.

The cursor hides three seconds after the last pointer action and the badge three
seconds after the last call. Neither appears in OpenCU's own screenshots.

## Limitations

The measurements behind this section are in
[measured behavior and limits](docs/opencu-independent-2026-10-12.md).

### Install and permissions

- Source build only, Apple silicon only. There is no notarized Developer ID build.
- On macOS 15 and later, the system periodically asks whether OpenCU may keep
  capturing the screen ("…is requesting to bypass the system private window
  picker…"). Choose **Allow**. **Open System Settings** does not count as an
  answer, and the prompt comes back. macOS keeps the answer per engine location,
  so the first screenshot after building in a new directory asks again; after
  that, about every 30 days.
- A caller sandbox that denies networking also blocks the local socket, so
  OpenCU cannot run from such a sandbox. Conversely, the worker runs outside any
  caller sandbox: a sandbox does not confine what OpenCU does.
- OpenCU cannot operate a locked Mac.

### Background operation

- **Windows agent desktop (0.4.0).** Windows 11 VM acceptance established separate
  foreground/input, no-password sign-in/refusal, Escape, close/EOF cleanup and
  ending on parent lock. Follow-up startup and watch-only fixes need re-acceptance.
  Administrator approval is needed once, possibly followed by one sign-out/in;
  smart-card-only sign-in is unsupported and unmeasured. One child session per
  machine; apps still share your account, profiles and files. Single-instance apps
  can refuse another instance. External minimize, covered/partly off-screen views,
  GPU/video apps and unsupported Windows editions remain unmeasured. This is UI
  isolation, not a security sandbox. macOS does not expose this shared tool yet.
- **Stage Manager.** A window in the Stage Manager strip cannot become the key
  window: many commands are disabled, Chromium stops rendering its pages, and a
  screenshot may show only the thumbnail. Reading and indexed actions still work.
  Use `activate_app` or turn Stage Manager off. For apps that accept background
  input, putting the app full screen in its own Space also worked (Keynote); it
  does not help custom-drawn apps.
- A Chromium window that is fully covered by other windows also stops rendering
  its pages.
- **Custom-drawn apps** such as Blender read the real mouse position and raise
  themselves when they become key. OpenCU refuses background input to windows
  that expose only title-bar controls (`BACKGROUND_INPUT_UNSUPPORTED`). Use such
  apps in the foreground, and only while nobody touches the mouse: their
  shortcuts act on whatever is under the real pointer.
- **System Open/Save panels** run in a separate process. While the app is in the
  background, keyboard and coordinate input to them is refused
  (`BACKGROUND_REMOTE_FOCUS`); `set_value` and exposed press actions still work.
- Apps can move windows, change focus or handle synthesized input differently.
  A successful action means the input was sent, not that the task succeeded.

### App coverage

- Accepted: the 18-check AppKit fixture suite and typing in TextEdit. Observed in
  real use: a five-slide Keynote deck built from Keynote's own Space, a web task
  in a disposable Chrome profile (with occluded-window throttling disabled to
  emulate a visible window), reading VS Code, and a Blender model built in the
  foreground through its Python console.
- Not yet accepted: Safari and other WebKit apps, Qt and Java apps.
- No public benchmark yet. Treat reliability on your own tasks as unmeasured.

### Known defects

- An app with several windows and no focused or main window, such as Blender with
  a render window open, fails with `AMBIGUOUS_WINDOW`, and the tools cannot yet
  choose a window.
- A non-Latin input source, such as a Chinese pinyin input method, can swallow
  letter shortcuts. OpenCU does not detect this; switch to a Latin layout.
- Some apps report an Accessibility action as failed after performing it. OpenCU
  reports the outcome as unknown and requires a new read rather than retrying.
  Some text areas refuse selection through Accessibility
  (`TEXT_SELECTION_UNSUPPORTED`); click at the text position instead.
- A state read occasionally fails once with no accessible window and succeeds on
  the next try.

### Safety and privacy

- There is no per-app approval, blocklist or confirmation step. The calling agent
  is responsible for what it asks OpenCU to do.
- OpenCU's signature identifies it to macOS; it does not restrict callers. Any
  local process that can run `bin/opencu` uses OpenCU's permissions.
- On macOS, the menu-bar **Stop** is the only built-in brake.
- `paste` temporarily replaces the clipboard and restores it afterwards, unless
  another app changed it meanwhile.
- The title-bar badge shows up to 16 characters of text being typed or pasted
  (only a character count in password fields). It is visible in screen
  recordings and screen sharing.
- While connected, OpenCU turns on `AXEnhancedUserInterface` in Chrome-family
  browsers so their pages are readable. This slows window moves by window
  managers; OpenCU turns it off again on disconnect.

### Experimental

An engine-level virtual display can take a window out of the Stage Manager strip
onto a display you cannot see, so the agent can use it fully in the background.
It passed its full probe on test fixtures but is not exposed through MCP.
Creating the display can make macOS move a window from your stage into the strip;
setups with external monitors are untested. See the [agent display probe](docs/agent-display-probe.md).

## Windows preview

The Rust engine in `native-win/` implements UI Automation trees, window capture,
indexed and coordinate clicks, drag, Unicode typing, plain-text paste, keys, scroll,
values and secondary actions. Unlike macOS, it works in the foreground: input
can bring a background or minimized target to the front after 10 seconds without
human keyboard or mouse input. Recent activity returns `PERSON_ACTIVE` without
changing foreground or sending input. Windows can still refuse activation; the
engine verifies the target is foreground before sending input. Human activity
during input stops the current call, physical Esc disables
input for the rest of the connection, and a banner excluded from capture shows
that OpenCU is operating.

In v0.3.2, indexed clicks and Invoke/default secondary actions prefer a checked
pointer click when the element owns its centre, avoiding synchronous modal UIA
handlers. Covered controls retain the UIA fallback. If an engine request still
times out, the same MCP connection can restart the engine after cleanup and a
fresh observation; input is never replayed, and a person's stop forbids restart.
Coordinate input without a fresh screenshot returns `SCREENSHOT_REQUIRED`.
v0.3.2 passed 34 fixture checks, including the modal dialog cases, in three
consecutive runs on a fresh Windows 11 VM; an OBS Studio Add Scene dialog that
wedged v0.3.1 now opens, fills and closes through indexed calls
([evidence](evidence/opencu-windows-gui-2026-10-19-v0.3.2.json)).

Missing: text selection. Elevated windows, UAC prompts and secure desktops are refused (`ELEVATED_TARGET`, `SCREEN_LOCKED`); these
refusals have not been checked on a real desktop yet. Controls without accessible
names, common in media players, are listed with an index and bounds but need a
screenshot to tell apart. v0.3.1 acceptance is 30 checks on disposable WinForms
and Chrome fixtures, including drag and idle foreground acquisition, in three
consecutive runs on a fresh Windows 11 x64 VM, plus the 10-second rule and
physical Escape checked with host-injected input
([evidence](evidence/opencu-windows-gui-2026-10-19.json)).

### Install

In Windows PowerShell 5.1 or PowerShell 7, as the signed-in user:

```powershell
irm https://github.com/Daily-AC/opencu/releases/latest/download/install.ps1 | iex
```

Installs the engine, Node.js 22 and MCP dependencies into
`%LOCALAPPDATA%\OpenCU`, without administrator rights or a separate Node install.
The installer verifies the release's SHA-256, replaces an existing install and
writes `opencu.json` last for hosts to discover. Close agent sessions using OpenCU
before updating. It prints the installed version, manifest path and desktop status.
The package is unsigned; SmartScreen or Defender may warn or block it. Check the
release source and your local policy; the installer does not disable protection.
To uninstall, close OpenCU sessions and delete `%LOCALAPPDATA%\OpenCU`.
If agent-desktop setup was used, also remove its demand-only task
`OpenCU-AgentDesktop-<your Windows SID>-<installation hash>` in Task Scheduler
(the exact name is in doctor output). Older candidates used the SID-only name. Child-session enablement
is a machine setting and is not automatically reversed for other applications.

Programs that start OpenCU on an agent's behalf, such as remote-control services,
follow the [host integration contract](docs/host-integration.md). Building the
package, its offline checks, error codes and safety behavior are in the
[Windows contract](docs/windows-engine-contract.md).

### Windows agent desktop

After installing 0.4.0, run this once from a **normal**, non-administrator terminal:

```powershell
& "$env:LOCALAPPDATA\OpenCU\bin\opencu.cmd" setup agent-desktop
& "$env:LOCALAPPDATA\OpenCU\bin\opencu.cmd" doctor
```

Windows asks for UAC approval to enable child sessions. Setup then prepares the
helper offline using the built-in .NET Framework compiler; no extra runtime is
downloaded. If your sign-in predates enablement, sign out and back in once.
OpenCU never asks for, accepts or stores a session password. Before UAC, setup
explains that Windows will ask to let Microsoft Windows PowerShell make changes
only to enable child sessions. Once enabled, a first start after an OpenCU update
rebuilds missing or outdated helpers automatically, offline and without elevation.
Doctor/status remain read-only; setup can also be run again manually.

The agent can call `agent_desktop` with `{"action":"start"}` to open the visible
**OpenCU agent desktop** window. All app tools then operate inside that session,
using ordinary foreground input while your desktop remains separate. The view
starts in **Watch only** mode: hovering does not forward mouse input. Click the
view to interact (the first click selects the mode); switching to another window
returns it to Watch only. The label shows the current mode. Read fresh
app state after starting. `{"action":"status"}` reports state and availability;
`{"action":"stop"}` logs off the child apps, so save their work first.

Closing the window or physical Escape inside its focused view permanently stops
that MCP connection. The agent must not reconnect or restart without your explicit
permission. A failed start or broken connection never falls back to your desktop.
After a failed start, app tools remain blocked until `agent_desktop` with
`{"action":"stop"}` finishes cleanup. This never clears a person's stop. The
[Windows contract](docs/windows-engine-contract.md#agent-desktop-040) separates the
measured VM results from the follow-up fixes still awaiting Windows acceptance.

## Development

```sh
npm test
python3 scripts/test-native.py
node scripts/verify-gui.mjs
```

`verify-gui.mjs` builds two disposable AppKit fixtures, keeps one in the
foreground and operates the other in the background through the MCP server. On
Windows, `node scripts/verify-gui-win.mjs` uses disposable WinForms and Chrome
fixtures and takes the foreground.

`python3 scripts/package-opencu.py` builds a self-contained archive with Node and
the MCP dependencies for your own Macs, signed with your local identity, and
`python3 scripts/verify-release.py` checks it offline.

## License

Original OpenCU code is available under the [MIT License](LICENSE). Bundled open
source dependencies retain their own licenses. No license for proprietary third
party software is included or implied.
