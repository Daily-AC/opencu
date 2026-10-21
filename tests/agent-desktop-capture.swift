import Foundation
import ScreenCaptureKit

@main
struct CapturePolicyChecks {
    static func main() {
        var checks = 0
        func expect(_ condition: Bool, _ message: String) {
            precondition(condition, message)
            checks += 1
        }
        var preview = AgentDesktopCapturePolicy()
        expect(!preview.requestStop(), "Never-started preview needs no stopCapture")
        preview.begin(); preview.stopped()
        expect(!preview.requestStop(), "Terminal stream loss cleans up without stopping again")
        preview.begin(); expect(preview.started(), "Start admits one stream")
        expect(preview.requestStop() && !preview.requestStop(), "Repeated stop never repeats completed capture teardown")
        preview.begin(); _ = preview.requestStop()
        expect(!preview.started(), "Late start after cancellation must be torn down")
        let alreadyStopped = NSError(domain: SCStreamErrorDomain, code: SCStreamError.attemptToStopStreamState.rawValue)
        expect(AgentDesktopCapturePolicy.alreadyStopped(alreadyStopped), "Already-stopped SCK error is terminal success")
        expect(AgentDesktopCapturePolicy.personStopped(NSError(domain: SCStreamErrorDomain, code: SCStreamError.userStopped.rawValue)), "System stop sharing is a person stop")
        expect(!AgentDesktopCapturePolicy.personStopped(NSError(domain: SCStreamErrorDomain, code: SCStreamError.internalError.rawValue)), "Other capture failures remain desktop loss")
        // Use the SDK's actual domain rather than assuming its spelling.
        expect(!AgentDesktopCapturePolicy.personStopped(NSError(domain: "unrelated", code: -3817)), "Other domains cannot forge a person-stop classification")
        let previewSize = AgentDesktopCapturePolicy.previewSize(width: 3456, height: 2234)
        expect(previewSize.width == 960 && previewSize.height == 620, "Preview capture is bounded before delivery, preserving aspect ratio")
        expect(AgentDesktopCapturePolicy.previewSize(width: 640, height: 480).width == 640, "Small previews are not upscaled")
        let full = AgentDesktopCapturePolicy.previewSize(width: 3456, height: 2234, fit: CGSize(width: 3456, height: 2160))
        expect(full.height == 2160 && full.width == 3341, "A full-screen preview follows the visible pixels, preserving aspect ratio")
        expect(AgentDesktopCapturePolicy.previewSize(width: 3456, height: 2234, fit: CGSize(width: 7000, height: 5000)).width == 3456, "The preview never exceeds the display's own pixels")
        print("\(checks) preview lifecycle/error/size checks passed; no capture or GUI access")
    }
}
