# OpenCU on Windows

The Rust engine in `native-win/` implements UI Automation trees, window capture,
indexed and coordinate clicks, drag, Unicode typing, plain-text paste, keys, scroll,
values and secondary actions. Ordinary Windows operation uses the foreground
(the limited [locked-parent patterns](#agent-desktop) are an exception): input
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
([evidence](../evidence/opencu-windows-gui-2026-10-19-v0.3.2.json)).

Missing: text selection. Elevated windows, UAC prompts and secure desktops are refused (`ELEVATED_TARGET`, `SCREEN_LOCKED`); these
refusals have not been checked on a real desktop yet. Controls without accessible
names, common in media players, are listed with an index and bounds but need a
screenshot to tell apart. v0.3.1 acceptance is 30 checks on disposable WinForms
and Chrome fixtures, including drag and idle foreground acquisition, in three
consecutive runs on a fresh Windows 11 x64 VM, plus the 10-second rule and
physical Escape checked with host-injected input
([evidence](../evidence/opencu-windows-gui-2026-10-19.json)).

## Install

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
follow the [host integration contract](host-integration.md). Building the
package, its offline checks, error codes and safety behavior are in the
[Windows contract](windows-engine-contract.md).

## Agent desktop

After installing 0.4.0 or later, run this once from a **normal**, non-administrator terminal:

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
about two seconds ([evidence](../evidence/opencu-windows-agent-desktop-2026-10-21-v0.4.0.json)).

On 2026-10-22 the 0.5.0 package passed the same clean-VM regression: verify-gui-win
three times (40/40 each), the package verifier, the agent-desktop suite with and
without `--locked-parent`, and the hardware-input, hover, Escape and locked-parent
checks. With real Hyper-V clicks, the title-bar close button only minimized the
host while the child kept working and could still be captured; the taskbar button
brought it back; **Stop** then logged the child off, and every later call returned
`USER_STOPPED` with no reconnect. Keep on top, maximize, clean view and leaving
clean view from the title-bar menu behaved as described below
([evidence](../evidence/opencu-windows-regression-2026-10-22-v0.5.0.json)).

The child window is hidden by the lock screen, so nobody at the machine can see it. `status` reports `parentLocked: true` or `false`.
Unlocking does not restart anything: the same child and host window remain.
The agent must issue a new call, under the normal input rules.
The caller can stop it while locked by ending the MCP connection. After unlocking,
press its **Stop** button or click into its view and press Escape.

The host is an ordinary window: it can be resized, minimized or maximized, kept on
top, or switched to a clean view without its bar (both choices are also in the
title-bar menu). Closing it only minimizes it to the taskbar; the child keeps
working. To keep a minimized view from pausing the child, the host sets the
per-user Remote Desktop client value `RemoteDesktop_SuppressWhenMinimized` to 2
(`HKCU\Software\Microsoft\Terminal Server Client`); your own minimized Remote
Desktop windows then keep updating too. Its **Stop** button or physical Escape inside its focused view permanently
stops that MCP connection. The agent must not reconnect or restart without your explicit
permission. A failed start or broken connection never falls back to your desktop.
After a failed start, app tools remain blocked until `agent_desktop` with
`{"action":"stop"}` finishes cleanup. This never clears a person's stop. The
[Windows contract](windows-engine-contract.md#agent-desktop-040) separates the
measured VM results from the remaining provider and follow-up regression checks.

Limitations are in [Limitations](limitations.md).
