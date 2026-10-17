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
`responsibility_get_pid_responsible_for_pid`. Their availability can change between
macOS releases.

## Permission attribution

macOS attributes Accessibility and Screen Recording to the responsible process,
normally the app that started the MCP client. Without intervention, OpenCU would
need each client's terminal or desktop app to be authorized, and the grant shown
for OpenCU in System Settings would be ignored.

The original 2026-10-12 `serve` and `--doctor` implementation respawned once with responsibility
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
it. Never use LaunchServices with redirected FIFO streams. The 2026-10-17
worker uses authenticated Unix sockets after launch instead; `bin/opencu setup`
continues to use `open` for the permission dialog without redirected streams.

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

These are the applications measured on October 12, not universal WindowServer
rules. [The October 15 Blender investigation](opencu-blender-2026-10-15.md)
obtained a full-size off-stage screenshot and found a different input limitation.

- Screenshots: every capture path yields the thumbnail or nothing.
  [Capture evidence](../evidence/opencu-stage-manager-capture-2026-10-12.json)
- The window cannot become key, even after setting `AXMain` or `AXFocused`, so
  window commands such as Save and Close are disabled.
- Chromium does not render the page (`visibilityState` is hidden), so no web
  content is exposed. A fully covered window behaves the same way.
- Keyboard input reached TextEdit in a thumbnail window but not VS Code in a fully
  hidden one. Reading and indexed actions work in both.

OpenCU detects both presentation states from WindowServer without capture
permission and says so in the returned state, recommending `activate_app` for
steps that need more. The current implementation reports capture availability
separately rather than inferring it from presentation state.
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

- macOS presence includes the V cursor, menu Stop, localized setup and an action
  badge in the target title bar. On 2026-10-15 the owner reported two 18/18 GUI
  runs, a smooth visible cursor, working menu Stop, and a post-click engine
  screenshot without the cursor. The newly added badge is checked only through
  pure logic and offscreen fixture rendering: its live stacking, capture exclusion,
  AX title-bar placement, secure-focus metadata and focus behavior still need
  reviewer acceptance. See the [badge contract](independent-engine-contract.md#macos-title-bar-badge).
- Custom title bars without usable AX toolbar/title geometry use a 28 pt title
  region. Badge text is capped to 45% width, with glyph-only display below 260 pt.
  Unverified text focus is masked; the badge never reads the existing clipboard.
- Cursor display requires an exact visible window and usable element centre;
  windowless menu actions and hidden/Stage Manager thumbnails have no indicator
  over the target. Stop cannot undo input already delivered or prevent a client
  from deliberately starting a new engine; hosts must respect the person's stop.
- Screen Recording setup conservatively requests reconnection after a new grant
  or request in the current process, even on OS versions that may apply it sooner.

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

## 2026-10-17: independent worker

The previous responsibility-disclaimed child fixed TCC responsibility but stayed
inside its caller's launchd job and resource coalition. Measurements supplied for
this Mac on 2026-10-17 established two separate attribution paths. ScreenCaptureKit's
macOS 15+ private-window-picker reminder stores approval using replayd's attribution
identity (`responsibility_get_attribution_for_audittoken`, binary path to bundle ID),
which was already `dev.opencu.engine`. The displayed name instead comes from
`RPClient.clientMainBundleID`, through `+[SCProcessUtility hostApplicationWithAuditToken:bundleID:]`
and `+[AVCaptureDevice proprietaryDefaultsDomainForAuditToken:]`, an XPC query to
the CMIO attribution service that resolves the host job. Under the Claude Reader
LaunchAgent this displayed “node” (previously “bash”), alarmingly suggesting an
arbitrary interpreter had screen access. The measured reminder interval is a
hard-coded 30 days. Self responsibility alone does not fix that displayed name.

The caller's LaunchAgent had no ProcessType. launchd clamped its entire tree to
utility QoS: engine threads remained at priority 20 despite QoS raises, and cold
list_apps took 35–75 seconds. A separate Interactive-job experiment reported the
engine as its own responsible PID and attribution binary, in its own coalition,
with priority 31 and successful screenshots. These are the supplied investigation
results, not new capture tests in this change.

The first implementation launched a new background OpenCU app instance through
NSWorkspace/LaunchServices; the final one bootstraps an Interactive launchd job
instead (see the end of this section). The spawned executable only relays stdio over a
private token-and-peer-PID-authenticated Unix socket. The worker uses its own job,
permissions and coalition, holds a user-initiated activity that allows idle system
sleep, and keeps the existing EOF cleanup for synthetic focus and agent display.
It runs outside the caller's sandbox, like setup already does. No LaunchAgent,
TCC, Spaces or Stage Manager configuration changes are needed. The historical
FIFO launch failure remains prohibited; no LaunchServices stdio redirection is used.

Validation and measured process values for this implementation are recorded below.
GUI/capture/input and virtual-display acceptance are reserved for the reviewer.

Measured read-only acceptance on this Mac (2026-10-17):

| Measurement | Relay | Independent worker |
| --- | --- | --- |
| PID | 6268 | 6269 |
| Responsible PID | 73007 (caller host) | 6269 (self) |
| Parent PID | 6264 | 1 |
| Resource coalition | 613048 | 682699 |
| Jetsam coalition | 613049 | 682700 |
| `ps -M` thread priorities | 20 | 31–46 (main thread 46) |
| Attribution executable | caller's node host | OpenCU.app/Contents/MacOS/opencu-engine |

The supplied `exitprobe/attr` and `exitprobe/coal` tools measured those attribution
and coalition values. Doctor reported Accessibility and Screen Recording true,
verifiedSelfResponsible true, and a worker PID different from the relay PID.
The 295 list_apps IDs/display names matched the pre-change main implementation;
the measured worker call took 0.481 seconds. This was a warm inventory comparison,
not a repeat of the historical 35–75 second cold measurement.

SIGKILL of the relay caused worker exit in 0.050 seconds. Closing stdin exited
both processes. SIGTERM, SIGINT and SIGHUP also exited both, with relay statuses
143, 130 and 129. These checks exercised disconnected idle workers, not real
synthetic-focus/display cleanup (GUI acceptance remains for the reviewer).
Ten consecutive serve starts produced 85 foreground samples at a requested
50 ms interval with no change; all ten workers registered as UIElement, the
LaunchServices policy that excludes Dock icons. No screenshots or other-app
window operations were used for this check. Private inventories, foreground
identities and full process output remain only in ignored `.cache/` files.

Offline tests compile WorkerTransport.swift without AppKit and exercise real
socketpairs/local sockets: token and peer-PID rejection, malformed/fragmented and
duplicate handshakes, doctor-only transport, payload preservation, bounded byte
forwarding, stderr, EOF in both directions, /dev/null descriptors, SIGTERM cleanup
and its grace deadline. Short-lived worker acknowledgement is necessary because
LOCAL_PEERPID fails with ENOTCONN after the peer exits. AppKit check-in must precede
that acknowledgement wait, so LaunchServices can return the worker's PID.

The release sandbox probe exposed an additional LaunchServices boundary: the
AppKit SDK documents that sandboxed callers' `arguments` are ignored, and this
Mac also stripped the configured environment. An environment-only duplication of
the invocation was tested and removed because it did not work. Such launches
initially entered the old no-argument setup path; those temporary instances were
terminated without granting permissions or changing TCC. Setup now requires the
explicit `--setup` argument used by `bin/opencu setup`, so a stripped worker
invocation cannot create setup UI. Supporting sandboxed callers requires a
separate launch-message protocol; the argv/environment protocol does not suffice.

The chosen scope retains the specified argv/environment protocol. Release runtime
checks therefore run outside sandbox-exec, with separate sandbox capability
probes; receipts explicitly mark runtime_sandboxed false. They verify the actual
worker's empty HOME and extracted-bundle executable. This does not establish
sandbox confinement or sandboxed-caller support. No AppleEvent launch protocol
was added.

### launchd instead of LaunchServices (reviewer, 2026-10-17)

With the LaunchServices worker, the first capture from a new build path raised
the reminder and the person read the name **OpenCU** in it (previously "node").
But GUI acceptance failed three times out of three at different Open/Save panel
steps: the open panel's identity was missing from the tree; `press_key` after
cancelling the panel reported STALE_APPLICATION for the unchanged target PID; the
target became frontmost after AXPress Save on the save sheet. The previous
disclaimed-child model passed 18/18 in the same session, external display
attached. An app that LaunchServices launches holds activation rights that the
panel service honoured when returning focus; that turned OpenCU's background
focus into real activation. The worker is now a per-connection Interactive
launchd job instead: responsible PID itself, its own coalition, main thread at
priority 31 with the caller clamped to 20, worker exit 0.13 s after relay
SIGKILL, ten starts without a foreground change, release check 3/3.

Correction to the reminder analysis above: every observed reminder and absence
fits replayd keying approval by the engine **executable path** (a new build
location reminds once, the same location does not), not by bundle ID. A caller
sandbox that denies networking also denies the relay's local socket.
