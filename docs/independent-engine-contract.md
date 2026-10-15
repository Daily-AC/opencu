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
ordinary text controls or running service processes do not qualify. These signals
never authorize an indexed action; pointer refusals below use the selected panel
or a panel on a revalidated window path at the pointer location. A local custom
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

Background screenshot-coordinate click, drag and scroll into a system Open/Save
panel also return `BACKGROUND_REMOTE_FOCUS`, before synthetic focus, modifiers or
pointer events. Indexed clicks and scrolls aimed at a live panel element are not
refused: they were measured to work on the GUI fixture's save sheet, while
coordinate input had no effect on Keynote's (2026-10-15). A selected AXWindow/AXSheet identified as `save-panel` or
`open-panel` qualifies regardless of the PID its AX proxy reports. If the app
keeps its document selected, a panel on a recorded `AXChildren` path must still
be attached to that exact document and intersect the pointer point or drag
segment. A drag crossing the panel qualifies even if its endpoints are outside;
a menu-bar path, detached panel or another window's panel does not. The guard is
checked again after asynchronous focus preparation and before the first event.
The message says the panel needs the app in front (`activate_app`) or a person;
indexed `set_value` and exposed AXPress remain available. No success is inferred
from AXConfirm or a disabled OK button; inspect the resulting state.

Foreground coordinate delivery retains its existing path. Unknown panel
identifiers outside the selected root/live recorded paths are outside this
rule; it does not discover arbitrary unobserved remote UI. Indexed pointer
fallbacks to positively foreign-PID controls (including held, modified or
multiple clicks and scrolling) retain `TARGETED_MOUSE_UNAVAILABLE` rather than
guessing a WindowServer ID or sending events to the host window. Coordinates
retain the exact window identity and fresh screenshot requirements.

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

## macOS windows exposing only decorations

Before synthetic focus or physical pointer/keyboard events, classify the selected
window using its latest filtered observation: `WindowSnapshot.elements`,
`elementPaths`, and role/label/action traits saved for those same indexed nodes.
Use the pure `observedWindowIsOpaque` function; do not re-read raw AXChildren or
compare children with AXCloseButton/AXZoomButton attribute identities.

A window is opaque when every indexed descendant is a title-bar button or lies
beneath one in the printed tree. A title-bar button here is an unlabelled direct
printed child with role AXButton and AXPress, optionally AXZoomWindow, and no
other listed actions. Its descendants, including the zoom button's nested
unlabelled groups, remain decorations. Filtered layout wrappers do not change
printed ancestry. Labels use the same title, description, identifier,
placeholder, readable value and kind fields as the listing; passive actions
omitted by the observer are omitted here too.

Any other printed content (a labelled empty group, ordinary labelled button,
static text, or even a single unlabelled text field) makes the window non-opaque.
The window's own title/AXRaise and the separate application menu bar do not count
as content. A root-only window is opaque; a windowless observation is not.
Missing root/path/trait data is not a valid opaque classification. Observation
filtering/truncation limits this policy to what was actually listed, not all
possible content in the app. An unlabelled direct content button with precisely
the title-bar action signature is indistinguishable here and is conservatively
treated as a decoration.

The observation warning and all relevant input guards use the same snapshot
classification, retained when a coordinate grant is consumed. Existing live
application/window and indexed-path validation still applies independently.
Refresh the app state to update the classification after content changes.

The stable error is `BACKGROUND_INPUT_UNSUPPORTED`; its message explains that
the engine cannot verify where background input lands and recommends explicit
`activate_app` followed by a new observation. This conservative boundary covers
coordinate click, multiple/modified/held click and indexed pointer fallbacks,
drag, scroll, `press_key`, `type_text`, and `paste`. Keyboard delivery is
rechecked for each character/chord and before clipboard mutation. Refusal occurs
before synthetic activation, modifier keys, mouse events or clipboard changes.
It consumes the prior coordinate grant like other failed actions. Remote-panel
refusals retain their existing error precedence.

Direct indexed AX actions (including menu items), value setting and selection
remain available under the existing live-attachment rules; AX clicks on these
windows skip synthetic focus. Reading and capturing remain available. Windowless
application shortcuts and foreground delivery retain their existing paths.
The rule deliberately also refuses ordinary empty AppKit windows with this AX
shape: the engine cannot verify their background pointer/keyboard destination.
It is not a general effect detector or a guarantee for other custom canvases.

Blender is the measured example: inactive button events refresh coordinates
from the person's real cursor, and key-window activation can order it forward.
The reviewer confirmed a click at the wrong location and 2.04 seconds of
foreground activation even on Blender's own full-screen Space. Treat Blender
as foreground-only. Do not repair this by moving the real cursor, activating or
raising the app implicitly, injecting target code, sending global input or
replaying input. Restoring the former foreground app afterwards does not undo
the violation. See [source analysis and measured limits](opencu-blender-2026-10-15.md).

WindowServer off-screen/thumbnail status must not be described as proof that
capture is unavailable. Report presentation status and the actual capture result
separately; a full screenshot is not proof of background input support.

## Unconfirmed AX actions and unsupported text selection

`AXUIElementPerformAction` returning `kAXErrorCannotComplete` (-25204) means the
outcome is unknown: the action can have replaced its own window before replying.
For AXPress, menu choices and exposed secondary actions, return a non-error
native result `{ok: true, outcome: "unknown", message: ..., app: ...}`. `ok` here
means a result was returned, not that the action completed. Use this exact text:

> The app did not confirm the action. Read state before continuing; do not repeat the action automatically.

Clear the native observation (including element indexes and coordinate grants)
and remembered menu paths. Further input requires `get_app_state` or an explicit
`activate_app` observation. The MCP adapter preserves the notice as a non-error
reply, with `_meta["opencu/actionOutcome"] = "unknown"` and
`_meta["opencu/actionsAttempted"]` equal to the number of requests sent in this
call. Stop `run_actions` at that action; do not send later actions, retry it or
perform the usual automatic final observation. The caller must explicitly read
and inspect state. That read is not hidden by the old accessibility diff.
Other AX errors retain their existing codes. In particular, -25204 from an
attribute read/write or capability query remains an error; only action dispatch
has this unknown-outcome rule. A successful AX response is still not proof of
the intended UI effect.

If `AXSelectedTextRange` is not settable (or the settable query reports that the
attribute is unsupported), `select_text` returns `TEXT_SELECTION_UNSUPPORTED`:

> This element does not support setting AXSelectedTextRange. Get a fresh screenshot and click at the text position instead.

No selection is written in that case. Other capability-query errors, non-text
attribute errors and the existing post-write selection verification are retained.
A fresh screenshot does not override any background input refusal.
