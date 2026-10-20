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
    mutating func cancel(reason: String = "cancelled") {
        if let request = pending { reduced[request.window] = reason }
        pending = nil
    }
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
    func requireRunning() throws {
        if stoppedByPerson { throw PresenceState.stopError }
        if parentLocked { throw OpenCUError("SCREEN_LOCKED", "macOS is locked. No agent desktop input or screenshot is allowed.") }
        guard phase == .running else {
            throw OpenCUError("AGENT_DESKTOP_UNAVAILABLE", "Agent desktop is \(phase.rawValue). Finish cleanup before continuing.")
        }
    }
}
