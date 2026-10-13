# Independent engine implementation contract

OpenCU provides original native engines using macOS frameworks and Windows APIs.
No OpenAI SDK, executable, account, signature allowlist, turn metadata or daemon is part
of the runtime. The [Windows contract](windows-engine-contract.md) records phase-1
behavior and its pending real-desktop acceptance.

Each native executable speaks JSON lines on inherited stdin/stdout. Requests are
`{id, method, params}`; responses are `{id, result}` or
`{id, error: {code, message}}`. Diagnostics go to stderr. One request runs at a
time. There is no network listener and no caller-brand identity check.

`Types.swift` owns common error, target app, window snapshot, menu effect, AX
helpers and observation types. `MacObserver` owns `listApps() -> [[String: Any]]`,
`resolveApp(_:launch:) async throws -> TargetApp`,
`observe(_:includeScreenshot:) async throws -> Observation` and
`record(_:pid:)` for menus the caller opened. `InputController` owns
`perform(method:args:snapshot:) async throws -> MenuEffect`. Both classes are
MainActor isolated. The root dispatcher owns the latest observation and routes calls.

Observation JSON has `text`, `app: {id, displayName, pid}`, and optional
`screenshot: {data, mimeType, width, height}`. Screenshot data is inline base64.
Coordinates are pixels in the captured window, mapped to the observed bounds.
Element indexes belong only to the latest observed application/window.

macOS Accessibility and Screen Recording permissions remain required. Setup
requests those through the standard OS flow; it never edits permission databases.
MCP caller approvals remain the caller's responsibility. Local invocation is not
restricted to Codex or any other agent. No proprietary lock-screen unlock path
is carried over.

Pointer routing uses the system-exported CGEventSetWindowLocation SPI after
public NSEvent/CGEvent creation. Actual received events showed that public
creation alone left the window-relative point at an invalid sentinel. Resolve
the system symbol locally, fail clearly if unavailable, and retain target-PID
routing and all normal OS permissions. Do not add a global input fallback.

## Direct-host safety contract

An engine can be spawned by any host over inherited stdio; the MCP server is an
optional adapter. The engine must enforce observation/window identity, finite
in-image coordinates, and latest screenshot geometry without relying on Node.
A state/action attempt consumes the prior coordinate grant, even on failure;
only successful capture renews it. Inventory/doctor calls do not consume it.
Text-only observations cannot renew screenshot coordinates. Hosts must never
retry input automatically and must inspect state after a partial failure.

Windows phase 1 enforces this in the engine, plus PERSON_ACTIVE interruption,
foreground checks, token-integrity checks, and interactive-session/secure-desktop
refusals. Error code names are stable and documented in the Windows note.

macOS already checks captured dimensions, exact window identity/current bounds,
lock state and AX permissions in its engine, and consumes screenshots before
input execution. Known parity gaps remain: app resolution/permission failures
can precede native screenshot invalidation, and real human activity does not yet
abort every input method with PERSON_ACTIVE (the focus guard only stops its own
foreground restoration). Node already invalidates its coordinate state earlier.
The macOS engine is unchanged in this phase; direct hosts must not interpret this
note as evidence that those parity gaps have been fixed or accepted.
