// Read-only cursor sampling for the live agent-display probe. No AX, event tap,
// event posting, permission prompt, window, or application activation.
import CoreGraphics
import Foundation
import Darwin

signal(SIGPIPE, SIG_IGN)
while true {
    guard let event = CGEvent(source: nil) else { exit(2) }
    let point = event.location
    let value: [String: Double] = ["x": point.x, "y": point.y,
                                   "uptimeMs": ProcessInfo.processInfo.systemUptime * 1000]
    do {
        try FileHandle.standardOutput.write(contentsOf: JSONSerialization.data(withJSONObject: value) + Data([10]))
    } catch { exit(0) }
    Thread.sleep(forTimeInterval: 0.02)
}
