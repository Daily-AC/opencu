# Android

Milestone 1 implements the phone's main display and milestone 2 adds an owned
virtual-display agent desktop. The fixture suite passed all nine main-display
checks in three consecutive rounds and the same checks on the agent display;
stop and configurable-idle lifecycle checks also passed three cycles on the OPPO
PGBM10, Android 14 / API 34. Measurements and the real MCP transcript are in
[the acceptance evidence](../evidence/opencu-android-2026-11-01.json). This establishes
fixture behavior, not general coverage of other apps or OEM builds.

## Build and launch

Requires Android 14 (API 34) or newer, shell uid 2000, and USB/wireless debugging
(or a host that can obtain shell through its authorized elevation channel).
Newer Android versions are untested. The conservative minimum matches the only
connected device and avoids claiming compatibility with older hidden APIs.

Build on a computer with JDK 21, Node 22+, Android platform `android-34`,
build-tools `36.1.0`, and platform-tools:

```sh
export JAVA_HOME=/opt/homebrew/opt/openjdk@21
export ANDROID_HOME="$HOME/Library/Android/sdk"
npm run build:android
npm run test:android
bin/opencu android --serial SERIAL doctor
bin/opencu android --serial SERIAL
```

`ANDROID_SDK_ROOT` also works; `OPENCU_ANDROID_BUILD_TOOLS` can select another
installed toolchain. No dependencies are downloaded by the build. The build bakes
`package.json`'s version into the Java classes. The fixture APK and throwaway
signing key stay under ignored `.build/android/`.

The launcher verifies the full SHA-256 and pushes the jar only when the matching
`/data/local/tmp/opencu-android-<sha256-16>.jar` is absent or has different bytes.
It uses adb shell v2 with `-T`, inherited MCP streams, and diagnostics on stderr.
Without `--serial`, adb's normal device selection and `ANDROID_SERIAL` apply.
The launcher neither pairs nor restarts/disconnects the shared adb server.
Calling `bin/opencu` without `android` is unchanged.

For wanctl packaging, `npm run package:android` writes `dist/opencu-android.jar`
and the content manifest `dist/opencu-android.json` with name, version, file,
size and lowercase SHA-256.

An on-phone host can run this directly as shell:

```sh
CLASSPATH=/data/local/tmp/opencu-android-<sha256-16>.jar \
  app_process / dev.opencu.android.Main mcp
```

Omit `mcp` for the same default; use `doctor` for one JSON object with version,
SDK, uid, pid, UiAutomation connection, display geometry, screen/lock status,
resolved hidden APIs and physical-input monitoring. Root must first drop to shell;
the engine deliberately refuses uid 0 and ordinary app identities.

The Java server implements newline-delimited JSON-RPC 2.0 MCP: `initialize`,
`notifications/initialized`, `tools/list` (opaque pagination cursor), `tools/call`
and `ping`. Unknown methods use `-32601`; invalid params use `-32602`. Tool errors
are `isError: true`, start `CODE: message` and retain the code in
`_meta["opencu/error"]`. Request lines are size-bounded; JSON-RPC batch arrays are
not supported. Stdin EOF cancels queued/in-flight work and exits the VM. There is
no listener, installed engine APK, accessibility service, account or brand gate.

## State and input

`app` is a launchable package name or an exact, case-insensitive launcher label.
Ambiguous labels return `AMBIGUOUS_APP`. `get_app_state` starts or brings forward
the app under the person rules. `list_apps` gives label, package, running and
foreground status. Every input tool returns an updated full state; there is no
diff or scope mode in this milestone.

State reports foreground package/activity, main display size, IME visibility and
a connection-local state id. Visible useful nodes get dense indexes. Pure layout
containers, invisible and empty rectangles are omitted while useful descendants
remain. Lines include class, text, description, resource id, flags, bounds and
secondary action names. Covering windows and the keyboard get their own headers. Persistent status and
navigation bars keep their window headers, but decorative subtrees (including
notification icon labels) are omitted.
Password text is redacted. Traversal is bounded (depth 60, 5000 nodes per window),
and a truncated tree is labelled. Arbitrarily large apps can exceed 4 KB; 4 KB is
a typical-screen target, not silent truncation of every response.

Use `includeScreenshot: true` only when needed. Images are full-display JPEG,
quality 80, long side at most 1280 px. The text result starts with a line such as
`Screenshot: 576x1280 JPEG of the 1080x2400 display; coordinates in later calls
use this image`; screenshot dimensions are also in `_meta["opencu/screenshot"]`.
Coordinate input uses these image pixels, not the physical display coordinates
printed in element bounds. A screenshot grant is
consumed on any app state/action attempt; only a successful new image renews it.
Changed display geometry/rotation or window identity invalidates it. Secure
content is never bypassed. Screenshots can include covering windows.

- `click`: observed `element_index` or both `x,y`; `click_count` 1–3; positive
  `duration` holds a touch for at least the platform long-press interval. Indexed
  clicks inject a touch at the visible center first, so Android views that only
  enter a mode on real touch behave like a person's tap. Accessibility click is
  used only when the center is covered/off-screen or touch injection is unavailable,
  and the returned state says so.
- `drag`: `from_x,from_y,to_x,to_y` from the fresh image, on the active display
  (display 0 unless `agent_desktop` is started).
- `scroll`: observed scrollable element or image point; up/down/left/right and
  short aliases; `pages` defaults to 1, at most 20. Indexed scrolling uses whole
  accessibility pages (fractional counts round up). At the end of a list it
  returns the current state and a notice instead of `ACTION_UNCONFIRMED`.
- `press_key`: back, home, enter/Return, delete/backspace, tab, recents/app_switch,
  search. No volume, power, arbitrary keycodes or modifier chords.
- `type_text`: paste through the focused editor first, preserving Unicode and
  restoring the previous clipboard when it can be read. If paste is unavailable,
  it falls back to accessibility set-text and says so in the result; the
  postcondition still has to match or the call returns `TEXT_INPUT_FAILED`. It
  never types through the person's keyboard. The acceptance Settings search now
  uses the touch-first click plus this paste path.
- `set_value`: replace an indexed editable field's entire value. Use click for
  a checkbox. The editor must actually expose `ACTION_SET_TEXT`.
- `paste`: `format: "text"` only, using the editor's accessibility paste action.
  Saves/restores the previous clipboard if readable and unchanged; refuses
  unreadable clipboard access and reports failed restoration. This clipboard path has not been exercised on the owner's clipboard.
- `perform_secondary_action`: only a name listed on that node, rechecked live.
- `activate_app`: explicit foreground activation under the same person rules. In
agent-desktop mode it launches on the owned display; an app already in front on
display 0 returns `APP_IN_USE_BY_PERSON` without input.

Before indexed input, the engine re-observes and checks window, tree path,
package, class, text, description, resource id and bounds (6 physical-pixel tolerance on display 0; up to 400 pixels while a
virtual display is settling its system-decoration inset). A changed/missing node returns `STALE_ELEMENT` without sending that
input. A false accessibility action result returns `ACTION_UNCONFIRMED`; it is
an unknown outcome and is never replayed. A fresh explicit state read is required
before continuing. A successful action still needs its actual result checked.

## Batches and local conditions

`run_actions {app, actions, includeScreenshot?}` accepts 1–16 input actions and
`{"method":"wait","ms":1..15000}`. Indexes always come from the state before the
batch. Coordinates must be in its first action. Each action can carry:

```json
{"until":{"text":"Fixture result ready","gone":"Loading fixture data","stable":true,"timeoutMs":8000}}
```

All given predicates must hold. `text`/`gone` are case-sensitive substrings of
visible element text/descriptions, excluding headers. `app` requires the named
foreground package/label; `stable: true` means unchanged observable state for
400 ms. Default timeout is 8000 ms, maximum 20000 ms, measured after the action.
Polling is local, normally every 40 ms plus the tree read.

The batch stops on timeout, a new dialog/covering foreign window, unexpected
foreground app, stale element, failed action, lock, physical input or stop.
An ordinary newly opened IME is expected. An explicit `until.app` can authorize
the new foreground for later non-indexed actions; it does not give old indexes
new meanings or renew coordinates. New activities within the same app are not
classified as dialogs solely for changing window id.

`_meta["opencu/batch"]` reports `completed`, one-based `stoppedStep`, `reason` and
`waitedMs` for the last step (including action time), followed by the final state.
Typical reasons: `timeout`, `popup`, `system_dialog`, `app_switched`,
`stale_element`, `person_active`, `user_stopped`, `screen_locked`. Earlier input
may have executed. Never retry the stopped sequence automatically.

## Agent desktop

`agent_desktop start` creates a virtual display matching display 0's physical
size and density. On the accepted PGBM10 it obtained flags value `97737`,
including `PUBLIC`, `OWN_CONTENT_ONLY`, `SUPPORTS_TOUCH`, `ROTATES_WITH_CONTENT`,
`DESTROY_CONTENT_ON_REMOVAL`, `TRUSTED`, `OWN_DISPLAY_GROUP`, `ALWAYS_UNLOCKED`,
`TOUCH_FEEDBACK_DISABLED`, `OWN_FOCUS` and `STEAL_TOP_FOCUS_DISABLED`. The
engine reports these flags, the display id and `imePolicy:"local"` in status.
The shell must have trusted-display permission; otherwise it retries with a
smaller untrusted flag set and reports that fact.

The person keeps display 0. App starts use `--display <id>`, input events carry
the active display id, screenshots and accessibility windows come from a
separate display-bound `UiAutomation` connection, and `setDisplayImePolicy`
keeps the IME local. Touches on display 0 do not interrupt agent-display work;
volume-down stop still latches `USER_STOPPED`. If the requested app is currently
frontmost on display 0, the call returns `APP_IN_USE_BY_PERSON` before sending
anything. Stop and EOF move owned tasks to the back and release the display.
The engine restores the launcher when the person was on the launcher; no agent
app is intentionally finished. A five-minute call-free period stops the display
and the next app call returns `AGENT_DESKTOP_IDLE_STOPPED`. The verifier accepts
a shorter `--idle-ms` for lifecycle tests.

The owner fixture run passed the main-display checks three times on the agent
display, with display 0 remaining on the launcher and no leftover engine process.
The display-0 lock transition, physical main-display interruption, and a visual
pixel diff outside the status bar remain owner follow-ups; no screen wake or
unlock was attempted. A locked or screen-off phone still returns `SCREEN_LOCKED`.

The notification probe used `cmd notification post` as `com.android.shell` and
successfully created a visible shell notification, but shell `cmd notification`
has no cancel/action subcommand, and a temporary app_process cancel probe was
killed by the device. The notification therefore cannot safely ship with a Stop
action; the volume gesture is the only shipped person stop. The probe notification
was snoozed for one day and is recorded as an unverified OEM limitation.

## The person wins

A resident platform `getevent -lt` process reads `/dev/input/event*`. These kernel
evdev events are below Android's InputManager injection, so UiAutomation and
`input keyevent` events are not counted as physical input. The engine checks that
touch and volume-down devices can be read and fails closed if monitoring dies or
a monitored device disappears. Kernel virtual/uinput devices are conservatively
counted as physical; there is no claim of distinguishing arbitrary kernel-level
injection from hardware. Hot-unplug requires a new, explicitly permitted session.

A foreground change requires 10 seconds without physical input. Because evdev
has no historical event stream, each connection starts with a conservative
10-second foreground-change holdoff. Input may proceed sooner when the requested
app is already in front and no physical key/contact is held. Physical input
arriving during a call/batch aborts further input with `PERSON_ACTIVE`; ask the
person before continuing. The engine requires a fresh observation afterwards.

Three distinct physical volume-down presses within 1.5 seconds latch
`USER_STOPPED`. Repeats from one held key do not count. All subsequent input,
activation and launches fail; read-only state/inventory remain available. The
Linux stop payload is delivered inside a valid MCP notification, keeping stdout
MCP-only:

```json
{"jsonrpc":"2.0","method":"notifications/message","params":{"level":"warning","logger":"opencu","data":{"event":"stop","error":{"code":"USER_STOPPED","message":"…"}}}}
```

Hosts must latch that notice immediately, as well as tool errors. Keep one
connection per agent session; never reconnect to clear a stop. EOF cleans up the
monitor and UiAutomation even while a batch is waiting. Do not operate the same
app through concurrent connections. Host call deadlines must accommodate all
requested action durations and local waits; no timed-out input is replayed.

Input requires `PowerManager.isInteractive()` and an unlocked
`KeyguardManager.isKeyguardLocked()` result. `SCREEN_LOCKED` never wakes, unlocks,
enters credentials or changes a setting. The real triple press, held contacts,
mid-call interruption and lock transition remain owner acceptance tasks.

## Validation and limits

`npm run test:android` runs production-core logic on a host JVM. Tests include a real normalized fixture tree from the PGBM10,
the AOSP documentation's published two-finger evdev trace, and synthetic edge
cases for stop-gesture timing and state transitions. The original source and
Apache 2.0 notice for the trace are in `native-android/THIRD_PARTY_NOTICES.md`. `node scripts/verify-android.mjs --serial
SERIAL` installs only `dev.opencu.android.fixture`, runs the requested checks in
three consecutive rounds, compares its private `truth.json` using `run-as`,
measures ten samples per timing and uninstalls it unless `--keep` is specified.
OEM installation approval is never automated. A failed install stops the suite.

Measured on the PGBM10 over wireless adb (10 samples each):

| Operation | Median | Target |
|---|---:|---:|
| Launcher start to first tools/list | 770 ms | — |
| Open-app text read | 272 ms | <=300 ms |
| Indexed click including state | 481 ms | <=800 ms |
| Screenshot read | 763 ms | <=800 ms |
| Plain indexed batch click step (10 steps) | 232 ms | <=250 ms |

Direct package-name resolution avoids loading other apps' labels. The final
PGBM10 samples and desktop lifecycle evidence are in the committed evidence;
all required targets passed. Startup includes computer launcher/cache
verification, wireless adb, MCP initialize and first tools/list answer. The evidence retains every sample and reports target misses without relaxing
assertions. Plain indexed batch steps measured 232 ms for ten clicks. On ColorOS, `cmd media_session volume --set` returned success without
applying the value. The verifier instead restores the original media volume via
injected volume-up events while the fixture explicitly routes keys to media; it
reads back every increment. The owner completed the initial OEM installation
confirmation; subsequent streamed fixture installs succeeded without UI input.

Known unverified boundaries include OEM clipboard policy for unrelated custom
editors, coordinate drag/long press, custom secondary actions, custom/WebView
trees, secure
screenshot behavior, orientation changes, physical stop and EOF during blocked
Binder calls. The fixture suite covers Unicode set_value, keyboard-path
`type_text` with ASCII and Chinese text, indexed clicks and
scrolls, back, popup/stale guards, local waits, injected-volume exclusion and idle EOF. Polling cannot detect a window
that appears and disappears entirely between observations. System UI windows use
platform window types; OEM dialogs presented as activities can be reported as
`app_switched` instead of `system_dialog`.

Remaining milestone 2 risks are OEM task reuse for single-task apps, permission
activities, display lock transitions, coordinate gestures, clipboard behavior,
and restoration when a task moves itself after display release. Virtual-display
windows, screenshots, display-targeted input, IME locality, APP_IN_USE_BY_PERSON,
stop, EOF and configurable idle were accepted only with the fixture on this
PGBM10.

Implementation references were the supplied local UiAutomation spike and Android
SDK/AOSP API definitions ([UiAutomation](https://android.googlesource.com/platform/frameworks/base/+/refs/heads/main/core/java/android/app/UiAutomation.java),
[getevent](https://source.android.com/docs/core/interaction/input/getevent)).
No Mika or scrcpy implementation was copied or adapted. The AOSP trace is
attributed test data; no third-party implementation is bundled in the engine.
