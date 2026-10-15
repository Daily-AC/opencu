import CoreGraphics
import Foundation
import Darwin

/// The hidden metadata-only child and its parent share this versioned wire format.
/// No NSApplication, AX, capture API, permission preflight/request, or UI is used.
struct OnlineDisplay: Codable, Equatable {
    struct Frame: Codable, Equatable {
        let x: Double, y: Double, width: Double, height: Double
        init(_ rect: CGRect) { x = rect.minX; y = rect.minY; width = rect.width; height = rect.height }
        var rect: CGRect { CGRect(x: x, y: y, width: width, height: height) }
    }
    let id: UInt32
    private let geometry: Frame
    let main: Bool
    let mirrored: Bool
    let pixelWidth: Int
    let pixelHeight: Int
    enum CodingKeys: String, CodingKey { case id, geometry = "frame", main, mirrored, pixelWidth, pixelHeight }
    var frame: CGRect { geometry.rect }
    var valid: Bool {
        id > 0 && [geometry.x, geometry.y, geometry.width, geometry.height].allSatisfy(\.isFinite)
            && geometry.width > 0 && geometry.height > 0 && pixelWidth >= 0 && pixelHeight >= 0
    }
    init(id: UInt32, frame: CGRect, main: Bool, mirrored: Bool, pixelWidth: Int, pixelHeight: Int) {
        self.id = id; geometry = Frame(frame); self.main = main; self.mirrored = mirrored
        self.pixelWidth = pixelWidth; self.pixelHeight = pixelHeight
    }
    var json: Arguments {
        ["id": id, "frame": agentDisplayRectJSON(frame), "main": main, "mirrored": mirrored,
         "pixelWidth": pixelWidth, "pixelHeight": pixelHeight]
    }
}

enum OnlineDisplays {
    struct Response: Codable { let schemaVersion: Int; let displays: [OnlineDisplay] }

    static func current() throws -> [OnlineDisplay] {
        var ids = [CGDirectDisplayID](repeating: 0, count: 64), count: UInt32 = 0
        guard CGGetOnlineDisplayList(UInt32(ids.count), &ids, &count) == .success, count < ids.count else {
            throw OpenCUError("AGENT_DISPLAY_STATUS_FAILED", "Could not enumerate all online displays.")
        }
        return ids.prefix(Int(count)).map { id in
            let mode = CGDisplayCopyDisplayMode(id)
            return OnlineDisplay(id: id, frame: CGDisplayBounds(id), main: id == CGMainDisplayID(),
                                 mirrored: CGDisplayIsInMirrorSet(id) != 0,
                                 pixelWidth: mode?.pixelWidth ?? 0, pixelHeight: mode?.pixelHeight ?? 0)
        }.sorted { $0.id < $1.id }
    }

    static func encode(_ displays: [OnlineDisplay]) throws -> Data {
        try JSONEncoder().encode(Response(schemaVersion: 1, displays: displays))
    }

    static func parse(_ data: Data) throws -> [OnlineDisplay] {
        do {
            guard data.count <= 65_536 else { throw invalid("response exceeds 64 KiB") }
            let response = try JSONDecoder().decode(Response.self, from: data)
            guard response.schemaVersion == 1, response.displays.count < 64 else { throw invalid("unsupported schema or count") }
            let values = response.displays
            guard Set(values.map(\.id)).count == values.count,
                  values.filter(\.main).count <= 1,
                  values.allSatisfy(\.valid) else {
                throw invalid("invalid display identity or geometry")
            }
            return values.sorted { $0.id < $1.id }
        } catch {
            throw invalid(error.localizedDescription)
        }
    }

    private static func invalid(_ reason: String) -> OpenCUError {
        OpenCUError("AGENT_DISPLAY_LIST_INVALID", "Fresh display query returned invalid JSON: \(reason)")
    }
}

/// Pure polling policy; tests inject the lister, clock and sleep. A failed query
/// is never treated as an empty display list or proof of successful removal.
enum DisplayRemovalPoll {
    struct Result {
        let removed: Bool
        let checks: Int
        let elapsedMs: Double
        let displays: [OnlineDisplay]?
        let error: String?
    }

    static func wait(for id: UInt32, started: Double, timeout: Double = 10,
                     now: () -> Double = { ProcessInfo.processInfo.systemUptime },
                     sleep: (Double) async throws -> Void = { try await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000)) },
                     list: (Double) async throws -> [OnlineDisplay]) async -> Result {
        var checks = 0
        var latest: [OnlineDisplay]?
        func result(_ removed: Bool, _ error: String?) -> Result {
            Result(removed: removed, checks: checks, elapsedMs: max(0, now() - started) * 1000, displays: latest, error: error)
        }
        while now() - started < timeout {
            do {
                let budget = min(2, timeout - (now() - started))
                if budget <= 0 { break }
                checks += 1
                // Each process is bounded independently, and by the overall deadline.
                latest = try await list(budget)
                if now() - started > timeout { return result(false, "Fresh display query exceeded the removal deadline.") }
                if !latest!.contains(where: { $0.id == id }) { return result(true, nil) }
                let remaining = timeout - (now() - started)
                if remaining <= 0 { break }
                try await sleep(min(0.25, remaining))
            } catch { return result(false, "Fresh display query failed: \(error.localizedDescription)") }
        }
        return result(false, "Fresh display processes still list display \(id) after \(timeout) seconds (\(checks) checks).")
    }
}

/// posix_spawn of the SAME signed executable, not LaunchServices. The child gets
/// only stdout's pipe and /dev/null stdin/stderr; it cannot inherit the client's
/// transport. Nonblocking reads bound output and enforce a monotonic deadline.
enum FreshOnlineDisplays {
    static func list(timeout: Double = 2) throws -> [OnlineDisplay] {
        guard let executable = Bundle.main.executablePath else {
            throw OpenCUError("AGENT_DISPLAY_LIST_FAILED", "Cannot locate the engine for a fresh display query.")
        }
        return try OnlineDisplays.parse(run(executable: executable, arguments: ["--online-displays"], timeout: timeout))
    }

    static func run(executable: String, arguments: [String], timeout: Double) throws -> Data {
        guard timeout.isFinite, timeout > 0 else { throw failure("invalid child deadline", EINVAL) }
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        var descriptors: [Int32] = [0, 0]
        guard pipe(&descriptors) == 0 else { throw failure("pipe", errno) }
        var writeOpen = true
        defer { close(descriptors[0]); if writeOpen { close(descriptors[1]) } }
        guard fcntl(descriptors[0], F_SETFL, O_NONBLOCK) != -1 else { throw failure("nonblocking pipe", errno) }
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        var error = posix_spawn_file_actions_init(&actions)
        guard error == 0 else { throw failure("file actions", error) }
        defer { posix_spawn_file_actions_destroy(&actions) }
        error = posix_spawnattr_init(&attributes)
        guard error == 0 else { throw failure("spawn attributes", error) }
        defer { posix_spawnattr_destroy(&attributes) }
        func checked(_ error: Int32, _ operation: String) throws {
            guard error == 0 else { throw failure(operation, error) }
        }
        try checked(posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0), "stdin")
        try checked(posix_spawn_file_actions_adddup2(&actions, descriptors[1], STDOUT_FILENO), "stdout")
        try checked(posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, "/dev/null", O_WRONLY, 0), "stderr")
        try checked(posix_spawn_file_actions_addclose(&actions, descriptors[0]), "close reader")
        try checked(posix_spawn_file_actions_addclose(&actions, descriptors[1]), "close writer")
        var mask = sigset_t(), defaults = sigset_t()
        sigemptyset(&mask); sigemptyset(&defaults)
        for number in [SIGTERM, SIGINT, SIGHUP, SIGPIPE] { sigaddset(&defaults, number) }
        try checked(posix_spawnattr_setsigmask(&attributes, &mask), "signal mask")
        try checked(posix_spawnattr_setsigdefault(&attributes, &defaults), "signal defaults")
        try checked(posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF)), "spawn flags")
        let argv = ([executable] + arguments).map { strdup($0)! }
        defer { argv.forEach { free($0) } }
        var pointers: [UnsafeMutablePointer<CChar>?] = argv.map { $0 } + [nil]
        var child: pid_t = 0
        try checked(posix_spawn(&child, executable, &actions, &attributes, &pointers, environ), "spawn")
        close(descriptors[1]); writeOpen = false
        var reaped = false
        defer {
            if !reaped {
                kill(child, SIGKILL)
                var status: Int32 = 0
                while waitpid(child, &status, 0) == -1 && errno == EINTR {}
            }
        }
        var output = Data(), status: Int32 = 0
        var buffer = [UInt8](repeating: 0, count: 4096)
        var ended = false
        while true {
            while true {
                let count = read(descriptors[0], &buffer, buffer.count)
                if count > 0 {
                    output.append(contentsOf: buffer.prefix(count))
                    guard output.count <= 65_536 else { throw failure("output exceeds 64 KiB", EOVERFLOW) }
                } else if count == 0 { ended = true; break }
                else if errno == EINTR { continue }
                else if errno == EAGAIN { break }
                else { throw failure("read", errno) }
            }
            if !reaped {
                let waited = waitpid(child, &status, WNOHANG)
                if waited == child { reaped = true }
                else if waited == -1 && errno != EINTR { throw failure("waitpid", errno) }
            }
            if reaped && ended {
                guard status == 0 else { throw failure("child exit status \(status)", ECHILD) }
                return output
            }
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw failure("child timed out", ETIMEDOUT) }
            var descriptor = pollfd(fd: descriptors[0], events: Int16(POLLIN), revents: 0)
            // EOF can precede process exit; do not spin on POLLHUP.
            if ended { Thread.sleep(forTimeInterval: 0.005) }
            else { _ = poll(&descriptor, 1, Int32(max(1, min(10, (deadline - ProcessInfo.processInfo.systemUptime) * 1000)))) }
        }
    }

    private static func failure(_ operation: String, _ code: Int32) -> OpenCUError {
        OpenCUError("AGENT_DISPLAY_LIST_FAILED", "Fresh display query \(operation) failed (\(code)).")
    }
}
