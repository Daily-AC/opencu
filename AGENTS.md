# OpenCU

OpenCU is an independent open-source computer-use engine. The macOS engine uses
AppKit, Accessibility, CoreGraphics and ScreenCaptureKit. Prefer public APIs;
targeted input, exact window identity, background operation and permission
attribution may use necessary OS-exported SPI, resolved and checked at runtime.
Keep those compatibility boundaries explicit and verify behavior on real windows.
It must not call or distribute a proprietary computer-use runtime, account files
or a hosted service. Windows support comes later.

- Do not add an agent-brand or signing-team allowlist. The engine uses an
  inherited stdio transport; macOS Accessibility/Screen Recording permissions
  and the caller's task approvals remain in force.
- The engine respawns itself with responsibility disclaimed so OpenCU's own
  permission grants apply under any client. Never start it through LaunchServices
  with redirected streams (`open --stdin/--stdout` FIFOs): a vanished reader left
  launchd's xpcproxy blocked and stopped every GUI launch on the Mac.
- Builds are signed with the per-machine identity created by
  `scripts/build-engine.py`. Keep the designated requirement pinned to a
  certificate; an identifier-only requirement lets any bundle claim the grants.
- Run GUI acceptance against a disposable fixture or an explicitly scoped app.
  Do not operate the same app concurrently. Do not replay input automatically.
- Build with `npm run build`; test with `npm test` and
  `python3 scripts/test-native.py`; run `node scripts/verify-gui.mjs` for input
  or observation changes. A release must be verified after extraction with
  `scripts/verify-release.py`: no network, no source checkout, empty HOME.
- Standard public Node and npm libraries may be bundled with their licenses.
- Keep app inventories, screenshots and local connection data in ignored
  `.cache/` directories. Published evidence should contain fixture data only.
