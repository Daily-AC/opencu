# Independent OpenCU engine — 2026-10-12

**OpenCU runs on its own native engine, passes the background GUI acceptance on
disposable AppKit fixtures, and completed a real web task in Chrome while staying
in the background.** An ordinary MCP client started it from a host with no
Accessibility or Screen Recording grant; the engine used OpenCU's own grants,
operated background windows without taking the foreground, and passed 12 fixture
checks in three consecutive runs while the Mac was in active use. Stage Manager
limits what any app can do with windows that are off the stage; those limits are
measured and reported below.

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

2026-10-16 qualification: that historical permission result did not establish
immunity from ScreenCaptureKit's private-picker reminder. Capture now verifies the
responsible PID before SCK. `ownPermissions` now reflects OS verification,
not merely the respawn marker. See the [agent-display capture audit](agent-display-probe.md#capture-boundary-and-the-private-picker-prompt).

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

Some apps activate themselves in response to background input; Chrome does when
a page opens a link in a new tab. For two seconds after each input, OpenCU returns
the foreground to the app the user was using if the target takes it, unless the
user clicked in that interval. Measured: such an activation was undone in 11 ms.

Menus are never displayed. Clicking a menu bar item or submenu lists its items:
Accessibility reads of a closed AppKit menu validate the items and run delegate
population, so enabled states and dynamic items are current. Clicking a listed
item runs it through AXPress on the closed menu; AppKit still refuses a disabled
item. If a menu is already open, the engine waits for it to close before
returning, because AppKit sends the chosen command after the dismissal animation.

## Real applications

The tree omits unlabelled layout containers, text that repeats its link's label,
icon-font glyphs and the context-menu and scroll-into-view actions present on
nearly every element; it skips content outside the window and reads each element's
attributes in one batched call. Web pages are listed in full: the mgtv.com home page
reads in about 190 ms as 20 k characters, where Chrome's web content previously sat
below the depth limit.

Chromium and Electron expose web content only to assistive clients. Electron
accepts `AXManualAccessibility`, which has no side effects. Chrome rejects it, so
OpenCU sets `AXEnhancedUserInterface` for apps that ship a Chromium renderer helper
and restores it when the client disconnects, because the attribute also slows
window moves made by window managers.

End-to-end check in a disposable Chrome profile, with Chrome kept in the
background: read mgtv.com, focus its search field, type 喜羊羊与灰太狼, press
Return, wait for results and click 立即播放. The listed play source, Tencent Video,
opened episode 1; the page's video was playing (current time 4.6 s, then 7.7 s
three seconds later). Chrome was started with occluded-window backgrounding
disabled to emulate a visible window; see Stage Manager below.

A temporary TextEdit document received background typing. VS Code with temporary
user data exposed its editor text through `AXManualAccessibility`.
[Evidence](../evidence/opencu-real-apps-2026-10-12.json)

## Stage Manager and hidden windows

Stage Manager keeps every app that is not on the stage either as a thumbnail or
fully hidden. Measured consequences for such a window in the background:

- Screenshots: every capture path yields the thumbnail or nothing.
  [Capture evidence](../evidence/opencu-stage-manager-capture-2026-10-12.json)
- The window cannot become key, even after setting `AXMain` or `AXFocused`, so
  window commands such as Save and Close are disabled.
- Chromium does not render the page (`visibilityState` is hidden), so no web
  content is exposed. A fully covered window behaves the same way.
- Keyboard input reached TextEdit in a thumbnail window but not VS Code in a fully
  hidden one. Reading and indexed actions work in both.

OpenCU detects both states from WindowServer without capture permission and says
so in the returned state, recommending `activate_app` for steps that need more.
A requested screenshot that cannot be taken no longer fails the call: the text
state is returned with the reason.

## Validation

- `node scripts/verify-gui.mjs`: **12 checks passed, 3 consecutive runs**, with the
  certificate-pinned engine, SHA-256
  `021647c815627ec21e1d6ea1c02dca1332782693272d8273193d0d6ce56ddeef`.
  A foreground sentinel fixture recorded no keyboard or pointer input and the
  target never became frontmost. Checks cover full-window capture, AXPress, typed
  values and secondary actions, physical click, shortcuts, Unicode typing, paste
  with clipboard restoration, UTF-16 selection, modifiers, mouse and key holds
  (350 ms requested, 372–374 ms observed), coordinate drag, pixel scroll, menus
  listed without being displayed (validated, nested and delegate-filled items;
  disabled items refused), and focus release on disconnect.
  [Evidence](../evidence/opencu-background-gui-2026-10-12.json)
- `npm test`: **17 passed**. `python3 scripts/test-native.py`: **34 passed**.
- `python3 scripts/verify-release.py`: the extracted archive started with an empty
  HOME, network denied, and the source checkout and common agent configuration
  unreadable; MCP initialized with 13 tools and `list_apps` returned 295 apps
  (helper processes and background agents are no longer listed).
  [Receipt](../evidence/opencu-release-2026-10-12.json)

The [initial implementation evidence](../evidence/opencu-independent-2026-10-12.json)
records the first pointer-routing failure (events reached the process, not the
control) that the window-location fix resolved.

## Limits

- Stage Manager and hidden windows limit background use as described above;
  the remedy is foreground use through `activate_app`, or turning Stage Manager off.
- A locked Mac returns `SCREEN_LOCKED`. The proprietary locked-use mechanism is
  not reproduced.
- Safari/WebKit, Qt and Java apps, and long multi-step workflows in real
  applications have not been accepted yet.
- Release archives are not notarized; see Permission attribution.

## Sources

- [Apple ScreenCaptureKit sample](https://developer.apple.com/documentation/screencapturekit/capturing-screen-content-in-macos)
- [AXUIElementCopyAttributeValue](https://developer.apple.com/documentation/applicationservices/1462085-axuielementcopyattributevalue)
- [CGEvent.postToPid](https://developer.apple.com/documentation/coregraphics/cgevent/posttopid(_:))
- [NSEvent mouse-event factory](https://developer.apple.com/documentation/appkit/nsevent/mouseevent(with:location:modifierflags:timestamp:windownumber:context:eventnumber:clickcount:pressure:))
