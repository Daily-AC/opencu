import AppKit
import ApplicationServices
import Foundation

@MainActor
final class Engine {
    private let observer = MacObserver()
    private let input = InputController()
    private var snapshot: WindowSnapshot?

    func shutdown() { input.releaseFocus() }

    func dispatch(_ method: String, _ args: Arguments) async throws -> Any {
        if method == "doctor" { return permissions() }
        if method == "list_apps" { return observer.listApps() }
        let actions = ["click", "drag", "press_key", "type_text", "paste", "scroll", "set_value", "select_text", "perform_secondary_action"]
        guard actions.contains(method) || ["get_app_state", "activate_app"].contains(method) else {
            throw OpenCUError("METHOD_NOT_FOUND", "Unknown OpenCU operation: \(method)")
        }
        try requireAccessibility()
        let app = try await observer.resolveApp(requiredString(args, "app"), launch: method == "get_app_state" || method == "activate_app")
        input.releaseFocus(unlessTarget: app.pid)
        if method == "activate_app" {
            input.releaseFocus()
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
            let state = try await observer.observe(app, includeScreenshot: args["includeScreenshot"] as? Bool ?? false)
            snapshot = state.snapshot
            return state.json
        }
        guard let current = snapshot, current.app.pid == app.pid, current.app.id == app.id else {
            throw OpenCUError("OBSERVATION_REQUIRED", "Read this application's state before sending input. No input was sent.")
        }
        // An action may change geometry even when it ultimately reports failure.
        snapshot = WindowSnapshot(app: current.app, window: current.window, bounds: current.bounds,
                                  windowID: current.windowID, elements: current.elements,
                                  screenshotWidth: nil, screenshotHeight: nil)
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

@MainActor
func setup() {
    NSApplication.shared.setActivationPolicy(.accessory)
    let settings: [(String, String)] = [
        ("Accessibility", "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"),
        ("Screen Recording", "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"),
    ]
    let alert = NSAlert()
    alert.messageText = "Set up OpenCU"
    alert.informativeText = "OpenCU runs locally and needs no account.\n\nAccessibility: \(AXIsProcessTrusted() ? "Allowed" : "Not yet allowed")\nScreen Recording: \(CGPreflightScreenCaptureAccess() ? "Allowed" : "Not yet allowed")\n\nAllow OpenCU in System Settings, then reconnect your agent. The grants apply to OpenCU whichever agent starts it."
    alert.addButton(withTitle: "Request Permissions")
    alert.addButton(withTitle: "Accessibility Settings")
    alert.addButton(withTitle: "Screen Recording Settings")
    alert.addButton(withTitle: "Close")
    NSApplication.shared.activate(ignoringOtherApps: true)
    let response = alert.runModal()
    if response == .alertFirstButtonReturn {
        _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
        _ = CGRequestScreenCaptureAccess()
    } else if response == .alertSecondButtonReturn {
        NSWorkspace.shared.open(URL(string: settings[0].1)!)
    } else if response == .alertThirdButtonReturn {
        NSWorkspace.shared.open(URL(string: settings[1].1)!)
    }
}

@main
struct OpenCUMain {
    @MainActor
    static func main() async {
        if CommandLine.arguments.contains("--version") { print("opencu-engine 0.2.0"); return }
        if CommandLine.arguments.contains("--doctor") || CommandLine.arguments.dropFirst() == ["serve"],
           let status = runAsResponsibleProcess() { exit(status) }
        _ = NSApplication.shared
        NSApplication.shared.setActivationPolicy(.prohibited)
        if CommandLine.arguments.contains("--doctor") { emit(permissions()); return }
        if CommandLine.arguments.contains("--setup") || CommandLine.arguments.count == 1 { setup(); return }
        guard CommandLine.arguments.dropFirst() == ["serve"] else {
            FileHandle.standardError.write(Data("Usage: opencu-engine serve | --doctor | --setup | --version\n".utf8))
            return
        }
        let engine = Engine()
        let lines = AsyncStream<String> { continuation in
            Task.detached {
                while let line = readLine() { continuation.yield(line) }
                continuation.finish()
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
