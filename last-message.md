# Windows engine phase 1 — 2026-10-13

Phase 1 is implemented and cross-compiled on the Mac, on `feat/windows-engine`.
No Windows device was contacted and no Windows binary/GUI fixture was executed.
Nothing was pushed. macOS engine sources, application signing and GUI acceptance
were not changed or run.

## Delivered

- `native-win/`: a standalone Rust `opencu-engine.exe`, using Microsoft's `windows`
  crate and `serde_json`. GUI subsystem, inherited JSON-lines stdin/stdout, no
  console/dialog/visible engine UI, account, proprietary runtime or caller allowlist.
- UIA raw trees, app/window/Start-menu resolution and launch, PrintWindow/WIC PNGs,
  indexed and coordinate clicks, Unicode/keys, plain-text clipboard paste/restore,
  wheel scrolling, Value/RangeValue and listed UIA secondary actions.
- Engine-side screenshot invalidation, physical/DPI coordinate checks, window and
  process identity checks, foreground verification, token-integrity and interactive
  desktop checks, and an independent invisible Raw Input monitor with fail-closed
  acknowledgements. All apply to direct Go/other hosts as well as Node.
- Platform selection in the shared MCP runtime, `bin/opencu.cmd`, Windows doctor,
  `npm run build:win`, and platform-aware descriptions. Swift behavior is unchanged.
- `scripts/verify-gui-win.mjs` and `tests/fixtures/OpenCUFixture.ps1`, plus the
  Windows contract/error-code reference and documented macOS safety parity gaps.

Built binary: `.build/win/opencu-engine.exe` (2,458,455 bytes).
SHA-256: `313f7de47a5b6e8af6af7e6c2c1f33deaf150ff940da20ed2429c61f0b137eba`.
PE import inspection: Windows GUI subsystem; only Windows system DLL imports,
including the Windows Universal CRT. No MinGW runtime DLL distribution is needed
for the inspected binary. This is static inspection, not a Windows launch test.

## Validation actually performed

| Check | Result |
| --- | --- |
| `cargo test` on this Mac | 5 tests passed: key parsing, tree filtering/formatting, physical coordinates/DPI, error mapping/validation, base64 vectors. |
| `cargo build --release --target x86_64-pc-windows-gnu` | Passed. |
| `npm run build:win` | Passed, including the final multi-window routing change. |
| Windows-target `cargo clippy --all-targets -- -D warnings` | Passed on final engine code. |
| `npm test` | 19 passed (17 existing checks unchanged, 2 added platform/error-envelope checks). |
| `python3 scripts/test-native.py` | 34 passed; no GUI input, clipboard mutation, app build or signing. |
| `npm ci --ignore-scripts` then `npm run build:win` from a clean `git archive` | Passed at source revision `6768f74`; subsequent routing-only change also cross-compiled and passed clippy. No existing build/node_modules were copied into the clean source directory. |
| Node syntax checks for Windows launcher and acceptance script | Passed. |
| Windows desktop / PowerShell-C# fixture execution | Not run; reserved for follow-up. |

The temporary clean source/build copy was deleted. Build artifacts and the local
validation receipt remain ignored. Commits before this report: `6f15bc6` (engine),
`b44d2c1` (runtime/build/launcher), `ebda878` (unnamed custom controls), `6768f74`
(acceptance/docs), `268b0a2` (multi-window keyboard routing).

## Running the later Windows acceptance

Copy this source tree (or its archive) and the compiled executable to the Windows
machine, keeping the executable at `.build/win/opencu-engine.exe`. In a signed-in,
unlocked desktop session with Node 22+ and Chrome installed:

```bat
npm ci --ignore-scripts
bin\opencu.cmd doctor
node scripts\verify-gui-win.mjs
```

Use an idle desktop: this acceptance takes foreground focus. Optionally set
`OPENCU_TEST_CHROME` to the Chrome executable. The script starts only its own
WinForms window and a local HTML page in a new temporary Chrome profile; all
control/read actions use MCP. It checks tree/PNG dimensions, indexed click,
Unicode, Ctrl+A, paste/clipboard digest restoration, slider value, Toggle, scroll,
fresh coordinate click, moved-window refusal, unsupported drag, Chrome page text
and a link action. A private fixture command file only simulates external window
movement, requests a clipboard digest, and closes the fixture. Cleanup kills only
processes identified by the private command/profile markers and their descendants,
verifies they are gone, and removes the temporary profile. Reports/screenshots stay
in `.cache/windows-acceptance-*`. It never loads an ordinary Chrome profile or a
remote page. Unsupported existing clipboard formats fail without replacing them.

For embedding without Node: spawn `opencu-engine.exe serve` with pipes. Send one
JSON request at a time, match reply IDs, map stable `error.code`, and read state
again after input. `run_actions`, diffs and waits are MCP conveniences, not native
methods. No wanctl changes or integration are included in this phase.

## Known limits and unconfirmed assumptions

- **No Windows runtime evidence yet.** UIA/COM initialization, inherited stdio on
  the GUI-subsystem executable, PowerShell fixture compilation, WIC encoding,
  cleanup and all real OS interactions still need the actual Windows run.
- **Foreground and interruption:** SetForegroundWindow may refuse the agent;
  OpenCU reports that instead of bypassing the lock. Raw Input metadata/self-event
  attribution, real mouse/key and precision-touchpad interruption, already-held
  keys, monitor failure and release of engine-held inputs need manual verification.
  Checks occur before events/provider calls and at completion. They cannot undo a
  sent event or interrupt a UIA method already executing. Windows does not provide
  an atomic foreground-check-and-SendInput operation. Activity monitoring is per
  native input request, not a persistent human-idle cooldown across requests.
- **Sessions/security:** higher-integrity/protected targets, locked/UAC secure
  desktops, disconnected sessions and RDP are untested. Session 0 is refused;
  a service host must spawn in the user's interactive session. Initialization on
  an inaccessible desktop requires a reconnect after unlocking.
- **App/window resolution:** `.lnk` executable target/arguments/cwd handling and
  Mango TV process/window identity need real checks. Shell/Store/advertised links
  without a Win32 executable target cannot launch. Failed-to-appear launches are
  not repeated in the same connection. Multiple title/process matches are refused.
  Multiple-window indexed-to-keyboard batching is implemented but not exercised.
- **Tree providers:** Chrome/Edge native UIA should expose page text through the
  raw walker without flags; verify with the installed Chrome 154/Edge 155. Qt may
  provide only partial trees. Unnamed classed controls remain listed, but the
  embedded CEF leaf is not magically expanded. No OCR, DevTools or JS bypass exists.
  Truncation budgets are explicit. UIA timeout settings do not guarantee a hard
  whole-request deadline against every misbehaving provider; performance is unmeasured.
- **Capture/DPI:** PrintWindow can return success with blank/incomplete GPU, CEF or
  protected video content. Mango TV playback capture is the principal open risk.
  Screenshots are not screen-wide fallback captures. Minimized windows return a
  reason instead of an image. 120-DPI physical mapping is unit-tested, but actual
  display scaling, negative origins, monitor changes and frame borders need checks.
- **Input details:** Unicode/surrogates, target keyboard layout, multi-click/holds,
  UIA Invoke/Toggle/SelectionItem/Legacy actions, RangeValue/Value semantics and
  scrolling must be verified with native, Chrome and Mango TV controls. Scroll
  approximates pages with wheel detents. Drag/select_text and rich paste are
  deliberately unsupported in phase 1.
- **Clipboard:** only safely copyable HGLOBAL formats are preserved; opaque/GDI,
  private/owner-rendered or oversized contents are refused. Delayed rendering,
  competing clipboard changes, restoration failures, and app consumption after
  the 200 ms paste wait need acceptance. A failed restore is reported, and input
  is never replayed.
- **Harness/packaging:** the script tests native and Chrome fixtures, not Mango TV
  playback, Edge, human interference, elevation, lock transitions or every keyboard
  layout. Those are separate manual follow-ups. The existing Node mock-executable
  suite remains Mac-oriented. No Windows release archive, installer or Authenticode
  signing is included; the current release packager remains macOS-only.
- **macOS parity:** its engine still has earlier-resolution screenshot-invalidation
  gaps and does not abort every input on human activity with PERSON_ACTIVE. These
  are documented in the shared contract, not fixed or represented as tested here.

## wanctl safety-monitor observation

Read only the local `wanctl-oss` `origin/main` at
`24ba07c62954f4dead3508b4dbe5846b735e1e6b`. In that source, the exact reported
“desktop safety monitor stopped responding” message comes from the visible
indicator's missing/older-than-100-ms heartbeat in `native_windows.go`, rather than
the separate Raw Input sink. The indicator thread drains messages without a bound
and periodically calls synchronous SetWindowPos before refreshing its heartbeat
(`indicator_windows.go`). A blocked window operation or scheduling/message delay
could therefore cause a false refusal even for one Esc key; this is a plausible
source-level explanation, not a diagnosis of the owner's v0.22.2 binary (its source
identity was not established). OpenCU avoids visible-indicator work on the monitor
thread, uses bounded message draining plus acknowledgements, and still refuses
input when monitoring fails. No wanctl file was changed and no remote reproduction
was attempted.
