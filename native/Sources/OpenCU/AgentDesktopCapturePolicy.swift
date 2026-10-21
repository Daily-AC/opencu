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
    /// Fits the stream to the pixels the person is looking at, keeping the aspect
    /// ratio. Never above the display's own pixels; a small window stays cheap.
    static func previewSize(width: Int, height: Int,
                            fit: CGSize = CGSize(width: 960, height: CGFloat.greatestFiniteMagnitude)) -> (width: Int, height: Int) {
        let ratio = min(1, Double(fit.width) / Double(max(1, width)), Double(fit.height) / Double(max(1, height)))
        return (max(1, Int(Double(width) * ratio)), max(1, Int(Double(height) * ratio)))
    }
}
