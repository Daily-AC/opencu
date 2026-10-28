# 0004: Linux engine in Rust on X11, XTest and AT-SPI2

Date: 2026-10-22. Status: accepted.

## Context

The first Linux user is an agent-owned XFCE desktop in a container: Xvnc, no
physical display, an ordinary user, started by a host that may only pass
`DISPLAY` through `docker exec`. The second is `wanctl act` on Linux hosts, which
can be a person's own desktop. Hosts already relay OpenCU's MCP server
unchanged ([ADR 0001](0001-mcp-as-host-interface.md)), so a Linux engine only has
to speak the existing JSON-lines protocol with the same tool semantics.

## Decision

- Write the engine in Rust as `native-linux/`, reusing the platform-independent
  library of the Windows engine (argument validation, screenshot-coordinate
  checks, key-name parsing). Every dependency is pure Rust (x11rb for the X
  protocol, zbus for D-Bus, png), so one static musl binary runs in any
  distribution or container without libX11, libxcb, libdbus or Python.
- X11 only. Window capture uses Composite (automatic redirection, then the
  window's own pixmap), so covered windows still capture their own pixels.
  Input uses XTest, which goes to the focused window and the pointer, so Linux
  follows the Windows foreground model: activate through EWMH, require ten
  seconds without a person's input before changing the foreground, verify the
  target before every event.
- A person is any input device other than the XTEST devices, seen through
  XInput 2 raw events on a separate connection. Their input interrupts a call
  with `PERSON_ACTIVE`; a physical Escape latches `USER_STOPPED` for the
  connection, as on Windows.
- Accessibility uses AT-SPI2 directly over D-Bus with explicit property reads,
  per-call timeouts and a read budget. OpenCU announces assistive technology
  (`org.a11y.Status.IsEnabled`) while connected and restores it afterwards.
  The bus is found from the environment, the X root window or the session bus.
- When the engine runs outside the desktop session (no session bus in its
  environment), it adopts the environment of a session process on the same
  display, so apps it launches join the person's or agent's session.

## Consequences

- Wayland sessions are refused; XWayland apps on a Wayland desktop are not
  supported. This is stated in [Limitations](../limitations.md).
- Person detection depends on the X server keeping VNC or hardware input on
  its own devices. TigerVNC/KasmVNC Xvnc do; x11vnc on Xvfb injects through
  XTEST, so a person's input there is indistinguishable from OpenCU's.
- There is no background operation and no agent desktop on Linux; an
  agent-owned container desktop already isolates the agent from people.
- Apps without an AT-SPI tree (or Chromium started without accessibility)
  still work through screenshots and coordinates.
