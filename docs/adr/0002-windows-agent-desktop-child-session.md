# 0002: Windows agent desktop uses a child session

Date: 2026-10-20. Status: implementation candidate; Windows acceptance pending.

## Problem and evidence

People want to keep using a PC while an agent works (Daily-AC/opencu#1, item 4).
Normal Windows input needs foreground ownership. The unmerged
`feat/win-background` experiment tried background UIA patterns. The owner measured
Invoke, SetValue and Toggle bringing target windows forward on Windows 11 with
WinForms, WPF and Chromium, including with Windows' managed UIA client. Omitting
OpenCU's activation calls does not prevent provider-driven activation. Checking
foreground afterwards cannot undo interruption or detect every transient one.
Those foreground-policy changes are not included here.

The owner's child-session spike used the v9 RDP ActiveX control with
ConnectToChildSession, localhost and EnableCredSspSupport. Six rounds of indexed
click, click and type_text succeeded with the unchanged foreground engine (about
0.27 seconds per round). Meanwhile the parent's Notepad kept foreground and
received all twenty Hyper-V keyboard chunks alongside pointer movement. No input
leak was reported. This is owner-reported evidence, not a run of this implementation.
The referenced spike scripts were not available in this checkout during design.

The spike enabled child sessions after the parent sign-in, then needed a password.
It does not validate this implementation's password-free connection path. The
[Windows documentation](https://learn.microsoft.com/en-us/windows/win32/termserv/child-sessions)
describes automatic sign-in after a new parent sign-in and a smart-card exception.

## Decision

Expose `agent_desktop` with start, stop and status through MCP. The runtime routes
every app tool to one engine in the child session while running. The engine keeps
ordinary foreground input, its idle guard, physical Escape latch and window
identity checks. macOS returns `UNSUPPORTED_ON_MACOS` for this tool for now.
No desktop selector is added to individual app tools.

A visible topmost WinForms host embeds `MsRdpClient9NotSafeForScripting`, measured in the
spike. It does not request initial activation, cannot normally minimize, and stops
if externally minimized. It disables credential prompting/saving, automatic
reconnect, clipboard, audio and device redirection. Focusing the viewport
intentionally sends the person's input into it.

`opencu setup agent-desktop` uses standard UAC only to enable child sessions. A
constant elevated payload calls WTSEnableChildSessions; it does not execute the
user-writable engine/helper as administrator. Remaining setup runs as the original
normal user, including when another administrator approves UAC. It imports the
system RDP type library, compiles a .NET Framework helper with the built-in compiler
and registers a demand-only, least-privilege interactive-token task. The release
archive is unsigned but SHA-256 pinned. Setup records source and derived-helper
hashes, checked before launch. No extra runtime or network install is needed.

The host selects its child with WTSGetChildSessionId and starts that fixed task
using RunEx with AS_SELF and USE_SESSION_ID. The
[Task Scheduler protocol](https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-tsch/77f2250d-500a-40ee-be18-c82f7079c4f0)
defines same-user authorization for non-admin callers. This is an unmeasured
replacement for the spike's SYSTEM launcher; there is no automatic fallback.
The bridge refuses a wrong session and requires an accessible engine doctor reply.
HKCU Run is rejected because it only fired once in the spike. A SYSTEM task pointing
into a writable per-user package would be an elevation vulnerability; a protected
SYSTEM broker adds installation and token-handling complexity.

Use a local-only, first-instance named pipe with a protected user-SID DACL, a random
256-bit token in a private temporary descriptor, bounded authentication and OS
peer PID/session/SID/integrity checks. The bridge verifies the host's process start
time too. Tokens never enter arguments or logs. The engine keeps inherited
JSON-lines stdio; the bridge owns an engine job object. A parent-session guardian
logs off the adopted child if the host dies. No transport reconnect is implemented.
This is not protection against arbitrary same-user code or administrators.

## Stops and failures

Host close and engine USER_STOPPED permanently latch the entire MCP connection.
Tool stop, mode switching, late replies and timeout cleanup cannot clear it.
Status and cleanup remain available. Tool stop alone permits a later explicit
start; it logs off child apps, potentially losing unsaved work. Changing desktop
clears observations and requires a fresh state read.

A failed start or lost child transport never falls back to the parent engine.
Explicit stop must confirm cleanup before routing can return to the parent.
Normal parent timeout recovery is unchanged; child engine replacement is disabled.
Host EOF ends ownership. Parent lock/disconnect also stops the child: the child
itself cannot lock, so its own desktop guard is insufficient.

## Trade-offs and verification boundary

Administrator approval is needed once, and the person may need to sign out/in
once. Smart-card-only sign-in is unsupported. OpenCU never requests, receives,
stores or supplies a session password; Windows automatic sign-in is required.
If required prompt-suppression properties fail, connection is refused.

Apps run separately in one visible child session per machine. Profiles, files and
application databases still belong to the same user. Global single-instance apps
may refuse startup or delegate to the parent; OpenCU will not follow them there.
GPU/video/protected content, WGC over RDP, policy/edition support, nonactivating
creation, covered rendering and parent lock need Windows measurement. The spike
does not establish those properties.

`scripts/verify-agent-desktop-win.mjs --allow-desktop` checks setup, real pipe
authentication, child fixture launch/capture/actions, concurrent parent fixture
foreground and input counters, repeat demand launch, tool stop and window-close
latching. Its parent stimulus uses SendInput, not physical hardware. Physical
Escape, pre-setup sign-in refusal, smart cards, lock/disconnect and crash timing
remain separate Windows checks. This job ran no Windows GUI acceptance.
