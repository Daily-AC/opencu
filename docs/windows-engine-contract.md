# Windows engine, phase 1

Status: implemented and cross-compiled on macOS; host logic tests pass. No Windows
executable or GUI acceptance has been run yet. This note specifies intended
behavior, not desktop acceptance evidence.

## Standalone transport and embedding

Run `.build/win/opencu-engine.exe serve` with inherited stdin/stdout pipes in the
signed-in user's interactive Windows session. Node is optional: a Go helper (for
example a future `wanctl act` integration) can spawn the same executable. OpenCU
neither imports nor invokes wanctl. The PE uses the Windows GUI subsystem, creates
no console, dialog or visible window, and only creates message-only windows for
input monitoring and clipboard ownership. It exposes no network listener.

Each UTF-8 JSON line is `{id, method, params}`; each flushed response is either
`{id, result}` or `{id, error: {code, message}}`. Diagnostics use stderr. Requests
are processed serially; EOF closes the engine. Do not operate one app concurrently
from multiple engine connections. No caller/account/signing-team allowlist exists.

Example requests (send one line, await its reply before sending the next):

```json
{"id":1,"method":"get_app_state","params":{"app":"芒果TV.exe","includeScreenshot":true}}
{"id":2,"method":"click","params":{"app":"芒果TV.exe","x":400,"y":250}}
{"id":3,"method":"get_app_state","params":{"app":"芒果TV.exe","includeScreenshot":true}}
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
`isRunning`, and where available `pid`/`pids`. Tool windows and the shell desktop
are excluded. Start-menu inventory can include shell/packaged shortcuts whose
launch target cannot be resolved; those fail explicitly on launch.

App selection accepts case-insensitive executable path, process name with or
without `.exe`, `pid:<pid>`, exact title or unique title fragment, and exact
Start-menu shortcut name/path. Ambiguous processes, titles or shortcut names are
rejected. Process/path selection observes all of that process's listed windows;
title selection observes that window. The returned canonical `app.id` is
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
CEF's Chrome Legacy Window. Password values are omitted. Listing caps are 1,200
nodes, 8,000 inspected nodes, depth 120, 180,000 bytes and an 8-second traversal
budget, with explicit truncation text. Individual UIA calls have 2-second timeout
settings; a misbehaving provider can still overrun the traversal budget.

The first listed window is the keyboard and screenshot target; indexed elements
retain their own top-level window. Use a unique title to select a specific window.
Capture uses full-window PrintWindow (`PW_RENDERFULLCONTENT`) and WIC PNG encoding.
No screen-wide fallback can accidentally capture another app. Minimized/failed
captures return tree text with a reason and no usable image. GPU video/DRM/CEF may
return blank or incomplete pixels despite API success; this requires real checks.
Chrome/Edge are traversed through native UIA without changing browser flags.

## Input and engine-side safety

Every input first activates its target window and verifies the actual foreground
HWND. If Windows denies SetForegroundWindow, `ACTIVATION_FAILED` is returned;
there is no synthetic Alt, AttachThreadInput, or foreground-lock bypass. Foreground
identity, live process identity and desktop accessibility are checked before each
new SendInput event and each UIA action. Pointer input also checks that the target
window owns the screen point. UIA actions cannot be cancelled after entering the
provider; events already delivered cannot be undone. Held engine keys/buttons are
released on failure, including PERSON_ACTIVE; no remaining action is replayed.

A dedicated invisible Raw Input thread watches keyboard/mouse device events.
Only source metadata is inspected; no human key text or pointer coordinates are
recorded. Engine-tagged input is exempt; unrecognized keyboard/mouse input,
including zero-device touchpad events, stops the call. Already-held keys/buttons
refuse a call. A bounded message drain and request/ack fence before each input and
at completion detect activity queued during the last API call. A failed monitor
or a 500 ms response timeout fails closed. Raw Input delivery, precision touchpads,
RDP and injected-input attribution need Windows acceptance; no visible heartbeat
window or timeout-sensitive low-level hook is used.

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

Supported inputs: click (Invoke, Toggle, SelectionItem or Legacy default action,
then centre-click fallback), Unicode typing, plain-text paste, xdotool-style keys,
vertical/horizontal wheel, Value/RangeValue and exposed secondary actions. `super`
means Windows, `ctrl` means Control; modifiers use the target keyboard layout.
`click.key` accepts modifiers only. Scroll approximates a page with three wheel
detents (user wheel settings still apply), limited to 100 pages per request.
`drag`, `select_text`, HTML and Markdown paste return UNSUPPORTED_ON_WINDOWS.

Paste snapshots every copyable HGLOBAL clipboard format before mutation, then
restores it after Ctrl+V and a short settling wait, unless the clipboard sequence
changed. Handle/private/owner-rendered or uncopyable formats and snapshots over
64 MiB are refused before mutation. Busy clipboard failures and restoration
failures are explicit; paste is never replayed. Applications consuming clipboard
data asynchronously after the settling wait require real verification.

## Stable error codes

Hosts should map `error.code`, not parse English messages. In particular,
`PERSON_ACTIVE` can be displayed as “有人在用这台电脑”. Errors after input begins
can represent partial completion; re-observe instead of automatically retrying.

| Code | Meaning |
| --- | --- |
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

Separate manual acceptance remains required for real human interruption, held-key
cleanup, elevated targets, locked/secure desktops, multiple monitors/DPI changes,
Start-menu launch variants, and Mango TV's Qt/CEF/video surfaces. The automatic
script does not synthesize “human” input or attempt to lock/elevate the desktop.

API references: [UIA raw tree](https://learn.microsoft.com/en-us/windows/win32/winauto/uiauto-treeoverview),
[Chrome native UIA](https://developer.chrome.com/blog/windows-uia-support-update),
[SendInput and UIPI](https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-sendinput),
[foreground restrictions](https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-setforegroundwindow),
[Raw Input](https://learn.microsoft.com/en-us/windows/win32/inputdev/raw-input),
[PrintWindow](https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-printwindow).
