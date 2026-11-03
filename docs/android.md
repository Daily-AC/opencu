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

When the phone or its adb transport is gone, the computer-side launcher (`bin/opencu
android`) ends with its own coded stderr line, so a host does not report an engine
fault: `DEVICE_UNAVAILABLE: adb cannot reach the phone SERIAL (adb's reason); …`.
Before launch it ends `the engine was not started and nothing was sent`. When the
adb connection ends while the engine runs (the launch exits with an error and adb
no longer reports the phone as `device`), it says the connection ended while the
engine was running and that a call in progress may or may not have reached the
phone, so state must be read before any further input. Restoring adb is up to the
person or host; a new connection never clears a person's stop.

The Java server implements newline-delimited JSON-RPC 2.0 MCP: `initialize`,
`notifications/initialized`, `tools/list` (opaque pagination cursor), `tools/call`
and `ping`. Unknown methods use `-32601`; invalid params use `-32602`. Tool errors
are `isError: true`, start `CODE: message` and retain the code in
`_meta["opencu/error"]`. Request lines are size-bounded; JSON-RPC batch arrays are
not supported. Stdin EOF refuses further work, kills running platform clients
(`input`, `am`), waits up to one second for an in-flight call to unwind, releases
the agent display and exits the VM. There is no listener, installed engine APK, accessibility service, account or brand gate;
the optional [companion app](#companion-app) only shows status and a preview and offers Stop.

## State and input

`app` is a launchable package name or an exact, case-insensitive launcher label.
Ambiguous labels return `AMBIGUOUS_APP`. `get_app_state` starts or brings forward
the app under the person rules. `list_apps` gives label, package, running and
foreground status. Every input tool returns an updated full state; there is no
diff or scope mode in this milestone. That state is read once the screen is
stable, so a key still scaled by its press animation, a moving result row or a
wheel still settling is not returned as the result: after input the engine reads
until two reads 120 ms apart agree, for at most 1.5 s (never past a batch's time
limit). `_meta["opencu/settle"]` reports `waitedMs` and `stable`, which is false
when the bound ended the wait, as on a screen that keeps animating.

State reports foreground package/activity, main display size, IME visibility and
a connection-local state id. Visible useful nodes get dense indexes. Pure layout
containers, invisible and empty rectangles are omitted while useful descendants
remain. Lines include class, text, description, resource id, flags, a range element's
value and range, bounds and secondary action names. Covering windows and the keyboard get their own headers. Persistent status and
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

- `click`: observed `element_index` or both `x,y` (pixels of the fresh image);
  `click_count` 1–3; positive
  `duration` holds a touch for at least the platform long-press interval. Indexed
  clicks inject a touch, so Android views that only enter a mode on real touch
  behave like a person's tap. The touch goes to the centre of the element's
  visible part, or, when something drawn above covers the centre, to the
  uncovered point of that part nearest the centre, and the result says where and
  what covered the centre. Covering are windows above the element's window, its
  own descendants that act on their own (clickable, editable or described), and
  in its window elements drawn above it that take touches, such as a floating
  action button (by the drawing order Android reports, else tree order).
  Accessibility click is used only when touch is known unusable before anything is
  sent (every visible point is covered, the element is off-screen, the input tool
  cannot start, or display-targeted injection is missing), and the returned state
  says why. A touch that may have
  been delivered (the input tool timed out, failed or was interrupted) returns
  `ACTION_UNCONFIRMED` and is never repeated another way.
- `drag`: `from_x,from_y,to_x,to_y` in pixels of the fresh image (not display
  pixels), on the active display (display 0 unless `agent_desktop` is started).
- `scroll`: an observed element or a point in pixels of the fresh image;
  up/down/left/right and short aliases; `pages` (default 1, at most 20) moves
  further in one call (fractional counts round up). One `scroll` with `pages`
  returns every row it passed over, so a whole list is read in one call rather
  than page by page (on the PGBM10 an agent read 29 alarms with 16 one-page calls
  where one `pages: 20` call returned them all). An indexed scroll moves the
  wheel picker the element is or is a row of, else the element when it scrolls (it says
  so or offers a scroll action), otherwise the nearest enclosing element that
  scrolls, so a row's index scrolls its list; an element with neither returns
  `ACTION_UNSUPPORTED` with nothing sent. Each page uses, in order: that
  element's own scroll action for the direction (generic forward/backward as
  down/right and up/left, which is what its line lists and what some views such
  as wheel pickers handle, unless the element offers direction-specific actions
  on the other axis; else its direction-specific action); the direction-specific
  action of the nearest scrolling element enclosing it (a generic one is ambiguous
  there: a horizontal pager's backward is the previous tab); otherwise a touch
  swipe inside the element's visible part, from 90% to 10% of it, clear of windows
  above it such as the keyboard and of the display's outer strips, held still
  before lifting so the list stops where the finger stopped. Once the element
  listed its own generic action for the direction (in the state the call is based
  on, or on an earlier page), that action keeps being sent even when the element
  stops listing it, and the content decides whether the page moved; it is never
  replaced by a swipe. A swipe runs through the centre, or else through another
  lane across the element, and never comes within a finger's reach (24 px) of an
  element a swipe could set: a wheel, slider, nested scroller or anything with a
  range or its own scroll actions. On a tree cut short at its node or depth limit
  no swipe is chosen, since something unseen could be in the way. When no lane is
  clear, the call returns
  `ACTION_UNSUPPORTED` naming that element, with nothing sent (or, after earlier
  pages, ends with a notice). After any swipe, a value that changed outside the
  scrolled element (a checked state, a range value, an editor's text or a wheel's
  selected value) is reported first in the result, such as `WARNING: the swipe
  also changed Switch id=vibrate not checked -> checked`, and no further pages are
  sent. The scrolled element and everything inside it are left out of that check,
  since its rows come, go and are recycled (every alarm row's switch on the
  PGBM10 has the same id, so an alarm that was on scrolling into a row once
  produced a false warning); for a coordinate swipe that is the innermost element
  under the finger that scrolls and holds no value itself (not a wheel, slider or
  other range). A control is the same one only when its window, tree path, class,
  resource id and the text around it match; that text leaves out the scrolled
  element's and value holders' own rows, so a slider beside the list in the same
  layout is still recognised. The check visits each element once per ancestor. A
  page that the warning stops after is listed as passed over; the state after it
  is the final page.
  The swipe is ordinary touch input on the active display under the person rules.
  ColorOS lists were seen offering only scroll-forward part-way down, so scrolling
  up such a list swipes. The Clock alarm list's enclosing coordinator then lists a
  generic scroll-backward once its toolbar has collapsed, but a generic action on an
  enclosing element can belong to a pager or a toolbar, so the list is still
  swiped. A list at its real start offers no action back either and
  is swiped too; in an app with pull-to-refresh that swipe can start a refresh. A
  swiped page moves about 80% of the visible list, close to an accessibility page
  (a whole viewport), so swiped pages overlap a little. When a page was not sent
  by the element's own action, the result says how it was sent.
  After each page the engine waits for the content to settle and compares it with
  the content before the page: the scrolled element's own text, description and
  bounds and those of its descendants, with their selected and checked state (the
  screen, for coordinates). A wheel picker's new value therefore counts wherever
  it shows; a change that springs back, such as an overscroll bounce, does not.
  An accessibility page is watched for 0.9 s before it counts as not moved,
  because a picker can change its value only after animating, and a page waits at
  most one second. A swiped page waits until the list has settled (unchanged for
  200 ms, at most 2 s after the finger lifts) and counts as moved only when the
  rows it shows changed: a ColorOS list at its end is pulled by the swipe and
  springs back, maybe a pixel off, and that is not a page. A page that did not move
  ends the call with a notice such as `Scrolled 3 of 5 pages; reached the end`
  (`reached the end (the top)` scrolling up), or `Nothing moved; the list is at its
  end or does not scroll this way` on the first page; a page whose content changed
  counts even when the accessibility action returned false. A scroll outside a
  batch ends within 45 s, inside a host's one-minute call limit, with a notice. Only a failed read
  after scrolling returns `ACTION_UNCONFIRMED`.
  The scrolled element is followed from page to page even when its tree path,
  bounds or text change (a collapsing toolbar resizes a list and shifts the
  indexes, a wheel shows its next value): it is the same element, or the only one
  in its window with its class and resource id that still covers at least half of
  where it was. A new dialog or foreign window or
  another foreground app still stops the call as `POPUP`; if the element can no
  longer be found (for example in a new activity) the remaining pages are not sent
  and the notice says so, such as `Scrolled 1 of 3 pages; the scrolled element was
  not found on the new screen, so the rest were not sent`. Every early end of a
  multi-page scroll says how many pages had scrolled and why: a notice for the
  list's end, the batch time limit or an element that is gone, and an error that
  ends a multi-page scroll (such as `POPUP` or `PERSON_ACTIVE`) adds `(2 of 5
  pages had scrolled)`. When every requested page moved, the notice is `All 20
  pages scrolled; there may be more: scroll again to go further.`
  When more than one page was requested, the result lists the rows on the pages
  scrolled past, after the notice and before the state, under `Passed over while
  scrolling (N distinct rows, top to bottom; the final page is in the state below,
  not here):` (`left to right` for a horizontal list). One rule holds in both
  directions: every distinct row seen on the starting page and the pages after it,
  in list order, and none of the final page. Each row joins the text,
  descriptions and checked state inside one child of the scrolled element. A row
  that touches the scrolled element's top or bottom (left or right) edge and is
  shorter than the page's whole rows, on every page it showed on, may be cut:
  ColorOS reports such a row with clipped bounds and without the children outside
  the list (on the PGBM10, `06:45` alone where the whole row is `06:45 | 响一次 |
  关闭 [not checked]`). It is left out when another row of its kind (the same row
  class and id) seen during the call, the final page's included, shows all its
  text and a field it lacks, and kept otherwise, so a row cut on every page it
  showed on is not lost and a row of another kind (a header `Today` above rows
  `Today | Standup`) is never taken for part of one. A kept one that lacks a field every whole
  row of its kind has (compared by child resource id, else class) ends ` (cut off
  at the list edge)`, so it is not read as the row's whole content; a row the edge
  cut that still shows all those fields (on the PGBM10, 196 of 280 px with time,
  label and switch) is listed as a normal row. Pieces of
  cut rows are never joined: recycled rows made joined pieces of two different
  alarms on the device. A wheel has no such list (see `set_value`). Rows are
  distinct, at most 200 rows of at most 200
  characters, and password fields are left out. One call can therefore read a
  long list.
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
- `set_value`: replace an indexed editable field's entire value (the editor must
  actually expose `ACTION_SET_TEXT`), or set a range element such as a slider to
  a number with the accessibility set-progress action. Range elements show
  `value=… range=min..max` in their lines; a value outside the range or not a
  number returns `INVALID_ARGUMENT` with nothing sent. Use click for a checkbox.
  A wheel picker (a time/date column, `NumberPicker`) is set in one call too:
  Android has no standard action that sets its value (the ColorOS time wheels
  offer only scroll forward/backward, and AOSP `NumberPicker`'s editable centre
  takes typed text only when it loses focus), so `set_value` steps it with its
  own scroll actions and reads its value after every step, until it shows the
  requested value. A wheel here is an element that is neither an editor, a web
  view nor a set-progress range, shows its selected value as its own text, offers
  scroll forward or backward, holds nothing editable and no web view (a page or a
  form that scrolls is no wheel, whatever its title), and is focusable or has a row
  inside it showing that same text. `set_value` on an editor always sets its text,
  even inside something that scrolls. The PGBM10's ColorOS time picker is such a wheel: each
  `COUINumberPicker` shows the value followed by a unit and spoken instructions
  (`23小时选择器项目 使用两指 上下滑动选择`) and holds three class-less virtual rows
  (previous, selected, next). A row of a wheel names the wheel too, for `set_value`
  and `scroll`. The selected value is the text of the one row marked selected,
  if any, else the wheel's own text; it is read as its leading integer when it has
  one (`23`). A wheel that shows numbers takes a plain number (`7` matches `07…`);
  anything else (`7 PM`, `07:35`, `5 min`) returns `VALUE_NOT_SETTABLE`, and a
  number outside a range the wheel reports returns `INVALID_ARGUMENT`, both with
  nothing sent. On other wheels a value matches the text or the start of it.
  Numbers go toward the requested number, or the short way round when the wheel's
  range is known; scroll-forward is taken to increase, as on AOSP wheels, until
  the first step shows otherwise. Other values go forward, and from an end back the
  other way. Each step waits up to one second for the value to change and settle.
  The call fails with `VALUE_NOT_REACHED`, naming the value the wheel now shows and
  the steps taken, as soon as a step goes past the number (it is not one of the
  wheel's values, as on a wheel of five-minute steps) or the wheel goes round past
  its end, when a step changes nothing at both ends, when the wheel comes round
  without showing the value, after 70 steps, or after 25 seconds (or at a batch's
  time limit); read state before continuing. On success the result starts `Set the wheel to 35
  in 12 steps.` One `run_actions` can set every wheel of a time. `scroll` on a
  wheel also steps it, one value per page (`down` is the next value: on ColorOS
  the hour went from 00 to 07 scrolling down), and a page counts as moved only when
  the wheel's selected value changed. Its result says `Selected value: 07.`
  instead of listing passed-over values, and never that there may be more.
- `paste`: `format: "text"` only; inserts the text exactly as `type_text` does.
  The clipboard is neither read nor changed.
- `perform_secondary_action`: only a name listed on that node, rechecked live;
  the live node must still carry the same name (including its label) under the
  same action id, otherwise `STALE_ELEMENT`.
- `activate_app`: explicit foreground activation under the same person rules. In
agent-desktop mode it launches on the owned display; an app already in front on
display 0 returns `APP_IN_USE_BY_PERSON` without input.

Within one `run_actions`, a step whose element an earlier step of the same batch
changed the value of (`set_value`, or a wheel picker's own scroll-forward/backward
or `scroll`, also through one of its rows) finds it again with its text allowed to
differ, since the batch changed it; every other identity component below still
has to hold. Other secondary actions (dismiss, delete, custom ones) do not loosen
this check.

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

Apps that preview a result while you type, such as a calculator, can satisfy an
`until` on the result text before the last key. Wait on the last step with
`stable: true`, or with a condition only the last action produces.

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
The final state waits for a stable screen as above and reports it in
`_meta["opencu/settle"]`, except after a dialog stop (which has its own short
settle), at the time limit, and after person activity, stop, lock or shutdown.
Typical reasons: `timeout`, `time_limit`, `popup`, `system_dialog`, `app_switched`,
`stale_element`, `person_active`, `user_stopped`, `screen_locked`. Earlier input
may have executed. Never retry the stopped sequence automatically.

## Agent desktop

`agent_desktop start` creates a virtual display with display 0's size in its
natural orientation (portrait on a phone, even while display 0 is turned by a
landscape app) and display 0's density. On the accepted PGBM10 it obtained flags value `97737`,
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
action. The probe notification was snoozed for one day and is recorded as an
unverified OEM limitation. The [companion app](#companion-app) provides the visible
status, a live preview and a Stop button instead.

## Companion app

`npm run build:android` also builds `.build/android/opencu-companion.apk`
(`dev.opencu.companion`, [ADR 0006](adr/0006-android-companion-app.md)). It is
optional: without it nothing changes. With it, the phone shows what the agent does:

- A black status island under the status bar: the app the agent uses, the current
  step (such as `Tap "Pay"`, `Step 3 of 9` in a batch) and a ring while a call runs.
  Typed or set text appears only when the engine has identified the field and it is
  not a password; otherwise the island shows only the number of characters. It
  appears with the connection and leaves when the connection ends.
- On the agent display, the island takes taps. A tap opens a card with **Watch**
  and **Stop**; the card stays open until you tap it or outside it. **Watch** opens a
  floating, watch-only live view of the agent display that you can drag (it settles
  at the nearer side); a tap on it shows Close and Stop. The card also folds by itself
  after a stop and when the agent moves to the main display.
- On the main display the island only shows status: it is drawn at 0.8 opacity and
  touches pass through it to the app below, so a tap aimed at the app never lands on
  it. Touching the screen pauses the agent there anyway.
- **Stop** latches the same `USER_STOPPED` as three volume-down presses and sends the
  same `USER_STOPPED` notification; its message names the app. The island shows
  Stopped only once the engine confirms; otherwise it asks for the volume gesture.
  After any stop, by the app or the volume buttons, the island keeps showing Stopped
  until the connection ends.
- Like any app drawn over others, the island makes touches below it look obscured to
  the app there: a view that refuses obscured touches (`filterTouchesWhenObscured`)
  ignores taps right under the island, the person's and the engine's alike.

Install it once and allow it to draw over other apps:

```sh
adb install -r .build/android/opencu-companion.apk
adb shell appops set dev.opencu.companion SYSTEM_ALERT_WINDOW allow
```

ColorOS refuses that `appops` command from shell; turn on Settings → Apps →
Special app access → Display over other apps → OpenCU instead. Words follow the
phone's language (Chinese or English).

How the engine reaches it: once per connection the engine checks that the app is
installed and signed with the certificate this build pins, then calls the app's
provider (`dev.opencu.companion.engine`) as shell with a Binder. The provider
refuses every caller but uid 2000; the engine's Binder refuses every caller but the
verified app and offers only Stop and attaching or detaching a preview surface while
the agent display runs. Status goes to the app one way. The build signs the app with
a per-machine key at `~/.local/share/opencu/android-companion.keystore` and bakes its
certificate's SHA-256 into the jar, so a jar attaches only the app built with it;
`doctor` reports `companion` as `not installed`, `installed`, or why it is not used.
The engine leaves the app's windows out of the state it reports. The preview is an
auto-mirror virtual display of the agent display (hidden
`DisplayManager.createVirtualDisplay(name, w, h, displayIdToMirror, surface)`) and
takes no input. If Android ends the app's process, the engine attaches again on its
next call, at most every five seconds.

Checked on the PGBM10 on 2026-11-03: the island and card on the main and agent
displays, Watch with live frames while a batch ran on the agent display, dragging
the preview, Stop from the card (the host received `USER_STOPPED`), a tap passing
through the main-display island to the app below, the app's windows absent from
the reported state, and attaching again after the app was reinstalled mid-connection.

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

Direct package-name resolution avoids loading other apps' labels. Loading a
launcher label maps that app's whole APK into the engine until the collector frees
its resources: on the PGBM10, the 58 launchable apps' labels held about 110 MB of
the engine's PSS (188 MB in all) right after `agent_desktop start`, which listed
every app. The engine therefore loads each label once per connection (keyed by
activity and APK path, so an updated app is read again), runs the collector after
every 16 newly loaded labels and once at the end, and `agent_desktop` start and
status no longer list apps (`list_apps` does, on request). The final
PGBM10 samples and desktop lifecycle evidence are in the committed evidence;
all required targets passed. Startup includes computer launcher/cache
verification, wireless adb, MCP initialize and first tools/list answer. The evidence retains every sample and reports target misses without relaxing
assertions. Plain indexed batch steps measured 232 ms for ten clicks. On ColorOS, `cmd media_session volume --set` returned success without
applying the value. The verifier instead restores the original media volume via
injected volume-up events while the fixture explicitly routes keys to media; it
reads back every increment. The owner completed the initial OEM installation
confirmation; subsequent streamed fixture installs succeeded without UI input.

Known unverified boundaries include custom editors that ignore accessibility
set-text, coordinate drag/long press, custom secondary actions, the scroll
fallbacks (an enclosing element's action and the touch swipe), wheel-picker
paging, the stable final-state wait and set-progress (host checks only so far),
and from the second PGBM10 round (host checks modelled on the device's nodes,
not yet run on the phone): `set_value` stepping a wheel, the swipe lanes that
avoid settable elements and the value-change warning, taps that avoid covering
elements (which use the reported drawing order),
the launcher's `DEVICE_UNAVAILABLE`, the label cache's effect on memory and the
agent display's portrait size while display 0 is turned,
custom/WebView trees, secure
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
