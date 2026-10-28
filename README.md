<p align="center">
  <img src="docs/assets/opencu.png" width="112" alt="OpenCU">
</p>

<h1 align="center">OpenCU</h1>

<p align="center">
  <strong>Computer use for any AI agent, on your own machine.</strong>
</p>

https://github.com/user-attachments/assets/5da04b21-47fe-44c4-9d3d-e2b3a2e9a9c6

<p align="center"><sub>Re-created in code from a real session.</sub></p>

<p align="center">
  OpenCU is an MCP server that lets Claude Code, Codex or any other MCP client read<br>
  and operate the apps on macOS, Windows and Linux. It runs locally, needs no account<br>
  or model key, and the person at the keyboard can stop it at any time.
</p>

<p align="center">
  <a href="https://github.com/Daily-AC/opencu/releases/latest"><img src="https://img.shields.io/github/v/release/Daily-AC/opencu?label=release&color=111111" alt="Latest release"></a>
  <img src="https://img.shields.io/badge/macOS%20%C2%B7%20Windows%20%C2%B7%20Linux-111111" alt="macOS, Windows, Linux">
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-111111" alt="MIT license"></a>
</p>

<p align="center">
  <a href="#install">Install</a> ·
  <a href="#connect-your-agent">Connect</a> ·
  <a href="#measured">Measured</a> ·
  <a href="docs/limitations.md">Limitations</a> ·
  <a href="README.zh-CN.md">简体中文</a>
</p>

<br>

## Why OpenCU

**It works beside you.** On macOS, input goes to the target app's process and
window. Your cursor stays where it is and the app in front keeps the keyboard.

**It can have a screen of its own.** Start the agent desktop and the agent works on
a virtual display (macOS) or in a separate session (Windows), which you watch in an
ordinary window.

**You stay in charge.** There is always a Stop button. On Windows and Linux a
physical Escape also stops it, and it will not take the foreground within 10
seconds of your last input. A stopped connection never restarts on its own.

**It is measured.** On Windows tasks that can only be done through the UI, the same
agent passed 7 of 8 trials with OpenCU and 2 of 8 with a shell and screenshots.
[Details below](#measured).

**It is yours.** MIT licensed, with no account, no proprietary runtime and nothing
hosted. The agent you already use brings the model.

## Install

**Windows** · PowerShell, as your normal user, no administrator rights

```powershell
irm https://github.com/Daily-AC/opencu/releases/latest/download/install.ps1 | iex
```

**Linux** · x86_64, X11 desktops

```sh
curl -fsSL https://github.com/Daily-AC/opencu/releases/latest/download/install.sh | sh
```

**macOS** · Apple silicon, macOS 14 or later, Node.js 22+

```sh
npm install -g opencu
opencu setup    # grant Accessibility and Screen Recording once
```

Run `opencu doctor` to check an installation. Platform guides:
[macOS](docs/macos.md) · [Windows](docs/windows.md) · [Linux](docs/linux.md).

## Connect your agent

OpenCU is a stdio MCP server. The command to register is:

| Platform | Command |
|---|---|
| macOS | `opencu` |
| Windows | `%LOCALAPPDATA%\OpenCU\bin\opencu.cmd` |
| Linux | `~/.local/share/opencu/bin/opencu` |

```sh
# Claude Code
claude mcp add --scope user opencu -- opencu

# Codex
codex mcp add opencu -- opencu
```

On Windows and Linux, use the command from the table instead of `opencu`.

Any other MCP client:

```json
{
  "mcpServers": {
    "opencu": { "command": "opencu" }
  }
}
```

Then ask your agent to do something in an app. It starts by reading the app with
`get_app_state`.

## What the agent can do

| Tool | What it does |
|---|---|
| `list_apps` | List running and launchable apps |
| `get_app_state` | Read a window's accessibility tree, with a screenshot on request; launches the app if needed |
| `click` · `drag` · `scroll` | Act on an element by its index, or on screenshot coordinates |
| `type_text` · `paste` · `press_key` | Type Unicode text, paste, send keys and shortcuts |
| `set_value` · `select_text` · `perform_secondary_action` | Change values and use an element's own actions |
| `activate_app` | Bring an app to the front when a step needs it |
| `run_actions` | Run up to 16 actions in one call and return one final state |
| `agent_desktop` | Start, check or stop the agent desktop |

Input requires a fresh observation of the same app, and every error starts with a
stable code such as `STOPPED_BY_PERSON`. Details are in [Tools](docs/tools.md) and
the [engine contract](docs/independent-engine-contract.md).

## Measured

**With and without OpenCU.** The same agent and model, with a shell and screenshots
alone or with OpenCU added:

| Platform | Tasks | Shell and screenshots | With OpenCU |
|---|---|---|---|
| Windows 11 VM | 4 tasks that need the UI: a form, an installer, Save As, an interrupting popup | 2/8 | 7/8 |
| Windows 11 VM | 3 Office and OBS tasks that can be scripted around | 6/6 | 3/6 |
| Linux XFCE container | 5 desktop tasks | 10/10 | 10/10, 40–65% faster inside app windows |

On the scriptable tasks the shell-only agent wrote LibreOffice and OBS scripts
instead of using the UI; two of OpenCU's three failures there were a modal-dialog
defect fixed in 0.3.2. Evidence: [Windows](evidence/opencu-windows-ab-2026-10-20.json),
[Linux](evidence/opencu-linux-ab-2026-10-22.json).

**Against open-computer-use.** The same agents, models and tasks with OpenCU and with
[iFurySt/open-computer-use](https://github.com/iFurySt/open-computer-use) 1.1.2 at
its default settings:

| Platform | Tasks | OpenCU | open-computer-use |
|---|---|---|---|
| Linux | 5 desktop tasks, 2 trials each | 10/10 | 9/10 |
| Windows 11 VM | 4 UI-only tasks, 2 trials each | 7/8 | 4/8 |
| macOS VM (MacArena subset) | 10 tasks, 1 trial each | 4/10 | 4/10, the same tasks |

- **Linux:** the two Firefox tasks took OpenCU 244 and 96 seconds (median) and
  open-computer-use 872 and 552. open-computer-use did not list Firefox until the
  agent turned on the AT-SPI bus itself, and in one trial its `set_value` and
  `type_text` left the Firefox entries empty without an error.
- **Windows:** in all eight open-computer-use trials the agent also wrote its own
  Win32 input code, and its four passes completed input that way. It wrote none
  with OpenCU. open-computer-use ran behind a bridge on the VM (1.5 to 7 seconds per
  call), so its Windows timings are not comparable.
- **macOS:** both passed the same four tasks. On those, the agent took 544 seconds
  in total with OpenCU and 1,498 with open-computer-use; median click time was 292
  ms against 2,029 ms. The OpenCU build in that VM was 0.2.0.

The samples are small and each platform used one model. We did not test
open-computer-use's locked-screen mode, its background input on covered Chrome
windows, or its global pointer setting
([evidence](evidence/opencu-vs-open-computer-use-2026-10-27.json)).

## Platforms

| | macOS | Windows | Linux |
|---|---|---|---|
| Install | npm, Apple silicon | Prebuilt x64, unsigned | Prebuilt x64 |
| Input | Background, to the target app only | Foreground, after 10 s without your input | Foreground, after 10 s without your input |
| Agent desktop | Virtual display with a watch-only preview | Separate session in a window | Not available |
| Screen locked | Refused; the agent desktop pauses | Refused; the agent desktop keeps indexed clicks and values | Refused |

## Stopping it

- **macOS:** the V in the menu bar has **Stop**. In agent desktop mode, the preview's
  Stop button does the same.
- **Windows and Linux:** a physical Escape stops input for the rest of the
  connection, and your own input during an action stops that action. The Windows
  agent desktop also has a Stop button.
- A person's stop is final for the connection. Agents must never reconnect around it.

OpenCU is a person-facing brake, not a sandbox: the agent's apps share your account
and files, and any local process that can run `opencu` uses its permissions.

## Limitations

- **macOS:** Apple silicon only. The package is signed with OpenCU's own certificate
  and is not notarized, so install it with npm, not a browser download. macOS asks
  about once a month whether OpenCU may keep capturing the screen. It cannot operate
  a locked Mac.
- **Windows:** the package is unsigned, so SmartScreen or Defender may warn.
  Outside the agent desktop, input uses the foreground.
- **Linux:** X11 only; Wayland is refused. Input uses the foreground.
- Custom-drawn apps such as Blender, and windows in the Stage Manager strip, need
  the foreground.

The full list, with measurements, is in [Limitations](docs/limitations.md).

## Documentation

- Platform guides: [macOS](docs/macos.md), [Windows](docs/windows.md), [Linux](docs/linux.md)
- [Tools](docs/tools.md) and the [engine contract](docs/independent-engine-contract.md),
  with the [Windows](docs/windows-engine-contract.md) and
  [Linux](docs/linux-engine-contract.md) contracts
- [Host integration](docs/host-integration.md), for programs that start OpenCU on an
  agent's behalf
- [Limitations](docs/limitations.md) and [measured behavior](docs/opencu-independent-2026-10-12.md)

## Development

```sh
npm test
python3 scripts/test-native.py
node scripts/verify-gui.mjs
```

`verify-gui.mjs` builds two disposable AppKit fixtures, keeps one in the
foreground and operates the other in the background through the MCP server. On
Windows, `node scripts/verify-gui-win.mjs` uses disposable WinForms and Chrome
fixtures and takes the foreground.

`python3 scripts/package-opencu.py` builds a self-contained archive with Node and
the MCP dependencies for your own Macs, signed with your local identity, and
`python3 scripts/verify-release.py` checks it offline.

## License

Original OpenCU code is available under the [MIT License](LICENSE). Bundled open
source dependencies retain their own licenses. No license for proprietary third
party software is included or implied.
