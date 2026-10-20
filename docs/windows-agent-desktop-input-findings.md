# Windows agent-desktop input findings

2026-10-20, follow-up 3. Scope: the system RDP ActiveX child session, normal user
privileges, no synthetic input on the parent's desktop, no reconnect workaround.
The Windows measurements below came from the owner's cu-bench acceptance session;
this implementation job researched APIs and ran local tests, not Windows GUI tests.

## The current evidence

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
The exact foreground HWND/thread and internal Windows reason for refusal were not
measured here.

[RDP input synchronization](https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-rdpbcgr/f0ea088b-1398-43f0-af42-f4e027ab2009)
includes keyboard-state synchronization around client focus changes. This is a
plausible source of the transition's input-like event, not a proven attribution
without a trace. [GrabFocusOnConnect](https://learn.microsoft.com/en-us/windows/win32/termserv/imsrdpclientadvancedsettings-grabfocusonconnect)
controls client focus during connection, not foreground rights inside a locked
parent's child. [allowBackgroundInput](https://learn.microsoft.com/en-us/windows/win32/termserv/imstscadvancedsettings-allowbackgroundinput)
accepts client-side input without client focus; it does not document a server-side
foreground grant. Enabling it would also work against watch-only input isolation.
Rendering suppression is not the observed failure: WGC still returned real content.

No reliable mechanism satisfying the requested boundaries was established. No
focus-bypass candidate, parent input, desktop switch, policy change, elevation or
automatic reconnect is implemented. This is not a claim that all Windows versions
can never support locked-parent input; a future mechanism needs reproducible
Windows evidence before it becomes a supported path.

## Shipped behavior and Windows verification

The child stays alive while the parent is locked, allowing reads and screenshots.
The authenticated bridge configures the native engine with its verified parent
session ID. Only that mode adds a parent-lock guard, before action dispatch and
at input safety fences. A locked parent returns SCREEN_LOCKED before input instead
of the incidental PERSON_ACTIVE/ACTIVATION_FAILED. If locking occurs mid-action,
the error says earlier input may have run; it never falsely promises zero input.
Person-stop latches take precedence. Ordinary parent-desktop input rules are unchanged.

Readiness confirms that the child engine installed the guard and can query its
parent's WTS lock state at Medium integrity. Unknown state refuses input. Unlocking
allows later explicit calls through the existing foreground/human-activity rules;
nothing is replayed. A refused input still consumes its screenshot grant.

On Windows verify: required pointer-property setter/readback; the parked-pointer
check and hardware counterpart; ordinary interactive takeover/Escape; readiness
and cross-session WTS queries; immediate and thirty-second lock refusals with
stable SCREEN_LOCKED, unchanged fixture text/counters and retained screenshots;
explicit post-unlock input on the same connection; and a lock during a long input,
where partial-outcome wording and held-input cleanup must remain correct. Keep
foreground-only acceptance, no-activation, setup/sign-in, update, close/EOF and
no-reconnect checks. Lock/unlock remains manual without supplying OpenCU a password.
