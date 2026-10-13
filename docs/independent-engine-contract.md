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
reads the live `AXFocusedUIElement` owner. If that PID differs from the target's
PID and the target is not the system's frontmost application, it refuses with
`BACKGROUND_REMOTE_FOCUS`. The message directs callers to indexed `set_value`,
exposed AX actions, or explicit `activate_app` for keyboard input. When the focused
owner cannot be read (some apps report no focused element in the background, and
windowless apps have none), input keeps the existing PID-targeted path, so
application shortcuts still work. The frontmost remote-panel path retains its existing PID-targeted input.
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
NSOpenPanel cancellation. Windowless shortcuts are checked by command counters,
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
