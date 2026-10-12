import AppKit
import ApplicationServices

// AppKit tracks application/key-window activation separately from WindowServer's
// foreground process. Process-targeted notifications let a background responder
// accept input without calling activate(), raising a window, or moving the cursor.
// These notification values are an OS compatibility boundary, checked against a
// real background AppKit fixture on the supported host; no target code is loaded.
@MainActor
final class BackgroundFocus {
    private let target: TargetApp
    let windowID: CGWindowID
    private let deactivate: CGEvent
    private let removeKeyFocus: CGEvent
    private let activate: CGEvent
    private let returnKeyFocus: CGEvent
    private var synthetic = false
    private var needsRefresh = true
    private var observer: NSObjectProtocol?
    var pid: pid_t { target.pid }

    init(snapshot: WindowSnapshot) throws {
        target = snapshot.app
        guard let windowID = snapshot.windowID else {
            throw OpenCUError("WINDOW_ID_UNAVAILABLE", "Background input requires the exact target window. Read its state again. No input was sent.")
        }
        self.windowID = windowID
        // Allocate cleanup events before notifying the target, so allocation
        // failure cannot leave synthetic activation behind.
        deactivate = try Self.notification(type: 13, subtype: 2)
        removeKeyFocus = try Self.notification(type: 21, subtype: 0x4000)
        activate = try Self.notification(type: 13, subtype: 1, window: windowID)
        returnKeyFocus = try Self.notification(type: 21, subtype: Int16(bitPattern: 0x8000))
        observer = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.needsRefresh = true }
        }
    }

    func refresh() -> Bool {
        if NSWorkspace.shared.frontmostApplication?.processIdentifier == target.pid {
            synthetic = false
            needsRefresh = true
            return false
        }
        guard needsRefresh else { return false }
        Self.post(activate, to: target.pid)
        Self.post(returnKeyFocus, to: target.pid)
        synthetic = true
        needsRefresh = false
        return true
    }

    func finish() {
        if let observer { NSWorkspace.shared.notificationCenter.removeObserver(observer); self.observer = nil }
        // The user may have chosen this app while the operation was running.
        // Do not deactivate a genuinely frontmost app or reuse an exited PID.
        guard synthetic, !target.application.isTerminated,
              NSWorkspace.shared.frontmostApplication?.processIdentifier != target.pid else { return }
        Self.post(removeKeyFocus, to: target.pid)
        Self.post(deactivate, to: target.pid)
        synthetic = false
    }

    private static func notification(type: UInt, subtype: Int16, window: CGWindowID = 0) throws -> CGEvent {
        guard let eventType = NSEvent.EventType(rawValue: type),
              let native = NSEvent.otherEvent(with: eventType, location: .zero,
                                              modifierFlags: type == 13 && subtype == 1 ? [.control, .option] : [],
                                              timestamp: ProcessInfo.processInfo.systemUptime,
                                              windowNumber: Int(window), context: nil,
                                              subtype: subtype, data1: 0, data2: 0),
              let event = native.cgEvent else {
            throw OpenCUError("BACKGROUND_INPUT_UNAVAILABLE", "This macOS version could not create targeted focus notifications. No input was sent.")
        }
        return event
    }

    private static func post(_ event: CGEvent, to pid: pid_t) {
        event.timestamp = DispatchTime.now().uptimeNanoseconds
        event.postToPid(pid)
    }
}
