# Experimental agent display probe

This is a feasibility experiment, not a claim that macOS offers an invisible or
isolated desktop. Reviewer run 7 on 2026-10-16 passed all window/input checks and preserved the
foreground and pointer; only display-removal observation failed (the subsequent
idempotence check did not run). The fresh-process removal fix below has offline
checks only; live revalidation is left to the reviewer.
It does not introduce MCP tools or consent UI.

## Direct engine API

Run `bin/opencu engine`. Each line is `{id, method, params}`; responses use the
existing `{id, result}` / `{id, error}` contract. Errors from window relocation include structured `error.data.move` diagnostics.
One connection owns at most one
display and one outstanding window restoration. Methods are:

| Method (all prefixed `experimental_agent_display_`) | Parameters | Result / behavior |
| --- | --- | --- |
| `create` | `{}` | Create a 1728 × 1117 point, 60 Hz display at the main display's 1x/2x backing scale. Refuse mirrored/unsupported layouts or an outstanding display/restoration. |
| `move_window` | `{app: "bundle ID or .app path"}` | Resolve an already-running app's selected ordinary window; record its AX identity, matched WindowServer ID and original frame/display before any write (including off-stage windows). Move only that window. Refuse a second move until restored. |
| `restore` | `{}` | Restore the recorded window, even if selection changed. Verify process/window identity and the original display still exists. Never substitute another window. Idempotent after success. |
| `destroy` | `{}` | Attempt restoration, release the display even if restoration fails, wait for removal, return `ok` and `cleanupErrors`. Repeated calls are safe. |
| `status` | `{}` | Online display IDs, Quartz frames, main/mirror flags and pixel dimensions; requested/actual agent placement; target AX/WindowServer frames, original frame/display, intersecting display IDs, on-screen flag and restoration state. |

Status also returns title-free WindowServer frame records with owner names for ordinary windows,
Dock-level and main-menu-level windows, for movement warnings. Every warning includes
`beforeOnScreen`, `afterOnScreen`, `beforeSize`, owner, PID and before/after frames;
unknown visibility stays null and zero-size helper windows remain distinguishable. These are
private local evidence, not publishable app inventories. Mutation attempts discard
that engine connection's observation and coordinate grant. Observe again before
input. Direct display calls and ordinary MCP input must be serialized; they must
never operate the same app concurrently.

## API boundary and placement

`AgentDisplaySPI.swift` is original Swift code using runtime class lookup and
checked Objective-C method implementations for `CGVirtualDisplay`, its descriptor,
settings and mode. Missing classes, selectors or unexpected argument/return ABI
fail closed. No private headers, proprietary runtime, agent identity checks,
driver, helper daemon or display-preview window are bundled.

[DeskPad](https://github.com/Stengo/DeskPad) was inspected after checking its
[MIT license](https://github.com/Stengo/DeskPad/blob/main/LICENSE.md). No implementation
was copied. Its handwritten mode declaration differs from Chromium's binary-derived
32-bit declaration; the bridge uses the latter and verifies it at runtime.
[Chromium's implementation](https://chromium.googlesource.com/chromium/src/+/HEAD/ui/display/mac/test/virtual_display_util_mac.mm)
also establishes logical mode dimensions under HiDPI, nonzero vendor/unique serial
requirements, and ownership-based removal. Its removal workaround documents flaky
first-removal timeouts. OpenCU does not reproduce that workaround by creating an
extra display; it reports a removal timeout instead.

The descriptor has a fresh random serial, sRGB primaries, a nonzero vendor/product
and pixel capacity of 1728 × scale by 1117 × scale. Mode dimensions are 1728 × 1117
logical points. The engine checks the resulting size and backing scale.
Public `CGBeginDisplayConfiguration`, `CGConfigureDisplayOrigin` and
`CGCompleteDisplayConfiguration(.forSession)` position only the new display.
No main-display, mode, mirroring, permanent-settings, Dock or menu-bar mutation is
requested for any existing display.

Placement tries the main display's bottom-right, bottom-left, top-right and
top-left corners in Quartz global coordinates, without overlap or a shared edge
with an existing display. If none is free it refuses. macOS may normalize corner adjacency; status
reports both requested and actual frames and `placementAdjustedByOS`. Any accepted
placement remains nonoverlapping and non-main. Pointer isolation is **not**
guaranteed. Relocation first uses the exact AX window ID when available. Otherwise it matches
only within the app PID using AX title and bounds against `CGWindowList` with
`.optionAll`; it never filters by on-screen state. Unique title matches allow
Stage Manager-transformed bounds; duplicate title/bounds matches fail closed.
This experimental correspondence does not change ordinary input/capture identity
checks. AX initialization gets a bounded read-only wait. After AX writes the engine
waits up to five seconds for the requested AX frame and for WindowServer to report
the same window on screen inside the agent display. `lastMove` / `error.data.move`
retain pre/post AX attributes and errors, CG candidates, each write result, and the
observation timeline with frame, display IDs and on-screen flags. If macOS refuses
to move/render it, the failure records what happened without automatic replay.

The window gets 64-point margins and retains its size if it fits;
oversized windows are clamped, with their original size preserved for restoration.

Creating a display is equivalent to attaching a monitor: WindowServer may react
before OpenCU can position or validate it. The engine checks original display
frames/main identity after creation, and removes the new display on unexpected
display-layout changes. Other-app window movement is reported as a warning with
owner name, PID and before/after frames: it may be caused by the person, app
animation or display reconfiguration, and the probe cannot establish causality.
It never moves other windows back itself. Target restoration remains a strict check.
These checks cannot prevent a transient rearrangement, detect every rebuilt
system window, or guarantee that the Dock/menu bar never appears on the new
screen. The live reviewer must assess those effects.

**Measured stage side effect (reviewer run 6, 2026-10-16):** the create-step warning
in `.cache/agent-display/run-4BTWD7/report.json` records Google Chrome changing from
`(297,208), 952×727` to `(16,646), 133×141`, before `move_window`. The reviewer
identified this as their on-stage Chrome window moving into the Stage Manager
strip, with the pointer untouched. The stored on-screen flags were null, so they
must not be retrospectively called true or false. Preserving physical display
frames/main identity did **not** preserve the person's stage.

Each new probe report includes this historical measurement separately in
`stageSideEffects.previousMeasurement`, and records current large-to-thumbnail
contractions as candidates with phase labels. The geometry heuristic alone does
not prove a Stage Manager transition. No documented CoreGraphics configuration
flag or inspected virtual-display descriptor/settings property preserves the
existing stage when attaching a display. `initWithDescriptor:` attaches the
display before OpenCU can set its origin; `.forSession` controls configuration
persistence, not WindowManager staging. There is no verified way to avoid this
effect with the current approach. This is a feasibility limitation, not solved
by corner placement. No Stage Manager or Spaces setting is changed.

## Lifetime and cleanup

The controller holds the sole owning reference to the `CGVirtualDisplay`; no
termination block captures it. Objective-C ownership releases its display resource
when the object is deallocated, as demonstrated by Chromium's strong-map erase
followed by waiting for display removal. Normal `destroy` drops that reference
inside an autorelease pool, then confirms disappearance using a **fresh process
for every query**, for up to ten seconds. `lastRemoval` includes the display ID,
`elapsedMs`, `checks`, `timeoutMs`, `removed`, the observation mechanism and
reconfiguration events retained for diagnostics only. A timeout or query failure
preserves the display ID for later cleanup; it is not success.

The hidden `opencu-engine --online-displays` mode emits one versioned JSON object
with display IDs, frames, main/mirror flags and pixel dimensions. It branches
before `NSApplication.shared`, responsibility respawn, AX, capture, permission
preflight/request and setup. It does not create a window or display. `destroy()`
uses `posix_spawn` of the same signed executable with a stdout pipe and `/dev/null`
stdin/stderr, never LaunchServices or `open`. Other client/engine descriptors are
closed on exec. Each query has at most two seconds, bounded by the remaining
removal deadline, and output is limited to 64 KiB. A timed-out/invalid child is
killed and reaped. JSON schema, identities and geometry are validated; a query
error cannot masquerade as an empty display list.

Queries run off the main actor with a 250 ms interval while the removed ID is
still present. Once a fresh process confirms absence, the returned cleanup status
uses that same fresh display snapshot. All later inventory reads in this engine
connection (including status and repeated destroy) also use fresh processes, so
they cannot reintroduce the stale display through the owner's cache. Explicit
destroy, failure cleanup, EOF and signal cleanup share this path. There is no
other wait-for-display-disappearance path. A fresh process still listing the ID
at the ten-second deadline is a real failure. No extra display is created as a
removal workaround.

**Reviewer run 7**, `.cache/agent-display/run-407s2d/report.json`, 2026-10-16
04:14 local: Stage Manager, background fixture launch, display creation/layout,
move from the strip, full screenshot and pixels, indexed click, coordinate click,
shortcut/Unicode, menu, original-frame restoration, fixture exit, foreground and
pointer checks all passed. Display removal alone timed out at about 10030 ms;
the second-destroy check was not run. `lastRemoval.reconfigurationEvents` was
empty, despite main-thread begin/added callbacks during creation. The reviewer’s
external sampler saw two displays from 04:14:37 and one at 04:14:41, immediately
after restore at 20:14:41.042Z. The owning process never learned about its own
released virtual display. Run 6 had shown the same stale-view behavior.

Keeping a main CFRunLoop and registering display callbacks did not solve that
owner-specific cache behavior. They remain for normal event delivery and
diagnostics, not as removal evidence. Offline checks inject display sequences,
clock and sleep into the actual polling policy, and cover immediate/delayed
removal, a real timeout, invalid/failed/late queries, and bounded child transport.
The transport tests spawn a fake metadata child only, with no live enumeration.

## Capture boundary and the private-picker prompt

The complete macOS pixel path is `src/opencu-runtime.mjs` spawning the native
`serve` process, its disclaimed respawn, then `MacObserver.capture` calling
`SCShareableContent.excludingDesktopWindows`, constructing an exact-window
`SCContentFilter`, and calling `SCScreenshotManager.captureImage`. The non-picker
ScreenCaptureKit chain is the only pixel-capture path in this checkout. There is
no `CGWindowListCreateImage`, `CGDisplayCreateImage`, capture helper, `SCStream`,
`CGDisplayStream`, or `screencapture` CLI path. CG window/display **metadata** reads,
the cursor monitor, and decoding the fixture PNG do not capture pixels.
`CGRequestScreenCaptureAccess` occurs only in explicitly invoked setup.

Run 6's `mcp-1.json` contains the returned PNG. Read-only unified-log inspection
at 03:51:20 local finds replayd's shareable-content enumeration with `TCC Allow`
at `.682600`, `captureScreenshot` at `.801131`, another `TCC Allow` at `.807895`,
and a successful screenshot at `.829722`. These logs and the reviewer's subsequent
UserNotificationCenter prompt identify the direct SCK chain, despite an existing
grant; they do not identify a Node or bash pixel-capture implementation. Client
identity fields are redacted. Neither the old report nor those logs establish
the engine's responsible PID, or whether enumeration or capture queued the
asynchronous reminder. Attribution to “node” is the reviewer's observed dialog
label, not proof that Node executed the capture. The separate hub Keynote path
is outside this repository and was not audited as OpenCU code.

Previously `ownPermissions` trusted only `OPENCU_RESPONSIBLE_PROCESS`; capture
also proceeded if respawn setup failed and the caller's Screen Recording grant
passed preflight. Now `responsibility_get_pid_responsible_for_pid` is resolved
and checked at runtime, using the self-PID rule also used by
[Chromium](https://chromium.googlesource.com/chromium/src/+/refs/tags/133.0.6916.0/base/process/process_info_mac.cc).
Capture requires both the respawn path and OS-confirmed self responsibility;
unavailable/failed/mismatched attribution returns `CAPTURE_RESPONSIBILITY_UNVERIFIED`
before SCK. `doctor.captureContext`, direct error data and MCP
`opencu/errorDetails` record the actual engine PID, responsible PID and policy.

There is no supported non-prompting preflight for the private-picker reminder.
The SDK exposes neither a suppression switch on `SCScreenshotManager` nor a
silent interactive picker. Apple's
[Persistent Content Capture entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.persistent-content-capture)
requires Apple's approval for VNC apps; it is not added to this locally signed
engine. The Apple forum page about the reminder was blocked by security
verification and is not treated as a verified workaround.

The reviewer rejected refusing all screenshots on macOS 15+: it removes the
engine's core capability to avoid a periodic system reminder. Capture requires
verified responsibility and an existing grant, checked before enumeration and
before capture. Run 6's unified log shows the reminder came from replayd's
`SCAlertStatsManager requireAlertWithCanonicalBundleID` (a per-identity
last-alerted date), not from a TCC request: both TCC checks returned Allow. Why
the dialog named "node" instead of OpenCU is still unexplained; the doctor path
spawned from Node reports a self-responsible engine. No legacy API, CLI, prompt
suppression, automatic permission request or automatic input retry is used.

EOF, a broken stdout pipe and SIGINT/SIGTERM/SIGHUP run the same cleanup on the main actor, after any
in-flight request unwinds. Shutdown releases synthetic focus, attempts the saved
frame restoration, then releases the display regardless of AX failure. Failed
restoration retains the original frame and is reported, rather than silently
losing recovery information. Failed `create` also releases any allocated display.
There is no persistent display owner after the engine process exits. On a crash
or SIGKILL the WindowServer client connection dies; resource removal is expected
from that process-scoped lifetime, but **exact window restoration cannot run**.
macOS may relocate windows when a display disappears. This private API has no
Apple-supported crash-cleanup contract; removal timing, abrupt-exit behavior and
absence of leaked displays still need live confirmation on the reviewer's OS.

## Reviewer run and evidence

On an authorized idle Mac, with Stage Manager already on and OpenCU's Accessibility
and Screen Recording grants already present, from this worktree run:

```sh
node scripts/probe-agent-display.mjs
```

On the owner's macOS 26, the screenshot check is now expected to fail clearly
before capture and enter cleanup; it must not pass based on the old PNG evidence.
This still exercises create/move/restore/removal for reviewer revalidation.

The script uses `bin/opencu engine` for the experimental API and a separate normal
`bin/opencu` MCP connection for observation/input. It compiles a disposable AppKit
fixture, launches it through `open -g -n -a` with `--stage-managed --background`
and no redirected LaunchServices streams (no Stage Manager bypass or activation
request), and operates only that fixture. Its unique per-run bundle ID resolves
the app PID for cleanup; the `open` process is not the fixture. It never activates a
sentinel or target, switches Spaces, or changes Stage Manager settings.
Reviewer fix `a28ace1` is retained: `--stage-managed --background` orders the
fixture window front without activating the app. Run 5 showed that `orderBack`
left this fixture absent from AXWindows, unlike a real off-stage TextEdit window;
run 6 verified AX visibility, relocation, full capture and restoration after the fix.
Discovery accepts `lsappinfo find`'s named ASN, empty-name `ASN:0x0-0x…-:`, and bare forms, and
records raw discovery/PID responses in the evidence. A fixture-only live diagnosis
found the state file present after about 1.16 seconds with one visible window and
no foreground change; the earlier timeout was ASN parsing, not lost launch arguments
or Stage Manager suppressing the state file.
A read-only helper samples the actual cursor location every 20 ms before the
baseline and throughout cleanup. It creates no windows and posts no events.
Before the first check, it waits for one second of stable foreground samples and
records that baseline separately from startup transitions. A baseline owned by
UserNotificationCenter or SecurityAgent stops the probe before launching the
fixture or creating a display, with an explicit system-dialog message.

| Check | Evidence / meaning |
| --- | --- |
| Stage Manager and background launch | Recorded preference; fixture launch state and foreground samples. |
| Create / move | Original and actual display arrangements, main flag, surviving window/Dock/menu frames, exact target ID, fixture-reported display ID. |
| Full screenshot | Normal MCP PNG; AX and WindowServer full-frame agreement, decoded pixel dimensions at the expected scale, known blue fixture canvas pixel. |
| Indexed click | Fixture counter increments exactly once after AXPress. |
| Coordinate click | Fresh screenshot coordinates, paired mouseDown/mouseUp with matching fixture-local coordinates. |
| Shortcut / Unicode | Cmd+A produces the exact selected range; typing produces exact Unicode text including emoji and accented text. |
| Menu | Nested menu action increments the counter; recorded action title and zero menu tracking events. |
| Restore / destroy | AX frame, fixture frame/display return to baseline; agent ID disappears; original display arrangement matches; second destroy succeeds. Other-app movement is a warning with its owner, not a failed arrangement check. |
| Foreground / exit | `lsappinfo front` scheduled every 50 ms from before compilation through cleanup; fixture exits. Actual sample times and maximum sampling gap are recorded. |

Any foreground change, cursor movement or sampling failure aborts further probe actions and cancels
the active MCP request. Already-dispatched input cannot be retracted. Native creation/relocation also
rechecks foreground and pointer position before subsequent geometry writes;
restoration/removal remain available during cleanup. Cleanup
closes the MCP input connection before restoring geometry, then restores, destroys,
closes the owning engine and terminates the fixture. Ctrl-C takes that same path;
no input is replayed. Engine shutdown has bounded TERM/KILL escalation if EOF
cleanup stalls. Temporary fixture files are removed. JSON evidence, fixture-state
snapshots and PNGs remain in ignored `.cache/agent-display/run-*/`; `latest.json`
points to the report. The final table distinguishes PASS, FAIL and unrun checks.
Sampling can miss changes shorter than its measured interval; it is evidence,
not a universal no-focus-steal guarantee.

## Consent and unanswered live questions

Production policy is to ask the person **before every window move**. Without
consent, retain the existing Stage Manager limited mode. This probe deliberately
does not implement that UI or claim that invoking its experimental methods is
production consent handling.

Only a live run can answer whether Stage Manager leaves a moved window fully
rendered/key-capable on this display; whether arbitrary apps such as Keynote behave
like the fixture; whether the pointer can cross the normalized boundary; what
Mission Control, Spaces, screen sharing and recording expose; whether Dock/menu
placement or other windows change transiently; and whether removal remains reliable
on disconnect, crashes, lock/unlock and sleep. Passing this fixture proves its
measured operations only. It does not establish invisibility, security isolation,
or support across macOS releases.
