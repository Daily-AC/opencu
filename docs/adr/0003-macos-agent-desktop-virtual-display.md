# 0003: macOS agent desktop uses a consented virtual display

Date: 2026-10-20. Status: implemented architecture; owner-run GUI acceptance pending.

## Decision and evidence

Expose the existing action-only `agent_desktop` MCP surface on macOS. A single
independently responsible launchd worker owns the virtual display, local watch-only
preview, app observation/input, consent and restoration. Use the existing checked
CGVirtualDisplay SPI and corner placement. One kernel lock permits one owner per
GUI session. The earlier probe's runs 7 and 9 established fixture background
operations and per-window capture on this display; they did not verify this new
product path. External monitors remain untested.

Start creates the host/display automatically. An SCStream captures only the owned
display, with no audio, a small queue and roughly 10 fps, downsampled locally with
no disk recording. Existing independently captured window screenshots remain in
MacObserver. Both paths require CaptureSafety's verified worker responsibility and
existing Screen Recording grant. Do not add a sharing picker, legacy capture API,
entitlement, account, helper service or macOS 15.2 requirement. The macOS 15+
periodic confirmation remains a documented limitation: it can take foreground
about monthly per executable path on the owner's Mac; input then stops.

A virtual display shares the person's GUI session, foreground, clipboard, apps
and files. The preview never forwards input. Opaque/foreground-only apps retain
BACKGROUND_INPUT_UNSUPPORTED; activate_app is refused in desktop mode. Apps may
launch on the person's display before a consented move. This does not provide the
Windows child-session isolation or click-to-interact behavior.

## Consent and lifecycle

Only an explicit get_app_state for a window outside the display can request a
move. The nonactivating host shows one card, Move once and Keep here, with a
60-second monotonic deadline. Approval binds the exact process lifetime, AX object,
WindowServer ID and proposed original geometry. Revalidate before writes and keep
the original before the first write. Denial/expiry remains reduced for that
lifetime; input returns AGENT_DESKTOP_CONSENT_REQUIRED. No re-offer row, blanket
consent, MCP consent parameter or prompts from waits/internal/final reads.

Move once includes return of that exact window on stop/close/EOF. A multi-window
ledger preserves distinct originals. Manual return revokes admission and
restoration; never pull that window back or substitute another window. Normal
cleanup restores frames/sizes and leaves apps/unsaved content running. Bound
restoration, release even on AX failure, and confirm removal using a fresh process
for each poll. Cleanup failures retain recovery evidence and block normal routing.
Crashes rely on OS resource lifetime; exact restoration cannot run after SIGKILL.

Close, native Stop and the persistent menu-bar Stop latch STOPPED_BY_PERSON for
the MCP connection, including when idle. Native events notify Node immediately.
Status/stop/cancellation bypass a pending consent through a narrow control lane;
ordinary app and geometry mutations remain serialized. Stop/EOF cancel pending
consent. No stream/worker reconnect or automatic input replay. Tool stop alone
permits a later explicit start after confirmed cleanup; a person stop never does.

macOS pauses while locked and keeps ownership for cleanup. Status exposes
parentLocked; sensitive work returns SCREEN_LOCKED and unlock needs fresh state.
Display layout changes fail with AGENT_DISPLAY_LAYOUT_CHANGED and clean up; no
special extended-monitor recovery is added. No Escape handler, recovery journal,
daemon, new public parameters or changes to existing tool annotations.

## Validation boundary

Node tests use fake native processes and routing adapters. Swift tests exercise
production pure consent, stop and restoration policy without accessing the screen.
The opt-in `scripts/verify-agent-desktop-mac.mjs --owner-present` uses disposable
fixtures for startup/preview, consent, background actions, manual return, stop,
close-latching and EOF cleanup. It must be run by an owner on an authorized idle
Mac; build/unit-test success is not a claim of GUI acceptance.
