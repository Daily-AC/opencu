# Independent engine implementation contract

The active goal is an original OpenCU engine using macOS frameworks. No OpenAI
SDK, executable, account, signature allowlist, turn metadata or daemon is part
of the runtime. Windows is outside this implementation step.

The Swift executable speaks JSON lines on inherited stdin/stdout. Requests are
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
