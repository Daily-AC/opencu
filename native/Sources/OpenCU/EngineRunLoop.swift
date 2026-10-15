import Foundation
import CoreFoundation

/// Explicitly service CFRunLoop sources for the lifetime of the stdio engine,
/// including while creation, removal and window settling suspend in Task.sleep.
/// Async-main scheduling alone is not our display-notification contract (a
/// timer-only async-main reproducer does run; that did not reproduce CG staleness).
enum EngineRunLoop {
    @MainActor static func run(_ operation: @escaping @MainActor () async -> Void) {
        precondition(Thread.isMainThread)
        let loop = CFRunLoopGetMain()
        // Keep an otherwise idle stdio process's run loop alive without a timer.
        var context = CFRunLoopSourceContext()
        let keepAlive = CFRunLoopSourceCreate(nil, 0, &context)!
        CFRunLoopAddSource(loop, keepAlive, .defaultMode)
        defer { CFRunLoopRemoveSource(loop, keepAlive, .defaultMode) }
        var finished = false
        Task { @MainActor in
            await operation()
            finished = true
            CFRunLoopStop(loop)
        }
        while !finished { CFRunLoopRun() }
    }
}
