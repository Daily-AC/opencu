<p align="center">
  <img src="docs/assets/opencu.png" width="112" alt="OpenCU">
</p>

<h1 align="center">OpenCU</h1>

<p align="center">
  <strong>给任何 AI agent 用的 computer use，跑在你自己的电脑上。</strong>
</p>

<p align="center">
  OpenCU 是一个 MCP 服务器，让 Claude Code、Codex 或任何 MCP 客户端读取并操作<br>
  macOS、Windows 和 Linux 上的应用。它在本机运行，不需要账号和模型密钥，<br>
  坐在电脑前的人随时可以叫停。
</p>

<p align="center">
  <a href="https://github.com/Daily-AC/opencu/releases/latest"><img src="https://img.shields.io/github/v/release/Daily-AC/opencu?label=release&color=111111" alt="最新版本"></a>
  <img src="https://img.shields.io/badge/macOS%20%C2%B7%20Windows%20%C2%B7%20Linux-111111" alt="macOS、Windows、Linux">
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-111111" alt="MIT 许可证"></a>
</p>

<p align="center">
  <a href="#安装">安装</a> ·
  <a href="#接入你的-agent">接入</a> ·
  <a href="#实测">实测</a> ·
  <a href="docs/limitations.md">限制</a> ·
  <a href="README.md">English</a>
</p>

<br>

## 为什么用 OpenCU

**不跟你抢电脑。** 在 macOS 上，输入只送到目标应用的进程和窗口。你的光标不会动，前台应用照样接收你的键盘。

**可以有自己的屏幕。** 打开 agent 桌面后，agent 在一块虚拟显示器（macOS）或一个独立会话（Windows）里干活，你在一个普通窗口里看着它。

**你说了算。** 随时有停止按钮。在 Windows 和 Linux 上按一下实体 Esc 也能停；你最近 10 秒内动过键鼠，它就不会抢前台。被人停掉的连接不会自己恢复。

**有实测数据。** 在只能走界面的 Windows 任务上，同一个 agent 接上 OpenCU 过了 8 次中的 7 次，只用 shell 加截图只过了 2 次。[见下文](#实测)。

**完全属于你。** MIT 许可证，不要账号，不依赖任何专有运行时，没有托管服务。模型由你正在用的 agent 自己带。

## 安装

**Windows** · 在 PowerShell 里以普通用户运行，不需要管理员权限

```powershell
irm https://github.com/Daily-AC/opencu/releases/latest/download/install.ps1 | iex
```

**Linux** · x86_64，X11 桌面

```sh
curl -fsSL https://github.com/Daily-AC/opencu/releases/latest/download/install.sh | sh
```

**macOS** · Apple 芯片，macOS 14 及以上，需要 Node.js 22+

```sh
npm install -g opencu
opencu setup    # 授予一次「辅助功能」和「录屏」权限
```

装好后运行 `opencu doctor` 检查。各平台说明：
[macOS](docs/macos.md) · [Windows](docs/windows.md) · [Linux](docs/linux.md)（英文）。

## 接入你的 agent

OpenCU 是 stdio 方式的 MCP 服务器，要注册的命令是：

| 平台 | 命令 |
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

Windows 和 Linux 把 `opencu` 换成上表里的命令。

其他 MCP 客户端：

```json
{
  "mcpServers": {
    "opencu": { "command": "opencu" }
  }
}
```

然后直接让 agent 去某个应用里办事，它会先用 `get_app_state` 读取那个应用。

## agent 能做什么

| 工具 | 作用 |
|---|---|
| `list_apps` | 列出正在运行和可以启动的应用 |
| `get_app_state` | 读取窗口的无障碍元素树，需要时附带截图；应用没开会先启动 |
| `click` · `drag` · `scroll` | 按元素编号或截图坐标操作 |
| `type_text` · `paste` · `press_key` | 输入任意文字、粘贴、发送按键和快捷键 |
| `set_value` · `select_text` · `perform_secondary_action` | 改值、选中文字、调用元素自带的动作 |
| `activate_app` | 需要时把应用切到前台 |
| `run_actions` | 一次调用最多执行 16 个动作，只返回最后的状态 |
| `agent_desktop` | 打开、查看或关闭 agent 桌面 |

每次输入前都要先读一次同一个应用；出错时，错误信息以固定的错误码开头，比如 `STOPPED_BY_PERSON`。完整说明见 [Tools](docs/tools.md) 和[引擎契约](docs/independent-engine-contract.md)。

## 实测

**接不接 OpenCU 的区别。** 同一个 agent、同一个模型，一组只有 shell 和截图，另一组再加上 OpenCU：

| 平台 | 任务 | 只有 shell 和截图 | 加上 OpenCU |
|---|---|---|---|
| Windows 11 虚拟机 | 4 道只能走界面的题：表单录入、安装向导、另存为、录入中途弹窗 | 2/8 | 7/8 |
| Windows 11 虚拟机 | 3 道能写脚本绕开界面的 Office 和 OBS 题 | 6/6 | 3/6 |
| Linux XFCE 容器 | 5 道桌面任务 | 10/10 | 10/10，应用窗口里的任务快 40% 到 65% |

那 3 道 Office 和 OBS 题，只有 shell 的那组是写 LibreOffice 和 OBS 脚本做成的，没有走界面；OpenCU 那组的 3 次失败里有 2 次撞上了一个对话框缺陷，0.3.2 已修复。原始数据：[Windows](evidence/opencu-windows-ab-2026-10-20.json)、[Linux](evidence/opencu-linux-ab-2026-10-22.json)。

**和 open-computer-use 对比。** 同样的 agent、模型和任务，分别接 OpenCU 和默认设置下的 [iFurySt/open-computer-use](https://github.com/iFurySt/open-computer-use) 1.1.2：

| 平台 | 任务 | OpenCU | open-computer-use |
|---|---|---|---|
| Linux | 5 道桌面任务，各 2 次 | 10/10 | 9/10 |
| Windows 11 虚拟机 | 4 道只能走界面的题，各 2 次 | 7/8 | 4/8 |
| macOS 虚拟机（MacArena 子集） | 10 道题，各 1 次 | 4/10 | 4/10，过的是同样的题 |

- **Linux：** 两道 Firefox 题，OpenCU 的中位用时是 244 秒和 96 秒，open-computer-use 是 872 秒和 552 秒。open-computer-use 要等 agent 自己打开 AT-SPI 无障碍总线才看得到 Firefox；有一次它的 `set_value` 和 `type_text` 没报错，Firefox 的输入框却一直是空的。
- **Windows：** open-computer-use 的 8 次试验里，agent 每次都另写了 Win32 输入代码，过了的 4 次都是靠这些代码完成输入的；接 OpenCU 时一次都没写。open-computer-use 在虚拟机上要经过一层桥接（每次调用 1.5 到 7 秒），所以 Windows 的用时不可比。
- **macOS：** 两边过的是同样的 4 道题。这 4 道题上，agent 用 OpenCU 共 544 秒，用 open-computer-use 共 1,498 秒；单次点击的中位耗时是 292 毫秒对 2,029 毫秒。虚拟机里的 OpenCU 是 0.2.0 版。

样本小，每个平台只用了一个模型。open-computer-use 的锁屏模式、在被遮挡的 Chrome 窗口上的后台输入、全局指针开关，这些都没测（[原始数据](evidence/opencu-vs-open-computer-use-2026-10-27.json)）。

## 平台

| | macOS | Windows | Linux |
|---|---|---|---|
| 安装 | npm，Apple 芯片 | x64 预编译包，未签名 | x64 预编译包 |
| 输入 | 后台，只送到目标应用 | 前台，你 10 秒没动键鼠才切 | 前台，你 10 秒没动键鼠才切 |
| agent 桌面 | 虚拟显示器，带只看不点的预览窗 | 独立会话，显示在一个窗口里 | 暂无 |
| 锁屏时 | 拒绝操作；agent 桌面暂停 | 拒绝操作；agent 桌面仍可按编号点击和设值 | 拒绝操作 |

## 怎么叫停

- **macOS：** 菜单栏里的 V 图标有「停止」。agent 桌面模式下，预览窗的停止按钮效果相同。
- **Windows 和 Linux：** 按一下实体 Esc，这个连接后面的输入就全停了；动作进行中你一动键鼠，这个动作就会停下。Windows 的 agent 桌面也有停止按钮。
- 被人停掉的连接就此结束，agent 绝不能绕开它重新连接。

OpenCU 是给人用的刹车，不是沙箱：agent 操作的应用和你共用同一个账号和文件，本机任何能运行 `opencu` 的程序都能用到它的权限。

## 限制

- **macOS：** 只支持 Apple 芯片。安装包用 OpenCU 自己的证书签名，没有经过苹果公证，所以要用 npm 安装，不要从浏览器下载。macOS 大约每月问一次是否允许 OpenCU 继续录屏。电脑锁屏时无法操作。
- **Windows：** 安装包没有签名，SmartScreen 或 Defender 可能会提示。不在 agent 桌面里时，输入走前台。
- **Linux：** 只支持 X11，Wayland 会被拒绝。输入走前台。
- Blender 这类自绘界面的应用，以及台前调度侧栏里的窗口，需要在前台操作。

完整清单和实测数据见 [Limitations](docs/limitations.md)（英文）。

## 文档

- 各平台说明：[macOS](docs/macos.md)、[Windows](docs/windows.md)、[Linux](docs/linux.md)
- [Tools](docs/tools.md) 和[引擎契约](docs/independent-engine-contract.md)，以及 [Windows](docs/windows-engine-contract.md)、[Linux](docs/linux-engine-contract.md) 契约
- [宿主接入](docs/host-integration.md)：给代替 agent 启动 OpenCU 的程序看
- [Limitations](docs/limitations.md) 和[实测行为](docs/opencu-independent-2026-10-12.md)

文档目前只有英文。

## 许可证

OpenCU 的原创代码使用 [MIT 许可证](LICENSE)。打包的开源依赖保留各自的许可证。不包含也不暗示任何专有第三方软件的许可。
