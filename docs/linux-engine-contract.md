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
and runs as the desktop's user. Without `DISPLAY` it refuses with
`DISPLAY_UNAVAILABLE`, including on Wayland sessions.

When the engine's own environment has no D-Bus session bus, it adopts the
environment of a process of the same user on the same display, preferring the
session manager (`xfce4-session`, `gnome-session`, ...), then `/run/user/<uid>/bus`.
Launched apps get that environment, so they join the desktop session. Doctor
reports the source as `sessionEnvironment`.

## Observation

Apps are processes owning managed top-level windows (`_NET_CLIENT_LIST`),
excluding docks and desktops, plus XDG desktop entries. `list_apps` returns
`pid:<pid>` records for running apps (with window titles) and desktop-entry IDs
for the rest. App names resolve as `pid:<pid>`, desktop entry name or ID,
executable name or path, `WM_CLASS`, exact window title, then a unique title
fragment. Different processes matching one name return `AMBIGUOUS_APP`.

A missing app launches from its desktop entry (field codes removed) or from
`PATH`, in its own session (`setsid`), with `GNOME_ACCESSIBILITY=1`,
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
While connected, OpenCU sets `org.a11y.Status.IsEnabled` and restores the
previous value on exit. The registered application is found by the D-Bus
connection's PID; its top-level frame is matched to the X window by title, then
by geometry. Calls use `Properties.Get` only (Qt5 crashes on a one-argument
`GetAll`), a 2-second timeout each, and a read budget of 8,000 inspected nodes,
depth 120, 8 seconds, 1,200 listed elements and 180,000 bytes, with explicit
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
Chromium's `doDefault`) are not listed. Element indexes belong to the latest observation.

Screenshots: Composite automatic redirection, then the window's own pixmap
(including WM decorations), so covered and partly off-screen windows capture
their own pixels. Without Composite the engine reads the screen area and
refuses partly off-screen windows. Minimized windows return no image. PNG,
1 image pixel = 1 screen pixel. Coordinates must lie inside the latest
screenshot and the window must not have moved (`STALE_SCREENSHOT`).

## Input

Input follows the Windows foreground model. Pointer and keyboard input use
XTest, so the target window must be active: the engine asks the window
manager (`_NET_ACTIVE_WINDOW`, source 2, with a server timestamp), sets focus,
and waits up to 1.5 seconds for confirmation (`ACTIVATION_FAILED` otherwise).
Changing the foreground requires 10 seconds without a person's input
(`PERSON_ACTIVE`, no input sent, foreground unchanged). Before each event the
active window must belong to the target: the observed window, a window
transient for it, or its owner, in the same process (`WINDOW_FOCUS_CHANGED`).

- Indexed click: pointer click at the element's live centre when the element's
  own window is on top there (a same-process menu popup also qualifies);
  otherwise a plain left click performs the element's activation action
  (`click`, `press`, `activate`, `jump`, `toggle`, ...). Disabled elements return
  `ELEMENT_DISABLED`. An action the app does not answer within 2 seconds returns
  an unknown outcome and requires a fresh read.
- Coordinate click, drag (20 steps), scroll (3 wheel steps per page) at a point
  owned by the target process (`TARGET_OCCLUDED` otherwise).
- `press_key` uses the shared xdotool-style parser; `type_text` types each
  character as a keysym, binding an unused keycode for characters missing from
  the keymap (Chinese, for example). Bindings stay for the connection and are
  removed on exit.
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

A separate X connection receives XInput 2 raw key, button and motion events.
Events from the XTEST devices are synthetic; any other device is a person.
A person's input during a call stops it with `PERSON_ACTIVE`; a physical Escape
latches `USER_STOPPED` for the connection: all later input, activation, waits and
launches are refused, reads continue. There is no reset. Doctor lists the person
devices (`personInputDevices`). The start of a connection uses the X screensaver
idle counter, which also counts earlier synthetic input, so a new connection
can wait up to 10 seconds after any recent input before changing the foreground.

TigerVNC/KasmVNC `Xvnc` deliver viewer input through their own devices
("TigerVNC keyboard/pointer"), so a person at a VNC viewer is detected.
`x11vnc` injects viewer input through XTEST: on such a desktop a person's input
cannot be told apart from OpenCU's, and neither interruption nor Escape works.

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
