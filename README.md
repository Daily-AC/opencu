# OpenCU

OpenCU is a local computer-use engine with an MCP interface. On macOS it reads
and operates app windows through Accessibility, CoreGraphics and
ScreenCaptureKit, and it can work in a background app while you keep using the
one in front. It needs no account, model credentials or proprietary runtime: any
MCP client can start it, and the calling agent supplies the model and decides
what to do.

**Status (v0.4.1):** macOS source builds and an unsigned Windows x64 package.
On the development Mac, 9 of the last 10 runs of its 18-check background GUI
suite passed, and it has completed a handful of real tasks. It has not been
benchmarked at scale. Read [Limitations](#limitations) before relying on it.
The Windows engine uses foreground input. Version 0.4.0 adds an optional visible
[agent desktop](#windows-agent-desktop) to isolate that input in a child session;
locked-parent indexed button clicks and value setting passed acceptance on a
Windows 11 VM, while ordinary input remained blocked. See the measured scope below.

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
`perform_secondary_action`, `run_actions` and `agent_desktop`.

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

In ordinary macOS mode, the V appears while an agent is using OpenCU and hides
15 seconds after its last call. Menu-bar **Stop** refuses input, activation and
screenshots with `STOPPED_BY_PERSON`; text-only reads remain available in that mode.

In **macOS agent desktop** mode the menu-bar item stays for the desktop lifetime.
Closing the host, its **Stop** button, menu-bar **Stop**, or a macOS Stop Sharing
control for the preview permanently stops that MCP connection. All app calls,
including text reads, then fail; only desktop status and cleanup remain available.
Windows return to their recorded frames when eligible; apps and unsaved content
stay open. A tool-requested stop alone permits a later explicit start.

Stop does not undo delivered input and applies to its connection. Agents must
never reconnect around it without permission. It is a person-facing brake, not a
barrier against another local client or automation running as the same user.

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
  that, about every 30 days. This confirmation can take the foreground; OpenCU
  refuses or interrupts the current input with `AGENT_DISPLAY_PERSON_ACTIVE` when
  it does. A foreground SecurityAgent or UserNotificationCenter prompt does not
  destroy an already running agent desktop or return its windows. Dismiss the
  prompt, then explicitly observe before continuing; input is never replayed.
  Agent desktop preview uses the same existing Screen
  Recording permission and verified worker responsibility; it does not suppress
  or replace this macOS reminder with a sharing picker.
- A caller sandbox that denies networking also blocks the local socket, so
  OpenCU cannot run from such a sandbox. Conversely, the worker runs outside any
  caller sandbox: a sandbox does not confine what OpenCU does.
- OpenCU cannot operate a locked Mac.

### Background operation

- **Windows agent desktop (0.4.0).** Windows 11 VM acceptance established separate
  foreground/input, no-password sign-in/refusal, Escape and close/EOF cleanup.
  Setup, nonactivating open, watch-only hover, pointer isolation, Escape, close
  and the locked-screen refusal were accepted on the VM
  ([evidence](evidence/opencu-windows-agent-desktop-2026-10-21-v0.4.0.json)).
  Administrator approval is needed once, possibly followed by one sign-out/in;
  smart-card-only sign-in is unsupported and unmeasured. While the parent screen
  is locked, the child stays alive for reads, screenshots and supported indexed
  control patterns. Locked button click/value setting and refused typing were
  accepted on a Windows 11 VM (the button used Invoke, the text box
  Value.SetValue). Other input returns `SCREEN_LOCKED`. A read-triggered launch
  while locked opens the app without activating it. Nobody at the machine
  can see the child while the lock screen is shown.
  Status reports `parentLocked`. After unlocking, close the host window or click
  the view and press Escape to stop; the caller can also end the MCP connection.
  Console/remote disconnect and logoff still end the child. One child session per
  machine; apps still share your account, profiles and files. Single-instance apps
  can refuse another instance. External minimize, covered/partly off-screen views,
  GPU/video apps and unsupported Windows editions remain unmeasured. This is UI
  isolation, not a security sandbox.
- **macOS agent desktop.** A watch-only virtual monitor in the same macOS session,
  not a Windows-style separate session. Each window move needs local consent;
  background-capable windows only. Blender and other opaque/foreground-only apps
  retain `BACKGROUND_INPUT_UNSUPPORTED`. App launch may appear on your display
  first. Creating the display can push an on-stage window into the Stage Manager
  strip. External monitors are untested; unsupported layouts are refused. The
  owner passed all seven product checks before rebase on 2026-10-21 with one
  built-in display and Stage Manager on ([evidence](evidence/opencu-macos-agent-desktop-2026-10-21.json)).
  This does not establish other display layouts or a post-rebase GUI run.
- **Stage Manager.** A window in the Stage Manager strip cannot become the key
  window: many commands are disabled, Chromium stops rendering its pages, and a
  screenshot may show only the thumbnail. Reading and indexed actions still work.
  The macOS agent desktop can move a window with your consent to keep it rendered
  for background work. Outside that mode, use `activate_app` or turn Stage Manager off. For apps that accept background
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

- There is no per-app allowlist or task approval system. The calling agent is
  responsible for its requests. macOS agent desktop adds local consent before
  moving each window, and before using an already-present window of another
  process. That card is a person-facing check, not a barrier against other local
  automation running as the same user (including Accessibility automation).
- OpenCU's signature identifies it to macOS; it does not restrict callers. Any
  local process that can run `bin/opencu` uses OpenCU's permissions.
- macOS agent desktop also stops through its host close/Stop controls or a macOS
  preview Stop Sharing control. See [Stopping it](#stopping-it).
- `paste` temporarily replaces the clipboard and restores it afterwards, unless
  another app changed it meanwhile.
- The title-bar badge shows up to 16 characters of text being typed or pasted
  (only a character count in password fields). It is visible in screen
  recordings and screen sharing.
- While connected, OpenCU turns on `AXEnhancedUserInterface` in Chrome-family
  browsers so their pages are readable. This slows window moves by window
  managers; OpenCU turns it off again on disconnect.

### Virtual display compatibility

The macOS virtual display is exposed through the consented `agent_desktop` product
path. Its OS-exported display SPI remains a compatibility boundary. Creating it
can put a window from your current stage into the Stage Manager strip; external
monitors are untested. The old consent-free experimental engine commands and their
probe script have been removed. [The probe record](docs/agent-display-probe.md)
is historical evidence, not a command to run or acceptance of the product UI.

## Windows preview

The Rust engine in `native-win/` implements UI Automation trees, window capture,
indexed and coordinate clicks, drag, Unicode typing, plain-text paste, keys, scroll,
values and secondary actions. Ordinary Windows operation uses the foreground
(the limited [locked-parent patterns](#windows-agent-desktop) are an exception): input
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
using ordinary foreground input while the parent is unlocked and your desktop remains separate. The view
starts in **Watch only** mode: hovering does not forward mouse input. Click the
view to interact (the first click selects the mode); switching to another window
returns it to Watch only. The label shows the current mode. Server-requested local
cursor warps are disabled for the whole connection, including interactive mode;
this protection requires a supported RDP setting and passed the 0.4.0 VM acceptance.
Read fresh
app state after starting. `{"action":"status"}` reports state and availability;
`{"action":"stop"}` logs off the child apps, so save their work first.

Locking the parent screen keeps the child alive for reading and screenshots.
Only the locked child uses supported patterns for a single left indexed `click`
without modifiers or duration, `set_value` via ValuePattern, and listed
`perform_secondary_action`. Click chooses SelectionItem.Select, Invoke, Toggle,
ExpandCollapse (expand collapsed/partially expanded, collapse expanded), then a
nonempty MSAA default action. Selection uses capabilities, never control names.
It calls one action, with no synthetic-input fallback or replay. Missing patterns
return `UNSUPPORTED_ACTION`. Coordinate or modified/multiple clicks, typing, keys,
scroll, drag, paste, activation and batch waits still return `SCREEN_LOCKED`.
`get_app_state` may launch a child app without OpenCU activating it; this was
accepted on the VM.

Each completed pattern call returns fresh state/diff. A changed observation stops
any remaining batch actions because indexes were refreshed. No change or an error
after dispatch returns unknown outcome; explicitly read state before continuing.
An already issued call is never reported as a plain failure or replayed. A client
call still outstanding after its three-second deadline blocks further writes;
a provider timeout may return earlier without leaving a pending client call.
OpenCU sends no synthetic input on this path; provider implementations can differ.
The ordinary and unlocked paths are unchanged.

On 2026-10-21, from a clean Windows 11 26H2 VM checkpoint, the release package
passed verify-gui-win three times (40/40 each), the package verifier, and the
agent-desktop suite with `--locked-parent` behind the real lock screen. The locked
indexed Increment click (Invoke) changed 10 to 11, `set_value` (Value.SetValue)
produced "locked pattern value", `type_text` returned SCREEN_LOCKED, a launch while
locked did not take the foreground, and unlock kept the same child with no replay.
Hardware concurrency, parked-pointer, hover, Escape and close regressions also
passed. A locked indexed click on the text box returned UNSUPPORTED_ACTION in
about two seconds ([evidence](evidence/opencu-windows-agent-desktop-2026-10-21-v0.4.0.json)).

The child window is hidden by the lock screen, so nobody at the machine can see it. `status` reports `parentLocked: true` or `false`.
Unlocking does not restart anything: the same child and host window remain.
The agent must issue a new call, under the normal input rules.
The caller can stop it while locked by ending the MCP connection. After unlocking,
close the host window or click into its view and press Escape.

Closing the window or physical Escape inside its focused view permanently stops
that MCP connection. The agent must not reconnect or restart without your explicit
permission. A failed start or broken connection never falls back to your desktop.
After a failed start, app tools remain blocked until `agent_desktop` with
`{"action":"stop"}` finishes cleanup. This never clears a person's stop. The
[Windows contract](docs/windows-engine-contract.md#agent-desktop-040) separates the
measured VM results from the remaining provider and follow-up regression checks.

### macOS agent desktop

On 2026-10-21, the owner passed all **7/7** product acceptance checks on a Mac
with a **single built-in display and Stage Manager on**, before this branch was
rebased onto released v0.4.0. The run used a local copy of the verifier with
Chinese prompts; the fixture returned its own window via the
`move-to-main-display` command file, standing in for a person/app moving it back.
The [fixture-only evidence](evidence/opencu-macos-agent-desktop-2026-10-21.json)
records the checks, pass/fail and scope. The rebased 0.4.1 build has not had another
owner GUI run. In earlier owner runs, the first capture from a new build path
showed the macOS reminder once and correctly named “opencu”.

The same `agent_desktop({action: "start" | "stop" | "status"})` tool automatically
opens a small **OpenCU agent desktop** window and a virtual monitor. The preview is
always **watch-only**: clicking it never forwards input. The host, consent card,
Stop controls and activity badges follow the first preferred system language:
Simplified Chinese for zh-Hans/zh-CN/zh-SG, English otherwise. MCP text and error
codes stay English; Windows host text stays English in this release.
Start moves no app window.
An explicit `get_app_state` on a window outside the monitor presents **Move once**
and **Keep here** in that nonactivating window. The card expires after 60 seconds.
Declined or expired windows stay text-only/read-only for that desktop's lifetime.
Lock or request cancellation is not a decline; a later explicit read may ask again.
Full-screen, minimized and other nonmovable windows remain readable as reduced
text-only state, with the refusal reason in `opencu/agentDesktop` metadata. Internal
reads, waits and final action reads never ask or move a new window.

A new window already on the agent display can inherit admission from an admitted
window of the same process; OpenCU does not move it and records no return frame.
A window of a different process already there gets an **Allow this window for the
agent?** card on an explicit read. Approval admits it without moving or restoring
it. macOS chooses where such unmoved windows go when the virtual display is
removed. Declined or previously returned windows cannot inherit admission.

Move once permits that exact window's move and its disclosed return on stop,
close or MCP EOF. Every new move asks again. All input is restricted to admitted
windows still on the virtual monitor; `activate_app` is refused there. Return all
moved windows with the host or menu-bar **Stop**. To return just one, use that app's
own **Window > Move to** command for your display: activate the app first, or the
menu belongs to whichever app is in front. The same menu offers the agent display
for your own windows too; a window you move there yourself shows in the preview,
is not automatically available to the agent unless it inherits admission from the
same process as described above. Another process still needs an Allow this window
card. macOS relocates these unmoved windows when the agent display closes. The
invisible monitor cannot be dragged through the watch-only preview. The preview
floats above other windows without taking keyboard focus. If a window leaves the agent
display by any means, admission is revoked for this desktop lifetime and cleanup
leaves it where it went. No input is replayed. Apps, accounts, clipboard and files are
still shared with your session; this is not an isolation/security boundary.

Tool stop restores eligible windows, leaves apps and unsaved content open, and
confirms display removal from a fresh process. A later explicit start may ask
again. Closing the host, its **Stop** button or menu-bar **Stop** permanently latches
`STOPPED_BY_PERSON` for the MCP connection, including when no tool call is running.
Only status/cleanup remain available; never reconnect to bypass a stop. EOF also
cleans up. A crash relies on OS resource cleanup and cannot restore exact frames.

macOS pauses while locked (`SCREEN_LOCKED`, `status.parentLocked: true`) and keeps
ownership for cleanup. Unlock requires a fresh observation; queued input never
resumes. Preview errors and display-layout changes fail closed and clean up,
without recreating a worker/display or falling back to the person's windows.
Status/stop remain responsive while a consent card is waiting. The preview may
show macOS's screen-recording indicator for its lifetime. If the person stops
preview sharing through macOS, `STOPPED_BY_PERSON` latches; other stream failures
return `AGENT_DESKTOP_LOST` and clean up without restarting the stream.

Start and moves retain the quiet-desktop guard. Keep the pointer/foreground still
during start and for 2 seconds after **Move once**. A move waits one second after
the consent click before taking its baseline. If activity interrupts it,
`AGENT_DISPLAY_PERSON_ACTIVE` affects that move only: OpenCU restores that window,
keeps the other approved windows and the desktop, and leaves the target reduced.
A later explicit read may ask again; there is no automatic retry. If restoring that
window fails, cleanup fails rather than losing its recovery record. An interrupted
start fails cleanly and removes its display. One agent display
per GUI session; another connection receives `AGENT_DISPLAY_BUSY`.

On an authorized idle Mac, the owner can run the fixture-only acceptance:

```sh
node scripts/verify-agent-desktop-mac.mjs --owner-present
```

The script needs Stage Manager already enabled and existing OpenCU permissions.
It asks the person to answer consent cards and close the host; a fixture moves its
own window back to stand in for the person taking it back;
it never targets personal applications. See [ADR 0003](docs/adr/0003-macos-agent-desktop-virtual-display.md).

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
