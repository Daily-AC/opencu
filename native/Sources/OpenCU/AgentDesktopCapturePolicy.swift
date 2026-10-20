import Foundation
import ScreenCaptureKit

/// Pure lifecycle/error policy, also tested without constructing a stream.
struct AgentDesktopCapturePolicy {
    enum Phase { case idle, starting, running, stopped }
    private(set) var phase: Phase = .idle
    mutating func begin() { phase = .starting }
    /// A late successful start still needs teardown, never admission to a new lifetime.
    mutating func started() -> Bool {
        guard phase == .starting else { return false }
        phase = .running
        return true
    }
    mutating func stopped() { phase = .stopped }
    mutating func requestStop() -> Bool {
        let needsStop = phase == .running
        phase = .stopped
        return needsStop
    }
    static func personStopped(_ error: Error) -> Bool {
        let value = error as NSError
        return value.domain == SCStreamErrorDomain && value.code == SCStreamError.userStopped.rawValue
    }
    static func alreadyStopped(_ error: Error) -> Bool {
        let value = error as NSError
        return value.domain == SCStreamErrorDomain && value.code == SCStreamError.attemptToStopStreamState.rawValue
    }
    static func previewSize(width: Int, height: Int) -> (width: Int, height: Int) {
        let ratio = min(1, 960 / Double(max(1, width)))
        return (max(1, Int(Double(width) * ratio)), max(1, Int(Double(height) * ratio)))
    }
}
