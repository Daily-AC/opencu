import AppKit
import Foundation
import Darwin

/// launchd owns the worker: a per-connection Interactive job in the person's GUI
/// domain gives it its own responsibility, resource coalition and scheduling
/// class. LaunchServices was not used: an app it launches holds activation rights
/// that turned OpenCU's background focus on system Open/Save panels into real
/// activation. The calling process never creates NSApplication or engine state.
@MainActor
enum WorkerLauncher {
    static func relay(mode: String) -> Int32 {
        WorkerTransport.installSignals()
        var job: WorkerJob?
        do {
            guard let executable = Bundle.main.executablePath else { throw WorkerTransport.Failure("cannot locate the OpenCU executable") }
            let listener = try WorkerTransport.Listener()
            var random = [UInt8](repeating: 0, count: 32)
            random.withUnsafeMutableBytes { arc4random_buf($0.baseAddress!, $0.count) }
            let token = random.map { String(format: "%02x", $0) }.joined()
            var environment = ["OPENCU_WORKER_TOKEN": token]
            for key in ["HOME", "TMPDIR", "PATH", "LANG"] + AgentConfig.forwardedEnvironmentKeys {
                if let value = ProcessInfo.processInfo.environment[key], !value.isEmpty { environment[key] = value }
            }
            do {
                let launchdLease = AdvisoryFileLock.acquireSync(path: AgentConfig.launchdLockPath, timeout: 15.0)
                defer { launchdLease?.release() }
                WorkerJob.removeStale()
                job = try WorkerJob.start(executable: executable, arguments: ["worker", mode, listener.path],
                                          environment: environment, directory: listener.directory)
            }
            let channels = try listener.acceptChannels(token: token, workerPID: job!.pid, doctor: mode == "doctor")
            defer { for fd in channels.values { close(fd) } }
            var status = try WorkerTransport.relay(stdio: channels["stdio"]!, stderrSocket: channels["stderr"])
            if status == 0, WorkerTransport.interrupted == 0, let outcome = job?.exitStatus(), outcome.exitCode != 0 {
                if let sig = outcome.signal {
                    let line = "OpenCU worker (\(job!.pid)) terminated by signal \(sig).\n"
                    line.withCString { _ = Darwin.write(STDERR_FILENO, $0, strlen($0)) }
                }
                status = outcome.exitCode
            }
            job?.remove()
            return status
        } catch {
            // A failed start must not leave a job or an unconnected worker behind.
            job?.remove()
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
        try WorkerTransport.awaitAcknowledgement(stdio)
        if let errors { try WorkerTransport.awaitAcknowledgement(errors) }
        EngineResponsibility.worker = true
    }
}

/// One launchd job per relay. Its label carries the relay PID so a later relay can
/// remove jobs whose relay was killed before it could boot them out.
struct WorkerJob {
    static let prefix = "dev.opencu.worker."
    static var domain: String { "gui/\(getuid())" }
    let label: String
    let pid: pid_t

    static func start(executable: String, arguments: [String], environment: [String: String], directory: String) throws -> WorkerJob {
        let file = directory + "/worker.plist"
        defer { unlink(file) }
        var bootstrappedLabel: String?
        for attempt in 0..<3 {
            var random = [UInt8](repeating: 0, count: 4)
            random.withUnsafeMutableBytes { arc4random_buf($0.baseAddress!, $0.count) }
            let label = prefix + "\(getpid())." + random.map { String(format: "%02x", $0) }.joined()
            let definition: [String: Any] = [
                "Label": label, "ProgramArguments": [executable] + arguments, "EnvironmentVariables": environment,
                "ProcessType": "Interactive", "RunAtLoad": true, "KeepAlive": false,
                "StandardInPath": "/dev/null", "StandardOutPath": "/dev/null", "StandardErrorPath": "/dev/null",
            ]
            // The definition holds the token: write it 0600 inside the 0700 socket
            // directory and delete it as soon as launchd has read it.
            unlink(file)
            let data = try PropertyListSerialization.data(fromPropertyList: definition, format: .xml, options: 0)
            guard FileManager.default.createFile(atPath: file, contents: data, attributes: [.posixPermissions: 0o600]) else {
                throw WorkerTransport.Failure("cannot write the worker job definition")
            }
            if launchctl(["bootstrap", domain, file]).status == 0 {
                bootstrappedLabel = label
                break
            }
            _ = launchctl(["bootout", "\(domain)/\(label)"])
            if attempt < 2 { usleep(40_000) }
        }
        guard let label = bootstrappedLabel else { throw WorkerTransport.Failure("launchd refused the worker job") }
        let job = WorkerJob(label: label, pid: 0)
        let deadline = WorkerTransport.now + 10
        while WorkerTransport.now < deadline && WorkerTransport.interrupted == 0 {
            if let pid = runningPID(label) { return WorkerJob(label: label, pid: pid) }
            usleep(20_000)
        }
        job.remove()
        throw WorkerTransport.Failure(WorkerTransport.interrupted != 0 ? "worker launch interrupted" : "launchd did not start the OpenCU worker")
    }

    func remove() { _ = WorkerJob.launchctl(["bootout", "\(WorkerJob.domain)/\(label)"]) }

    static func decodeWaitStatus(_ raw: Int32) -> (exitCode: Int32, signal: Int32?) {
        let low = raw & 0x7f
        if low == 0 {
            return ((raw >> 8) & 0xff, nil)
        }
        if low != 0x7f {
            return (128 + low, low)
        }
        return (1, nil)
    }

    func exitStatus(timeout: TimeInterval = 0.25) -> (exitCode: Int32, signal: Int32?)? {
        let deadline = WorkerTransport.now + max(0, timeout)
        while true {
            let result = WorkerJob.launchctl(["list", label])
            guard result.status == 0 else { return nil }
            var stillRunning = false
            var rawStatus: Int32?
            for line in result.output.split(separator: "\n") {
                let trimmed = line
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .trimmingCharacters(in: CharacterSet(charactersIn: ";"))
                let parts = trimmed.split(separator: "=", maxSplits: 1).map {
                    $0.trimmingCharacters(in: .whitespaces)
                        .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                }
                guard parts.count == 2 else { continue }
                if parts[0] == "PID" { stillRunning = true }
                if parts[0] == "LastExitStatus", let parsed = Int32(parts[1]) { rawStatus = parsed }
            }
            if !stillRunning, let rawStatus {
                return Self.decodeWaitStatus(rawStatus)
            }
            if WorkerTransport.now >= deadline { return nil }
            usleep(10_000)
        }
    }

    static func runningPID(_ label: String) -> pid_t? {
        let output = launchctl(["print", "\(domain)/\(label)"]).output
        for line in output.split(separator: "\n") {
            let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if parts.count == 2, parts[0] == "pid", let pid = pid_t(parts[1]), pid > 0 { return pid }
        }
        return nil
    }

    static func removeStale() {
        for line in launchctl(["list"]).output.split(separator: "\n") {
            guard let label = line.split(separator: "\t").last.map(String.init), label.hasPrefix(prefix),
                  let relay = pid_t(label.dropFirst(prefix.count).split(separator: ".").first ?? "") else { continue }
            if !alive(relay) { _ = launchctl(["bootout", "\(domain)/\(label)"]) }
        }
    }

    /// A killed relay may linger as a zombie until its client reaps it.
    static func alive(_ pid: pid_t) -> Bool {
        ProcessLiveness.alive(pid)
    }

    static func launchctl(_ arguments: [String]) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return (-1, "") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}
