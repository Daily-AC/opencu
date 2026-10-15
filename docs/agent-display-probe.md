# Experimental agent display probe

This is a feasibility experiment, not a claim that macOS offers an invisible or
isolated desktop. Implementation and non-GUI tests are complete; live acceptance
is deliberately left to the reviewer. It does not introduce MCP tools or consent UI.

## Direct engine API

Run `bin/opencu engine`. Each line is `{id, method, params}`; responses use the
existing `{id, result}` / `{id, error}` contract. One connection owns at most one
display and one outstanding window restoration. Methods are:

| Method (all prefixed `experimental_agent_display_`) | Parameters | Result / behavior |
| --- | --- | --- |
| `create` | `{}` | Create a 1728 × 1117 point, 60 Hz display at the main display's 1x/2x backing scale. Refuse mirrored/unsupported layouts or an outstanding display/restoration. |
| `move_window` | `{app: "bundle ID or .app path"}` | Resolve an already-running app's selected ordinary window; record its exact AX identity, WindowServer ID, original frame/display before any write. Move only that window. Refuse a second move until restored. |
| `restore` | `{}` | Restore the recorded window, even if selection changed. Verify process/window identity and the original display still exists. Never substitute another window. Idempotent after success. |
| `destroy` | `{}` | Attempt restoration, release the display even if restoration fails, wait for removal, return `ok` and `cleanupErrors`. Repeated calls are safe. |
| `status` | `{}` | Online display IDs, Quartz frames, main/mirror flags and pixel dimensions; requested/actual agent placement; target AX/WindowServer frames, original frame/display, intersecting display IDs, on-screen flag and restoration state. |

Status also returns title-free WindowServer frame records with owner names for ordinary windows,
Dock-level and main-menu-level windows, for movement warnings. These are
private local evidence, not publishable app inventories. Mutation attempts discard
that engine connection's observation and coordinate grant. Observe again before
input. Direct display calls and ordinary MCP input must be serialized; they must
never operate the same app concurrently.

## API boundary and placement

`AgentDisplaySPI.swift` is original Swift code using runtime class lookup and
checked Objective-C method implementations for `CGVirtualDisplay`, its descriptor,
settings and mode. Missing classes, selectors or unexpected argument/return ABI
fail closed. No private headers, proprietary runtime, agent identity checks,
driver, helper daemon or display-preview window are bundled.

[DeskPad](https://github.com/Stengo/DeskPad) was inspected after checking its
[MIT license](https://github.com/Stengo/DeskPad/blob/main/LICENSE.md). No implementation
was copied. Its handwritten mode declaration differs from Chromium's binary-derived
32-bit declaration; the bridge uses the latter and verifies it at runtime.
[Chromium's implementation](https://chromium.googlesource.com/chromium/src/+/HEAD/ui/display/mac/test/virtual_display_util_mac.mm)
also establishes logical mode dimensions under HiDPI, nonzero vendor/unique serial
requirements, and ownership-based removal. Its removal workaround documents flaky
first-removal timeouts. OpenCU does not reproduce that workaround by creating an
extra display; it reports a removal timeout instead.

The descriptor has a fresh random serial, sRGB primaries, a nonzero vendor/product
and pixel capacity of 1728 × scale by 1117 × scale. Mode dimensions are 1728 × 1117
logical points. The engine checks the resulting size and backing scale.
Public `CGBeginDisplayConfiguration`, `CGConfigureDisplayOrigin` and
`CGCompleteDisplayConfiguration(.forSession)` position only the new display.
No main-display, mode, mirroring, permanent-settings, Dock or menu-bar mutation is
requested for any existing display.

Placement tries the main display's bottom-right, bottom-left, top-right and
top-left corners in Quartz global coordinates, without overlap or a shared edge
with an existing display. If none is free it refuses. macOS may normalize corner adjacency; status
reports both requested and actual frames and `placementAdjustedByOS`. Any accepted
placement remains nonoverlapping and non-main. Pointer isolation is **not**
guaranteed. The window gets 64-point margins and retains its size if it fits;
oversized windows are clamped, with their original size preserved for restoration.

Creating a display is equivalent to attaching a monitor: WindowServer may react
before OpenCU can position or validate it. The engine checks original display
frames/main identity after creation, and removes the new display on unexpected
display-layout changes. Other-app window movement is reported as a warning with
owner name, PID and before/after frames: it may be caused by the person, app
animation or display reconfiguration, and the probe cannot establish causality.
It never moves other windows back itself. Target restoration remains a strict check.
These checks cannot prevent a transient rearrangement, detect every rebuilt
system window, or guarantee that the Dock/menu bar never appears on the new
screen. The live reviewer must assess those effects.

## Lifetime and cleanup

The controller holds the sole owning reference to the `CGVirtualDisplay`; no
termination block captures it. Objective-C ownership releases its display resource
when the object is deallocated, as demonstrated by Chromium's strong-map erase
followed by waiting for display removal. Normal `destroy` drops that reference
inside an autorelease pool and polls the online display list for up to two seconds.
A timeout preserves the display ID for subsequent cleanup/status; it is not success.

EOF, a broken stdout pipe and SIGINT/SIGTERM/SIGHUP run the same cleanup on the main actor, after any
in-flight request unwinds. Shutdown releases synthetic focus, attempts the saved
frame restoration, then releases the display regardless of AX failure. Failed
restoration retains the original frame and is reported, rather than silently
losing recovery information. Failed `create` also releases any allocated display.
There is no persistent display owner after the engine process exits. On a crash
or SIGKILL the WindowServer client connection dies; resource removal is expected
from that process-scoped lifetime, but **exact window restoration cannot run**.
macOS may relocate windows when a display disappears. This private API has no
Apple-supported crash-cleanup contract; removal timing, abrupt-exit behavior and
absence of leaked displays still need live confirmation on the reviewer's OS.

## Reviewer run and evidence

On an authorized idle Mac, with Stage Manager already on and OpenCU's Accessibility
and Screen Recording grants already present, from this worktree run:

```sh
node scripts/probe-agent-display.mjs
```

The script uses `bin/opencu engine` for the experimental API and a separate normal
`bin/opencu` MCP connection for observation/input. It compiles a disposable AppKit
fixture, launches it through `open -g -n -a` with `--stage-managed --background`
and no redirected LaunchServices streams (no Stage Manager bypass or activation
request), and operates only that fixture. Its unique per-run bundle ID resolves
the app PID for cleanup; the `open` process is not the fixture. It never activates a
sentinel or target, switches Spaces, or changes Stage Manager settings.
Discovery accepts `lsappinfo find`'s named ASN form as well as its bare form, and
records raw discovery/PID responses in the evidence. A fixture-only live diagnosis
found the state file present after about 1.16 seconds with one visible window and
no foreground change; the earlier timeout was ASN parsing, not lost launch arguments
or Stage Manager suppressing the state file.
Before the first check, it waits for one second of stable foreground samples and
records that baseline separately from startup transitions. A baseline owned by
UserNotificationCenter or SecurityAgent stops the probe before launching the
fixture or creating a display, with an explicit system-dialog message.

| Check | Evidence / meaning |
| --- | --- |
| Stage Manager and background launch | Recorded preference; fixture launch state and foreground samples. |
| Create / move | Original and actual display arrangements, main flag, surviving window/Dock/menu frames, exact target ID, fixture-reported display ID. |
| Full screenshot | Normal MCP PNG; AX and WindowServer full-frame agreement, decoded pixel dimensions at the expected scale, known blue fixture canvas pixel. |
| Indexed click | Fixture counter increments exactly once after AXPress. |
| Coordinate click | Fresh screenshot coordinates, paired mouseDown/mouseUp with matching fixture-local coordinates. |
| Shortcut / Unicode | Cmd+A produces the exact selected range; typing produces exact Unicode text including emoji and accented text. |
| Menu | Nested menu action increments the counter; recorded action title and zero menu tracking events. |
| Restore / destroy | AX frame, fixture frame/display return to baseline; agent ID disappears; original display arrangement matches; second destroy succeeds. Other-app movement is a warning with its owner, not a failed arrangement check. |
| Foreground / exit | `lsappinfo front` scheduled every 50 ms from before compilation through cleanup; fixture exits. Actual sample times and maximum sampling gap are recorded. |

Any foreground change or sampling failure aborts further probe actions and cancels
the active MCP request. Already-dispatched input cannot be retracted. Cleanup
closes the MCP input connection before restoring geometry, then restores, destroys,
closes the owning engine and terminates the fixture. Ctrl-C takes that same path;
no input is replayed. Engine shutdown has bounded TERM/KILL escalation if EOF
cleanup stalls. Temporary fixture files are removed. JSON evidence, fixture-state
snapshots and PNGs remain in ignored `.cache/agent-display/run-*/`; `latest.json`
points to the report. The final table distinguishes PASS, FAIL and unrun checks.
Sampling can miss changes shorter than its measured interval; it is evidence,
not a universal no-focus-steal guarantee.

## Consent and unanswered live questions

Production policy is to ask the person **before every window move**. Without
consent, retain the existing Stage Manager limited mode. This probe deliberately
does not implement that UI or claim that invoking its experimental methods is
production consent handling.

Only a live run can answer whether Stage Manager leaves a moved window fully
rendered/key-capable on this display; whether arbitrary apps such as Keynote behave
like the fixture; whether the pointer can cross the normalized boundary; what
Mission Control, Spaces, screen sharing and recording expose; whether Dock/menu
placement or other windows change transiently; and whether removal remains reliable
on disconnect, crashes, lock/unlock and sleep. Passing this fixture proves its
measured operations only. It does not establish invisibility, security isolation,
or support across macOS releases.
