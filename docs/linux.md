# OpenCU on Linux

The Rust engine in `native-linux/` drives X11 desktops: window capture through
Composite (covered windows capture their own pixels), AT-SPI2 trees with indexed
clicks, values, text selection and actions, and XTest pointer and keyboard input
that follows the Windows foreground rules (the target is brought forward only
after 10 seconds without a person's input; a person's input during a call
returns `PERSON_ACTIVE`; a physical Escape latches `USER_STOPPED`). It runs as an
ordinary user, also in a headless container on Xvfb or Xvnc, and needs no
desktop-specific interfaces. Wayland is not supported.

## Install

On x86_64 Linux, as the desktop's user:

```sh
curl -fsSL https://github.com/Daily-AC/opencu/releases/latest/download/install.sh | sh
```

This installs the engine, Node.js 22 and the MCP dependencies into
`~/.local/share/opencu` without root, after checking the release's SHA-256, and
writes `opencu.json` for hosts. Connect an agent with the stdio command
`~/.local/share/opencu/bin/opencu` (`DISPLAY` must be set) and check the desktop
with `~/.local/share/opencu/bin/opencu doctor`. The desktop needs an X server with
XTEST, Composite and XInput 2 (Xorg, Xvfb and Xvnc have them) and, for element
trees, `at-spi2-core` in the session. Set `GNOME_ACCESSIBILITY=1` in the session
environment so apps started outside OpenCU expose their trees from the start;
otherwise Firefox, for example, registers only when its window is next activated. A container image can extract the release
archive instead; [tests/linux-desktop/Dockerfile](../tests/linux-desktop/Dockerfile)
is the disposable XFCE desktop used for acceptance. Hosts follow the
[host integration contract](host-integration.md#linux-060); behavior and
measured results are in the [Linux engine contract](linux-engine-contract.md).

## Measured

On 2026-10-22 a dsh agent with `gemini-3.8-flash-high` ran five tasks twice in a
fresh XFCE container per trial, with a shell, screenshots and `xdotool` (A) or the
same plus OpenCU (B). Both arms passed 10/10, so with this model OpenCU did not
change what could be done. It changed the cost of work inside app windows: a
browser registration wizard took 277 instead of 459 seconds (median) and 175k
instead of 318k input tokens; fixing and saving an unsaved Mousepad note took 79
instead of 223 seconds and 101k instead of 230k tokens. A terminal quiz tied. The
hardened engine then passed the same tasks 14/14 in arm B
([evidence](../evidence/opencu-linux-ab-2026-10-22.json)).

Limitations that apply on Linux are in [Limitations](limitations.md#linux).
