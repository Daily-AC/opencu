# Windows engine contract

Status: cross-compiled on macOS and accepted on disposable Windows 11 native and
Chrome fixtures in three consecutive runs. Direct UTF-8 stdio was also exercised
from PowerShell without Node. See the [fixture evidence](../evidence/opencu-windows-gui-2026-10-13.json).
The owned-foreground regression and foreign-process refusals were additionally
accepted in [three consecutive fixture runs](../evidence/opencu-windows-owned-foreground-2026-10-13.json).
Physical takeover and privileged/locked-desktop cases remain manual follow-ups.

## Standalone transport and embedding

Run `.build/win/opencu-engine.exe serve` with inherited stdin/stdout pipes in the
signed-in user's interactive Windows session. Node is optional: a Go helper (for
example a future `wanctl act` integration) can spawn the same executable. OpenCU
neither imports nor invokes wanctl. The PE uses the Windows GUI subsystem, creates
no console or dialogs. A nonactivating status banner is visible during input and
briefly afterwards; Windows excludes it from captures. Message-only windows handle
input monitoring and clipboard ownership. It exposes no network listener.

Each UTF-8 JSON line is `{id, method, params}`; each flushed response is either
`{id, result}` or `{id, error: {code, message}}`. Diagnostics use stderr. Requests
are processed serially; EOF closes the engine. Do not operate one app concurrently
from multiple engine connections. No caller/account/signing-team allowlist exists.

Example requests (send one line, await its reply before sending the next):

```json
{"id":1,"method":"get_app_state","params":{"app":"Example.exe","includeScreenshot":true}}
{"id":2,"method":"click","params":{"app":"Example.exe","x":400,"y":250}}
{"id":3,"method":"get_app_state","params":{"app":"Example.exe","includeScreenshot":true}}
```

`list_apps`, `get_app_state`, `activate_app` and input names/parameters match the
shared engine contract. An input response is `{ok:true, app}`; it is not a new
observation. The MCP server supplies post-action observation, diffs, waits and
`run_actions` batching. A non-Node host must implement those conveniences itself.
`doctor` (or `--doctor`) reports platform, executable path, desktop accessibility,
foreground-only operation, and no account/proprietary-runtime requirement.

## Observations and targeting

`list_apps` includes processes with visible, non-cloaked top-level windows and
user/common Start-menu `.lnk` entries. Records use `id`, `displayName`, `path`,
`isRunning`, and where available `pid`/`pids`. The shell desktop is excluded. Start-menu inventory can include shell/packaged shortcuts whose
launch target cannot be resolved; those fail explicitly on launch.

App selection accepts case-insensitive executable path, process name with or
without `.exe`, `pid:<pid>`, exact title or unique title fragment, and exact
Start-menu shortcut name/path. Matches across different processes or duplicate
shortcuts are rejected. Same-process title matches form one window set, not an
ambiguity. A non-tool, unowned content window takes priority over utility windows,
then larger area wins; equal ranks retain Z order. The chosen HWND and class are
shown in the observation. Process/path selection observes its listed windows;
title selection restricts that set. The returned canonical `app.id` is
`pid:<pid>`, so isolated Chrome profiles do not share an ambiguous executable ID.
Process creation time and HWND ownership are revalidated before input.

Missing apps launch via CreateProcess, including resolved Win32 shortcut target,
arguments and working directory. No shell/elevation UI is requested. An executable
requiring elevation fails launch; shell/Store shortcuts without an executable
are not supported. A successful launch with no visible window is remembered for
the connection and returns `APP_LAUNCH_PENDING`; subsequent reads cannot repeat
that launch. Inspect state/list_apps, or reconnect to deliberately launch again.

Observation JSON remains `{text, app:{id,displayName,pid}, screenshot?}`. The image
is `{data:<base64>, mimeType:"image/png", width, height}`. The raw UIA tree uses
`[1] Button title="..." ID="..." class="..." value="..." settable actions=Invoke`
with `disabled`/`offscreen` flags. Unnamed controls include physical screen bounds
`(x,y,width,height)` and class names. Empty structural containers are omitted but
their children are visited; unnamed leaves remain, including Qt IconButton and
CEF's Chrome Legacy Window. Metadata and patterns are fetched with UIA cache
requests. Password values/names and descendants are omitted; an unreadable
password flag is treated as protected, not as false. Listing caps are 1,200
nodes, 8,000 inspected nodes, depth 120, 180,000 bytes and an 8-second traversal
budget, with explicit truncation text. Individual UIA calls have 2-second timeout
settings; a misbehaving provider can still overrun the traversal budget.

The first listed window is the screenshot and initial keyboard target. Indexed
input retains its own top-level window, which becomes the keyboard target for
following input in the same batch. Use a unique title to select a specific window.
Capture uses Windows.Graphics.Capture for the selected HWND, with D3D11 hardware
or WARP readback and WIC PNG encoding. Physical bounds use DWM's visible frame;
covering windows never supply replacement pixels. Cursor capture is disabled;
the standard OS capture border is retained without a permission prompt. No
screen-wide fallback can accidentally capture another app. Minimized/failed
captures return a reason and no image. Protected video can remain unavailable.
Chrome/Edge are traversed through native UIA without changing browser flags.

## Input and engine-side safety

Every input verifies that the actual foreground window belongs to the target's
top-level ownership family: normalize children with `GetAncestor(GA_ROOT)`, then
walk `GetWindow(GW_OWNER)` to the ultimate owner (at most 64 steps). Both windows
must reach the same live owner, and every HWND visited must belong to the target
PID. This includes the owner, owned overlays/dialogs, siblings sharing that root
owner, and their child controls. Same PID alone does
not include unrelated top-level windows, and a cross-process owned window is
never accepted. Walking the actual ownership chain also handles non-`WS_POPUP`
owned windows that [`GA_ROOTOWNER`/`GetParent`](https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-getparent)
omit. The observed process creation
time and HWND are still validated.
The same live predicate guards activation, each subsequent input safety check,
pointer hit testing, and the focused control used for literal text.

If this family already holds foreground, activation succeeds without calling
SetForegroundWindow or changing the active overlay. Otherwise the engine makes
the existing single SetForegroundWindow attempt and waits up to 500 ms for the
target family. If Windows denies it, `ACTIVATION_FAILED` is returned;
there is no synthetic Alt, AttachThreadInput, or foreground-lock bypass. Foreground
identity, live process identity and desktop accessibility are checked before each
new SendInput event, Unicode character message and each UIA action. Pointer input also checks that the target
window owns the screen point. UIA actions cannot be cancelled after entering the
provider; events already delivered cannot be undone. Held engine keys/buttons are
released on failure, including PERSON_ACTIVE; no remaining action is replayed.

A dedicated invisible Raw Input thread watches keyboard/mouse device events.
Only source metadata is inspected; no human key text or pointer coordinates are
recorded. Escape key metadata is also inspected for the stop control.
Engine-tagged input is exempt; unrecognized keyboard/mouse input,
including zero-device touchpad events, stops the call. Already-held keys/buttons
refuse a call. A bounded message drain and request/ack fence before each input and
at completion detect activity queued during the last API call. A failed monitor
or a 500 ms response timeout fails closed. Raw Input delivery, precision touchpads,
RDP and injected-input attribution need Windows acceptance. The indicator runs on
a separate UI thread, with acknowledgement/visibility checks before input. It is
not the physical-input monitor's heartbeat.

Physical Escape latches `USER_STOPPED` for this engine connection. In-flight input
stops at its next safety check, held engine keys/buttons are released, and all
later input/activation is refused. Existing apps can still be observed, but reads
cannot launch an app or clear the latch. There is no reset method; a host must not
reconnect automatically to defeat the person's stop. Escape detection has both a
low-level hook (ignoring injected events) and a Raw Input path. Ordinary physical
input returns `PERSON_ACTIVE`; the next input needs a fresh observation. No
system cursor scheme is changed and no foreground-lock bypass is used.

Session 0, disconnected/locked sessions, a non-Default input/thread desktop, or
an unreadable session/desktop return SCREEN_LOCKED. The engine does not unlock,
switch sessions, elevate, or create a helper in another session. A host service
must spawn it in the signed-in user's interactive session. Target integrity must
be readable and no higher than the engine's token. An engine started while its
desktop is inaccessible must be reconnected after unlocking (initialization is
not retried).

The engine itself consumes the screenshot on every recognized state/action
attempt, including failed or unsupported actions. Only a successful capture grants
new coordinate input. `list_apps` and `doctor` preserve it. Coordinates must be
finite, inside the latest image, for the same observed window/process, and match
its current position, size and DPI **before activation/input** and again after
activation. Per-monitor-v2 awareness makes image pixels physical pixels: at
120 DPI, no additional factor of 1.25 is applied. Absolute SendInput coordinates
use virtual-desktop pixel centres, including negative monitor origins.

Keyboard input goes to the actual foreground family window, using its keyboard
layout. Literal `type_text` uses bounded WM_CHAR delivery to the actual foreground
thread's focused HWND (including an owned overlay on a separate UI thread),
revalidating its family and that exact focus before each UTF-16 unit. This avoids
IME composition consuming spaces and does not change the user's input method.
It emits character/input events, not a physical keydown/keyup pair for every
character; use `press_key` for key-event semantics. Native Edit and Chrome input
acceptance cover this distinction.

Supported inputs: click (Invoke, Toggle, SelectionItem or Legacy default action,
then centre-click fallback), Unicode typing, plain-text paste, xdotool-style keys,
vertical/horizontal wheel, Value/RangeValue and exposed secondary actions. `super`
means Windows, `ctrl` means Control; modifiers use the target keyboard layout.
`click.key` accepts modifiers only. Scroll approximates a page with three wheel
detents (user wheel settings still apply), limited to 100 pages per request.
`drag`, `select_text`, HTML and Markdown paste return UNSUPPORTED_ON_WINDOWS.

Paste snapshots every copyable HGLOBAL clipboard format before mutation. Temporary
paste content is marked ExcludeClipboardContentFromMonitorProcessing so Windows
clipboard history and cloud sync do not retain it. The engine then
restores it after Ctrl+V and a short settling wait. Windows can synthesize legacy
text formats and advance the sequence while consuming the paste; unchanged owner
and Unicode payload still identify the engine's clipboard. A changed owner or
payload with a new sequence is preserved as an external copy. Handle/private/owner-rendered or uncopyable formats and snapshots over
64 MiB are refused before mutation. Busy clipboard failures and restoration
failures are explicit; paste is never replayed. Applications consuming clipboard
data asynchronously after the settling wait require real verification.

## Stable error codes

Hosts should map `error.code`, not parse English messages. In particular,
`PERSON_ACTIVE` can be displayed as “有人在用这台电脑”. Errors after input begins
can represent partial completion; re-observe instead of automatically retrying.

| Code | Meaning |
| --- | --- |
| `USER_STOPPED` | Physical Escape disabled all further input on this connection. |
| `INDICATOR_UNAVAILABLE` | Required visible indication could not be shown/verified. |
| `PERSON_ACTIVE` | Human/foreign device input arrived or a key/button was held; stop. |
| `SAFETY_MONITOR_UNAVAILABLE` | Input monitoring failed or did not acknowledge in time. |
| `SCREEN_LOCKED` | Locked, secure, disconnected or inaccessible interactive desktop/session. |
| `ELEVATED_TARGET` | Target integrity is higher or cannot be verified. |
| `ACTIVATION_FAILED` | Windows refused foreground activation; no input sent. |
| `WINDOW_FOCUS_CHANGED` | Foreground changed during the operation; stop remaining input. |
| `TARGET_OCCLUDED` | Another window owns the pointer point. |
| `OBSERVATION_REQUIRED` | No matching latest app/window observation. |
| `SCREENSHOT_REQUIRED` | No unconsumed screenshot in this engine connection. |
| `STALE_SCREENSHOT` | Window moved, resized or changed DPI. |
| `INVALID_COORDINATE` | Nonfinite/out-of-image/off-desktop coordinate. |
| `STALE_WINDOW`, `STALE_ELEMENT` | HWND/process identity or UIA element is no longer valid. |
| `ELEMENT_DISABLED`, `ELEMENT_NOT_VISIBLE` | Disabled control or no usable centre-click bounds. |
| `UNSUPPORTED_ON_WINDOWS` | Phase-1 operation/format is intentionally unavailable. |
| `UNSUPPORTED_ACTION`, `ATTRIBUTE_NOT_SETTABLE` | Pattern/action/value not supported or read-only. |
| `UNSUPPORTED_KEY`, `UNSUPPORTED_KEY_CHORD` | Unknown key or unavailable layout mapping. |
| `INVALID_ARGUMENT`, `INVALID_REQUEST`, `METHOD_NOT_FOUND` | Invalid parameters, envelope or method. |
| `AMBIGUOUS_APP`, `APP_NOT_FOUND`, `APP_NOT_RUNNING` | App selection failed. |
| `LAUNCH_FAILED`, `APP_LAUNCH_PENDING` | Launch failed, or succeeded without a visible window yet. |
| `NO_ACCESSIBLE_WINDOW`, `WINDOW_CHANGED` | No window, or geometry changed while capturing. |
| `SCREENSHOT_FAILED`, `SCREENSHOT_TOO_LARGE` | Capture unavailable or over 32 million pixels; also used in observation text. |
| `CLIPBOARD_UNAVAILABLE`, `CLIPBOARD_CHANGED` | Clipboard could not be preserved or changed before paste. |
| `CLIPBOARD_RESTORE_FAILED` | Input may have run; clipboard restoration failed. |
| `INPUT_FAILED` | SendInput did not accept the event; never retry automatically. |
| `ACCESS_DENIED`, `UIA_TIMEOUT`, `WINDOWS_API_ERROR` | OS/provider failure; message includes diagnostic details. |

## Validation follow-up

On an idle Windows desktop, run `node scripts/verify-gui-win.mjs` after installing
Node dependencies and placing the executable at `.build/win/opencu-engine.exe`.
It operates only a disposable WinForms fixture and a local HTML page in a new
Chrome profile, then closes all processes identified by their private markers.
Screenshots and results stay under ignored `.cache/windows-acceptance-*`.
It never opens a normal browser profile, remote site or user document. It hashes
the existing clipboard for restoration verification and does not replace it with
a fixture baseline. Unsupported clipboard contents cause an explicit failure.
`OPENCU_TEST_CHROME` can select a Chrome executable.
`scripts/verify-engine-win.ps1` tests the native protocol without Node, including
engine-side coordinate refusals. PowerShell clients must explicitly use UTF-8
for both pipe directions; default console code pages can corrupt app names.

Separate manual acceptance remains required for real human interruption, held-key
cleanup, elevated targets, locked/secure desktops, multiple monitors/DPI changes,
Start-menu launch variants, and Qt/CEF desktop clients and protected video surfaces. The automatic
script does not synthesize “human” input or attempt to lock/elevate the desktop.

The owned-foreground fixture keeps its control overlay active when its content
window is requested. The old engine refuses the main-window indexed click with
`ACTIVATION_FAILED`; the fixed engine accepts it while leaving the overlay active.
The suite covers owned popup and non-popup windows, pointer and text focus, and
stopping a held key when foreground leaves the ownership family. Foreign-process
refusal uses a separate cold engine connection with no preceding SendInput grant:
the original connection may legitimately receive foreground rights from Windows
after its own input. This does not reconnect after physical Escape or interruption.

API references: [UIA raw tree](https://learn.microsoft.com/en-us/windows/win32/winauto/uiauto-treeoverview),
[Chrome native UIA](https://developer.chrome.com/blog/windows-uia-support-update),
[SendInput and UIPI](https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-sendinput),
[foreground restrictions](https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-setforegroundwindow),
[Raw Input](https://learn.microsoft.com/en-us/windows/win32/inputdev/raw-input),
[window capture](https://learn.microsoft.com/en-us/windows/win32/api/windows.graphics.capture.interop/nf-windows-graphics-capture-interop-igraphicscaptureiteminterop-createforwindow).
