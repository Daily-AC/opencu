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
installed toolchain. The engine and fixture compile against `android-34`'s
`android.jar` as the boot class path (with build-tools' `core-lambda-stubs.jar`,
at Java language level 8), so `java.*` resolves to Android's classes and a Java
API that Android lacks fails the build rather than the phone. No dependencies are downloaded by the build. The build bakes
`package.json`'s version into the Java classes. The fixture APK and throwaway
signing key stay under ignored `.build/android/`.

The launcher verifies the full SHA-256 and pushes the jar only when the matching
`/data/local/tmp/opencu-android-<sha256-16>.jar` is absent or has different bytes.
It uses adb shell v2 with `-T`, inherited MCP streams, and diagnostics on stderr.
Without `--serial`, the launcher asks adb for the one connected device
(`ANDROID_SERIAL` still selects it) and passes that serial to every adb call of
the launch, so the hash check, publication and launch reach the same phone.
The launcher neither pairs nor restarts/disconnects the shared adb server.

The cache lives in `/data/local/tmp`, which only shell and root can write. Both
already hold the identity the engine runs as, so a file swapped there between
verification and launch grants its writer nothing new, and the launcher does not
try to pin the file object further. It does refuse to launch a cached jar that is
not a regular file owned by shell with mode 0644 or stricter, printing
`UNSAFE_ENGINE_JAR: …` on stderr; remove that file and launch again. An on-phone
host that starts the jar itself relies on the same assumption.
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

A fatal error prints exactly one stderr line `CODE: detail`, where the code is
`UNSUPPORTED_PLATFORM`, `PERMISSION_DENIED`, `UIAUTOMATION_UNAVAILABLE` or
`INVALID_ARGUMENT` when the cause is known, otherwise `ENGINE_START_FAILED`,
`DOCTOR_FAILED` or `ENGINE_FAILED` by stage, and the detail is the exception
class and message folded to one line of at most 300 characters. It never contains
screen or clipboard content. `doctor` also returns that line as `error`.

The Java server implements newline-delimited JSON-RPC 2.0 MCP: `initialize`,
`notifications/initialized`, `tools/list` (opaque pagination cursor), `tools/call`
and `ping`. Unknown methods use `-32601`; invalid params use `-32602`. Tool errors
are `isError: true`, start `CODE: message` and retain the code in
`_meta["opencu/error"]`. Request lines are size-bounded; JSON-RPC batch arrays are
not supported. Stdin EOF refuses further work, kills running platform clients
(`input`, `am`), waits up to one second for an in-flight call to unwind, releases
the agent display and exits the VM. There is no listener, installed engine APK, accessibility service, account or brand gate.

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

Use `includeScreenshot: true` only when needed. Images are JPEG of the whole
active display (the same display the element lines describe), quality 80, long
side at most 1280 px. The text result starts with a line such as
`Screenshot: 576x1280 JPEG of the 1080x2400 display; coordinates in later calls
use this image`; screenshot dimensions are also in `_meta["opencu/screenshot"]`.
Coordinate input uses these image pixels, not the physical display coordinates
printed in element bounds. A screenshot grant is
consumed on any app state/action attempt; only a successful new image renews it.
A different display, changed display geometry/rotation or window identity
invalidates it. Secure content is never bypassed. Screenshots can include covering
windows. While `agent_desktop` is started, images come only from the agent
display's own frames (see [Agent desktop](#agent-desktop)); display 0 is never
captured in their place.

- `click`: observed `element_index` or both `x,y`; `click_count` 1–3; positive
  `duration` holds a touch for at least the platform long-press interval. Indexed
  clicks inject a touch at the visible center first, so Android views that only
  enter a mode on real touch behave like a person's tap. Accessibility click is
  used only when touch is known unusable before anything is sent (the centre is
  covered or off-screen, the input tool cannot start, or display-targeted
  injection is missing), and the returned state says why. A touch that may have
  been delivered (the input tool timed out, failed or was interrupted) returns
  `ACTION_UNCONFIRMED` and is never repeated another way.
- `drag`: `from_x,from_y,to_x,to_y` from the fresh image, on the active display
  (display 0 unless `agent_desktop` is started).
- `scroll`: an observed element or image point; up/down/left/right and short
  aliases; `pages` (default 1, at most 20) moves further in one call (fractional
  counts round up). An indexed scroll moves the element when it scrolls (it says
  so or offers a scroll action), otherwise the nearest enclosing element that
  scrolls, so a row's index scrolls its list; an element with neither returns
  `ACTION_UNSUPPORTED` with nothing sent. Each page uses, in order: that
  element's scroll action for the direction (the direction-specific one, or
  generic forward/backward as down/right and up/left unless the element offers
  direction-specific actions on the other axis only); the direction-specific
  action of the nearest scrolling element enclosing it (a generic one is ambiguous
  there: a horizontal pager's backward is the previous tab); otherwise a touch
  swipe through the centre of the element's visible part, from 80% to 20% of it,
  clear of windows above it such as the keyboard and of the display's outer
  strips, held still before lifting so the list stops where the finger stopped.
  The swipe is ordinary touch input on the active display under the person rules.
  ColorOS lists were seen offering only scroll-forward part-way down, so scrolling
  up such a list swipes. A swiped page moves about 60% of the visible list, so
  swiped pages overlap. When a page was not sent by the element's own action, the
  result says how it was sent.
  After each page the engine waits for the content to settle and compares it with
  the content before the page: the scrolled element's own text, description and
  bounds and those of its descendants, with their selected and checked state (the
  screen, for coordinates). A wheel picker's new value therefore counts wherever
  it shows; a change that springs back, such as an overscroll bounce, does not.
  An accessibility page is watched for 0.9 s before it counts as not moved,
  because a picker can change its value only after animating, and a page waits at
  most one second. A page that did not move ends the call with a notice such as
  `Scrolled 3 of 5 pages; reached the end`, or `Nothing moved; the list is at its
  end or does not scroll this way` on the first page; a page whose content changed
  counts even when the accessibility action returned false. Only a failed read
  after scrolling returns `ACTION_UNCONFIRMED`.
  The scrolled element is followed from page to page even when its tree path,
  bounds or text change (a collapsing toolbar resizes a list and shifts the
  indexes, a wheel shows its next value): it is the same element, or the only one
  in its window with its class and resource id. A new dialog or foreign window or
  another foreground app still stops the call as `POPUP`; if the element can no
  longer be found (for example in a new activity) the remaining pages are not sent
  and the notice says so, such as `Scrolled 1 of 3 pages; the scrolled element was
  not found on the new screen, so the rest were not sent`.
  When more than one page was requested, the result lists the rows on the pages
  scrolled past, after the notice and before the state, under `Passed over while
  scrolling (N distinct rows, in order; the final page is the state below):`.
  Each row joins the text, descriptions and checked state inside one child of the
  scrolled element (a wheel's own value is a row); rows are distinct and in the
  order met, at most 200 rows of at most 200 characters, and password fields are
  left out. One call can therefore read a long list.
- `press_key`: back, home, enter/Return, delete/backspace, tab, recents/app_switch,
  search. No volume, power, arbitrary keycodes or modifier chords.
- `type_text`: types into the focused editable only. Without one it returns
  `NO_FOCUSED_ELEMENT` and sends nothing; click the intended field first. It
  replaces the editor's selected range through accessibility set-text, Unicode
  included. Set-text rewrites the whole field, so spans such as mentions or links
  become plain text. The caret is then placed after the inserted text, so a further
  `type_text` continues there; if the editor does not confirm that, the result
  says so and it is not retried. It never uses the clipboard or the person's keyboard, and never sends
  the text another way; an unconfirmed set-text returns `ACTION_UNCONFIRMED`. The
  editor's resulting text must match or the call returns `TEXT_INPUT_FAILED`. A
  field that acts only on typed keys may not react. Android reports password text
  masked, so a password field that already has text (and is not wholly selected)
  returns `PASSWORD_INSERT_UNSUPPORTED` with nothing sent; use `set_value` to
  replace the whole value. An empty or wholly selected password field is set and
  checked by length only, and the result says so. An app reaction can arrive after
  the text postcondition; use `waitForText` or an `until` condition to observe it.
  These waits search visible non-editor content, so the editor's own newly typed
  value does not satisfy a reaction wait by itself.
- `set_value`: replace an indexed editable field's entire value. Use click for
  a checkbox. The editor must actually expose `ACTION_SET_TEXT`.
- `paste`: `format: "text"` only; inserts the text exactly as `type_text` does.
  The clipboard is neither read nor changed.
- `perform_secondary_action`: only a name listed on that node, rechecked live;
  the live node must still carry the same name (including its label) under the
  same action id, otherwise `STALE_ELEMENT`.
- `activate_app`: explicit foreground activation under the same person rules. In
agent-desktop mode it launches on the owned display; an app already in front on
display 0 returns `APP_IN_USE_BY_PERSON` without input.

Before indexed input, the engine settles, re-observes and checks activity,
display, window, tree path, package, class, text, description, resource id and
bounds within 6 physical pixels. On an owned virtual display a window may shift as
a whole (up to 400 pixels) while its decoration insets settle; that is accepted
only when every other element of that window moved by the same amount. Touches go
to the matched element's current centre. A changed/missing node returns
`STALE_ELEMENT` without sending that input; the error names the components that
changed (for example `changed: text` or `changed: bounds`) and shows the old and
current tree path, window and bounds, never node text. A false accessibility action result returns `ACTION_UNCONFIRMED`; it is
an unknown outcome and is never replayed. A fresh explicit state read is required
before continuing, as after any failure once input may have reached the phone.
A state's indexes and screenshot grant become current only with a complete
response; a failed screenshot leaves the last returned state in force. A successful action still needs its actual result checked.

## Batches and local conditions

`run_actions {app, actions, includeScreenshot?}` accepts 1–16 input actions and
`{"method":"wait","ms":1..15000}`. Indexes always come from the state before the
batch. Every step reads the screen afresh right before it sends input and
compares it with the state left by the previous step. Only the first action may
use screenshot coordinates (`x,y` on `click` or `scroll`, or a `drag`), so a batch
has at most one coordinate action; a coordinate action in any later position is
rejected with `INVALID_ARGUMENT` (`Coordinate input must be the first batch
action`) before anything is sent. Each action can carry:

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

A batch is limited to 100 seconds from the start of the call, inside a host's
two-minute call limit. Before each step the engine adds the step's longest possible
time (holds, `ms`, one second per scroll page, the `until` timeout and two seconds
for reading) to the time used so far; if that would pass the limit, the step is not
sent and the batch stops with reason `time_limit` and `BATCH_TIME_LIMIT`. A
multi-page scroll also stops before a page that could pass the limit (with a
notice), and an `until` wait ends at the limit at the latest, also as `time_limit`.

`_meta["opencu/batch"]` reports `completed`, one-based `stoppedStep`, `reason` and
`waitedMs` for the last step (including action time), followed by the final state.
Typical reasons: `timeout`, `time_limit`, `popup`, `system_dialog`, `app_switched`,
`stale_element`, `person_active`, `user_stopped`, `screen_locked`. Earlier input
may have executed. Never retry the stopped sequence automatically.

## Agent desktop

`agent_desktop start` creates a virtual display matching display 0's physical
size and density. On the accepted PGBM10 it obtained flags value `97737`,
including `PUBLIC`, `OWN_CONTENT_ONLY`, `SUPPORTS_TOUCH`, `ROTATES_WITH_CONTENT`,
`DESTROY_CONTENT_ON_REMOVAL`, `TRUSTED`, `OWN_DISPLAY_GROUP`, `ALWAYS_UNLOCKED`,
`TOUCH_FEEDBACK_DISABLED`, `OWN_FOCUS` and `STEAL_TOP_FOCUS_DISABLED`. The
engine reports these flags, the display id and `imePolicy:"local"` in status.
Start requires a trusted display that keeps its own focus and cannot take the top
focus, as read back from the display's flags (`displayFlags` in status), and a
local IME policy read back from the window manager. If any is missing, start
releases everything and returns `AGENT_DESKTOP_UNAVAILABLE`; there is no weaker
fallback. Start is all-or-nothing: on failure the display and agent connection
are released and the main-display connection is restored; if that restoration
fails, the connection returns `DISPLAY_UNAVAILABLE` until a new connection.

The person keeps display 0. App starts use `--display <id>`, input events carry
the active display id, accessibility windows come from a separate display-bound
`UiAutomation` connection, and `setDisplayImePolicy` keeps the IME local.
Screenshots do not use `UiAutomation`: on Android 14 its `takeScreenshot` captures
display 0 whatever display the connection is bound to (on the PGBM10 the element
lines described the agent display while the image showed the person's home
screen). The virtual display instead renders into an `ImageReader` (RGBA_8888)
that keeps only its newest frame, and a screenshot copies that frame. If no frame
arrives within 1.5 seconds or it cannot be read, the call returns
`SCREENSHOT_FAILED` and grants no coordinates; display 0 is never captured
instead. This capture path has host checks only; device verification is an owner
follow-up. Touches on display 0 do not interrupt agent-display work;
volume-down stop still latches `USER_STOPPED`. If the requested app is currently
frontmost on display 0, the call returns `APP_IN_USE_BY_PERSON` before sending
anything. Stop and EOF move owned tasks to the back and release the display.
The engine restores the launcher when the person was on the launcher; no agent
app is intentionally finished. Five minutes after the last call ends, the
connection's own worker stops the display (never during a call), and the next app
call returns `AGENT_DESKTOP_IDLE_STOPPED`. `status` does not keep it alive. The verifier accepts
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
has no historical event stream, the engine starts the monitor, waits until every
device is open, and only then seeds the last activity from the power service's
last user activity time: a touch before that moment is in that time, and any later
touch is seen by the monitor. A contact already held when monitoring begins is
known only through that time until it next moves or lifts. Input may proceed sooner when the requested
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

`npm run test:android` runs production-core logic on a host JVM. It also runs the
engine's own decision code (identity, input paths, scrolling, batches,
shutdown, idle stop, agent-display start) against a scripted phone, and the
launcher against a local fake adb. Tests include a real normalized fixture tree from the PGBM10,
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

Known unverified boundaries include custom editors that ignore accessibility
set-text, coordinate drag/long press, custom secondary actions, custom/WebView
trees, secure
screenshot behavior, orientation changes, physical stop and EOF during blocked
Binder calls. The fixture suite covers Unicode set_value, `type_text` with ASCII
and Chinese text, indexed clicks and
scrolls, back, popup/stale guards, local waits, injected-volume exclusion and idle EOF. Polling cannot detect a window
that appears and disappears entirely between observations. System UI windows use
platform window types; OEM dialogs presented as activities can be reported as
`app_switched` instead of `system_dialog`.

Remaining milestone 2 risks are OEM task reuse for single-task apps, permission
activities, display lock transitions, coordinate gestures, and restoration when a task moves itself after display release. Virtual-display
windows, screenshots, display-targeted input, IME locality, APP_IN_USE_BY_PERSON,
stop, EOF and configurable idle were accepted only with the fixture on this
PGBM10.

Implementation references were the supplied local UiAutomation spike and Android
SDK/AOSP API definitions ([UiAutomation](https://android.googlesource.com/platform/frameworks/base/+/refs/heads/main/core/java/android/app/UiAutomation.java),
[getevent](https://source.android.com/docs/core/interaction/input/getevent)).
No Mika or scrcpy implementation was copied or adapted. The AOSP trace is
attributed test data; no third-party implementation is bundled in the engine.
