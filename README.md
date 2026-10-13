# OpenCU

OpenCU is an independent local computer-use engine with an MCP interface. Its
macOS Swift engine uses Accessibility, CoreGraphics and ScreenCaptureKit directly
and operates apps in the background without taking over your keyboard or cursor.
A Windows Rust engine is implemented for foreground operation; its real-desktop
acceptance is pending.
It needs no account, model credentials or proprietary runtime. Any compatible MCP
client can call it; the calling agent supplies the model and decides what to do.

**Development status:** the engine passes background GUI acceptance on disposable
AppKit fixtures and isolated release verification, and completed a real web task
in Chrome in the background. Safari/WebKit, Qt and Java apps are not yet accepted.
See the [current evidence and limits](docs/opencu-independent-2026-10-12.md).

The accepted target is **macOS 14 or later on Apple silicon**. Windows phase 1
is cross-compiled for **Windows 11 x64**; see the Windows section below.

## Quick start

Install Node.js 22+ and Apple's Command Line Tools, then:

```sh
git clone https://github.com/Daily-AC/opencu.git
cd opencu
npm ci --ignore-scripts
npm run build
./bin/opencu setup
./bin/opencu doctor
```

Grant macOS Accessibility permission for input and interface text, and Screen
Recording permission for screenshots, to OpenCU itself. These are ordinary OS
permissions, with no account or agent-brand restriction. The engine runs as its
own responsible process, so the same grants apply whichever terminal or agent app
starts it; `opencu doctor` reports `ownPermissions: true`. Reconnect the MCP client
after changing permissions. Text-only observations do not require Screen Recording.

Configure a stdio MCP server in your agent:

```json
{
  "mcpServers": {
    "opencu": {
      "command": "/absolute/path/to/opencu/bin/opencu"
    }
  }
}
```

No network service is exposed. The engine communicates through inherited
stdin/stdout and exits when its client disconnects.

## Tools

OpenCU exposes `list_apps`, `get_app_state`, `activate_app`, `click`, `drag`,
`press_key`, `type_text`, `paste`, `scroll`, `set_value`, `select_text`,
`perform_secondary_action`, and `run_actions`.

Start with `get_app_state` for the target app. It accepts its bundle identifier,
name or full `.app` path and can launch it in the background. An ambiguous name
is rejected. State includes indexed Accessibility elements. Set
`includeScreenshot: true` for a window PNG and use coordinates in that image.

Input actions require a preceding observation of the same app. They do not
activate it: the engine gives the target application-local focus and sends input
to that process and window only, so the user's foreground app keeps the keyboard
and cursor. Indexed clicks prefer the element's Accessibility press action.
Coordinate input checks the screenshot size and current window geometry; a
screenshot becomes stale after input or a text-only observation. Apps can still
move, change focus or handle synthesized input differently: inspect the returned
state before deciding what to do next. Use `activate_app` explicitly when
foreground interaction is needed. If the target app activates itself in response
to background input, for example a browser opening a new tab, OpenCU returns the
foreground to the app you were using unless you clicked in the meantime.

With Stage Manager, an app that is not on the stage is shown as a thumbnail or
hidden. macOS then provides no full screenshot, Chromium-based apps stop rendering
their pages, and the window cannot run commands such as Save or Close. OpenCU
reports this in the returned state; reading and indexed actions still work, and
`activate_app` covers the rest. A requested screenshot that cannot be taken is
replaced by its reason instead of failing the call.

Chromium browsers and Electron apps expose their web content to OpenCU: Electron
through `AXManualAccessibility`, Chrome-family browsers through
`AXEnhancedUserInterface`, which OpenCU resets when it disconnects.

Clicking a menu bar item or submenu lists its items without displaying the menu;
the app validates and fills them for the read. Clicking a listed item runs the
command before the call returns. A disabled item is refused by the app.

Standalone input returns updated Accessibility text. Coordinate input and drag
also return a new screenshot. `run_actions` executes up to 16 known actions and
returns one final observation. It stops at the first error, does not repeat input,
and identifies when input succeeded but the final observation failed. Coordinate
actions must come first in a batch. Calls on one connection are serialized.

`click.key` accepts modifier chords such as `Shift` or `super`; `click.duration`
and `press_key.duration` accept 0–30 seconds. Unicode typing is supported. Prefer
`paste` for multiline content because typing a newline can submit a form.
Clipboard contents are restored after paste unless another application changed
them during the operation. Markdown supplies plain text and rich representations;
HTML supplies its HTML representation.

`set_value` requires a settable element and preserves its current string, number
or boolean value type. `select_text` uses the exposed editable text and supports
`prefix`, `suffix`, and `selection_type` (`text`, `cursor_before`, `cursor_after`).
Ambiguous matches are rejected. Secondary actions must exactly match an action
exposed by the current element.

State options include `disableDiff`, `includeScreenshot`, `waitForText` and
`waitTimeoutMs` (0–15,000 ms). Unchanged text can return a short unchanged notice;
`disableDiff: true` always returns the full tree. A missed expected label returns
an error with the last observed state. The tree reports its node/depth/time limits
when truncated. Image coordinates never silently fall back to another window.

## Windows (phase 1)

The Rust engine implements UI Automation trees (including unnamed controls),
window PNGs, indexed/coordinate click, Unicode typing, plain-text paste, keys,
scroll, writable values and exposed secondary actions. Input brings the target
window to the foreground; Windows can refuse activation. Human keyboard/mouse
activity stops the current call. A capture-excluded banner shows that OpenCU is
operating; physical Esc disables further input on that connection. Drag and text selection are not supported yet.
These paths are implemented, **not yet accepted on a Windows desktop**.

Cross-compile on a Mac with Rust's `x86_64-pc-windows-gnu` target and MinGW-w64
(`x86_64-w64-mingw32-gcc` on PATH):

```sh
npm ci --ignore-scripts
npm run build:win
cd native-win
cargo test
cargo build --release --target x86_64-pc-windows-gnu
```

The stable executable is `.build/win/opencu-engine.exe`. On Windows, install Node
22+ and the npm dependencies, copy that executable to the same path, then run
`bin\opencu.cmd doctor` or `bin\opencu.cmd mcp`. MCP clients can also launch
`node C:\path\to\opencu\src\server.mjs` directly. Go or other hosts can spawn
`opencu-engine.exe serve` with pipes; Node is not required for the engine.

Windows acceptance, when the desktop is available for foreground testing:
`node scripts/verify-gui-win.mjs`. It uses disposable WinForms/Chrome fixtures.
See the [Windows contract and pending checks](docs/windows-engine-contract.md)
for error codes, embedding, clipboard/capture limits and safety behavior. The
background-focus, closed-menu and rich-paste behavior described above is macOS-only.

## Development

```sh
npm test
python3 scripts/test-native.py
node scripts/verify-gui.mjs
```

`verify-gui.mjs` builds two disposable AppKit fixtures, keeps one in the
foreground and operates the other in the background through the MCP server.

The macOS native engine has no package dependencies. `native/Package.swift` links only
system frameworks. The first build creates this Mac's OpenCU signing identity in
`~/Library/Application Support/OpenCU/signing`, in its own keychain; the login
keychain is not modified. Every build of `.build/OpenCU.app` is signed with it,
and the app's designated requirement pins that certificate. macOS permission
grants therefore survive rebuilds, while another app claiming OpenCU's bundle
identifier is refused. The signature identifies the app to macOS; it does not
restrict callers.

## Release archives

A release archive contains the compiled OpenCU app, standard public Node.js and
the MCP dependencies, so it needs no compiler or separate Node installation.
Prepare the public Node runtime, create the archive and verify it offline:

```sh
python3 scripts/package-opencu.py --prepare-node
python3 scripts/package-opencu.py
python3 scripts/verify-release.py
```

The packager validates the public Node download checksum, native source/build
hashes, npm lockfile origins and an explicit file list, and rejects stale native
builds. The archive retains third-party licenses. Archives are signed with the
builder's local OpenCU identity, not a notarized Developer ID: a browser download
is quarantined and Gatekeeper blocks it. Building from source is unaffected.

## Limits

OpenCU does not unlock a locked Mac; a locked or inaccessible desktop remains
subject to macOS restrictions. It does not supply a chat interface, remote relay,
app-specific workflows or a model. The caller remains responsible for task
authorization and approvals. The engine has no built-in block on particular
agent brands or application bundle identifiers.

## License

Original OpenCU code is available under the [MIT License](LICENSE). Bundled open
source dependencies retain their own licenses. No license for proprietary third
party software is included or implied.
