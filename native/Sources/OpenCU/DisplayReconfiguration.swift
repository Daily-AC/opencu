import CoreGraphics
import Foundation

/// Subscribe before creating a virtual display and retain the subscription until
/// its owner exits. Apple documents that CG state is current at the completion
/// callback. Do not configure displays inside this callback.
final class DisplayReconfiguration {
    private let lock = NSLock()
    private var events: [Arguments] = []
    private var registered = false

    private static let callback: CGDisplayReconfigurationCallBack = { id, flags, context in
        guard let context else { return }
        let observer = Unmanaged<DisplayReconfiguration>.fromOpaque(context).takeUnretainedValue()
        observer.lock.lock()
        defer { observer.lock.unlock() }
        observer.events.append(["displayID": id, "flags": flags.rawValue,
                                "begin": flags.contains(.beginConfigurationFlag),
                                "added": flags.contains(.addFlag), "removed": flags.contains(.removeFlag),
                                "uptimeMs": ProcessInfo.processInfo.systemUptime * 1000,
                                "mainThread": Thread.isMainThread])
        if observer.events.count > 256 { observer.events.removeFirst(observer.events.count - 256) }
    }

    func start() throws {
        guard !registered else { return }
        let result = CGDisplayRegisterReconfigurationCallback(Self.callback, Unmanaged.passUnretained(self).toOpaque())
        guard result == .success else {
            throw OpenCUError("AGENT_DISPLAY_NOTIFICATION_FAILED", "Cannot subscribe to display reconfiguration (\(result.rawValue)); no display was created.")
        }
        registered = true
    }

    func snapshot(since uptimeMs: Double = 0) -> [Arguments] {
        lock.lock()
        defer { lock.unlock() }
        return events.filter { ($0["uptimeMs"] as? Double ?? 0) >= uptimeMs }
    }

    deinit {
        if registered { CGDisplayRemoveReconfigurationCallback(Self.callback, Unmanaged.passUnretained(self).toOpaque()) }
    }
}
