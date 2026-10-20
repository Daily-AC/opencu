import Foundation

/// The person decision is scoped to one exact window and desktop lifetime.
/// No UI, AX, clock, or display access: the production controller supplies time.
struct AgentDesktopConsent {
    struct Request: Equatable {
        let token: UUID
        let window: String
        let deadline: TimeInterval
    }
    private(set) var pending: Request?
    private(set) var reduced: [String: String] = [:]

    mutating func begin(window: String, now: TimeInterval) throws -> Request? {
        if reduced[window] != nil { return nil }
        guard pending == nil else {
            throw OpenCUError("AGENT_DISPLAY_BUSY", "Another window consent is pending.")
        }
        let request = Request(token: UUID(), window: window, deadline: now + 60)
        pending = request
        return request
    }
    mutating func decide(token: UUID, approve: Bool, now: TimeInterval) -> Bool {
        guard let request = pending, request.token == token else { return false }
        pending = nil
        if now >= request.deadline { reduced[request.window] = "expired"; return false }
        if !approve { reduced[request.window] = "declined" }
        return approve
    }
    mutating func cancel() { pending = nil }
    mutating func returned(_ window: String) { reduced[window] = "returned_externally" }
}

enum AgentDesktopPhase: String {
    case inactive, starting, running, stopping, stopped, failed
}

struct AgentDesktopState {
    private(set) var phase: AgentDesktopPhase = .inactive
    private(set) var stoppedByPerson = false
    private(set) var generation = 0
    private(set) var parentLocked = false
    var ownsDesktop: Bool { phase != .inactive }
    var ready: Bool { phase == .running && !stoppedByPerson && !parentLocked }

    mutating func change(_ phase: AgentDesktopPhase) {
        self.phase = stoppedByPerson ? .stopped : phase
        invalidate()
    }
    mutating func stopByPerson() { stoppedByPerson = true; change(.stopped) }
    mutating func lock(_ locked: Bool) -> Bool {
        guard locked != parentLocked else { return false }
        parentLocked = locked
        invalidate()
        return true
    }
    mutating func invalidate() { generation += 1 }
    static var stopError: OpenCUError {
        OpenCUError("STOPPED_BY_PERSON", "The person stopped this agent desktop connection. Only status and cleanup remain available. Never restart or reconnect without explicit permission.")
    }
    func requireGeneration(_ observed: Int) throws {
        guard observed == generation else { throw OpenCUError("OBSERVATION_REQUIRED", "The desktop changed during observation. Read fresh state before input.") }
    }
    func requireRunning() throws {
        if stoppedByPerson { throw Self.stopError }
        if parentLocked { throw OpenCUError("SCREEN_LOCKED", "macOS is locked. No agent desktop input or screenshot is allowed.") }
        guard phase == .running else {
            throw OpenCUError("AGENT_DESKTOP_UNAVAILABLE", "Agent desktop is \(phase.rawValue). Finish cleanup before continuing.")
        }
    }
}


/// Move eligibility is distinct from read eligibility and existing-display admission.
enum AgentDesktopAdmissionPolicy {
    static func usableWindow(role: String?, minimized: Bool, fullScreen: Bool, onDisplay: Bool) -> Bool {
        !minimized && !fullScreen && (role == "AXWindow" || onDisplay && role == "AXSheet")
    }
    static func readBounds(_ measured: CGRect?, reduced: Bool) throws -> CGRect {
        if let measured { return measured }
        if reduced { return .zero }
        throw OpenCUError("WINDOW_BOUNDS_UNAVAILABLE", "The selected window does not expose usable Accessibility bounds. Read a visible window before input.")
    }
    enum Choice: Equatable { case admitted, inheritProcess, askMove, askUse, reduced }
    static func choice(admitted: Bool, onDisplay: Bool, sameProcess: Bool, sticky: Bool, explicit: Bool) -> Choice {
        if admitted { return .admitted }
        if sticky { return .reduced }
        if onDisplay && sameProcess { return .inheritProcess }
        guard explicit else { return .reduced }
        return onDisplay ? .askUse : .askMove
    }
    static func reducedReason(_ error: OpenCUError) -> String? {
        let codes: Set<String> = ["AGENT_DISPLAY_UNSUPPORTED_WINDOW", "AGENT_DISPLAY_AX_BOUNDS_UNAVAILABLE",
            "AGENT_DISPLAY_WINDOW_ID_UNAVAILABLE", "AGENT_DISPLAY_AMBIGUOUS_WINDOW", "AGENT_DISPLAY_ORIGINAL_DISPLAY_MISSING"]
        return codes.contains(error.code) ? error.code : nil
    }
    static func requireSnapshot(admitted: Bool, fresh: Bool) throws {
        if !admitted { throw OpenCUError("AGENT_DESKTOP_CONSENT_REQUIRED", "This window has not been admitted on the agent display. No input was sent.") }
        if !fresh { throw OpenCUError("OBSERVATION_REQUIRED", "This window is admitted, but its observation is stale. Read fresh state before input.") }
    }
    static func tearsDownDesktop(_ code: String) -> Bool {
        !["AGENT_DISPLAY_PERSON_ACTIVE", "SCREEN_LOCKED"].contains(code)
    }
}


/// Bounded native queue bookkeeping: cancellation can precede dispatch, but never
/// transfers to a later request. IDs are registered before the tail task is queued.
struct AgentDesktopRequestQueue {
    private var queued: [String: Bool] = [:]
    mutating func enqueue(_ id: String) throws {
        guard queued[id] == nil, queued.count < 128 else {
            throw OpenCUError("INVALID_REQUEST", "Duplicate request ID or native request queue is full.")
        }
        queued[id] = false
    }
    mutating func cancel(_ id: String) { if queued[id] != nil { queued[id] = true } }
    mutating func begin(_ id: String) throws {
        if queued.removeValue(forKey: id) == true { throw CancellationError() }
    }
}


enum AgentDesktopMonitoring {
    static func batch(ids: [UInt32], cursor: inout Int, observed: UInt32?) -> [UInt32] {
        guard !ids.isEmpty else { return [] }
        let next = ids[cursor % ids.count]; cursor = (cursor + 1) % ids.count
        if let observed, observed != next, ids.contains(observed) { return [next, observed] }
        return [next]
    }
}
