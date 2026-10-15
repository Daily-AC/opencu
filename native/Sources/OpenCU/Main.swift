import AppKit
import ApplicationServices
import Foundation

@MainActor
final class Engine {
    private let observer = MacObserver()
    private let input = InputController()
    private var snapshot: WindowSnapshot?
    private let focusGuard = FocusGuard()

    private let presence = PresenceController()
    private var activeTask: Task<Any, Error>?
    private var activeSensitive = false

    init() {
        input.pointerDelivered = { [weak self] point, snapshot, click in
            self?.presence.pointer(point, snapshot: snapshot, click: click)
        }
        input.requireInputAllowed = { [weak self] in try self?.presence.state.requireAllowed("click") }
        observer.requireCaptureAllowed = { [weak self] in try self?.presence.state.requireAllowed("get_app_state", screenshot: true) }
        presence.onPersonInteraction = { [weak self] in self?.focusGuard.cancel() }
        presence.onStop = { [weak self] in
            guard let self else { return }
            if self.activeSensitive { self.activeTask?.cancel() }
            self.input.releaseFocus()
        }
    }
    func disconnected() {
        presence.disconnect()
        if activeSensitive { activeTask?.cancel() }
        focusGuard.cancel()
    }
    func shutdown() { disconnected(); input.releaseFocus(); observer.restoreAccessibilityModes() }

    func dispatch(_ method: String, _ args: Arguments) async throws -> Any {
        let screenshot = args["includeScreenshot"] as? Bool ?? false
        let appCall = PresenceState.inputMethods.contains(method) || method == "get_app_state"
        defer { if appCall { presence.finishedCall() } }
        if presence.state.connected, let query = args["app"] as? String, appCall {
            presence.beginCall(query: query)
        }
        try presence.state.requireAllowed(method, screenshot: screenshot)
        activeSensitive = PresenceState.requiresPermissionToContinue(method, screenshot: screenshot)
        let task = Task { try await self.perform(method, args) }
        activeTask = task
        defer { activeTask = nil; activeSensitive = false }
        do {
            let value = try await task.value
            try presence.state.requireAllowed(method, screenshot: screenshot)
            return value
        } catch {
            try presence.state.requireAllowed(method, screenshot: screenshot)
            let failure = error as? OpenCUError ?? OpenCUError("ENGINE_ERROR", error.localizedDescription)
            throw presence.permissionFailure(failure)
        }
    }

    private func perform(_ method: String, _ args: Arguments) async throws -> Any {
        if method == "doctor" { return permissions() }
        if method == "list_apps" { return observer.listApps() }
        let actions = ["click", "drag", "press_key", "type_text", "paste", "scroll", "set_value", "select_text", "perform_secondary_action"]
        guard actions.contains(method) || ["get_app_state", "activate_app"].contains(method) else {
            throw OpenCUError("METHOD_NOT_FOUND", "Unknown OpenCU operation: \(method)")
        }
        guard presence.state.connected else { throw OpenCUError("ENGINE_DISCONNECTED", "The client disconnected. No input was sent.") }
        let query = try requiredString(args, "app")
        try requireAccessibility()
        let app = try await observer.resolveApp(query, launch: !presence.state.stopped && (method == "get_app_state" || method == "activate_app"))
        try Task.checkCancellation()
        guard app.pid != getpid(), app.id != "dev.opencu.engine" else {
            throw OpenCUError("INVALID_TARGET", "OpenCU's own interface is reserved for the person and cannot be targeted.")
        }
        // Use a stable identity after resolution, so aliases do not carry a
        // cursor across applications. Every observed window is checked as well.
        presence.called(target: String(app.pid), name: app.name)
        input.releaseFocus(unlessTarget: app.pid)
        if method == "activate_app" {
            if let current = snapshot, current.app.pid == app.pid { presence.badge(method: method, args: args, snapshot: current) }
            input.releaseFocus()
            focusGuard.cancel()
            guard app.application.activate(options: []) else {
                throw OpenCUError("ACTIVATION_FAILED", "The application could not be activated. No input was sent.")
            }
            for _ in 0..<25 {
                if NSWorkspace.shared.frontmostApplication?.processIdentifier == app.pid { break }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == app.pid else {
                throw OpenCUError("ACTIVATION_FAILED", "The application did not become frontmost. No input was sent.")
            }
            // Stage Manager animates the rendered window after focus changes.
            try await Task.sleep(nanoseconds: 250_000_000)
        }
        if method == "get_app_state" || method == "activate_app" {
            // A failed read must not leave a previous window usable for input.
            snapshot = nil
            observer.willObserveWindow = { [weak self] window in
                self?.presence.badge(method: method, args: args, snapshot: window)
            }
            defer { observer.willObserveWindow = nil }
            let state = try await observer.observe(app, includeScreenshot: args["includeScreenshot"] as? Bool ?? false)
            presence.observed(state.snapshot)
            snapshot = state.snapshot
            return state.json
        }
        guard let current = snapshot, current.app.pid == app.pid, current.app.id == app.id else {
            throw OpenCUError("OBSERVATION_REQUIRED", "Read this application's state before sending input. No input was sent.")
        }
        // An action may change geometry even when it ultimately reports failure.
        snapshot = WindowSnapshot(app: current.app, window: current.window, bounds: current.bounds,
                                  windowID: current.windowID, elements: current.elements, elementPaths: current.elementPaths,
                                  screenshotWidth: nil, screenshotHeight: nil)
        presence.badge(method: method, args: args, snapshot: current)
        focusGuard.protect(target: app.pid)
        observer.record(try await input.perform(method: method, args: args, snapshot: current), pid: app.pid)
        return ["ok": true, "app": app.json]
    }
}

private var ownsPermissions = false
private var disclaimedChild: pid_t = 0

/// macOS attributes privacy grants to the responsible process, normally the app
/// that started the MCP client. Respawn once with responsibility disclaimed, an
/// OS-exported SPI also used by browsers and debuggers, so the user's OpenCU grants
/// apply whichever client launched it. Returns nil when this process should run
/// the engine itself; otherwise the child's exit status.
func runAsResponsibleProcess() -> Int32? {
    let marker = "OPENCU_RESPONSIBLE_PROCESS"
    if getenv(marker) != nil {
        unsetenv(marker)
        ownsPermissions = true
        return nil
    }
    typealias Disclaim = @convention(c) (UnsafeMutablePointer<posix_spawnattr_t?>, Int32) -> Int32
    guard let executable = Bundle.main.executablePath,
          let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_spawnattrs_setdisclaim") else { return nil }
    var attributes: posix_spawnattr_t?
    guard posix_spawnattr_init(&attributes) == 0 else { return nil }
    defer { posix_spawnattr_destroy(&attributes) }
    guard unsafeBitCast(symbol, to: Disclaim.self)(&attributes, 1) == 0 else { return nil }
    setenv(marker, "1", 1)
    let spawned = posix_spawn(&disclaimedChild, executable, nil, &attributes, CommandLine.unsafeArgv, environ)
    unsetenv(marker)
    guard spawned == 0 else { return nil }
    // The child shares stdin/stdout; this process only relays termination.
    for signalNumber in [SIGTERM, SIGINT, SIGHUP] {
        signal(signalNumber) { received in if disclaimedChild > 0 { kill(disclaimedChild, received) } }
    }
    var status: Int32 = 0
    while waitpid(disclaimedChild, &status, 0) == -1 && errno == EINTR {}
    return status & 0x7f == 0 ? (status >> 8) & 0xff : 128 + (status & 0x7f)
}

func permissions() -> [String: Any] {
    ["engine": "opencu", "version": "0.2.0", "platform": "macos",
     "accessibility": AXIsProcessTrusted(), "screenRecording": CGPreflightScreenCaptureAccess(), "screenLocked": desktopLocked(),
     "ownPermissions": ownsPermissions,
     "transport": "stdio", "requiresAccount": false, "requiresOfficialRuntime": false]
}

func emit(_ value: Any) {
    do {
        let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .fragmentsAllowed])
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data([10]))
    } catch {
        FileHandle.standardError.write(Data("OpenCU could not encode a response.\n".utf8))
    }
}

@main
struct OpenCUMain {
    @MainActor
    static func main() {
        if CommandLine.arguments.contains("--version") { print("opencu-engine 0.2.0"); return }
        // `opencu setup` already launches through LaunchServices with its own
        // responsibility. Only stdio/doctor need the disclaimed respawn.
        if CommandLine.arguments.contains("--doctor") || CommandLine.arguments.dropFirst() == ["serve"],
           let status = runAsResponsibleProcess() { exit(status) }
        _ = NSApplication.shared
        NSApplication.shared.setActivationPolicy(.accessory)
        if CommandLine.arguments.contains("--doctor") { emit(permissions()); return }
        if CommandLine.arguments.contains("--setup") || CommandLine.arguments.count == 1 {
            let setup = PermissionSetup()
            setup.didClose = { NSApp.stop(nil); wakeApplicationLoop() }
            setup.show(activate: true)
            withExtendedLifetime(setup) { NSApp.run() }
            return
        }
        guard CommandLine.arguments.dropFirst() == ["serve"] else {
            FileHandle.standardError.write(Data("Usage: opencu-engine serve | --doctor | --setup | --version\n".utf8))
            return
        }
        let engine = Engine()
        Task { await serve(engine); NSApp.stop(nil); wakeApplicationLoop() }
        NSApp.run()
    }

    @MainActor private static func serve(_ engine: Engine) async {
        let lines = AsyncStream<String> { continuation in
            Task.detached {
                while let line = readLine() { continuation.yield(line) }
                continuation.finish()
                await MainActor.run { engine.disconnected() }
            }
        }
        for await line in lines {
            var id: Any = NSNull()
            do {
                guard line.utf8.count <= 4_194_304,
                      let data = line.data(using: .utf8),
                      let request = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let requestID = request["id"], let method = request["method"] as? String,
                      let args = request["params"] as? Arguments else {
                    throw OpenCUError("INVALID_REQUEST", "Expected a JSON object with id, method and params.")
                }
                id = requestID
                let result = try await engine.dispatch(method, args)
                emit(["id": id, "result": result])
            } catch {
                let failure = error as? OpenCUError ?? OpenCUError("ENGINE_ERROR", error.localizedDescription)
                emit(["id": id, "error": ["code": failure.code, "message": failure.message]])
            }
        }
        engine.shutdown()
    }
}

/// NSApplication.stop only takes effect after the next event. This application-
/// local event wakes an idle run loop without posting any device input.
@MainActor
private func wakeApplicationLoop() {
    if let event = NSEvent.otherEvent(with: .applicationDefined, location: .zero, modifierFlags: [],
                                     timestamp: 0, windowNumber: 0, context: nil, subtype: 0, data1: 0, data2: 0) {
        NSApp.postEvent(event, atStart: false)
    }
}
