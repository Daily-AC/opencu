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
    private var desktopOwner: AgentDesktopController?
    private var desktop: AgentDesktopController { desktopOwner! }
    private var ownsDesktop: Bool { desktopOwner?.ownsDesktop == true }
    private var requestQueue = AgentDesktopRequestQueue()
    private var activeRequestID: String?
    private var activeInterruption: OpenCUError?
    private var desktopCleanup: Task<Void, Never>?

    private let presence = PresenceController()
    private var activeTask: Task<Any, Error>?
    private var activeSensitive = false

    init() {
        input.pointerDelivered = { [weak self] point, snapshot, click in
            self?.presence.pointer(point, snapshot: snapshot, click: click)
        }
        input.requireInputAllowed = { [weak self] in
            guard let self else { throw CancellationError() }
            try self.requireAllowed("click")
            if self.ownsDesktop { try self.desktop.requireContinuation() }
        }
        input.requirePointerAllowed = { [weak self] _ in
            guard let self, self.ownsDesktop else { return }
            try self.desktop.requireContinuation()
            guard let snapshot = self.snapshot, let window = snapshot.window,
                  let frame = axRect(window), self.agentDisplay.frame?.contains(frame) == true else {
                throw OpenCUError("AGENT_DESKTOP_CONSENT_REQUIRED", "The target left the agent display. No pointer input was sent.")
            }
            guard AgentDisplayGeometry.close(frame, snapshot.bounds) else {
                throw OpenCUError("OBSERVATION_REQUIRED", "The window moved or resized. Read fresh state before pointer input.")
            }
        }
        observer.requireCaptureAllowed = { [weak self] in
            guard let self else { throw CancellationError() }
            try self.requireAllowed("get_app_state", screenshot: true)
            if self.ownsDesktop { try self.desktop.state.requireRunning() }
        }
        presence.onPersonInteraction = { [weak self] in self?.focusGuard.cancel() }
        presence.onStop = { [weak self] in
            guard let self else { return }
            if self.activeSensitive { self.activeTask?.cancel() }
            self.input.releaseFocus()
            if self.desktopOwner != nil {
                self.desktop.latchPersonStop()
                self.scheduleDesktopCleanup(keepFailure: true)
            }
        }
    }
    private func initializeDesktop() {
        guard desktopOwner == nil else { return }
        desktopOwner = AgentDesktopController(display: agentDisplay)
        desktop.onInvalidate = { [weak self] in self?.snapshot = nil; self?.input.releaseFocus(); self?.focusGuard.cancel() }
        desktop.onPersonStop = { [weak self] in self?.presence.stop() }
        desktop.onFailure = { [weak self] in self?.scheduleDesktopCleanup(keepFailure: true) }
        desktop.onInputPause = { [weak self] in
            self?.activeInterruption = self?.desktopOwner?.inputPause
            self?.activeTask?.cancel(); self?.input.releaseFocus(); self?.focusGuard.cancel()
        }
    }
    func enqueue(_ id: String) throws { try requestQueue.enqueue(id) }
    private func requireAllowed(_ method: String, screenshot: Bool = false) throws {
        if desktopOwner?.state.stoppedByPerson == true { throw AgentDesktopState.stopError }
        try presence.state.requireAllowed(method, screenshot: screenshot)
    }
    private func scheduleDesktopCleanup(keepFailure: Bool) {
        activeTask?.cancel(); desktop.cancelConsent()
        guard desktopCleanup == nil else { return }
        let operation = activeTask
        desktopCleanup = Task { [weak self] in
            _ = await operation?.result
            guard let self else { return }
            _ = await self.desktop.stop(keepFailure: keepFailure)
            self.presence.desktopVisible = false
            self.desktopCleanup = nil
        }
    }
    func control(_ method: String, _ args: Arguments) async throws -> Any {
        if method == "agent_desktop_cancel" {
            if let id = args["requestID"] as? String {
                requestQueue.cancel(id)
                if id == activeRequestID { activeTask?.cancel(); desktopOwner?.cancelConsent() }
            }
            return ["ok": true]
        }
        guard let desktop = desktopOwner else {
            return ["state": "inactive", "stoppedByPerson": presence.state.stopped, "parentLocked": desktopLocked(),
                    "ready": false, "workerPID": getpid(), "cleanup": ["ok": true, "cleanupErrors": []]]
        }
        if method == "agent_desktop_status" { return desktop.status() }
        desktop.requestStop(); activeTask?.cancel()
        _ = await activeTask?.result
        if let desktopCleanup { await desktopCleanup.value }
        let result = await desktop.stop()
        presence.desktopVisible = false
        return result
    }
    func disconnected() {
        presence.disconnect()
        if activeSensitive || ownsDesktop { activeTask?.cancel() }
        desktopOwner?.cancelConsent()
        focusGuard.cancel()
    }
    func shutdown() async {
        disconnected()
        input.releaseFocus()
        observer.restoreAccessibilityModes()
        if let desktopCleanup { await desktopCleanup.value }
        let cleanup: Arguments
        if ownsDesktop {
            let status = await desktop.stop()
            cleanup = status["cleanup"] as? Arguments ?? ["ok": false]
        } else { cleanup = ["ok": true] }
        if cleanup["ok"] as? Bool == false {
            FileHandle.standardError.write(Data("Agent display cleanup errors: \(cleanup["cleanupErrors"] ?? []); removal: \(cleanup["lastRemoval"] ?? [:])\n".utf8))
        }
    }

    func dispatch(_ method: String, _ args: Arguments, requestID: String) async throws -> Any {
        try requestQueue.begin(requestID)
        activeRequestID = requestID
        activeInterruption = nil
        defer { activeRequestID = nil; activeInterruption = nil }
        if desktopOwner?.state.stoppedByPerson == true { throw AgentDesktopState.stopError }
        let screenshot = args["includeScreenshot"] as? Bool ?? false
        let appCall = PresenceState.inputMethods.contains(method) || method == "get_app_state"
        defer { if appCall { presence.finishedCall() } }
        if presence.state.connected, let query = args["app"] as? String, appCall {
            presence.beginCall(query: query)
        }
        try requireAllowed(method, screenshot: screenshot)
        if args["scope"] != nil {
            throw OpenCUError("INVALID_ARGUMENT", "scope is Windows-only for now.")
        }
        activeSensitive = ownsDesktop || method == "agent_desktop_start" || PresenceState.requiresPermissionToContinue(method, screenshot: screenshot)
        let task = Task { try await self.perform(method, args) }
        activeTask = task
        defer { activeTask = nil; activeSensitive = false }
        do {
            let value = try await task.value
            try requireAllowed(method, screenshot: screenshot)
            return value
        } catch {
            try requireAllowed(method, screenshot: screenshot)
            if error is CancellationError, let pause = activeInterruption { throw pause }
            let failure = error as? OpenCUError ?? OpenCUError("ENGINE_ERROR", error.localizedDescription)
            if ownsDesktop || method == "agent_desktop_start" { throw failure }
            throw presence.permissionFailure(failure)
        }
    }

    private func perform(_ method: String, _ args: Arguments) async throws -> Any {
        try Task.checkCancellation()
        if method == "agent_desktop_start" {
            initializeDesktop()
            presence.desktopVisible = true
            do { return try await desktop.start() }
            catch { presence.desktopVisible = false; throw error }
        }
        if ownsDesktop {
            try desktop.state.requireRunning()
            if method == "activate_app" { throw OpenCUError("BACKGROUND_INPUT_UNSUPPORTED", "Agent desktop is watch-only and uses background input. activate_app would take the person's foreground.") }
        }
        if method == "doctor" { return permissions() }
        if method == "list_apps" { return observer.listApps() }
        if method == "wait" {
            let ms = try waitMilliseconds(args)
            guard presence.state.connected else { throw OpenCUError("ENGINE_DISCONNECTED", "The client disconnected. No input was sent.") }
            // Time can invalidate pixels while retaining the observed element objects.
            if let current = snapshot {
                snapshot = WindowSnapshot(app: current.app, window: current.window, bounds: current.bounds,
                    windowID: current.windowID, elements: current.elements, elementPaths: current.elementPaths,
                    elementTraits: current.elementTraits, screenshotWidth: nil, screenshotHeight: nil)
            }
            try await Task.sleep(nanoseconds: ms * 1_000_000)
            return ["ok": true]
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
            let admitted = ownsDesktop ? try await desktop.prepareObservation(app, explicit: args["desktopExplicitObservation"] as? Bool == true) : true
            observer.requireWindowAllowed = ownsDesktop && admitted ? { [weak self] candidate in
                try self?.agentDisplay.requireAdmitted(candidate)
            } : nil
            defer { observer.requireWindowAllowed = nil }
            let observedGeneration = ownsDesktop ? desktop.state.generation : nil
            let state = try await observer.observe(app, includeScreenshot: admitted && (args["includeScreenshot"] as? Bool ?? false), reduced: ownsDesktop && !admitted)
            if let observedGeneration { try desktop.state.requireGeneration(observedGeneration) }
            presence.observed(state.snapshot)
            var result = state.json
            if ownsDesktop {
                if admitted { try desktop.observed(state.snapshot, generation: observedGeneration!) }
                else {
                    result["text"] = state.text + "\nAgent desktop: reduced, read-only. Reason: \(desktop.observationConsent). No screenshot or input is allowed. Declined/expired windows stay reduced until tool stop and a new start."
                }
                result["agentDesktop"] = ["windowState": admitted ? "admitted" : "reduced", "consent": desktop.observationConsent, "generation": desktop.state.generation]
            }
            snapshot = admitted ? state.snapshot : nil
            return result
        }
        if ownsDesktop { try desktop.requireInput(app, snapshot: snapshot) }
        defer { if ownsDesktop { desktop.endInput() } }
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
    ["engine": "opencu", "version": "0.4.1", "platform": "macos",
     "accessibility": AXIsProcessTrusted(), "screenRecording": CGPreflightScreenCaptureAccess(), "screenLocked": desktopLocked(),
     "ownPermissions": EngineResponsibility.verified, "captureContext": EngineResponsibility.json,
     "workerPID": getpid(), "responsiblePID": EngineResponsibility.responsiblePID().map { $0 as Any } ?? NSNull(),
     "launchedBy": EngineResponsibility.worker ? "launchd" : "direct",
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
        if CommandLine.arguments.contains("--version") { print("opencu-engine 0.4.1"); return }
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
            source.setEventHandler { stopping = true; engine.disconnected(); finishInput?() }
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
        var tail: Task<Void, Never>?
        var controls: [UUID: Task<Void, Never>] = [:]
        func respond(_ request: Arguments, control: Bool) async {
            let id = request["id"] ?? NSNull()
            do {
                guard let method = request["method"] as? String, let args = request["params"] as? Arguments else {
                    throw OpenCUError("INVALID_REQUEST", "Expected id, method and params.")
                }
                let result: Any
                if control { result = try await engine.control(method, args) }
                else { result = try await engine.dispatch(method, args, requestID: String(describing: id)) }
                if !emit(["id": id, "result": result]) { engine.disconnected(); stopping = true; finishInput?() }
            } catch {
                let failure = error as? OpenCUError ?? OpenCUError("ENGINE_ERROR", error.localizedDescription)
                var errorJSON: Arguments = ["code": failure.code, "message": failure.message]
                if let details = failure.details { errorJSON["data"] = details }
                if !emit(["id": id, "error": errorJSON]) { engine.disconnected(); stopping = true; finishInput?() }
            }
        }
        for await line in lines {
            if stopping { break }
            guard line.utf8.count <= 4_194_304, let data = line.data(using: .utf8),
                  let request = try? JSONSerialization.jsonObject(with: data) as? Arguments,
                  request["id"] != nil else {
                _ = emit(["id": NSNull(), "error": ["code": "INVALID_REQUEST", "message": "Expected a JSON object with id, method and params."]])
                continue
            }
            let method = request["method"] as? String ?? ""
            if ["agent_desktop_status", "agent_desktop_stop", "agent_desktop_cancel"].contains(method) {
                let key = UUID()
                controls[key] = Task { await respond(request, control: true); controls.removeValue(forKey: key) }
            } else {
                do { try engine.enqueue(String(describing: request["id"]!)) }
                catch {
                    _ = emit(["id": request["id"]!, "error": ["code": "INVALID_REQUEST", "message": error.localizedDescription]])
                    continue
                }
                let previous = tail
                tail = Task {
                    await previous?.value
                    if !stopping { await respond(request, control: false) }
                }
            }
        }
        stopping = true
        engine.disconnected()
        await tail?.value
        for task in Array(controls.values) { await task.value }
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
