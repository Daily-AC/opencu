import CoreGraphics
import Darwin
import Foundation

struct CompanionPoint: Codable, Equatable, Sendable {
    let x: Double
    let y: Double

    init?(cgPoint: CGPoint?) {
        guard let cgPoint, cgPoint.x.isFinite, cgPoint.y.isFinite else { return nil }
        self.x = (Double(cgPoint.x) * 100.0).rounded() / 100.0
        self.y = (Double(cgPoint.y) * 100.0).rounded() / 100.0
    }

    init?(x: Double, y: Double) {
        guard x.isFinite, y.isFinite else { return nil }
        self.x = (x * 100.0).rounded() / 100.0
        self.y = (y * 100.0).rounded() / 100.0
    }
}

struct CompanionApp: Codable, Equatable, Sendable {
    let pid: Int32
    let bundleId: String
    let name: String

    init(pid: Int32, bundleId: String?, name: String) {
        self.pid = pid
        self.bundleId = AgentConfig.sanitize(bundleId, maxCount: 128) ?? "pid.\(pid)"
        self.name = AgentConfig.sanitize(name, maxCount: 48) ?? "App"
    }

    init(targetApp app: TargetApp) {
        let safeBundle = app.application.bundleIdentifier
        let rawName = app.application.localizedName
            ?? app.application.bundleURL?.deletingPathExtension().lastPathComponent
            ?? safeBundle
            ?? "App"
        self.init(pid: app.pid, bundleId: safeBundle, name: rawName)
    }
}

struct CompanionWindow: Codable, Equatable, Sendable {
    let id: UInt32
    let x: Double
    let y: Double
    let width: Double
    let height: Double

    init?(id: CGWindowID?, bounds: CGRect) {
        guard let id, id != kCGNullWindowID,
              !bounds.isNull, !bounds.isInfinite,
              bounds.origin.x.isFinite, bounds.origin.y.isFinite,
              bounds.size.width.isFinite, bounds.size.height.isFinite,
              bounds.size.width > 0, bounds.size.height > 0 else {
            return nil
        }
        self.id = id
        self.x = (Double(bounds.origin.x) * 100.0).rounded() / 100.0
        self.y = (Double(bounds.origin.y) * 100.0).rounded() / 100.0
        self.width = (Double(bounds.size.width) * 100.0).rounded() / 100.0
        self.height = (Double(bounds.size.height) * 100.0).rounded() / 100.0
    }
}

enum CompanionEventKind: String, Codable, Sendable {
    case connected
    case observed
    case actionStart = "action_start"
    case pointerMove = "pointer_move"
    case actionDone = "action_done"
    case waitingTurn = "waiting_turn"
    case stopped
    case disconnected
}

enum CompanionActionKind: String, Codable, Sendable {
    case click
    case drag
    case scroll
    case typeText = "type_text"
    case paste
    case pressKey = "press_key"
    case setValue = "set_value"
    case selectText = "select_text"
    case performSecondaryAction = "perform_secondary_action"
    case activateApp = "activate_app"

    init?(method: String) {
        self.init(rawValue: method)
    }
}

struct CompanionAction: Codable, Equatable, Sendable {
    let kind: CompanionActionKind
    var point: CompanionPoint?
    var from: CompanionPoint?
    var to: CompanionPoint?
    var progress: Double?

    init(
        kind: CompanionActionKind,
        point: CompanionPoint? = nil,
        from: CompanionPoint? = nil,
        to: CompanionPoint? = nil,
        progress: Double? = nil
    ) {
        self.kind = kind
        self.point = point
        self.from = from
        self.to = to
        if let progress, progress.isFinite {
            let clamped = min(1.0, max(0.0, progress))
            self.progress = (clamped * 1000.0).rounded() / 1000.0
        } else {
            self.progress = nil
        }
    }
}

/// Strictly typed companion telemetry payload.
/// By construction, no `text`, `value`, `key`, window `title`, `url`, `label`, or screenshot field exists.
struct CompanionEventPayload: Codable, Equatable, Sendable {
    let v: Int
    let ts: Int64
    let coordSpace: String
    let agentId: String
    let agentName: String
    let agentColor: String
    let slot: Int
    let event: CompanionEventKind
    var app: CompanionApp?
    var window: CompanionWindow?
    var action: CompanionAction?

    init(
        identity: AgentIdentity,
        ts: Int64 = AgentHub.currentEpochMs,
        event: CompanionEventKind,
        app: CompanionApp? = nil,
        window: CompanionWindow? = nil,
        action: CompanionAction? = nil
    ) {
        self.v = 1
        self.ts = ts
        self.coordSpace = "cg_points_top_left"
        self.agentId = AgentConfig.sanitize(identity.agentId, maxCount: 64) ?? "opencu-\(identity.pid)"
        self.agentName = AgentConfig.sanitize(identity.agentName, maxCount: 24) ?? AgentSlotPalette.entry(for: identity.slot).defaultName
        self.agentColor = AgentRGB.parseHex(identity.agentColor)?.hex ?? AgentSlotPalette.entry(for: identity.slot).hex
        self.slot = ((identity.slot % AgentSlotPalette.maxSlots) + AgentSlotPalette.maxSlots) % AgentSlotPalette.maxSlots
        self.event = event
        self.app = app
        self.window = window
        self.action = action
    }
}

final class CompanionBroadcaster {
    static let maxDatagramBytes = 2048

    let socketPath: String
    private var fd: Int32 = -1
    private var active = false
    private var sentDisconnected = false
    private var lastApp: CompanionApp?
    private var lastWindow: CompanionWindow?
    private let encoder = JSONEncoder()

    init(socketPath: String? = nil, environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.socketPath = socketPath ?? AgentConfig.eventSocketPath(environment: environment)
    }

    deinit {
        closeSocket()
    }

    func activate(identity: AgentIdentity) {
        guard !active else { return }
        active = true
        sentDisconnected = false
        send(CompanionEventPayload(identity: identity, event: .connected))
    }

    func observed(identity: AgentIdentity, snapshot: WindowSnapshot) {
        guard active else { return }
        let app = CompanionApp(targetApp: snapshot.app)
        let window = CompanionWindow(id: snapshot.windowID, bounds: snapshot.bounds)
        lastApp = app
        lastWindow = window
        send(CompanionEventPayload(identity: identity, event: .observed, app: app, window: window))
    }

    func waitingTurn(identity: AgentIdentity, app: CompanionApp, window: CompanionWindow?, kind: CompanionActionKind?) {
        guard active else { return }
        lastApp = app
        if let window { lastWindow = window }
        let action = kind.map { CompanionAction(kind: $0) }
        send(CompanionEventPayload(identity: identity, event: .waitingTurn, app: app, window: window ?? matchingLastWindow(for: app), action: action))
    }

    func actionStart(identity: AgentIdentity, app: CompanionApp, window: CompanionWindow?, action: CompanionAction) {
        guard active else { return }
        lastApp = app
        if let window { lastWindow = window }
        send(CompanionEventPayload(identity: identity, event: .actionStart, app: app, window: window ?? matchingLastWindow(for: app), action: action))
    }

    func pointerMove(identity: AgentIdentity, snapshot: WindowSnapshot, point: CGPoint, from: CGPoint? = nil, to: CGPoint? = nil, progress: Double? = nil, kind: CompanionActionKind = .drag) {
        guard active else { return }
        let app = CompanionApp(targetApp: snapshot.app)
        let window = CompanionWindow(id: snapshot.windowID, bounds: snapshot.bounds)
        lastApp = app
        if let window { lastWindow = window }
        let action = CompanionAction(
            kind: kind,
            point: CompanionPoint(cgPoint: point),
            from: CompanionPoint(cgPoint: from),
            to: CompanionPoint(cgPoint: to),
            progress: progress
        )
        send(CompanionEventPayload(identity: identity, event: .pointerMove, app: app, window: window, action: action))
    }

    func actionDone(identity: AgentIdentity, app: CompanionApp, window: CompanionWindow?, action: CompanionAction) {
        guard active else { return }
        lastApp = app
        if let window { lastWindow = window }
        send(CompanionEventPayload(identity: identity, event: .actionDone, app: app, window: window ?? matchingLastWindow(for: app), action: action))
    }

    func stopped(identity: AgentIdentity) {
        guard active else { return }
        send(CompanionEventPayload(identity: identity, event: .stopped, app: lastApp, window: lastWindow))
    }

    func disconnect(identity: AgentIdentity) {
        guard active, !sentDisconnected else {
            closeSocket()
            return
        }
        sentDisconnected = true
        send(CompanionEventPayload(identity: identity, event: .disconnected, app: lastApp, window: lastWindow))
        active = false
        closeSocket()
    }

    private func matchingLastWindow(for app: CompanionApp) -> CompanionWindow? {
        app.pid == lastApp?.pid ? lastWindow : nil
    }

    func encodeLine(_ payload: CompanionEventPayload) -> Data? {
        guard var data = try? encoder.encode(payload) else { return nil }
        data.append(0x0A)
        guard data.count <= Self.maxDatagramBytes else { return nil }
        return data
    }

    @discardableResult
    func send(_ payload: CompanionEventPayload) -> Bool {
        guard !socketPath.isEmpty, let line = encodeLine(payload) else { return false }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let utf8 = Array(socketPath.utf8)
        let maxPathBytes = MemoryLayout.size(ofValue: addr.sun_path)
        guard !utf8.isEmpty, utf8.count < maxPathBytes else { return false }
        let sock = ensureSocket()
        guard sock >= 0 else { return false }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.initializeMemory(as: UInt8.self, repeating: 0)
            for (index, byte) in utf8.enumerated() {
                raw[index] = byte
            }
        }
        let addrLen = socklen_t(MemoryLayout.offset(of: \sockaddr_un.sun_path)! + utf8.count + 1)
        addr.sun_len = UInt8(min(Int(UInt8.max), Int(addrLen)))
        let sent = line.withUnsafeBytes { buffer -> Int in
            guard let base = buffer.baseAddress else { return -1 }
            return withUnsafePointer(to: &addr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockAddr in
                    Darwin.sendto(sock, base, buffer.count, 0, sockAddr, addrLen)
                }
            }
        }
        return sent == line.count
    }

    private func ensureSocket() -> Int32 {
        if fd >= 0 { return fd }
        let created = Darwin.socket(AF_UNIX, SOCK_DGRAM, 0)
        guard created >= 0 else { return -1 }
        _ = Darwin.fcntl(created, F_SETFD, FD_CLOEXEC)
        let flags = Darwin.fcntl(created, F_GETFL)
        if flags >= 0 {
            _ = Darwin.fcntl(created, F_SETFL, flags | O_NONBLOCK)
        }
        var one: Int32 = 1
        _ = Darwin.setsockopt(created, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        fd = created
        return created
    }

    func closeSocket() {
        guard fd >= 0 else { return }
        _ = Darwin.close(fd)
        fd = -1
    }
}
