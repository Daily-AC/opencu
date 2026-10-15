# Independent engine implementation contract

OpenCU provides original native engines using macOS frameworks and Windows APIs.
No OpenAI SDK, executable, account, signature allowlist, turn metadata or daemon is part
of the runtime. The [Windows contract](windows-engine-contract.md) records phase-1
behavior and its pending real-desktop acceptance.

Each native executable speaks JSON lines on inherited stdin/stdout. Requests are
`{id, method, params}`; responses are `{id, result}` or
`{id, error: {code, message}}`. Diagnostics go to stderr. One request runs at a
time. There is no network listener and no caller-brand identity check.

`Types.swift` owns common error, target app, window snapshot, menu effect, AX
helpers and observation types. `MacObserver` owns `listApps() -> [[String: Any]]`,
`resolveApp(_:launch:) async throws -> TargetApp`,
`observe(_:includeScreenshot:) async throws -> Observation` and
`record(_:pid:)` for menus the caller opened. `InputController` owns
`perform(method:args:snapshot:) async throws -> MenuEffect`. Both classes are
MainActor isolated. The root dispatcher owns the latest observation and routes calls.

Observation JSON has `text`, `app: {id, displayName, pid}`, and optional
`screenshot: {data, mimeType, width, height}`. Screenshot data is inline base64.
Coordinates are pixels in the captured window, mapped to the observed bounds.
Element indexes belong only to the latest observed application/window.

macOS Accessibility and Screen Recording permissions remain required. Setup
requests those through the standard OS flow; it never edits permission databases.
MCP caller approvals remain the caller's responsibility. Local invocation is not
restricted to Codex or any other agent. No proprietary lock-screen unlock path
is carried over.

Pointer routing uses the system-exported CGEventSetWindowLocation SPI after
public NSEvent/CGEvent creation. Actual received events showed that public
creation alone left the window-relative point at an invalid sentinel. Resolve
the system symbol locally, fail clearly if unavailable, and retain target-PID
routing and all normal OS permissions. Do not add a global input fallback.

## Direct-host safety contract

An engine can be spawned by any host over inherited stdio; the MCP server is an
optional adapter. The engine must enforce observation/window identity, finite
in-image coordinates, and latest screenshot geometry without relying on Node.
A state/action attempt consumes the prior coordinate grant, even on failure;
only successful capture renews it. Inventory/doctor calls do not consume it.
Text-only observations cannot renew screenshot coordinates. Hosts must never
retry input automatically and must inspect state after a partial failure.

Windows phase 1 enforces this in the engine, plus PERSON_ACTIVE interruption,
foreground checks, token-integrity checks, and interactive-session/secure-desktop
refusals. Error code names are stable and documented in the Windows note.

macOS already checks captured dimensions, exact window identity/current bounds,
lock state and AX permissions in its engine, and consumes screenshots before
input execution. Known parity gaps remain: app resolution/permission failures
can precede native screenshot invalidation, and real human activity does not yet
abort every input method with PERSON_ACTIVE (the focus guard only stops its own
foreground restoration). Node already invalidates its coordinate state earlier.
The macOS engine is unchanged in this phase; direct hosts must not interpret this
note as evidence that those parity gaps have been fixed or accepted.

## macOS remote panels and applications without windows

An indexed element is authorized by its live attachment, not by its PID. The
observation stores the complete `AXChildren` path from either the selected AX
window/sheet or the target application's `AXMenuBar` to each indexed element. The
window root is resolved from the target application's focused window, main window,
or sole window, in that order. Before an action, the engine checks the application's process lifetime, checks that the
same window is still selected (or that the application still has no window),
resolves the menu bar again, and rechecks every child edge by AX element identity.
An inaccessible or missing edge fails closed. `AXFocusedUIElement` alone never
grants an index outside those observed paths.

This permits system Save/Open panel controls hosted by another process when
macOS exposes them beneath the target's selected window. The exception is not
based on a service name, signing team, caller brand, equal PID, window title or
geometry. Controls in an unrelated app, another window of the same app, another
panel hosted by the same service, or a dismissed/detached panel do not qualify.
Changing the selected window invalidates the old window snapshot. Re-read the
state after a panel opens or closes before continuing.

Indexed AXPress, set_value and select_text use the authorized AX element directly.
A simple indexed click on an editable remote control uses its settable AXFocused
attribute. This focus operation alone does not establish background keyboard
delivery. Before `press_key`, `type_text` or `paste` sends any events, the engine
reads the live focused-element owner and the selected window's role/AXIdentifier.
In the background it refuses with `BACKGROUND_REMOTE_FOCUS` if either:

- The focused owner is positively a different PID; or
- The selected AXWindow/AXSheet has identifier `save-panel` or `open-panel`, or a
  window/sheet with one of those identifiers occurs on the focused element's
  recorded `AXChildren` path, revalidated against the currently selected window.

The second rule is deliberately about system file-panel identity, not a claim
that AX exposes the actual hosting process. On macOS 26 the proxy can report the
host PID. It also works without a readable focused element when the selected
root itself identifies the panel. Identifiers on unrelated windows, stale paths,
ordinary text controls or running service processes do not qualify. This is only
a keyboard refusal rule; it never authorizes an indexed action. A local custom
window/sheet using these system panel identifiers will also be refused in the
background. Ordinary local text controls/sheets without them keep their existing
background input behavior, including when their focused owner is unreadable.

The message directs callers to indexed `set_value`, exposed AX actions, or
explicit `activate_app` for keyboard input. Foreground keyboard input retains the
existing PID-targeted path even with these panel identifiers or a different PID.
Synthetic AppKit activation is not foreground status. The guard runs before
synthetic focus, again before each character/chord, and before paste changes the
clipboard. If focus changes during a multi-character operation, input already
sent is not replayed. The engine never automatically activates the app.

Remote pointer fallbacks (including held,
modified or multiple clicks and scrolling) are refused rather than guessing a
WindowServer ID or sending the event to the host window. Coordinates retain the
existing exact window ID and screenshot requirements.

A windowless snapshot contains only the target's menu bar and an explicit note;
requesting a screenshot still returns that text, without an image. Only AXWindow
and AXSheet roots count as windows (Safari selects its Save sheet directly).
Finder's desktop scroll area in AXFocusedWindow does not.
Multiple unselected windows remain ambiguous, and minimized windows remain an
error. A real AXWindow with no WindowServer ID is not treated as windowless.

Indexed menu actions need no window ID. `press_key` can send application shortcuts
such as Cmd+N and Cmd+O with application-local focus notifications whose window
number is zero when no window exists. There is no foreground activation or global
input fallback. The next action must observe a newly opened window first; typing,
paste, physical pointer input and screenshots do not gain a windowless fallback.
Synthetic application focus is released on target changes and disconnect as before.

`scripts/verify-gui.mjs` covers a real NSSavePanel sheet saving exact fixture bytes
inside a temporary directory, refusal of all three background remote keyboard
methods (plus a keyboard batch), unchanged filename and clipboard change count,
completion through `set_value` and AXPress, dismissal,
window/app isolation, all windows closed, File > New / Open, Cmd+N / Cmd+O, and
NSOpenPanel keyboard refusal and cancellation. Windowless shortcuts are checked by command counters,
visible windows and observed controls, not just successful replies. The suite
also checks the foreground sentinel and removes the
temporary saved files. The attachment logic has non-GUI checks for foreign and
same-process windows, detached edges, and shared remote-service PIDs. Compilation
and these logic checks do not establish remote-view forwarding or windowless
AppKit event delivery: those require the GUI acceptance run on an authorized idle
desktop. Do not run that suite on an occupied Mac without the owner's approval.

Measured on the owner's idle Mac on 2026-10-14: three GUI runs passed the ten
pre-existing background checks and the remote filename `set_value` step. Clicking
the filename then sending Cmd+A and `type_text` returned success but left its
value unchanged. No later new checks ran. In the paired MacArena VM benchmark,
with the target frontmost in the guest, remote-panel keyboard input did work
(including Cmd+Shift+G, path paste and path typing). Thus live AX attachment is
sufficient for the tested indexed value edit, but background remote keyboard
forwarding is not supported. The new refusal and the remainder of the panel and
windowless GUI suite still require reviewer desktop acceptance; non-GUI tests do
not verify delivery. Foreground support here is based on the VM evidence, not a
new foreground run on the owner's Mac.

Reviewer follow-up on macOS 26.6.2 (2026-10-14 00:45): three further runs again
passed the ten old checks, but the PID-only refusal failed. Instrumentation found
the filename AXTextField reporting the target PID. The saved fixture state shows
an AXSheet with `AXIdentifier="save-panel"`. The macOS 15.6 VM traces also show
that identifier on Save sheets, and `open-panel` on Open windows, despite panel
controls reporting a separate PID there. These observed, nonlocalized panel
identifiers now provide the second pre-send signal; no speculative remote-view
attribute or service-name lookup is used. The suite asserts the panel identities,
background refusal and unchanged field/clipboard, then saves via AX operations.
Future OS versions exposing neither a remote PID nor these identifiers are outside
this detection rule; no general post-input effect detector is claimed. Unknown
focus in ordinary apps keeps the previous PID-targeted behavior so that input
which worked before this change is not newly refused.

Reviewer GUI run on macOS 26.6.2 (2026-10-14 00:55, owner away, foreground sentinel
in front): after the suite waits for asynchronously opened windows in a fresh
observation instead of the action's immediate reply, 10 consecutive runs passed all
18 checks (about 40 s each), including the Open panel's `open-panel` identity and the
windowless File > New / Open, Cmd+N / Cmd+O flows. One earlier run timed out waiting
for the save to complete after AXPress on Save; it did not recur in the next 10
runs, and the suite now prints the fixture state and tree if it does.


## macOS presence and person stop

The stdio engine runs an AppKit event loop with accessory activation policy.
No UI is created for `doctor` or `list_apps`. App-targeting calls show a non-template
monochrome V status item, with the last app name, Stop and Permissions. It
expires 15 seconds after the last app call completes; an in-flight call keeps
Stop available even during a 30-second hold. An open menu stays until dismissed
so its Stop item cannot disappear under the person. Timers use monotonic system
uptime and run during menu tracking. Disconnect removes the item, cursor and setup.
Each engine process owns one connection and one irreversible stop latch.

`STOPPED_BY_PERSON` is a stable error code. It rejects `click`, `drag`, `scroll`,
`press_key`, `type_text`, `paste`, `set_value`, `select_text`,
`perform_secondary_action`, `activate_app`, and `get_app_state` with
`includeScreenshot: true`, before app resolution or permission checks. Text-only
`get_app_state`, `doctor` and `list_apps` remain allowed; a stopped text read does
not launch a missing app. The MCP batch stops on the first error and preserves
the code. The adapter also latches it before coordinate validation so subsequent
input cannot obscure Stop with a stale-screenshot error. Hosts must not reconnect or retry automatically, including on another
engine instance; a new connection is appropriate only after the person explicitly
allows it. A new connection starts with a fresh latch.

Stop cancels a currently suspended input/capture task. Input's existing defers
release held buttons/modifiers and restore an unchanged clipboard. Input checks
the latch again during validation and waits; capture checks it before capture and
after the async result, and dispatch checks it before returning. A completed input
or already submitted capture cannot be undone; a capture completing after Stop is
not returned. Synchronous AX IPC can delay processing a menu event until AppKit
regains control. This is a person-operated stop, not general human-activity
interruption or a security boundary against a malicious client.

InputController reports delivered pointer positions through one callback. The
visual arrow uses the same screenshot-pixel to AX-screen-point conversion as
input, then converts CG's top-left origin to AppKit's primary-display bottom-left
origin. Movement is a clamped 250 ms cubic ease-out; clicks pulse for 300 ms.
Pointer inactivity hides it at 3 seconds. Changing app/window, Stop and EOF hide
it immediately. The cursor is clipped to the target bounds; windowless/menu-bar
AX actions or elements without an exact visible window/usable centre cannot show
a cursor. Hidden, resized or moved targets suppress it until a fresh pointer event.

The transparent borderless nonactivating panel ignores mouse events, cannot be
key/main, has no window shadow, and never calls activation or real-cursor APIs.
Its tiny clipped frame avoids an overlay the size of the entire target. Its
level matches the target, and it is ordered immediately above that window with
[NSWindow.order(_:relativeTo:)](https://developer.apple.com/documentation/appkit/nswindow/order(_:relativeto:)).
The relationship is refreshed while visible so covering windows stay above it.
No child-window relationship is established with the other process.

The overlay has `sharingType = .none`. OpenCU additionally captures only the exact
foreign target via `SCContentFilter(desktopIndependentWindow:)`, with child windows
disabled on macOS 14.2+, so exclusion does not rely solely on sharingType. OpenCU
processes are excluded from its app inventory and cannot be targeted; window
identity and presentation checks continue to use the target's exact PID/window
ID, never the overlay. There is no new generic coverage heuristic. Actual capture
exclusion and cross-process ordering remain live reviewer checks, not established
by offscreen rendering.

The setup window uses standard AppKit controls and the same original monitor
glyph as the menu item and generated AppIcon.icns. English and Simplified Chinese
resources follow the system language. Both grants refresh once per second while
open. Each Allow button requests its own OS permission and opens the matching
Privacy & Security pane. No TCC grant is reset or modified directly. Because
Screen Recording preflight may remain stale, a grant/request in a process that
started without it conservatively asks for reconnection instead of claiming ready.
The Done button appears only when both grants report allowed.

`opencu setup` and Permissions activate the normal-level, centered setup window;
an automatic permission failure orders it without activating OpenCU. It opens
automatically at most once per process. Missing Screen Recording is now a tool
error (rather than text-only degradation); its message, like missing Accessibility,
says whether the setup window is still open and asks the agent to wait for the
person. Closing setup hides OpenCU if it is frontmost, without reactivating a
previously used app. Menu tracking and setup opening cancel the focus guard;
OpenCU becoming frontmost also cancels it, and the guard never restores OpenCU
as a foreground destination. Tool calls never activate OpenCU.

Offline review: `python3 scripts/render-presence.py` produces
`.cache/presence-review/` from the actual setup controls, glyph and cursor drawing
code, with no ordered windows, status items, capture or permission requests.
The menu images are layout previews from the actual NSMenu items, not screenshots
of a tracked system menu. Both languages and appearances include neither grant,
each individual grant, ready and reconnect states. `npm run build` generates the
icon before signing; release verification requires icon and both localization
resources in the extracted bundle.

Reviewer-only live acceptance (not run on an occupied Mac): verify no foreground
change during background calls; 1x/2x and multi-display cursor alignment, click/
drag/scroll/indexed centres, clipping, covering windows and the 3-second timeout;
capture while the cursor is visible and confirm absence; 15-second status timeout,
menu tracking and language; Stop during a long hold/typing/capture and all subsequent
methods including batches; EOF cleanup; setup's exact Settings links, live statuses,
reconnect guidance and closing focus. Use only disposable fixtures and follow the
project's desktop authorization rules. Offscreen/native logic checks do not prove
OS compositing, TCC prompting or real input delivery.
