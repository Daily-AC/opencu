# OpenCU on macOS

On macOS, OpenCU reads and operates app windows through Accessibility,
CoreGraphics and ScreenCaptureKit, and it can work in a background app while you
keep using the one in front.

**Status (v0.6.0):** source builds for Apple silicon. On the development Mac, 9 of
the last 10 runs of the 18-check background GUI suite passed, and it has completed
a handful of real tasks. Read [Limitations](limitations.md) before relying on it.

## What it does

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

## How it runs

OpenCU opens no network port. Each connection starts its own engine worker as a
launchd job, talking to the client over an authenticated local socket. The worker
exits when the client disconnects.

The pi coding agent can load OpenCU as an extension (tested with pi 0.83):
`pi -e ./adapters/pi/opencu.ts`. See the [pi adapter guide](../adapters/pi/README.md).

## Stopping it

In ordinary macOS mode, the V appears while an agent is using OpenCU and hides
15 seconds after its last call. Menu-bar **Stop** refuses input, activation and
screenshots with `STOPPED_BY_PERSON`; text-only reads remain available in that mode.

In **macOS agent desktop** mode the menu-bar item stays for the desktop lifetime.
Closing or minimizing the preview only puts it in the Dock; click its Dock tile to
watch again. The preview's **Stop** button, menu-bar **Stop**, or a macOS Stop
Sharing control for the preview permanently stops that MCP connection. All app
calls, including text reads, then fail; only desktop status and cleanup remain
available. Windows return to their recorded frames when eligible; apps and unsaved
content stay open. A tool-requested stop alone permits a later explicit start.
Agents should stop the desktop when their task no longer needs it; a macOS desktop
with no tool calls for 5 minutes stops itself the same way.

Stop does not undo delivered input and applies to its connection. Agents must
never reconnect around it without permission. It is a person-facing brake, not a
barrier against another local client or automation running as the same user.

The cursor hides three seconds after the last pointer action and the badge three
seconds after the last call. Neither appears in OpenCU's own screenshots.

## Agent desktop

On 2026-10-21, the owner passed all **7/7** product acceptance checks on a Mac
(macOS 26.6) with a **single built-in display and Stage Manager on**, both before
and after the 0.4.1 rebase and localization; the second run showed the Chinese
interface. The fixture returned its own window via a command file, standing in for
a person or app moving it back. The
[fixture-only evidence](../evidence/opencu-macos-agent-desktop-2026-10-21.json)
records the checks and scope. The first capture from a new build path showed the
macOS screen-capture reminder once, correctly naming “opencu”.

On 2026-10-22 the final 0.5.0 build passed all **8/8** checks on the same Mac in one
automated run that pressed only OpenCU's own consent card, preview buttons and Dock
tile through Accessibility, with fixtures only. It repeated the start, consent,
background input, manual return, tool stop and EOF checks. In addition, closing
and minimizing tucked the preview into the Dock and its tile brought it back; keep on top and clean view switched and were remembered; clean view kept the
agent display's shape; Stop latched; and an unused desktop stopped itself after
318 seconds and returned its window. Full-screen sharpness and the clean view's
hover were checked by the owner by hand
([evidence](../evidence/opencu-macos-agent-desktop-2026-10-22.json)).

The same `agent_desktop({action: "start" | "stop" | "status"})` tool automatically
opens a small **OpenCU agent desktop** window and a virtual monitor. The preview is
always **watch-only**: clicking it never forwards input. It is an ordinary window:
it can be resized, minimized, made full screen, kept on top with the pin button, or
switched to a picture-only clean view; its title bar returns on hover. Until then
its buttons are hidden from assistive technologies too; the menu-bar Stop remains. The picture
follows the window's size up to the virtual monitor's own pixels; the agent's
screenshots are captured separately and do not depend on it. The host, consent card,
Stop controls and activity badges follow the first preferred system language:
Simplified Chinese for zh-Hans/zh-CN/zh-SG, English otherwise. MCP text and error
codes stay English; Windows host text stays English in this release.
Start moves no app window.
An explicit `get_app_state` on a window outside the monitor presents **Move once**
and **Keep here** in the preview, bringing it back from the Dock if needed. The card expires after 60 seconds.
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
moved windows with the preview's or menu-bar **Stop**. To return just one, use that app's
own **Window > Move to** command for your display: activate the app first, or the
menu belongs to whichever app is in front. The same menu offers the agent display
for your own windows too; a window you move there yourself shows in the preview,
is not automatically available to the agent unless it inherits admission from the
same process as described above. Another process still needs an Allow this window
card. macOS relocates these unmoved windows when the agent display closes. The
invisible monitor cannot be dragged through the watch-only preview. The preview
opens without taking keyboard focus. If a window leaves the agent
display by any means, admission is revoked for this desktop lifetime and cleanup
leaves it where it went. No input is replayed. Apps, accounts, clipboard and files are
still shared with your session; this is not an isolation/security boundary.

Tool stop restores eligible windows, leaves apps and unsaved content open, and
confirms display removal from a fresh process. A later explicit start may ask
again. The preview's **Stop** button or menu-bar **Stop** permanently latches
`STOPPED_BY_PERSON` for the MCP connection, including when no tool call is running;
closing the preview does not. With no tool call for 5 minutes, and no pending
consent or lock, the desktop stops itself like a tool stop; the next app call returns
`AGENT_DESKTOP_IDLE_STOPPED` without sending input, until `agent_desktop` is called again.
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

You can keep using the Mac while the desktop starts and windows move. A move stops
only if you start using that window: its app comes forward, or a mouse button is
held over it. Then `AGENT_DISPLAY_PERSON_ACTIVE` affects that move only: OpenCU restores that window,
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
It asks the person to answer consent cards and use the preview's window controls; a fixture moves its
own window back to stand in for the person taking it back;
it never targets personal applications. See [ADR 0003](adr/0003-macos-agent-desktop-virtual-display.md).

Limitations that apply on macOS are in [Limitations](limitations.md).
