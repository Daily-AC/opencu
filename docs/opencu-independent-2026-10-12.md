# Independent OpenCU engine — 2026-10-12

**OpenCU runs on its own native engine and passes the background GUI acceptance
on disposable AppKit fixtures.** An ordinary MCP client started it from a host
with no Accessibility or Screen Recording grant; the engine used OpenCU's own
grants, operated a background window without taking the foreground, and passed
12 checks in three consecutive runs while the Mac was in active use.

## Independence boundary

The Swift engine calls AppKit, Accessibility, CoreGraphics and ScreenCaptureKit.
No account, trusted-turn metadata, signing-team allowlist or proprietary runtime
is used. Any stdio MCP client can call the engine. There is no network listener.

Targeted input, exact window identity, background focus and permission
attribution use OS-exported SPI resolved at runtime: `CGEventSetWindowLocation`,
`_AXUIElementGetWindow`, AppKit process notifications and
`responsibility_spawnattrs_setdisclaim`. Their availability can change between
macOS releases.

## Permission attribution

macOS attributes Accessibility and Screen Recording to the responsible process,
normally the app that started the MCP client. Without intervention, OpenCU would
need each client's terminal or desktop app to be authorized, and the grant shown
for OpenCU in System Settings would be ignored.

`opencu-engine serve` and `--doctor` therefore respawn once with responsibility
disclaimed, inheriting the same stdin/stdout. The parent only relays SIGTERM,
SIGINT and SIGHUP and returns the child's exit status. Measured from an
unauthorized host: a direct start reported both permissions false; the disclaimed
child reported both true. `opencu doctor` reports this as `ownPermissions`.

An earlier temporary test instead started the app through
`open --stdin FIFO --stdout FIFO`. When the reading side vanished, launchd's
`xpcproxy` blocked on the FIFO and every later GUI launch on the Mac queued behind
it. Do not route the engine through LaunchServices; `bin/opencu setup` uses `open`
only for the permission dialog, without redirected streams.

Builds are signed with a per-machine OpenCU identity that `scripts/build-engine.py`
creates on first use in `~/Library/Application Support/OpenCU/signing`, in a
dedicated keychain; the login keychain is not modified. The designated requirement
pins that certificate, so grants survive rebuilds. The earlier requirement,
`identifier "dev.opencu.engine"` alone, was satisfied by any ad-hoc signed bundle
with that identifier: a separate test bundle inherited both grants. After
re-signing, resetting OpenCU's grants and granting them again, the same test
bundle was refused both permissions while OpenCU kept them. The packager refuses
an engine whose requirement does not pin a certificate.

A browser-downloaded archive is quarantined, and Gatekeeper blocks code without a
notarized Developer ID signature. Building from source avoids this; publishing
download-ready releases requires a Developer ID.

## Background operation

The engine posts AppKit's application-local activation and key-focus
notifications to the target process, then delivers input to that PID only. The
system foreground application does not change. Synthetic focus is kept across
operations on the same target window and released when the target changes or
the client disconnects. It is not released if the user genuinely activates the
target meanwhile. Pointer events carry the exact window ID and window-relative
position, so a background window receives clicks, drags and scrolls without
moving the cursor.

Menus are handled without leaving them open. Clicking a menu bar item opens its
menu once, so the application populates and validates the items, then closes it;
the items stay listed in later state. Clicking a submenu item only lists its
children, because pressing it inside a closed menu displays it alone. Clicking a
listed item chooses it through Accessibility on the closed menu. Probes showed
why: a command chosen from an open background menu arrived 0.25–0.45 s after
AXPress returned, and an open background menu was dismissed by the user's input
before the next read in one of three runs. On a closed menu the command ran in
about 40 ms. If a menu is already open, the engine waits for it to close before
returning so the observation includes the command's effect.

## Validation

- `node scripts/verify-gui.mjs`: **12 checks passed, 3 consecutive runs**, with the
  certificate-pinned engine, SHA-256
  `5c0b94c650fe9a67dd2de945ab1850146b582bdbb042f45c9376bce744130178`.
  A foreground sentinel fixture recorded no keyboard or pointer input and the
  target never became frontmost. Checks cover full-window capture, AXPress, typed
  values and secondary actions, physical click, shortcuts, Unicode typing, paste
  with clipboard restoration, UTF-16 selection, modifiers, mouse and key holds
  (350 ms requested, 365–373 ms observed), coordinate drag, pixel scroll, menu bar,
  nested submenu and closed-menu commands, and focus release on disconnect.
  [Evidence](../evidence/opencu-background-gui-2026-10-12.json)
- `npm test`: **17 passed**. `python3 scripts/test-native.py`: **34 passed**.
- `python3 scripts/verify-release.py`: the extracted archive started with an empty
  HOME, network denied, and the source checkout and common agent configuration
  unreadable; MCP initialized with 13 tools and `list_apps` returned 378 apps.
  [Receipt](../evidence/opencu-release-2026-10-12.json)

The [initial implementation evidence](../evidence/opencu-independent-2026-10-12.json)
records the first pointer-routing failure (events reached the process, not the
control) that the window-location fix resolved.

## Limits

- A window shrunk into Stage Manager's side strip yields only its thumbnail.
  Eight capture paths were tried; OpenCU rejects the size mismatch instead of
  returning a thumbnail as the window.
  [Evidence](../evidence/opencu-stage-manager-capture-2026-10-12.json)
- A locked Mac returns `SCREEN_LOCKED`. The proprietary locked-use mechanism is
  not reproduced.
- Opening a menu bar menu shows it briefly (about 0.3 s including its fade-out).
- Acceptance used AppKit fixtures. Electron, WebKit and other toolkits, and real
  application workflows, have not been accepted yet.
- Release archives are not notarized; see Permission attribution.

## Sources

- [Apple ScreenCaptureKit sample](https://developer.apple.com/documentation/screencapturekit/capturing-screen-content-in-macos)
- [AXUIElementCopyAttributeValue](https://developer.apple.com/documentation/applicationservices/1462085-axuielementcopyattributevalue)
- [CGEvent.postToPid](https://developer.apple.com/documentation/coregraphics/cgevent/posttopid(_:))
- [NSEvent mouse-event factory](https://developer.apple.com/documentation/appkit/nsevent/mouseevent(with:location:modifierflags:timestamp:windownumber:context:eventnumber:clickcount:pressure:))
