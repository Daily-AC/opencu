import AppKit
import Foundation
import Darwin

/// LaunchServices owns the worker's job, responsibility and resource coalition.
/// The calling process never creates NSApplication or any engine/presence state.
@MainActor
enum WorkerLauncher {
    static func relay(mode: String) -> Int32 {
        WorkerTransport.installSignals()
        var application: NSRunningApplication?
        do {
            let listener = try WorkerTransport.Listener()
            var random = [UInt8](repeating: 0, count: 32)
            random.withUnsafeMutableBytes { arc4random_buf($0.baseAddress!, $0.count) }
            let token = random.map { String(format: "%02x", $0) }.joined()
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.createsNewApplicationInstance = true
            configuration.activates = false
            configuration.addsToRecentItems = false
            configuration.promptsUserIfNeeded = false
            configuration.arguments = ["worker", mode, listener.path]
            var environment = ["OPENCU_WORKER_TOKEN": token]
            for key in ["HOME", "TMPDIR", "PATH", "LANG"] {
                if let value = ProcessInfo.processInfo.environment[key] { environment[key] = value }
            }
            configuration.environment = environment
            var completed = false
            var launchError: Error?
            NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { app, error in
                application = app
                launchError = error
                completed = true
            }
            let deadline = WorkerTransport.now + 20
            while !completed && WorkerTransport.now < deadline && WorkerTransport.interrupted == 0 {
                RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))
            }
            guard completed, let worker = application, launchError == nil else {
                throw WorkerTransport.Failure(WorkerTransport.interrupted != 0 ? "worker launch interrupted" :
                    completed ? "LaunchServices could not launch OpenCU worker" : "LaunchServices worker launch timed out")
            }
            let channels = try listener.acceptChannels(token: token, workerPID: worker.processIdentifier, doctor: mode == "doctor")
            defer { for fd in channels.values { close(fd) } }
            return try WorkerTransport.relay(stdio: channels["stdio"]!, stderrSocket: channels["stderr"])
        } catch {
            // Failed starts must not leave an unconnected app instance behind.
            application?.terminate()
            let line = "OpenCU relay: \(error).\n"
            line.withCString { _ = Darwin.write(STDERR_FILENO, $0, strlen($0)) }
            return WorkerTransport.interrupted == 0 ? 1 : 128 + WorkerTransport.interrupted
        }
    }

    static func attach(mode: String, path: String) throws {
        let token = ProcessInfo.processInfo.environment["OPENCU_WORKER_TOKEN"]
        unsetenv("OPENCU_WORKER_TOKEN")
        guard let token, token.utf8.count == 64,
              token.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw WorkerTransport.Failure("worker requires a relay token")
        }
        signal(SIGPIPE, SIG_IGN)
        let stdio = try WorkerTransport.connect(path: path, token: token, channel: "stdio")
        defer { close(stdio) }
        let errors = mode == "serve" ? try WorkerTransport.connect(path: path, token: token, channel: "stderr") : nil
        defer { if let errors { close(errors) } }
        guard dup2(stdio, STDIN_FILENO) >= 0, dup2(stdio, STDOUT_FILENO) >= 0 else {
            throw WorkerTransport.Failure("cannot attach worker stdio")
        }
        if let errors, dup2(errors, STDERR_FILENO) < 0 { throw WorkerTransport.Failure("cannot attach worker stderr") }
        // LaunchServices does not complete openApplication until the app has
        // checked in. Do this only in the worker, before waiting for the relay
        // to receive our NSRunningApplication and authenticate the sockets.
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        NSApp.finishLaunching()
        try WorkerTransport.awaitAcknowledgement(stdio)
        if let errors { try WorkerTransport.awaitAcknowledgement(errors) }
        EngineResponsibility.worker = true
    }
}
