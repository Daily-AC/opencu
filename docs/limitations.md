# Limitations

The measurements behind this section are in
[measured behavior and limits](opencu-independent-2026-10-12.md).

## Install and permissions

- Source build only, Apple silicon only. There is no notarized Developer ID build.
- On macOS 15 and later, the system periodically asks whether OpenCU may keep
  capturing the screen ("…is requesting to bypass the system private window
  picker…"). Choose **Allow**. **Open System Settings** does not count as an
  answer, and the prompt comes back. macOS keeps the answer per engine location,
  so the first screenshot after building in a new directory asks again; after
  that, about every 30 days. This confirmation can take the foreground; OpenCU
  refuses or interrupts the current input with `AGENT_DISPLAY_PERSON_ACTIVE` when
  it does. A foreground SecurityAgent or UserNotificationCenter prompt does not
  destroy an already running agent desktop or return its windows. Dismiss the
  prompt, then explicitly observe before continuing; input is never replayed.
  Agent desktop preview uses the same existing Screen
  Recording permission and verified worker responsibility; it does not suppress
  or replace this macOS reminder with a sharing picker.
- A caller sandbox that denies networking also blocks the local socket, so
  OpenCU cannot run from such a sandbox. Conversely, the worker runs outside any
  caller sandbox: a sandbox does not confine what OpenCU does.
- OpenCU cannot operate a locked Mac.

## Background operation

- **Windows agent desktop (0.4.0, ordinary window since 0.5.0).** Windows 11 VM
  acceptance established separate foreground/input, no-password sign-in/refusal,
  Escape, Stop and EOF cleanup. Setup, nonactivating open, watch-only hover,
  pointer isolation, Escape and the locked-screen refusal were accepted on the VM
  ([evidence](../evidence/opencu-windows-agent-desktop-2026-10-21-v0.4.0.json)); in
  0.5.0, close-to-minimize with the child still working, Stop, keep on top,
  maximize and clean view were accepted with real clicks
  ([evidence](../evidence/opencu-windows-regression-2026-10-22-v0.5.0.json)).
  Administrator approval is needed once, possibly followed by one sign-out/in;
  smart-card-only sign-in is unsupported and unmeasured. While the parent screen
  is locked, the child stays alive for reads, screenshots and supported indexed
  control patterns. Locked button click/value setting and refused typing were
  accepted on a Windows 11 VM (the button used Invoke, the text box
  Value.SetValue). Other input returns `SCREEN_LOCKED`. A read-triggered launch
  while locked opens the app without activating it. Nobody at the machine
  can see the child while the lock screen is shown.
  Status reports `parentLocked`. After unlocking, press the host's Stop button or
  click the view and press Escape to stop; the caller can also end the MCP connection.
  Console/remote disconnect and logoff still end the child. One child session per
  machine; apps still share your account, profiles and files. Single-instance apps
  can refuse another instance. Covered/partly off-screen views, GPU/video apps
  and unsupported Windows editions remain unmeasured. This is UI
  isolation, not a security sandbox.
- **macOS agent desktop.** A watch-only virtual monitor in the same macOS session,
  not a Windows-style separate session. Each window move needs local consent;
  background-capable windows only. Blender and other opaque/foreground-only apps
  retain `BACKGROUND_INPUT_UNSUPPORTED`. App launch may appear on your display
  first. Creating the display can push an on-stage window into the Stage Manager
  strip. External monitors are untested; unsupported layouts are refused. The
  owner passed all seven product checks on 2026-10-21 on macOS 26.6 with one
  built-in display and Stage Manager on, before and after the 0.4.1 rebase and
  localization ([evidence](../evidence/opencu-macos-agent-desktop-2026-10-21.json)).
  The final 0.5.0 build passed the eight checks of the ordinary-window version on
  2026-10-22, driven through Accessibility on OpenCU's own controls
  ([evidence](../evidence/opencu-macos-agent-desktop-2026-10-22.json)).
  This does not establish other display layouts.
- **Stage Manager.** A window in the Stage Manager strip cannot become the key
  window: many commands are disabled, Chromium stops rendering its pages, and a
  screenshot may show only the thumbnail. Reading and indexed actions still work.
  The macOS agent desktop can move a window with your consent to keep it rendered
  for background work. Outside that mode, use `activate_app` or turn Stage Manager off. For apps that accept background
  input, putting the app full screen in its own Space also worked (Keynote); it
  does not help custom-drawn apps.
- A Chromium window that is fully covered by other windows also stops rendering
  its pages.
- **Custom-drawn apps** such as Blender read the real mouse position and raise
  themselves when they become key. OpenCU refuses background input to windows
  that expose only title-bar controls (`BACKGROUND_INPUT_UNSUPPORTED`). Use such
  apps in the foreground, and only while nobody touches the mouse: their
  shortcuts act on whatever is under the real pointer.
- **System Open/Save panels** run in a separate process. While the app is in the
  background, keyboard and coordinate input to them is refused
  (`BACKGROUND_REMOTE_FOCUS`); `set_value` and exposed press actions still work.
- Apps can move windows, change focus or handle synthesized input differently.
  A successful action means the input was sent, not that the task succeeded.

## App coverage

- Accepted: the 18-check AppKit fixture suite and typing in TextEdit. Observed in
  real use: a five-slide Keynote deck built from Keynote's own Space, a web task
  in a disposable Chrome profile (with occluded-window throttling disabled to
  emulate a visible window), reading VS Code, and a Blender model built in the
  foreground through its Python console.
- Not yet accepted: Safari and other WebKit apps, Qt and Java apps.
- No public benchmark yet. Treat reliability on your own tasks as unmeasured.

## Known defects

- An app with several windows and no focused or main window, such as Blender with
  a render window open, fails with `AMBIGUOUS_WINDOW`, and the tools cannot yet
  choose a window.
- A non-Latin input source, such as a Chinese pinyin input method, can swallow
  letter shortcuts. OpenCU does not detect this; switch to a Latin layout.
- Some apps report an Accessibility action as failed after performing it. OpenCU
  reports the outcome as unknown and requires a new read rather than retrying.
  Some text areas refuse selection through Accessibility
  (`TEXT_SELECTION_UNSUPPORTED`); click at the text position instead.
- A state read occasionally fails once with no accessible window and succeeds on
  the next try.

## Safety and privacy

- There is no per-app allowlist or task approval system. The calling agent is
  responsible for its requests. macOS agent desktop adds local consent before
  moving each window, and before using an already-present window of another
  process. That card is a person-facing check, not a barrier against other local
  automation running as the same user (including Accessibility automation).
- OpenCU's signature identifies it to macOS; it does not restrict callers. Any
  local process that can run `bin/opencu` uses OpenCU's permissions.
- macOS agent desktop also stops through its preview's Stop button or a macOS
  preview Stop Sharing control; closing the preview does not stop it. See
  [Stopping it](macos.md#stopping-it).
- `paste` temporarily replaces the clipboard and restores it afterwards, unless
  another app changed it meanwhile.
- The title-bar badge shows up to 16 characters of text being typed or pasted
  (only a character count in password fields). It is visible in screen
  recordings and screen sharing.
- While connected, OpenCU turns on `AXEnhancedUserInterface` in Chrome-family
  browsers so their pages are readable. This slows window moves by window
  managers; OpenCU turns it off again on disconnect.

## Linux

- X11 only; Wayland sessions, including XWayland, are refused. Input uses the
  foreground: there is no background operation and no agent desktop on Linux.
- A person's input is fully attributed only when it arrives through a device other
  than XTEST. Xvnc (TigerVNC, KasmVNC) and hardware input qualify. Remote and
  shared-input tools that inject through XTEST (x11vnc, Barrier, on-screen
  keyboards) count as activity between OpenCU's calls, but not during one, and
  their Escape does not stop OpenCU.
- Input is refused while the screen is locked: logind, an
  `org.freedesktop.ScreenSaver` service, or a full-screen locker window on top
  (i3lock, xscreensaver, xfce4-screensaver) reveal it. A locker that reports in
  none of these ways is not detected. Disable screen savers on agent-owned
  desktops: an active one blocks input.
- Only desktop entries are launched; a program without one must be started
  another way.
- Flatpak apps report their sandbox PID, so two of them can be taken for one app.
  Typing assumes the first keyboard group without an active input method; use
  `paste` otherwise.
- Apps without an AT-SPI tree, and Chromium or Electron apps started without
  `--force-renderer-accessibility` (OpenCU adds it when it launches them), work only
  through screenshots and coordinates. Chromium in an unprivileged container also
  needs `--no-sandbox`.
- While connected, OpenCU announces assistive technology to the session
  (`org.a11y.Status.IsEnabled`) and turns it off again afterwards, unless a screen
  reader or another OpenCU connection still uses it.
- After `paste`, the restored clipboard lives in the engine process and is lost
  when the connection ends unless a clipboard manager keeps it.
- `scope` is not supported yet.

## Virtual display compatibility

The macOS virtual display is exposed through the consented `agent_desktop` product
path. Its OS-exported display SPI remains a compatibility boundary. Creating it
can put a window from your current stage into the Stage Manager strip; external
monitors are untested. The old consent-free experimental engine commands and their
probe script have been removed. [The probe record](agent-display-probe.md)
is historical evidence, not a command to run or acceptance of the product UI.
