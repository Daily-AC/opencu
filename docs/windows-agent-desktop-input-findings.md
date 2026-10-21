# Windows agent-desktop input findings

2026-10-21, locked-pattern follow-up (not a release). Scope: the system RDP ActiveX child session, normal user
privileges, no synthetic input on the parent's desktop, no reconnect workaround.
The Windows measurements below came from the owner's cu-bench acceptance session;
this implementation job researched APIs and ran local tests, not Windows GUI tests.

## Earlier evidence (2026-10-20)

Candidate `987d042` plus acceptance fixes `69a1dae`/`4b7db3b`, packaged as
`4b6c40d2...`, preserved parent foreground and isolated keyboard text in the
Hyper-V hardware test. Hover over the watch-only view no longer interrupted the
child. However, parking the parent cursor over that view let child clicks warp
it to mapped remote click positions. The cursor stayed still when outside the view.
Disabling input to a native control therefore does not disable server-to-client
pointer updates.

Five locked-parent trials failed to deliver input. The transition first produced
PERSON_ACTIVE; subsequent attempts, including after thirty seconds, produced
ACTIVATION_FAILED. Disabling watch-only, omitting status calls and focusing the
interactive view before locking did not help. Reads and real WGC screenshots
remained available; the next round after unlock succeeded. The earlier report of
successful input while locked is unreliable and is not evidence for support.

## Pointer isolation: a documented setting

[IMsRdpExtendedSettings.Property](https://learn.microsoft.com/en-us/windows/win32/termserv/imsrdpextendedsettings-property)
provides `IgnoreServerGeneratedMouseMoves`. It suppresses the remote cursor-position
packets identified by the [RDP pointer update specification](https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-rdpbcgr/3058381e-c856-4b26-a93c-d8f5514f8c3c).
Set it to true and require a true Boolean readback immediately before Connect.
An unsupported setter/getter or an unconfirmed value refuses startup. There is no
fallback that moves the cursor back after it has already moved.

Microsoft marks this property as immutable after connection. It stays enabled in
both watch-only and interactive modes; a mode change does not reconnect. Deliberate
local mouse/keyboard input still reaches the child in interactive mode, but remote
applications cannot request a local cursor warp. Applications relying on those
warps may behave differently. `IgnoreCursors`, which concerns remote cursor data,
is not substituted for this specific movement control.

The new acceptance check parks the parent cursor once with SendInput, then sends
no more parent mouse input while six child clicks alternate between two controls.
It checks exact before/after cursor pixels and the existing unexpectedCursor
counter, retaining state on failure. The actual system DLL must still be verified
on Windows; readback alone is not a measured pointer-isolation result.

## Locked-parent focus: no supported mechanism established

The [child-session documentation](https://learn.microsoft.com/en-us/windows/win32/termserv/child-sessions)
says a child cannot itself lock. It does not promise foreground acquisition when
its parent locks. Session lifetime, readable surfaces and permission to receive
foreground input are separate properties.

[SetForegroundWindow](https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-setforegroundwindow)
can be refused even when its listed eligibility conditions hold. The existing
engine already checks idle time and tries this API plus a checked input-queue
attachment. [AttachThreadInput](https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-attachthreadinput)
cannot attach threads on different desktops and requires message queues.
[SetThreadDesktop](https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-setthreaddesktop)
is limited to the process's window station and cannot move a thread with existing
windows/hooks to a different desktop. These APIs do not document a parent-lock
exception for child-session foreground input.

For the reported later ACTIVATION_FAILED path, the existing `safety::activate`
checks imply that the child's WTS state was Active/unlocked and its thread/input
desktop names passed the Default checks before activation failed. That is an
inference from the executed guard path, not a captured trace of every handle.
[OpenInputDesktop](https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-openinputdesktop)
returns a desktop handle; having such a handle is not a foreground authorization.
The 2026-10-21 probe below measured NULL foreground and SendInput denial;
it did not establish an internal Windows explanation for the restriction.

[RDP input synchronization](https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-rdpbcgr/f0ea088b-1398-43f0-af42-f4e027ab2009)
includes keyboard-state synchronization around client focus changes. This is a
plausible source of the transition's input-like event, not a proven attribution
without a trace. [GrabFocusOnConnect](https://learn.microsoft.com/en-us/windows/win32/termserv/imsrdpclientadvancedsettings-grabfocusonconnect)
controls client focus during connection, not foreground rights inside a locked
parent's child. [allowBackgroundInput](https://learn.microsoft.com/en-us/windows/win32/termserv/imstscadvancedsettings-allowbackgroundinput)
accepts client-side input without client focus; it does not document a server-side
foreground grant. Enabling it would also work against watch-only input isolation.
Rendering suppression is not the observed failure: WGC still returned real content.

No reliable foreground/synthetic-input mechanism satisfying the requested boundaries was established. No
focus-bypass candidate, parent input, desktop switch, policy change, elevation or
automatic reconnect is implemented. This is not a claim that all Windows versions
can never support locked-parent input; a future mechanism needs reproducible
Windows evidence before it becomes a supported path.

## New measurements (owner, 2026-10-21)

The owner ran a disposable WinForms fixture in the child of cu-bench Windows 11
26H2 while the parent was locked. GetForegroundWindow was NULL, SetForegroundWindow
failed, and keyboard down/up and absolute mouse SendInput returned zero with
ERROR_ACCESS_DENIED (5). The supplied summary also reports Unicode-key denial;
the retained `lockfg-probe.ps1` / `locked-probe-output.txt` log skips typing because
there was no foreground. These private job artifacts are not published here.
An MSAA `accDoDefaultAction` returned and the fixture's click counter went from
1 to 2, while text stayed unchanged. WGC still returned real content. Unlock
restored ordinary explicit input on the same child.

This distinguishes synthetic input from semantic accessibility calls. The earlier
2026-10-20 measurements in the unlocked parent found UIA Invoke, Value.SetValue
and Toggle functional on WinForms, WPF and Chromium (Edge --app), but activating
the target. That disqualified general same-desktop background UIA. Activation
inside an agent-owned child is acceptable; it does not authorize UIA operations
on the person's desktop while locked. These earlier measurements did not accept the engine implementation across providers.

## Engine acceptance (owner, 2026-10-21)

On 2026-10-21, from a clean Windows 11 26H2 VM checkpoint, the owner passed
verify-gui-win three times (40/40 each), the package verifier, and the agent-desktop
suite with `--locked-parent` behind the real lock screen. The indexed Increment
click changed 10 to 11, `set_value` produced "locked pattern value", `type_text`
returned SCREEN_LOCKED, and unlock retained the same child with no replay.
Hardware concurrency, parked-pointer, hover, Escape and close regressions also
passed. A locked indexed click on the text box returned UNSUPPORTED_ACTION in
about two seconds. The run did not record which pattern/default action delivered
the button click; Invoke versus MSAA must not be inferred.

The private job artifacts `vm-acceptance/ad-14-locked.txt` and `chain.log` record
the locked suite and successful command exits. They are not committed. The checks
below distinguish that accepted implementation from subsequent review corrections.

## Branch behavior and acceptance boundary

The 0.4.0 baseline at `1cf23f8` accepted pointer isolation and explicit locked-input
refusal. Only an engine in a WTS-verified RDP process session, configured by
the authenticated bridge with `--agent-parent-session` and a
positively verified locked parent enters the new pattern path. Ordinary desktop
and unlocked-child routing remain unchanged. Unknown parent state refuses input.

Supported actions are plain single-left indexed click (no modifiers/duration),
ValuePattern `set_value`, and listed `perform_secondary_action`. Click selects
SelectionItem.Select, Invoke, Toggle, ExpandCollapse, then a nonempty Legacy MSAA
default action. ExpandCollapse expands collapsed/partially expanded controls,
collapses expanded controls, and skips leaf nodes. Names and roles do not choose
a pattern. A failed provider call never triggers another pattern or input replay.
Missing capability returns UNSUPPORTED_ACTION; read-only Value returns
ATTRIBUTE_NOT_SETTABLE. RangeValue, scroll, coordinate/modified/multiple clicks,
typing, keys, paste, drag, activation and waits are not enabled while locked.
Their SCREEN_LOCKED message identifies the indexed actions that remain available.
Read-triggered CreateProcess launches are allowed without OpenCU activation; the
2026-10-21 VM run launched a fixture while locked and it did not take the foreground. The independent
WTSClientProtocolType query rejects console, failed, truncated or unknown results
before accepting the parent-session flag. The bridge still checks the child relationship.

A dedicated MTA worker reuses the bounded delivery from the unmerged background
branch, without that branch's general background mode, scroll or foreground
comparison. It retains the observed COM identity and validates live attachment,
window identity, integrity, child desktop, parent lock, monitor and Escape at the
mutation boundary. Ordinary activity/held keys are ignored only on this locked
path; a prior interrupted action still requires a read. The normal visible child
indicator remains, though the parent lock screen hides the child from the person.

The worker deadline is three seconds; an already entered call cannot be cancelled.
A provider timeout may return around two seconds, with no client call left pending.
Only calls still outstanding after the deadline block further writes and launches,
including after unlock. A preparation timeout/lock change before dispatch says no
pattern was sent. Once dispatch starts, every subsequent error or unlock during
the fresh read returns unknown outcome with explicit dispatched wording. Target
identity is not revalidated after a call that can legitimately close its window or
exit the app. Escape also preserves unknown outcome and latches the connection.
Cancellation and dispatch marking are synchronized to avoid false preflight claims.
Explicit reads remain available, subject to the existing person-stop rules. This
uses the documented [MTA sharing model](https://learn.microsoft.com/en-us/windows/win32/com/processes--threads--and-apartments)
and accounts for [blocking Invoke providers](https://learn.microsoft.com/en-us/dotnet/api/system.windows.automation.invokepattern.invoke).

After a completed call, the engine reads fresh state using the existing scope.
Window summaries and accessibility element lines are compared, excluding capture
and lock guidance. If nothing changed, the response includes that state plus an
unknown-outcome notice and invalidates native indexes, requiring an explicit read.
A changed observation also stops any remaining batch actions and returns the fresh
state, because indexes may have shifted. MCP exposes the selected route in the
short structured field `_meta["opencu/pattern"]`, including dispatched unknown
outcomes. A change is an observation, not proof of the requested business effect;
asynchronous/provider-internal effects can be missed. Failed follow-up reads also report unknown without replay.

The old branch's zero-code Toggle failure is explained by the pinned windows-rs
0.62.2 source: a successful null pattern pointer becomes `Error::empty()` with
code zero. The old query treated it as a fatal error while checking Invoke,
before trying Toggle. The new query inspects raw HRESULT and pointer separately;
only successful null or UIA_E_NOTSUPPORTED means absent. Actual failures propagate.
The offline regression exercises this distinction; the real checkbox still needs
Windows verification.

To repeat the accepted case and record the selected patterns, use an authorized
idle VM's foreground terminal with child sessions already set up:

```powershell
node scripts/verify-agent-desktop-win.mjs --allow-desktop --locked-parent
```

At the prompt, manually lock the parent with Win+L and leave it locked. The suite
waits for parentLocked=true, captures the child, clicks the fixture button once,
sets its text through ValuePattern, and confirms type_text returns SCREEN_LOCKED
with unchanged counter/text. It asks for manual unlock only after those checks,
then checks the same session/host and no replay. It also launches a second disposable fixture through get_app_state while locked,
checks its child session and screenshot, and records both action pattern fields.
This added launch check has not run on Windows. It never collects credentials or
unlocks automatically. Evidence stays in ignored `.cache/agent-desktop-acceptance-*`.

Also verify Toggle (including absent Invoke), SelectionItem, ExpandCollapse and
MSAA-only controls, named secondary actions, disabled/read-only/missing patterns,
a no-op provider, modal/late completion, pending-write refusal, lock/unlock during
action, unknown lock state, and Escape during provider delivery. Recheck the
review changes: selection before Invoke, batch truncation, post-dispatch unknown
outcomes, and console-session flag refusal. Keep the unlocked 40-check suite
and setup/update/watch-only/pointer isolation/close/EOF regressions. Disconnect and
logoff must still end the child; unlocking must never revive a stopped connection.
No Windows GUI test was run from the implementation Mac.
