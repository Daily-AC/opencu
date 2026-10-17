# OpenCU

OpenCU is an independent open-source computer-use engine. The macOS engine uses
AppKit, Accessibility, CoreGraphics and ScreenCaptureKit. Prefer public APIs;
targeted input, exact window identity, background operation and permission
attribution may use necessary OS-exported SPI, resolved and checked at runtime.
Keep those compatibility boundaries explicit and verify behavior on real windows.
It must not call or distribute a proprietary computer-use runtime, account files
or a hosted service. The Rust Windows engine uses UI Automation, Windows Graphics
Capture and guarded foreground input; it intentionally has different focus semantics.

- Do not add an agent-brand or signing-team allowlist. The engine uses an
  inherited stdio transport; macOS Accessibility/Screen Recording permissions
  and the caller's task approvals remain in force.
- The stdio executable is a relay; LaunchServices starts an independent OpenCU
  app worker with its own responsibility and resource coalition. A private Unix
  socket authenticates its token and OS peer PID. The worker runs outside the
  caller's sandbox, as `opencu setup` already does. Never use LaunchServices
  with redirected streams (`open --stdin/--stdout` FIFOs): a vanished reader left
  launchd's xpcproxy blocked and stopped every GUI launch on the Mac.
- Builds are signed with the per-machine identity created by
  `scripts/build-engine.py`. Keep the designated requirement pinned to a
  certificate; an identifier-only requirement lets any bundle claim the grants.
- GUI acceptance usually runs on a Mac someone is using. Never take their
  foreground or touch their data: use the disposable fixtures, temporary files,
  and apps with temporary profiles, such as Chrome for Testing in
  `.cache/browsers` with `--user-data-dir`, `--use-mock-keychain` (otherwise a
  keychain prompt appears) and `--mute-audio`. `open -g` does not stop Electron
  apps from activating themselves; watch `lsappinfo front`. Ask before a step that
  needs the screen. Quit every temporary instance afterwards.
- Do not operate the same app concurrently. Do not replay input automatically.
- A probe started from an agent shell has the host's permissions, not OpenCU's.
  Drive the engine through `bin/opencu`. If a probe needs OpenCU's grants, sign it
  as a bundle with the local identity, launch it independently through
  LaunchServices without redirected streams, and delete it afterwards: it holds
  those grants.
- With Stage Manager on, off-stage windows give no screenshot, cannot become key
  and stop Chromium rendering. To test background web content anyway, start
  Chrome for Testing with `--disable-backgrounding-occluded-windows
  --disable-renderer-backgrounding`, and say so in the evidence.
- Build with `npm run build`; test with `npm test` and
  `python3 scripts/test-native.py`; run `node scripts/verify-gui.mjs` for input
  or observation changes. A release must be verified after extraction with
  `scripts/verify-release.py`: no network, no source checkout, empty HOME.
- Standard public Node and npm libraries may be bundled with their licenses.
- Keep app inventories, screenshots and local connection data in ignored
  `.cache/` directories. Published evidence should contain fixture data only.

Map: `native/Sources/OpenCU` is the engine (`MacObserver` reads, `InputController`
acts, `BackgroundFocus` holds background focus and the focus guard); `src/` is the
MCP server; `docs/independent-engine-contract.md` is the internal contract;
`docs/opencu-independent-2026-10-12.md` records measured behavior and limits.

Windows: `native-win/` owns the standalone JSON-lines engine. Build with
`npm run build:win`; run host logic with `cargo test --manifest-path native-win/Cargo.toml`.
Windows GUI acceptance is `scripts/verify-gui-win.mjs`; direct stdio acceptance is
`scripts/verify-engine-win.ps1`. These require an authorized idle Windows desktop
and operate disposable fixtures only. Keep real-app observations in ignored caches;
publish fixture evidence only. Physical Escape disables further input on that
engine connection. Never reconnect automatically to defeat a person's stop.
