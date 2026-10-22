# Linux engine contract

Status: X11 only. Built as a static musl executable from `native-linux/`
(`npm run build:linux`); see [ADR 0004](adr/0004-linux-engine-rust-x11-atspi.md).
Accepted on 2026-10-22 in a disposable Debian 12 XFCE desktop (TigerVNC Xvnc,
xfwm4) with Mousepad, xfce4-terminal, Thunar, Firefox ESR and Chromium, as an
ordinary user, started through `docker exec` with only `DISPLAY` set.

## Transport

`opencu-engine serve` speaks the same JSON-lines protocol as the other engines
on inherited stdin/stdout; `--doctor` prints one JSON object. Hosts use the MCP
server ([host integration](host-integration.md)). The engine needs `DISPLAY`
and runs as the desktop's user. Without `DISPLAY`, and under XWayland in a
Wayland session, it refuses with `DISPLAY_UNAVAILABLE`.

When a physical Escape latches the stop, the engine also writes an unsolicited
line `{"event":"stop","error":{"code":"USER_STOPPED",...}}` at once, so the host
latches it even if the call in progress never returns. SIGTERM, SIGINT and SIGHUP
stop input in progress with `ENGINE_STOPPING` (held keys and buttons are
released), then the engine cleans up as at the end of input. A panic answers the
call with `ENGINE_FAILED` and the engine exits after the same cleanup.

When the engine's own environment has no D-Bus session bus, it adopts the
environment of a process of the same user on the same display, preferring the
session manager (`xfce4-session`, `gnome-session`, ...), otherwise the first such
process with a session bus, then `/run/user/<uid>/bus`. Launched apps get that
environment, so they join the desktop session. Doctor reports the source as
`sessionEnvironment`.

## Observation

Apps are processes owning managed top-level windows (`_NET_CLIENT_LIST`),
excluding docks and desktops, plus XDG desktop entries. `list_apps` returns
`pid:<pid>` records for running apps (with window titles) and desktop-entry IDs
for the rest. Running apps resolve as `pid:<pid>`, desktop entry name or ID,
executable name or path, `WM_CLASS`, exact window title, then a unique title
fragment. Different processes matching one name return `AMBIGUOUS_APP`.

A missing app launches only from a desktop entry (by name, ID or the entry's
program name; field codes removed), never from `PATH` or a file path, so a read
cannot run a program such as `reboot` (`APP_NOT_FOUND`). A new window usually
takes the focus, so launching follows the 10-second rule (`PERSON_ACTIVE`,
nothing launched). The app starts in its own session (`setsid`), with `GNOME_ACCESSIBILITY=1`,
`ACCESSIBILITY_ENABLED=1` and `QT_LINUX_ACCESSIBILITY_ALWAYS_ON=1`; Chromium-family
programs also get `--force-renderer-accessibility`. The engine waits up to 15
seconds for a window from that process or a new window whose class matches
(single-instance apps and wrapper scripts hand windows to another process),
otherwise returns `APP_LAUNCH_PENDING` and never launches it again on that connection.

The capture window is the app's active window, otherwise its topmost visible
non-utility window. The tree contains that window and windows transient for it
(dialogs); other windows of the app get `Window summary:` lines.

Accessibility uses AT-SPI2 over D-Bus. The bus address comes from
`AT_SPI_BUS_ADDRESS`, the X root window's `AT_SPI_BUS`, or `org.a11y.Bus.GetAddress`.
While connected, OpenCU sets `org.a11y.Status.IsEnabled`; on exit, including
after a termination signal, it turns it off again unless a screen reader is
enabled (`ScreenReaderEnabled`) or another OpenCU engine of the same user is
running. Apps register, and add their windows, shortly after accessibility is
turned on, so for 10 seconds after a connection turned it on a read waits up to
4 seconds for the app's frame. Connecting to the bus gives up after 5 seconds.
The registered application is found by the D-Bus
connection's PID; its top-level frame is matched to the X window by title, then
by geometry. Calls use `Properties.Get` only (Qt5 crashes on a one-argument
`GetAll`), a 2-second timeout each, and a read budget of 8,000 inspected nodes,
depth 120, 8 seconds (including finding the frames), 1,200 listed elements and 180,000 bytes, with explicit
truncation text; three timeouts end the read as unresponsive. Containers with
more than 2,048 children (or 400 managing their descendants) show their first 200.
Action names are read one by one: Firefox's bridge returns placeholders from `GetActions`.

Element lines follow the Windows format: `[n] Role title=... bounds=(x,y,w,h)
value=... disabled settable focused toggle=on|off|mixed selected=... expanded=...
range=(min,max) step=... actions=[...]`. Roles are AT-SPI role names in PascalCase.
Nodes that are not showing are not listed; one `Offscreen:` line counts them.
Unnamed structural containers without their own state or actions are omitted
while their children are listed. Text-bearing leaves (paragraphs, labels,
cells) show their text as `value` (600 characters); editable text shows 4,000;
terminals show their last 4,000 characters. Password text is never read.
Actions every element has (`showContextMenu`, Firefox's `clickAncestor`,
Chromium's `doDefault`) are not listed. Element indexes belong to the latest
observation; before indexed input the element's role and name must still match
it, because toolkits reuse object paths for new controls (`STALE_ELEMENT`).

Screenshots: Composite automatic redirection, then the window's own pixmap
(including WM decorations), so covered and partly off-screen windows capture
their own pixels. If the pixmap cannot be read, the screenshot fails rather than
showing the screen area, which could contain other windows. Without Composite the
engine reads the screen area and refuses partly off-screen windows. Minimized windows return no image. PNG,
1 image pixel = 1 screen pixel. Coordinates must lie inside the latest
screenshot and the window must not have moved (`STALE_SCREENSHOT`).

## Input

Input follows the Windows foreground model. Pointer and keyboard input use
XTest, so the target window must be active: the engine asks the window
manager (`_NET_ACTIVE_WINDOW`, source 2, with a server timestamp), sets focus,
and waits up to 1.5 seconds for confirmation (`ACTIVATION_FAILED` otherwise); one
of the window's own dialogs becoming active also counts. Each activation request
checks for a person first. Changing the foreground requires 10 seconds without a
person's input (`PERSON_ACTIVE`, no input sent, foreground unchanged). Before each
key press the active window must belong to the target: the observed window, a
window transient for it, or its owner, in the same process (`WINDOW_FOCUS_CHANGED`);
before each button press the window at the point must belong to the target
process (`TARGET_OCCLUDED`).

Before any input the engine refuses with `SCREEN_LOCKED` when logind reports the
session locked or inactive (`LockedHint`, `Active`), when a running
`org.freedesktop.ScreenSaver` service reports itself active, or when a full-screen
override-redirect window of another program covers the display (i3lock,
xscreensaver, xfce4-screensaver, KDE); the last check repeats before each key
press. The X server's own blanking is not a lock: input wakes the screen. It
refuses with `PERSON_ACTIVE` while any key or pointer button is down, whether a
person holds it or a killed client left it pressed. It rereads the keymap, so
layout changes and other clients' bindings are followed.

- Indexed click: pointer click at the element's live centre when the element's
  own window is on top there (a same-process menu popup also qualifies);
  otherwise a plain left click performs the element's activation action
  (`click`, `press`, `activate`, `jump`, `toggle`, ...). Disabled elements return
  `ELEMENT_DISABLED`. An action the app does not answer within 2 seconds returns
  an unknown outcome and requires a fresh read.
- Coordinate click, drag (20 steps), scroll (3 wheel steps per page) at a point
  owned by the target process (`TARGET_OCCLUDED` otherwise).
- `press_key` uses the shared xdotool-style parser; `type_text` types each
  character as a keysym of the first keyboard group, binding an unused keycode
  for characters missing from the keymap (Chinese, for example). Bindings stay
  for the connection and are removed on exit. An active input method or a second
  keyboard group can change what arrives; use `paste` for such text.
- `paste`: plain text only. The engine saves the current CLIPBOARD contents
  (every readable format, up to 16 MiB; otherwise `CLIPBOARD_UNAVAILABLE` before
  any change), serves the text while sending Ctrl+V, then serves the previous
  contents again. Restored contents live in the engine process: they disappear
  when the connection ends unless a clipboard manager keeps them.
- `set_value`: AT-SPI EditableText or Value; no focus or foreground needed.
- `select_text`: AT-SPI Text selection or caret, by character offsets.
- `perform_secondary_action`: a listed AT-SPI action by name.
- `wait`: as on Windows. `scope` is refused (`INVALID_ARGUMENT`).

## People and stopping

A separate X connection receives XInput 2.1 raw key, button, motion and touch
events from every device, including floating ones. Any device other than the
XTEST slaves is a person. OpenCU injects only inside its own calls, so XTEST input
outside them comes from another program (x11vnc, Barrier, an on-screen keyboard,
a script running `xdotool key`) and counts as activity for the 10-second rule.
Pointer warps (`XWarpPointer`, which `xdotool mousemove` uses) produce no input
events and are not seen.

A person's input during a call stops it with `PERSON_ACTIVE`, and later input is
refused with `OBSERVATION_REQUIRED` until a successful `get_app_state`. When a
call fails, a person's stop or activity during it is reported instead of the
call's own error. A physical Escape latches `USER_STOPPED` for the connection:
all later input, activation, waits and launches are refused, reads continue.
There is no reset. Doctor lists the person devices (`personInputDevices`). The
start of a connection uses the X screensaver idle counter, which also counts
earlier synthetic input, so a new connection can wait up to 10 seconds after any
recent input before changing the foreground; without that counter the engine
assumes a person was just active.

TigerVNC/KasmVNC `Xvnc` deliver viewer input through their own devices
("TigerVNC keyboard/pointer"), so a person at a VNC viewer is detected.
`x11vnc` injects viewer input through XTEST: between OpenCU's calls that input
counts as activity, but during a call it cannot be told apart from OpenCU's own,
and its Escape does not stop OpenCU.

## Known gaps

- Apps are identified by `_NET_WM_PID`, which the app sets. Flatpak apps report
  their sandbox PID, so two Flatpak apps can merge into one app; use window titles
  or avoid running several.
- Typing assumes the first keyboard group without an active input method.
- On desktops whose session process is not in the engine's list (LXQt, tiling
  window managers), the adopted environment comes from the first same-user process
  on the display, which can be a sandboxed one.
- Composite automatic redirection lasts for the connection; on a desktop without
  a compositing manager, full-screen games lose unredirection meanwhile.

## Safety checks measured on 2026-10-22 (arm64 container)

`get_app_state` for `reboot`, `/usr/bin/xmessage` and `xmessage` returned
`APP_NOT_FOUND` without running anything; `mousepad` launched from its entry.
With i3lock running, `press_key` returned `SCREEN_LOCKED` naming i3lock. With
`xdotool keydown shift` held by another client, input returned `PERSON_ACTIVE`
naming keycode 50. `xdotool key shift` between calls made the next foreground
change return `PERSON_ACTIVE`. VNC pointer motion during a `wait` returned
`PERSON_ACTIVE`, the next `press_key` `OBSERVATION_REQUIRED`, and input worked
again after a read. A VNC Escape during a 5-second `wait` produced the unsolicited
stop line, then the `USER_STOPPED` reply. SIGTERM during `press_key ctrl` held
for 8 seconds returned `ENGINE_STOPPING` at once; a second engine had seen
keycode 37 held during the hold and saw nothing held afterwards, and
`IsEnabled` was back to false.

## Measured on 2026-10-22 (arm64 container, then the x64 package)

Mousepad: launch, tree, typing `Hello OpenCU 你好 café!`, Ctrl+S, GTK Save
dialog tree, `set_value` on the file name, indexed Save, file bytes checked;
paste of two lines (one Chinese) with the previous clipboard restored;
`select_text` then typing. Firefox ESR: cold launch with an accessible tree,
address bar, page paragraphs, form entry with Chinese, indexed and coordinate
clicks, slider drag (10 → 61), scroll by two pages. Chromium (container flags
`--no-sandbox --force-renderer-accessibility`): tree and a web search through
indexed input. xfce4-terminal: typed command and its output read as text.
Thunar's single-instance hand-off. A VNC client's pointer motion interrupted a
4-second `wait` after 2.46 s; a background window was refused within 10 seconds
of VNC input with the foreground unchanged; a VNC Escape latched `USER_STOPPED`
while reads continued. XTest Escape did not latch. The x64 package installed
with `install.sh` in an amd64 container and served 13 tools over MCP.
