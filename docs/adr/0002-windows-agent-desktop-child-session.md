# 0002: Windows agent desktop uses a child session

Date: 2026-10-20. Status: accepted architecture; follow-up fixes awaiting Windows re-acceptance.

## Problem and evidence

People want to keep using a PC while an agent works (Daily-AC/opencu#1, item 4).
Normal Windows input needs foreground ownership. The unmerged
`feat/win-background` experiment tried background UIA patterns. The owner measured
Invoke, SetValue and Toggle bringing target windows forward on Windows 11 with
WinForms, WPF and Chromium, including with Windows' managed UIA client. Omitting
OpenCU's activation calls does not prevent provider-driven activation. Checking
foreground afterwards cannot undo interruption or detect every transient one.
Those foreground-policy changes are not included here.

The latest owner acceptance on a clean cu-bench Windows 11 26H2 VM used the
reproduced `4b6c40d2...` package. The normal foreground suite passed three runs of
40/40, package/update checks passed, and setup was repeatable without a second
UAC prompt. Post-enable sign-in was password-free; before it start returned
SIGN_IN_REQUIRED without credential UI. Medium-integrity RunEx, nonactivating
open, watch-only hover, intentional Escape and physical close/no-reconnect passed.

The parent received exactly twenty Hyper-V text chunks while six agent rounds ran
in the child, with unchanged foreground. But the parent's pointer moved when
parked over the watch-only view: RDP applied server cursor-position updates despite
disabled local input. Five locked-parent trials also showed that the child lost
foreground and input failed (initial PERSON_ACTIVE, later ACTIVATION_FAILED, even
after thirty seconds). Reads and WGC screenshots worked; input worked after
unlock. The earlier locked-input success report is unreliable and is withdrawn.
See the [measured results](../windows-engine-contract.md#agent-desktop-040).

## Decision

Expose `agent_desktop` with start, stop and status through MCP. The runtime routes
every app tool to one engine in the child session while running. The engine keeps
ordinary foreground input, its idle guard, physical Escape latch and window
identity checks. macOS returns `UNSUPPORTED_ON_MACOS` for this tool for now.
No desktop selector is added to individual app tools.

A visible topmost WinForms host embeds `MsRdpClient9NotSafeForScripting`, measured in the
spike and VM acceptance. ShowWithoutActivation alone was measured to steal focus
from a foreground launcher. The host now holds WS_EX_NOACTIVATE until readiness
and clears it without activation, matching the successful probe. It cannot normally
minimize and stops if externally minimized (the latter remains unmeasured). It disables credential prompting/saving, automatic
reconnect, clipboard, audio and device redirection. Hover over the old inactive
view was measured to interrupt the child. The view now starts watch-only, with its
native input ancestor disabled; a deliberate click enables interaction and focuses
RDP, consuming that first click. Deactivation disables input again. That local
input gate passed acceptance, but does not block RDP server cursor-position updates.
Require IgnoreServerGeneratedMouseMoves=true with readback before Connect. Because
it is immutable once connected, it stays enabled even during interactive takeover.
Failure to confirm it refuses startup; no cursor restoration or reconnect fallback
is permitted. The 2026-10-21 VM run confirmed the parked parent pointer stays put.

`& "$env:LOCALAPPDATA\OpenCU\bin\opencu.cmd" setup agent-desktop` in normal
PowerShell uses standard UAC only to enable child sessions. Setup explains the
Microsoft Windows PowerShell UAC prompt before requesting it. A
constant elevated payload calls WTSEnableChildSessions; it does not execute the
user-writable engine/helper as administrator. Remaining setup runs as the original
normal user, including when another administrator approves UAC. It imports the
system RDP type library, compiles a .NET Framework helper with the built-in compiler
and registers a demand-only, least-privilege interactive-token task. The release
archive is unsigned but SHA-256 pinned. Setup records source and derived-helper
hashes, checked before launch. No extra runtime or network install is needed. On first start after an update,
missing/outdated helpers are prepared automatically if child sessions are already
enabled; this path refuses rather than elevates otherwise. Repeated preparation
changes the DACL without rewriting ownership. Demand-task names include an
installation hash so disposable verification installs cannot replace a real task.

The host selects its child with WTSGetChildSessionId and starts that fixed task
using RunEx with AS_SELF and USE_SESSION_ID. The
[Task Scheduler protocol](https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-tsch/77f2250d-500a-40ee-be18-c82f7079c4f0)
defines same-user authorization for non-admin callers. The VM measured this
replacement for the spike's SYSTEM launcher working repeatedly at Medium integrity;
there is no automatic fallback.
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
Host EOF ends ownership. Following the 2026-10-20 owner decision, parent lock is
not a stop: the child stays alive for reads and screenshots. The latest measurements
show input unavailable while locked. Its native engine is configured by the
authenticated bridge with the parent session ID and refuses locked-parent input
with SCREEN_LOCKED at preflight and safety fences. Partial input is reported
honestly; no input is replayed. USER_STOPPED retains precedence. Ordinary parent
engine foreground rules are unchanged. Unlock permits later explicit requests,
not automatic recovery/reconnect. Console/remote disconnect and logoff still end
ownership.

## Trade-offs and verification boundary

Administrator approval is needed once, and the person may need to sign out/in
once. Smart-card-only sign-in is unsupported. OpenCU never requests, receives,
stores or supplies a session password; Windows automatic sign-in is required.
If required prompt-suppression properties fail, connection is refused.

Apps run separately in one visible child session per machine. Profiles, files and
application databases still belong to the same user. Global single-instance apps
may refuse startup or delegate to the parent; OpenCU will not follow them there.
External minimize, covered/partly off-screen viewports, GPU/video/protected
content, smart-card sign-in and unsupported editions remain unmeasured. WGC fixture
capture, retained session identity and lock status were measured; those do not
establish locked input or the remaining cases.

`scripts/verify-agent-desktop-win.mjs --allow-desktop` checks setup, real pipe
authentication, child fixture launch/capture/actions, concurrent parent fixture
foreground and input counters, watch-only hover, repeat demand launch, tool stop
and window-close latching. Run it from a foreground terminal, not a headless shell. Its parent stimulus uses SendInput, not physical hardware. The original
physical Escape, sign-in refusal and lock results are recorded above. Recheck
Escape through the new deliberate-interaction gate, automatic preparation,
repeated setup and diagnostics, plus unmeasured disconnect and crash timing.
This follow-up implementation job ran no new Windows GUI acceptance.

The prior diagnostic claim of locked-parent input could not be reproduced. The
latest five trials govern the contract: reads/screenshots work, input does not.
No official, reliable foreground-activation mechanism meeting the no-elevation/
no-parent-input boundaries was established, so no speculative bypass is shipped.
The [input investigation](../windows-agent-desktop-input-findings.md) explains the
public foreground APIs, child input-desktop checks, possible RDP focus sync, and
the documented cursor setting.

Nobody at the machine can see the child behind the parent lock screen. The caller
can stop it by ending MCP; after unlocking the person can close the host or press
Escape in its interactive view. Status retains parentLocked=true/false. Lock tests
remain manual because the suite cannot unlock without a password. The final
pointer-suppression and lock-refusal implementation still needs Windows verification.
