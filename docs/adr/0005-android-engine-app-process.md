# 0005: Android engine as a shell-identity app_process that speaks MCP

Date: 2026-11-01. Status: accepted; implementation in progress.

## Context

OpenCU is the execution layer of `wanctl act` ([ADR 0001](0001-mcp-as-host-interface.md)).
wanctl already runs on Android phones and can obtain the `shell` identity
(uid 2000) through an elevation channel: su on rooted phones, otherwise the
phone's own wireless-debugging adbd. A person can also reach the same identity
from a computer over USB or wireless adb. Neither path can run Node, which the
desktop MCP server needs.

Measured on an OPPO PGBM10 (Android 14, ColorOS 14) on 2026-11-01:

| Read | Time | Size |
|---|---|---|
| `screencap -p`, fetched over wireless adb | 3.9–4.5 s (1.8 s is PNG encoding on the phone) | 2.4 MB |
| `uiautomator dump` | 2.4–2.8 s | 12–17 KB XML |
| A resident `app_process` holding `UiAutomation` | 43–53 ms start, 100–390 ms first read, 5–35 ms afterwards | about 1.5 KB of element lines |

Two existing projects show the shape. OpenGCUA's Android adapter starts a Java
`app_process` as shell over adb, obtains the hidden `UiAutomation` by
reflection and talks JSON lines on stdin/stdout. Mika (an on-phone agent)
starts a shell helper the same way, creates a virtual display so the person
keeps using the phone, and is fast because the model reads text, refers to
elements by number, and runs several steps per model call with local wait
conditions.

## Decision

- **One artifact.** `native-android/` builds `opencu-android.jar` (dex inside)
  with `javac` and `d8`, without Gradle and without an APK. A host runs
  `CLASSPATH=<jar> app_process / dev.opencu.android.Main mcp` as shell and gets
  an MCP server (newline-delimited JSON-RPC) on stdin/stdout. `doctor` prints one
  JSON object. No network port, no installed app, no accessibility service; it
  exits when stdin closes. Reads use `UiAutomation` connected with
  `FLAG_DONT_SUPPRESS_ACCESSIBILITY_SERVICES`, so the person's own
  accessibility services keep running.
- **The engine speaks MCP itself.** There is no Node on a phone, so the Android
  server implements the MCP surface directly. Tool names, argument names, error
  codes (`CODE: message`, also in `_meta["opencu/error"]`) and the
  one-connection-per-agent-session rule follow the desktop server
  ([host integration](../host-integration.md)). Platform differences are stated
  in the tool descriptions, as on Windows and Linux.
- **Same tools, phone semantics.** `list_apps`, `get_app_state`,
  `activate_app`, `click`, `drag`, `scroll`, `type_text`, `paste`, `set_value`,
  `press_key`, `perform_secondary_action`, `run_actions`, `agent_desktop`.
  `app` is a package name or launcher label. State is compact element lines with
  indexes; screenshots are JPEG, scaled, and only on request. Unicode text works
  in ordinary fields without a third-party keyboard.
- **Batches wait locally.** On Android every `run_actions` step may carry an
  `until` condition (text appears, text gone, foreground app, screen stable;
  default 8 s, at most 20 s), checked by the engine. A batch stops early on a new
  dialog, a window of another app on top, or an app switch, and reports why and
  how long it waited. Indexes in a batch refer to the state read before it; the
  engine checks that each still names the same element before acting.
- **Agent desktop is a virtual display.** `agent_desktop start` creates a
  display owned by the engine. Apps launch there, reads and input target it,
  and the person keeps using the main screen. Its lifetime is the engine
  connection; stopping never brings an app over what the person is looking at.
- **The person wins.** Without an agent desktop, input on the main display
  follows the desktop rules: a person's touch during a call returns
  `PERSON_ACTIVE`, and the foreground is not changed within 10 seconds of their
  last touch. A physical stop gesture read from the input devices (volume-down
  pressed three times within 1.5 s) latches `USER_STOPPED` for the connection.
  Injected events never count as the person. Locked phones return
  `SCREEN_LOCKED` for input.

## Not in the first version

OCR for apps without a usable tree, per-app knowledge files, intent shortcuts
(alarms, calendar, share), accessibility-event wake-ups (polling a 5–35 ms read
is enough), and audio muting of agent-desktop apps. Each comes back only if
acceptance on real apps shows it is needed.

## Consequences

- Android needs USB debugging, wireless debugging or root. Wireless debugging
  is cleared at reboot, so a host must re-establish it; the engine's lifetime is
  that of its adb (or su) session.
- `UiAutomation` and virtual displays from shell use hidden APIs found by
  reflection. They are checked at start, reported by `doctor`, and may break on
  a new Android release.
- The shell identity can do much more than the tools expose. The engine opens
  no port and takes commands only from the process that started it; hosts keep
  their own approval rules.

## Implementation findings from milestone 2

On the accepted OPPO PGBM10 (Android 14), shell can create a trusted,
own-focus virtual display with the main display's size and density. ColorOS
allows only one registered `UiAutomation` service per shell process, so the
engine disconnects its main-display automation while the agent desktop is
active, binds a second connection to the owned display, and reconnects the main
display on stop. This differs from the initial implementation assumption that
one connection could query all displays reliably; the all-displays overload
returned no virtual-display windows on this device. The desktop uses local IME
policy and display-targeted input, and reports the flags actually obtained.

## Decisions from milestone 4

- **Never repeat input whose outcome is unknown.** A second input method is used
  only when the first is known unavailable before anything is sent. Once a shell
  tap has started, or an accessibility action has been sent, a timeout, error or
  false result is `ACTION_UNCONFIRMED` and needs a fresh read.
- **Text goes in through set-text only.** `type_text` and `paste` set the focused
  editor's text through accessibility; the engine never uses the clipboard.
  Pasting through the clipboard put the agent's text where other apps and the
  IME's clipboard history can see it, and an unconfirmed paste could later insert
  the person's restored clip. On the accepted phone, set-text gave the same
  search results as paste in the apps tested.
- **The agent display is isolated or absent.** It must read back as trusted, with
  its own focus and unable to take the top focus, and its IME policy must read
  back as local. Otherwise start releases everything and returns
  `AGENT_DESKTOP_UNAVAILABLE`; the earlier untrusted fallback is removed. Start is
  a transaction that restores the main-display connection on failure.
- **The launch cache is trusted as far as shell is.** `/data/local/tmp` is
  writable only by shell and root, and both already hold the identity the engine
  runs as, so swapping the cached jar between its hash check and `app_process`
  grants nothing new. The launcher therefore does not pin the file object; it
  refuses a cached jar that is not a regular file owned by shell with mode 0644 or
  stricter, and sends every adb call of one launch to one device serial. On-phone
  hosts that start the jar themselves rely on the same assumption.
- **No blanket start-up holdoff.** A fixed ten-second holdoff at connection start
  made every new session's first app launch fail. Instead the engine starts the
  input monitor, waits until it is live, and then seeds the last physical
  activity from the power service, so no touch falls between the two sources.
