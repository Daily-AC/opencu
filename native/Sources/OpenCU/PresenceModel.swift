import Foundation
import CoreGraphics

/// Per-connection policy, independent of AppKit and wall-clock adjustments.
struct PresenceState {
    static let inputMethods: Set<String> = ["wait", "click", "drag", "press_key", "type_text", "paste", "scroll",
                                            "set_value", "select_text", "perform_secondary_action", "activate_app"]
    private(set) var stopped = false
    private(set) var connected = true
    private(set) var target: String?
    private(set) var callInFlight = false
    private(set) var lastCall: TimeInterval?
    private(set) var lastPointer: TimeInterval?

    mutating func call(target: String, now: TimeInterval) {
        if self.target != target { lastPointer = nil }
        self.target = target
        lastCall = now
        callInFlight = true
    }
    mutating func finished(now: TimeInterval) { callInFlight = false; if lastCall != nil { lastCall = now } }
    mutating func pointer(now: TimeInterval) { if connected && !stopped { lastPointer = now } }
    mutating func hideCursor() { lastPointer = nil }
    mutating func stop() { stopped = true; hideCursor() }
    mutating func disconnect() { connected = false; lastCall = nil; hideCursor() }
    func menuVisible(at now: TimeInterval) -> Bool { connected && (callInFlight || lastCall.map { now - $0 < 15 } == true) }
    func cursorVisible(at now: TimeInterval) -> Bool { connected && !stopped && lastPointer.map { now - $0 < 3 } == true }
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
    let start: CGPoint
    let end: CGPoint
    let began: TimeInterval
    func point(at now: TimeInterval) -> CGPoint {
        let t = min(1, max(0, (now - began) / 0.25))
        let ease = 1 - pow(1 - t, 3)
        return CGPoint(x: start.x + (end.x - start.x) * ease, y: start.y + (end.y - start.y) * ease)
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
}

struct PermissionStatus {
    var accessibility: Bool
    var screenRecording: Bool
    var reconnect: Bool = false
    var ready: Bool { accessibility && screenRecording && !reconnect }
}
