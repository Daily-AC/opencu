import AppKit
import ApplicationServices
import Foundation

@MainActor
final class Engine {
    private let observer = MacObserver()
    private let input = InputController()
    private var snapshot: WindowSnapshot?
    private let focusGuard = FocusGuard()
    private let agentDisplay = AgentDisplay()

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
    func shutdown() async {
        disconnected()
        input.releaseFocus()
        observer.restoreAccessibilityModes()
        let cleanup = await agentDisplay.destroy()
        if cleanup["ok"] as? Bool == false {
            FileHandle.standardError.write(Data("Agent display cleanup errors: \(cleanup["cleanupErrors"] ?? []); removal: \(cleanup["lastRemoval"] ?? [:])\n".utf8))
        }
    }

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
        if method.hasPrefix("experimental_agent_display_") {
            if method == "experimental_agent_display_status" { return try agentDisplay.status() }
            // Any attempted geometry mutation invalidates prior indexes and
            // screenshot coordinates, including on partial failure.
            snapshot = nil
            input.releaseFocus()
            focusGuard.cancel()
            switch method {
            case "experimental_agent_display_create": return try await agentDisplay.create()
            case "experimental_agent_display_move_window":
                try requireAccessibility()
                let app = try await observer.resolveApp(requiredString(args, "app"), launch: false)
                return try await agentDisplay.moveWindow(app)
            case "experimental_agent_display_restore": return try await agentDisplay.restore()
            case "experimental_agent_display_destroy": return await agentDisplay.destroy()
            default: throw OpenCUError("METHOD_NOT_FOUND", "Unknown experimental agent display operation: \(method)")
            }
        }
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
                                  elementTraits: current.elementTraits,
                                  screenshotWidth: nil, screenshotHeight: nil)
        presence.badge(method: method, args: args, snapshot: current)
        focusGuard.protect(target: app.pid)
        let effect = try await input.perform(method: method, args: args, snapshot: current)
        observer.record(effect, pid: app.pid)
        if effect.requiresObservation { snapshot = nil }
        var result = effect.actionResult
        result["app"] = app.json
        return result
    }
}

func permissions() -> [String: Any] {
    ["engine": "opencu", "version": "0.2.0", "platform": "macos",
     "accessibility": AXIsProcessTrusted(), "screenRecording": CGPreflightScreenCaptureAccess(), "screenLocked": desktopLocked(),
     "ownPermissions": EngineResponsibility.verified, "captureContext": EngineResponsibility.json,
     "workerPID": getpid(), "responsiblePID": EngineResponsibility.responsiblePID().map { $0 as Any } ?? NSNull(),
     "launchedBy": EngineResponsibility.worker ? "LaunchServices" : "direct",
     "transport": "stdio", "requiresAccount": false, "requiresOfficialRuntime": false]
}

@discardableResult
func emit(_ value: Any) -> Bool {
    do {
        let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .fragmentsAllowed])
        try FileHandle.standardOutput.write(contentsOf: data + Data([10]))
        return true
    } catch {
        try? FileHandle.standardError.write(contentsOf: Data("OpenCU could not encode or deliver a response; closing the connection.\n".utf8))
        return false
    }
}

@main
struct OpenCUMain {
    @MainActor
    static func main() {
        // Hidden one-shot metadata mode. Must precede NSApplication creation,
        // worker launch, doctor/setup, and all permission/AX calls.
        if CommandLine.arguments.dropFirst() == ["--online-displays"] {
            do {
                let data = try OnlineDisplays.encode(OnlineDisplays.current())
                try FileHandle.standardOutput.write(contentsOf: data + Data([10]))
            } catch {
                emit(["error": error.localizedDescription])
                exit(1)
            }
            return
        }
        if CommandLine.arguments.contains("--version") { print("opencu-engine 0.2.0"); return }
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments == ["serve"] { exit(WorkerLauncher.relay(mode: "serve")) }
        if arguments == ["--doctor"] { exit(WorkerLauncher.relay(mode: "doctor")) }
        let worker = arguments.count == 3 && arguments[0] == "worker" && ["serve", "doctor"].contains(arguments[1])
        if getenv("OPENCU_WORKER_TOKEN") != nil && !worker {
            FileHandle.standardError.write(Data("OpenCU worker: invalid launch context.\n".utf8))
            exit(1)
        }
        if worker {
            do { try WorkerLauncher.attach(mode: arguments[1], path: arguments[2]) }
            catch {
                FileHandle.standardError.write(Data("OpenCU worker: \(error).\n".utf8))
                exit(1)
            }
        }
        // Keep the activity alive through serve's disconnect/shutdown cleanup.
        // Avoid App Nap without inhibiting the person's display or system sleep.
        let activity = worker ? ProcessInfo.processInfo.beginActivity(
            options: .userInitiatedAllowingIdleSystemSleep, reason: "OpenCU client connection") : nil
        defer { if let activity { ProcessInfo.processInfo.endActivity(activity) } }
        if worker && arguments[1] == "doctor" { emit(permissions()); return }
        _ = NSApplication.shared
        NSApplication.shared.setActivationPolicy(.accessory)
        if arguments == ["--setup"] {
            let setup = PermissionSetup()
            setup.didClose = { NSApp.stop(nil); wakeApplicationLoop() }
            setup.show(activate: true)
            withExtendedLifetime(setup) { NSApp.run() }
            return
        }
        guard worker && arguments[1] == "serve" else {
            FileHandle.standardError.write(Data("Usage: opencu-engine serve | --doctor | --setup | --version\n".utf8))
            return
        }
        let engine = Engine()
        Task { await serve(engine); NSApp.stop(nil); wakeApplicationLoop() }
        NSApp.run()
    }

    @MainActor private static func serve(_ engine: Engine) async {
        // Run cleanup on the main actor, never inside a POSIX signal handler.
        // Signals stop accepting queued work; an in-flight action unwinds first.
        signal(SIGPIPE, SIG_IGN)
        var stopping = false
        var finishInput: (() -> Void)?
        var signalSources: [DispatchSourceSignal] = []
        for number in [SIGINT, SIGTERM, SIGHUP] {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler { stopping = true; finishInput?() }
            source.resume()
            signalSources.append(source)
        }
        let lines = AsyncStream<String> { continuation in
            finishInput = { continuation.finish() }
            Task.detached {
                while let line = readLine() { continuation.yield(line) }
                continuation.finish()
                await MainActor.run { engine.disconnected() }
            }
        }
        for await line in lines {
            if stopping { break }
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
                if !emit(["id": id, "result": result]) { break }
            } catch {
                let failure = error as? OpenCUError ?? OpenCUError("ENGINE_ERROR", error.localizedDescription)
                var errorJSON: Arguments = ["code": failure.code, "message": failure.message]
                if let details = failure.details { errorJSON["data"] = details }
                if !emit(["id": id, "error": errorJSON]) { break }
            }
        }
        await engine.shutdown()
        for source in signalSources { source.cancel() }
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
