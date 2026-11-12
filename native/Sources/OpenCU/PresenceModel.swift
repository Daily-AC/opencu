import Foundation
import CoreGraphics

/// Per-connection policy, independent of AppKit and wall-clock adjustments.
struct PresenceState {
    static let inputMethods: Set<String> = ["wait", "hover", "click", "drag", "press_key", "type_text", "paste", "scroll",
                                            "set_value", "select_text", "perform_secondary_action", "activate_app",
                                            "swarm_dispatch", "cluster_cursors"]
    var cursorHoldDuration: TimeInterval = 3
    private(set) var stopped = false
    private(set) var connected = true
    private(set) var target: String?
    private(set) var callInFlight = false
    private(set) var lastCall: TimeInterval?
    private(set) var lastPointer: TimeInterval?
    private(set) var waitingTurn = false

    init(cursorHoldDuration: TimeInterval = 3) {
        self.cursorHoldDuration = cursorHoldDuration
    }

    mutating func call(target: String, now: TimeInterval) {
        if self.target != target { lastPointer = nil; waitingTurn = false }
        self.target = target
        lastCall = now
        callInFlight = true
    }
    mutating func finished(now: TimeInterval) { callInFlight = false; waitingTurn = false; if lastCall != nil { lastCall = now } }
    mutating func pointer(now: TimeInterval) { if connected && !stopped { lastPointer = now } }
    mutating func setWaitingTurn(_ waiting: Bool, now: TimeInterval) {
        guard connected, !stopped else { waitingTurn = false; return }
        waitingTurn = waiting
        if lastPointer != nil { lastPointer = now }
    }
    mutating func hideCursor() { lastPointer = nil; waitingTurn = false }
    mutating func stop() { stopped = true; hideCursor() }
    mutating func disconnect() { connected = false; lastCall = nil; hideCursor() }
    func menuVisible(at now: TimeInterval) -> Bool { connected && (callInFlight || lastCall.map { now - $0 < 15 } == true) }
    func cursorVisible(at now: TimeInterval) -> Bool {
        connected && !stopped && lastPointer.map { waitingTurn || now - $0 < cursorHoldDuration } == true
    }
    // Creating a display or moving a window onto it rearranges the person's screen.
    // Restore and destroy undo that work and stay allowed after a stop.
    static let screenChangingMethods: Set<String> = ["agent_desktop_start"]
    static func requiresPermissionToContinue(_ method: String, screenshot: Bool) -> Bool {
        inputMethods.contains(method) || screenChangingMethods.contains(method) || (method == "get_app_state" && screenshot)
    }
    func requireAllowed(_ method: String, screenshot: Bool = false) throws {
        if stopped && Self.requiresPermissionToContinue(method, screenshot: screenshot) { throw Self.stopError }
    }
    static var stopError: OpenCUError {
        OpenCUError("STOPPED_BY_PERSON", "The person stopped OpenCU on this Mac. Do not reconnect or retry on your own. Wait for the person's explicit permission. Text-only state can still be read.")
    }
}

struct CursorMotion {
    struct CometDot: Equatable {
        let point: CGPoint
        let radius: CGFloat
        let alpha: CGFloat
    }

    struct SelectionHighlight: Equatable {
        var rect: CGRect
        var began: TimeInterval
        var holdDuration: TimeInterval = 1.15
        var guideLines: Bool = true

        func opacity(at now: TimeInterval, waitingTurn: Bool = false) -> CGFloat {
            if waitingTurn { return 1 }
            let elapsed = max(0, now - began)
            guard elapsed < holdDuration else { return 0 }
            let fadeWindow = min(0.18, holdDuration * 0.25)
            if elapsed <= holdDuration - fadeWindow { return 1 }
            return CGFloat(max(0, min(1, (holdDuration - elapsed) / fadeWindow)))
        }
    }

    static let defaultGlideDuration: TimeInterval = 0.28

    let start: CGPoint
    let end: CGPoint
    let began: TimeInterval
    let duration: TimeInterval
    let arcOffset: CGFloat

    init(start: CGPoint, end: CGPoint, began: TimeInterval, duration: TimeInterval = 0.25, arcOffset: CGFloat = 0) {
        self.start = start
        self.end = end
        self.began = began
        self.duration = max(0.001, duration)
        self.arcOffset = arcOffset
    }

    /// Deterministic lateral quadratic Bézier control offset for organic curved cursor swoops
    /// (always zero during active `drag` so slider drags remain dead-straight).
    static func deterministicArcOffset(slot: Int, start: CGPoint, end: CGPoint, isDrag: Bool = false) -> CGFloat {
        guard !isDrag else { return 0 }
        let dist = hypot(end.x - start.x, end.y - start.y)
        guard dist >= 22 else { return 0 }
        let hashSeed = abs(slot &* 31 &+ Int(start.x.rounded()) &* 7 &+ Int(end.y.rounded()) &* 13)
        let sign: CGFloat = (hashSeed % 2 == 0) ? 1 : -1
        let ratio: CGFloat = 0.20 + CGFloat(abs(slot) % 4) * 0.035
        return sign * min(68, max(14, dist * ratio))
    }

    func point(at now: TimeInterval) -> CGPoint {
        let t = min(1, max(0, (now - began) / duration))
        let ease = 1 - pow(1 - t, 3)
        let lx = start.x + (end.x - start.x) * ease
        let ly = start.y + (end.y - start.y) * ease
        guard abs(arcOffset) > 0.01 else {
            return CGPoint(x: lx, y: ly)
        }
        let dist = hypot(end.x - start.x, end.y - start.y)
        guard dist >= 1 else {
            return CGPoint(x: lx, y: ly)
        }
        let nx = -(end.y - start.y) / dist
        let ny = (end.x - start.x) / dist
        let bow = CGFloat(2 * ease * (1 - ease)) * arcOffset
        return CGPoint(x: lx + nx * bow, y: ly + ny * bow)
    }

    /// 5-dot fading comet trail sampled behind the moving cursor tip.
    func cometTrail(at now: TimeInterval, count: Int = 5) -> [CometDot] {
        guard count > 0, now >= began else { return [] }
        let settleAfter = 0.08
        let elapsed = now - began
        guard elapsed < duration + settleAfter else { return [] }
        let totalDistance = hypot(end.x - start.x, end.y - start.y)
        guard totalDistance >= 8 else { return [] }
        let head = point(at: now)
        let tailFade: CGFloat = elapsed <= duration ? 1 : CGFloat(max(0, 1 - (elapsed - duration) / settleAfter))
        guard tailFade > 0.01 else { return [] }
        var dots: [CometDot] = []
        dots.reserveCapacity(count)
        for index in 1...count {
            let sampleTime = max(began, now - Double(index) * 0.024)
            let sample = point(at: sampleTime)
            if hypot(sample.x - head.x, sample.y - head.y) < 2.5 { continue }
            let fraction = CGFloat(index - 1) / CGFloat(max(1, count - 1))
            let radius = 4.6 - 2.6 * fraction
            let alpha = (0.56 - 0.42 * fraction) * tailFade
            dots.append(CometDot(point: sample, radius: radius, alpha: alpha))
        }
        return dots
    }
    static func screenPoint(pixel: CGPoint, pixels: CGSize, bounds: CGRect) -> CGPoint {
        CGPoint(x: bounds.minX + pixel.x * bounds.width / pixels.width,
                y: bounds.minY + pixel.y * bounds.height / pixels.height)
    }
    // CG/AX: top-left of the primary display. AppKit: bottom-left of that display,
    // including displays to its left/above/below. NSScreen.main can change with focus.
    static func appKitRect(_ rect: CGRect, primaryHeight: CGFloat) -> CGRect {
        CGRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
    }
    static func press(at now: TimeInterval, began: TimeInterval?) -> CGFloat {
        guard let began else { return 0 }
        let t = (now - began) / 0.3
        return (0...1).contains(t) ? sin(t * .pi) : 0
    }
    static func rippleProgress(at now: TimeInterval, began: TimeInterval?) -> CGFloat? {
        guard let began else { return nil }
        let t = (now - began) / 0.35
        return (0...1).contains(t) ? CGFloat(t) : nil
    }
}

struct PermissionStatus {
    var accessibility: Bool
    var screenRecording: Bool
    var reconnect: Bool = false
    var ready: Bool { accessibility && screenRecording && !reconnect }
}

enum SwarmAgentMode: String, Equatable {
    case orbit
    case glide
    case click
    case drag
    case ripple
    case dismiss

    static func parse(_ raw: String?) -> SwarmAgentMode {
        guard let cleaned = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !cleaned.isEmpty else {
            return .glide
        }
        return SwarmAgentMode(rawValue: cleaned) ?? .glide
    }
}

/// Pure 60fps state for a single cursor in the native `swarm_dispatch` Fleet/Swarm Pool.
struct SwarmAgentState {
    static let dismissFadeDuration: TimeInterval = 0.22

    var agentId: String
    var agentName: String
    var colorHex: String
    var rgb: AgentRGB
    var slot: Int
    var mode: SwarmAgentMode
    var motion: CursorMotion
    var orbitCenter: CGPoint = .zero
    var orbitRadius: CGFloat = 84
    var orbitAngularSpeed: Double = 2.6
    var orbitPhase: Double = 0
    var orbitBegan: TimeInterval = 0
    var pressBegan: TimeInterval?
    var pendingClickAt: TimeInterval?
    var selection: CursorMotion.SelectionHighlight?
    var showTag: Bool = true
    var dismissBegan: TimeInterval?
    var lastUpdatedAt: TimeInterval
    var holdDuration: TimeInterval = 15.0
    var emitCompanion: Bool = false
    var companionConnected: Bool = false

    func orbitTarget(at time: TimeInterval) -> CGPoint {
        let elapsed = max(0, time - orbitBegan)
        let angle = orbitPhase + elapsed * orbitAngularSpeed
        let rx = orbitRadius
        let ry = orbitRadius * 0.86
        return CGPoint(
            x: orbitCenter.x + CGFloat(cos(angle)) * rx,
            y: orbitCenter.y + CGFloat(sin(angle)) * ry
        )
    }

    func point(at now: TimeInterval) -> CGPoint {
        if mode == .orbit {
            let target = orbitTarget(at: now)
            let blend = min(1, max(0, (now - orbitBegan) / 0.30))
            let ease = CGFloat(1 - pow(1 - blend, 3))
            return CGPoint(
                x: motion.start.x + (target.x - motion.start.x) * ease,
                y: motion.start.y + (target.y - motion.start.y) * ease
            )
        }
        if now < motion.began {
            return motion.start
        }
        return motion.point(at: now)
    }

    func trail(at now: TimeInterval, count: Int = 5) -> [CursorMotion.CometDot] {
        guard count > 0 else { return [] }
        if mode == .orbit {
            guard now >= orbitBegan else { return [] }
            let head = point(at: now)
            var dots: [CursorMotion.CometDot] = []
            dots.reserveCapacity(count)
            for idx in 1...count {
                let sampleTime = max(orbitBegan, now - Double(idx) * 0.028)
                let sample = point(at: sampleTime)
                if hypot(sample.x - head.x, sample.y - head.y) < 2.2 { continue }
                let fraction = CGFloat(idx - 1) / CGFloat(max(1, count - 1))
                dots.append(
                    CursorMotion.CometDot(
                        point: sample,
                        radius: 4.4 - 2.5 * fraction,
                        alpha: 0.54 - 0.40 * fraction
                    )
                )
            }
            return dots
        }
        return motion.cometTrail(at: now, count: count)
    }

    func opacity(at now: TimeInterval) -> CGFloat {
        if let dismissBegan {
            let elapsed = max(0, now - dismissBegan)
            if elapsed >= Self.dismissFadeDuration { return 0 }
            return CGFloat(max(0, 1 - elapsed / Self.dismissFadeDuration))
        }
        if mode == .orbit { return 1 }
        let idleElapsed = max(0, now - max(lastUpdatedAt, motion.began + motion.duration))
        if idleElapsed >= holdDuration { return 0 }
        let fadeWindow = 0.35
        if idleElapsed <= holdDuration - fadeWindow { return 1 }
        return CGFloat(max(0, (holdDuration - idleElapsed) / fadeWindow))
    }

    mutating func advanceEffects(at now: TimeInterval) {
        if let clickAt = pendingClickAt, now >= clickAt {
            pressBegan = clickAt
            pendingClickAt = nil
            if var sel = selection {
                sel.began = clickAt
                selection = sel
            }
        }
    }
}
