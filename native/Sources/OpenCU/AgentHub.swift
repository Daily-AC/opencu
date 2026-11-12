import CoreGraphics
import Darwin
import Foundation

enum ProcessLiveness {
    /// Returns true if `pid` exists and is not a zombie.
    static func alive(_ pid: pid_t) -> Bool {
        guard pid > 0 else { return false }
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return false }
        return info.pbi_status != UInt32(SZOMB)
    }
}

struct AgentRGB: Equatable, Sendable {
    let r: UInt8
    let g: UInt8
    let b: UInt8

    var red: CGFloat { CGFloat(r) / 255.0 }
    var green: CGFloat { CGFloat(g) / 255.0 }
    var blue: CGFloat { CGFloat(b) / 255.0 }

    static func parseHex(_ raw: String?) -> (hex: String, rgb: AgentRGB)? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("#") else { return nil }
        let digits = String(trimmed.dropFirst()).uppercased()
        let expanded: String
        if digits.count == 6 {
            expanded = digits
        } else if digits.count == 3 {
            expanded = digits.map { "\($0)\($0)" }.joined()
        } else {
            return nil
        }
        guard expanded.utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) }),
              let value = UInt32(expanded, radix: 16) else {
            return nil
        }
        let rgb = AgentRGB(
            r: UInt8((value >> 16) & 0xFF),
            g: UInt8((value >> 8) & 0xFF),
            b: UInt8(value & 0xFF)
        )
        return ("#" + expanded, rgb)
    }
}

enum AgentSlotPalette {
    struct Entry: Equatable, Sendable {
        let slot: Int
        let hex: String
        let defaultName: String
        let rgb: AgentRGB
    }

    static let count = 16
    static let maxSlots = 24

    static let entries: [Entry] = [
        Entry(slot: 0, hex: "#FF6B9D", defaultName: "Agent 1", rgb: AgentRGB(r: 0xFF, g: 0x6B, b: 0x9D)),
        Entry(slot: 1, hex: "#38BDF8", defaultName: "Agent 2", rgb: AgentRGB(r: 0x38, g: 0xBD, b: 0xF8)),
        Entry(slot: 2, hex: "#F59E0B", defaultName: "Agent 3", rgb: AgentRGB(r: 0xF5, g: 0x9E, b: 0x0B)),
        Entry(slot: 3, hex: "#34D399", defaultName: "Agent 4", rgb: AgentRGB(r: 0x34, g: 0xD3, b: 0x99)),
        Entry(slot: 4, hex: "#A78BFA", defaultName: "Agent 5", rgb: AgentRGB(r: 0xA7, g: 0x8B, b: 0xFA)),
        Entry(slot: 5, hex: "#FB7185", defaultName: "Agent 6", rgb: AgentRGB(r: 0xFB, g: 0x71, b: 0x85)),
        Entry(slot: 6, hex: "#2DD4BF", defaultName: "Agent 7", rgb: AgentRGB(r: 0x2D, g: 0xD4, b: 0xBF)),
        Entry(slot: 7, hex: "#FBBF24", defaultName: "Agent 8", rgb: AgentRGB(r: 0xFB, g: 0xBF, b: 0x24)),
        Entry(slot: 8, hex: "#60A5FA", defaultName: "Agent 9", rgb: AgentRGB(r: 0x60, g: 0xA5, b: 0xFA)),
        Entry(slot: 9, hex: "#F472B6", defaultName: "Agent 10", rgb: AgentRGB(r: 0xF4, g: 0x72, b: 0xB6)),
        Entry(slot: 10, hex: "#4ADE80", defaultName: "Agent 11", rgb: AgentRGB(r: 0x4A, g: 0xDE, b: 0x80)),
        Entry(slot: 11, hex: "#C084FC", defaultName: "Agent 12", rgb: AgentRGB(r: 0xC0, g: 0x84, b: 0xFC)),
        Entry(slot: 12, hex: "#FB923C", defaultName: "Agent 13", rgb: AgentRGB(r: 0xFB, g: 0x92, b: 0x3C)),
        Entry(slot: 13, hex: "#22D3EE", defaultName: "Agent 14", rgb: AgentRGB(r: 0x22, g: 0xD3, b: 0xEE)),
        Entry(slot: 14, hex: "#A3E635", defaultName: "Agent 15", rgb: AgentRGB(r: 0xA3, g: 0xE6, b: 0x35)),
        Entry(slot: 15, hex: "#E879F9", defaultName: "Agent 16", rgb: AgentRGB(r: 0xE8, g: 0x79, b: 0xF9)),
    ]

    static func entry(for slot: Int) -> Entry {
        let normalizedSlot = ((slot % maxSlots) + maxSlots) % maxSlots
        let colorIndex = ((slot % count) + count) % count
        let base = entries[colorIndex]
        return Entry(
            slot: normalizedSlot,
            hex: base.hex,
            defaultName: "Agent \(normalizedSlot + 1)",
            rgb: base.rgb
        )
    }
}

enum AgentConfig {
    static let forwardedEnvironmentKeys: [String] = [
        "OPENCU_AGENT_ID",
        "OPENCU_AGENT_NAME",
        "OPENCU_AGENT_COLOR",
        "OPENCU_HUB_DIR",
        "OPENCU_EVENT_SOCK",
        "OPENCU_CAPTURE_OVERLAY",
    ]

    static var launchdLockPath: String {
        "/tmp/opencu-launchd-\(getuid()).lock"
    }

    static func captureOverlayEnabled(environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        guard let raw = environment["OPENCU_CAPTURE_OVERLAY"]?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() else {
            return false
        }
        return raw == "1" || raw == "true"
    }

    static func homeDirectory(environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
        if let home = environment["HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines), !home.isEmpty {
            return home
        }
        return NSHomeDirectory()
    }

    static func expandPath(_ raw: String?, defaultRelative: String,
                           environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
        let home = homeDirectory(environment: environment)
        if let raw {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                if trimmed == "~" { return home }
                if trimmed.hasPrefix("~/") {
                    return (home as NSString).appendingPathComponent(String(trimmed.dropFirst(2)))
                }
                return trimmed
            }
        }
        return (home as NSString).appendingPathComponent(defaultRelative)
    }

    static func hubDirectory(environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
        expandPath(environment["OPENCU_HUB_DIR"], defaultRelative: ".opencu/hub", environment: environment)
    }

    static func eventSocketPath(environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
        expandPath(environment["OPENCU_EVENT_SOCK"], defaultRelative: ".ibuki-pet/opencu.sock", environment: environment)
    }

    /// Strips control, newline, and bidi override scalars and clamps to `maxCount` characters.
    static func sanitize(_ raw: String?, maxCount: Int) -> String? {
        guard let raw else { return nil }
        let scalars = raw.unicodeScalars.map { scalar -> Character in
            if scalar.properties.generalCategory == .control
                || CharacterSet.newlines.contains(scalar)
                || (0x202A...0x202E).contains(scalar.value)
                || (0x2066...0x2069).contains(scalar.value)
                || [0x061C, 0x200E, 0x200F].contains(scalar.value) {
                return " "
            }
            return Character(String(scalar))
        }
        let collapsed = String(scalars).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !collapsed.isEmpty else { return nil }
        let clamped = String(collapsed.prefix(maxCount)).trimmingCharacters(in: .whitespacesAndNewlines)
        return clamped.isEmpty ? nil : clamped
    }
}

struct AgentIdentity: Equatable, Sendable {
    let pid: Int32
    let agentId: String
    let agentName: String
    let agentColor: String
    let rgb: AgentRGB
    let slot: Int
    let explicitName: Bool

    static func make(pid: Int32, slot: Int, environment: [String: String]) -> AgentIdentity {
        let palette = AgentSlotPalette.entry(for: slot)
        let explicitId = AgentConfig.sanitize(environment["OPENCU_AGENT_ID"], maxCount: 64)
        let explicitNameValue = AgentConfig.sanitize(environment["OPENCU_AGENT_NAME"], maxCount: 24)
        let parsedColor = AgentRGB.parseHex(environment["OPENCU_AGENT_COLOR"])
        return AgentIdentity(
            pid: pid,
            agentId: explicitId ?? "opencu-\(pid)",
            agentName: explicitNameValue ?? palette.defaultName,
            agentColor: parsedColor?.hex ?? palette.hex,
            rgb: parsedColor?.rgb ?? palette.rgb,
            slot: palette.slot,
            explicitName: explicitNameValue != nil
        )
    }
}

struct AgentRecord: Codable, Equatable, Sendable {
    let pid: Int32
    let agentId: String
    let agentName: String
    let agentColor: String
    let slot: Int
    let explicitName: Bool
    var windowID: UInt32?
    var targetPID: Int32?
    var updatedAtMs: Int64
}

enum AdvisoryFileLock {
    private static let cFlock: @Sendable (Int32, Int32) -> Int32 = flock

    final class Lease {
        private var fd: Int32

        init(fd: Int32) {
            self.fd = fd
        }

        func release() {
            guard fd >= 0 else { return }
            _ = AdvisoryFileLock.cFlock(fd, LOCK_UN)
            _ = Darwin.close(fd)
            fd = -1
        }

        deinit {
            release()
        }
    }

    static var monotonicNow: TimeInterval {
        var ts = timespec()
        clock_gettime(CLOCK_MONOTONIC, &ts)
        return Double(ts.tv_sec) + Double(ts.tv_nsec) / 1_000_000_000
    }

    static func ensureDirectory(_ path: String) throws {
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue {
            return
        }
        try FileManager.default.createDirectory(
            atPath: path,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
    }

    static func tryAcquire(path: String) -> Lease? {
        let parent = (path as NSString).deletingLastPathComponent
        try? ensureDirectory(parent)
        let fd = Darwin.open(path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return nil }
        if cFlock(fd, LOCK_EX | LOCK_NB) == 0 {
            return Lease(fd: fd)
        }
        _ = Darwin.close(fd)
        return nil
    }

    static func acquireSync(path: String, timeout: TimeInterval = 2.0) -> Lease? {
        let parent = (path as NSString).deletingLastPathComponent
        try? ensureDirectory(parent)
        let fd = Darwin.open(path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return nil }
        let deadline = monotonicNow + max(0, timeout)
        while true {
            if cFlock(fd, LOCK_EX | LOCK_NB) == 0 {
                return Lease(fd: fd)
            }
            let err = errno
            if err != EWOULDBLOCK && err != EAGAIN && err != EINTR {
                _ = Darwin.close(fd)
                return nil
            }
            if monotonicNow >= deadline {
                _ = Darwin.close(fd)
                return nil
            }
            usleep(2_000)
        }
    }

    /// Returns true if another open file descriptor currently holds an exclusive flock on `path`.
    static func isContended(path: String) -> Bool {
        let fd = Darwin.open(path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { return false }
        if cFlock(fd, LOCK_EX | LOCK_NB) == 0 {
            _ = cFlock(fd, LOCK_UN)
            _ = Darwin.close(fd)
            return false
        }
        let contended = (errno == EWOULDBLOCK || errno == EAGAIN)
        _ = Darwin.close(fd)
        return contended
    }

    @MainActor
    static func acquire(
        path: String,
        timeout: TimeInterval,
        pollInterval: TimeInterval = 0.025,
        errorCode: String,
        errorMessage: String,
        checkAllowed: (@MainActor () throws -> Void)? = nil,
        onContended: (@MainActor () -> Void)? = nil
    ) async throws -> Lease {
        dispatchPrecondition(condition: .onQueue(.main))
        let parent = (path as NSString).deletingLastPathComponent
        do {
            try ensureDirectory(parent)
        } catch {
            throw OpenCUError(errorCode, errorMessage)
        }
        let fd = Darwin.open(path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard fd >= 0 else {
            throw OpenCUError(errorCode, errorMessage)
        }
        if cFlock(fd, LOCK_EX | LOCK_NB) == 0 {
            return Lease(fd: fd)
        }
        let initialErr = errno
        guard initialErr == EWOULDBLOCK || initialErr == EAGAIN || initialErr == EINTR else {
            _ = Darwin.close(fd)
            throw OpenCUError(errorCode, errorMessage)
        }
        onContended?()
        let deadline = monotonicNow + max(0, timeout)
        while monotonicNow < deadline {
            do {
                try Task.checkCancellation()
                try checkAllowed?()
            } catch {
                _ = Darwin.close(fd)
                throw error
            }
            let remaining = deadline - monotonicNow
            if remaining <= 0 { break }
            let waitSeconds = min(pollInterval, remaining)
            do {
                try await Task.sleep(nanoseconds: UInt64(max(1_000_000, waitSeconds * 1_000_000_000)))
            } catch {
                _ = Darwin.close(fd)
                throw error
            }
            if cFlock(fd, LOCK_EX | LOCK_NB) == 0 {
                return Lease(fd: fd)
            }
            let err = errno
            if err != EWOULDBLOCK && err != EAGAIN && err != EINTR {
                _ = Darwin.close(fd)
                throw OpenCUError(errorCode, errorMessage)
            }
        }
        _ = Darwin.close(fd)
        throw OpenCUError(errorCode, errorMessage)
    }
}

final class AgentHub {
    let hubDirectory: String
    let selfPID: pid_t
    private let environment: [String: String]
    private let isAlive: (pid_t) -> Bool
    private(set) var identity: AgentIdentity
    private(set) var registered = false
    private var lastWindowID: UInt32?
    private var lastTargetPID: Int32?
    private var cachedPeers: [AgentRecord] = []
    private var lastPeerScan: TimeInterval = -.infinity

    var agentsDirectory: String { (hubDirectory as NSString).appendingPathComponent("agents") }
    var locksDirectory: String { (hubDirectory as NSString).appendingPathComponent("locks") }
    var registryLockPath: String { (locksDirectory as NSString).appendingPathComponent("registry.lock") }
    var clipboardLockPath: String { (locksDirectory as NSString).appendingPathComponent("clipboard.lock") }
    func pidLockPath(_ pid: pid_t) -> String { (locksDirectory as NSString).appendingPathComponent("pid-\(pid).lock") }
    var selfRecordPath: String { (agentsDirectory as NSString).appendingPathComponent("\(selfPID).json") }

    init(
        hubDirectory: String? = nil,
        selfPID: pid_t = getpid(),
        environment: [String: String] = ProcessInfo.processInfo.environment,
        isAlive: @escaping (pid_t) -> Bool = ProcessLiveness.alive
    ) {
        self.hubDirectory = hubDirectory ?? AgentConfig.hubDirectory(environment: environment)
        self.selfPID = selfPID
        self.environment = environment
        self.isAlive = isAlive
        self.identity = AgentIdentity.make(pid: selfPID, slot: 0, environment: environment)
    }

    static var currentEpochMs: Int64 {
        Int64((Date().timeIntervalSince1970 * 1000.0).rounded())
    }

    @discardableResult
    func register() -> AgentIdentity {
        try? AdvisoryFileLock.ensureDirectory(hubDirectory)
        try? AdvisoryFileLock.ensureDirectory(agentsDirectory)
        try? AdvisoryFileLock.ensureDirectory(locksDirectory)
        let lease = AdvisoryFileLock.acquireSync(path: registryLockPath)
        defer { lease?.release() }

        let siblings = scanActiveRecordsLocked(excludingSelf: true, cleanStale: true)
        let slot = Self.pickDeterministicSlot(existing: siblings)
        let resolved = AgentIdentity.make(pid: selfPID, slot: slot, environment: environment)
        self.identity = resolved
        let record = AgentRecord(
            pid: selfPID,
            agentId: resolved.agentId,
            agentName: resolved.agentName,
            agentColor: resolved.agentColor,
            slot: resolved.slot,
            explicitName: resolved.explicitName,
            windowID: lastWindowID,
            targetPID: lastTargetPID,
            updatedAtMs: Self.currentEpochMs
        )
        writeRecordLocked(record)
        registered = true
        cachedPeers = (siblings + [record]).sorted(by: Self.recordOrder)
        lastPeerScan = AdvisoryFileLock.monotonicNow
        return resolved
    }

    static func pickDeterministicSlot(existing: [AgentRecord]) -> Int {
        let totalSlots = AgentSlotPalette.maxSlots
        var counts = [Int](repeating: 0, count: totalSlots)
        for record in existing where (0..<totalSlots).contains(record.slot) {
            counts[record.slot] += 1
        }
        if let free = (0..<totalSlots).first(where: { counts[$0] == 0 }) {
            return free
        }
        var bestSlot = 0
        for candidate in 1..<totalSlots where counts[candidate] < counts[bestSlot] {
            bestSlot = candidate
        }
        return bestSlot
    }

    func updateTarget(windowID: UInt32?, targetPID: pid_t?) {
        let target: Int32? = targetPID
        guard registered else {
            lastWindowID = windowID
            lastTargetPID = target
            return
        }
        guard lastWindowID != windowID || lastTargetPID != target else { return }
        lastWindowID = windowID
        lastTargetPID = target
        let lease = AdvisoryFileLock.acquireSync(path: registryLockPath)
        defer { lease?.release() }
        let record = AgentRecord(
            pid: selfPID,
            agentId: identity.agentId,
            agentName: identity.agentName,
            agentColor: identity.agentColor,
            slot: identity.slot,
            explicitName: identity.explicitName,
            windowID: windowID,
            targetPID: target,
            updatedAtMs: Self.currentEpochMs
        )
        writeRecordLocked(record)
        lastPeerScan = -.infinity
    }

    func unregister() {
        guard registered else { return }
        let lease = AdvisoryFileLock.acquireSync(path: registryLockPath)
        defer { lease?.release() }
        _ = Darwin.unlink(selfRecordPath)
        registered = false
        cachedPeers = []
        lastPeerScan = -.infinity
    }

    func activeAgents(forceRefresh: Bool = false) -> [AgentRecord] {
        guard registered else { return [] }
        let now = AdvisoryFileLock.monotonicNow
        if !forceRefresh, now - lastPeerScan < 0.15, !cachedPeers.isEmpty {
            return cachedPeers
        }
        let lease = AdvisoryFileLock.acquireSync(path: registryLockPath, timeout: 0.1)
        defer { lease?.release() }
        let records = scanActiveRecordsLocked(excludingSelf: false, cleanStale: lease != nil)
        cachedPeers = records.sorted(by: Self.recordOrder)
        lastPeerScan = now
        return cachedPeers
    }

    func shouldShowCursorTag(forceRefresh: Bool = false) -> Bool {
        if identity.explicitName { return true }
        return activeAgents(forceRefresh: forceRefresh).count > 1
    }

    func peerPlacement(for windowID: UInt32, forceRefresh: Bool = false) -> (peerIndex: Int, peerCount: Int, totalAgents: Int) {
        guard registered else { return (0, 1, 1) }
        let records = activeAgents(forceRefresh: forceRefresh)
        var onWindow = records.filter { $0.windowID == windowID }
        if !onWindow.contains(where: { $0.pid == selfPID }) {
            onWindow.append(AgentRecord(
                pid: selfPID,
                agentId: identity.agentId,
                agentName: identity.agentName,
                agentColor: identity.agentColor,
                slot: identity.slot,
                explicitName: identity.explicitName,
                windowID: windowID,
                targetPID: lastTargetPID,
                updatedAtMs: Self.currentEpochMs
            ))
        }
        onWindow.sort(by: Self.recordOrder)
        let index = onWindow.firstIndex(where: { $0.pid == selfPID }) ?? 0
        return (index, max(1, onWindow.count), max(1, records.count))
    }

    private static func recordOrder(_ lhs: AgentRecord, _ rhs: AgentRecord) -> Bool {
        if lhs.slot != rhs.slot { return lhs.slot < rhs.slot }
        return lhs.pid < rhs.pid
    }

    private func scanActiveRecordsLocked(excludingSelf: Bool, cleanStale: Bool) -> [AgentRecord] {
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: agentsDirectory) else {
            return []
        }
        let decoder = JSONDecoder()
        var results: [AgentRecord] = []
        for name in entries where name.hasSuffix(".json") && !name.hasPrefix(".") {
            let fullPath = (agentsDirectory as NSString).appendingPathComponent(name)
            let stem = String(name.dropLast(5))
            guard let filePID = Int32(stem), filePID > 0 else {
                if cleanStale { _ = Darwin.unlink(fullPath) }
                continue
            }
            if filePID != selfPID && !isAlive(filePID) {
                if cleanStale { _ = Darwin.unlink(fullPath) }
                continue
            }
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: fullPath)),
                  let record = try? decoder.decode(AgentRecord.self, from: data),
                  record.pid == filePID else {
                if cleanStale && filePID != selfPID { _ = Darwin.unlink(fullPath) }
                continue
            }
            if excludingSelf && record.pid == selfPID { continue }
            results.append(record)
        }
        return results
    }

    private func writeRecordLocked(_ record: AgentRecord) {
        guard let data = try? JSONEncoder().encode(record) else { return }
        let tempPath = (agentsDirectory as NSString).appendingPathComponent(".tmp-\(selfPID)-\(UUID().uuidString).json")
        guard FileManager.default.createFile(atPath: tempPath, contents: data, attributes: [.posixPermissions: 0o600]) else {
            return
        }
        if Darwin.rename(tempPath, selfRecordPath) != 0 {
            _ = Darwin.unlink(tempPath)
        }
    }
}
