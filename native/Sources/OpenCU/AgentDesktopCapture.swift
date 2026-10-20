import AppKit
import ScreenCaptureKit
import CoreMedia
import CoreImage

/// Screen-only preview of the owned display. Normal window screenshots keep their
/// independent exact-window path in MacObserver. No picker, recording or fallback.
@MainActor
final class AgentDesktopCapture: NSObject, SCStreamOutput, SCStreamDelegate {
    private var stream: SCStream?
    private var generation = 0
    private var stopping = false
    private final class StopResult {
        var completed = false
        var failure: String?
    }
    private var stopResult: StopResult?

    /// SCK callbacks may outlive cancellation. Waiting is bounded and never keeps
    /// the native control lane hostage to a shareable-content/start callback.
    private func bounded<T>(_ begin: (@escaping (Result<T, Error>) -> Void) -> Void) async throws -> T {
        var outcome: Result<T, Error>?
        begin { result in Task { @MainActor in outcome = result } }
        let deadline = ProcessInfo.processInfo.systemUptime + 10
        while outcome == nil {
            try Task.checkCancellation()
            guard ProcessInfo.processInfo.systemUptime < deadline else {
                throw OpenCUError("AGENT_DESKTOP_UNAVAILABLE", "Preview capture setup timed out. No reconnect was attempted.")
            }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        try Task.checkCancellation()
        return try outcome!.get()
    }
    private(set) var frames = 0
    private(set) var running = false
    var onFrame: ((CGImage) -> Void)?
    var onFailure: ((OpenCUError) -> Void)?
    var mayDisplayFrame: (() -> Bool)?
    private let queue = DispatchQueue(label: "dev.opencu.agent-desktop.preview")
    nonisolated private let context = CIContext(options: [.cacheIntermediates: false])

    func start(displayID: CGDirectDisplayID) async throws {
        try EngineResponsibility.requireCapture()
        frames = 0; stopping = false; stopResult = nil
        let content: SCShareableContent = try await bounded { complete in
            SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: false) { content, error in
                if let error { complete(.failure(error)) }
                else if let content { complete(.success(content)) }
                else { complete(.failure(OpenCUError("SCREENSHOT_UNAVAILABLE", "No capture content was returned."))) }
            }
        }
        try Task.checkCancellation()
        try EngineResponsibility.requireCapture()
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            throw OpenCUError("AGENT_DESKTOP_UNAVAILABLE", "The owned virtual display is not available for preview capture.")
        }
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let configuration = SCStreamConfiguration()
        configuration.width = display.width
        configuration.height = display.height
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 10)
        configuration.queueDepth = 3
        configuration.capturesAudio = false
        configuration.showsCursor = false
        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        self.stream = stream
        generation += 1
        let epoch = generation
        try EngineResponsibility.requireCapture()
        try await bounded { (complete: @escaping (Result<Void, Error>) -> Void) in
            stream.startCapture { error in
                Task { @MainActor [weak self] in
                    // A cancelled start may complete late; never leave that stream running.
                    if self?.generation != epoch { stream.stopCapture(completionHandler: nil) }
                    if let error { complete(.failure(error)) } else { complete(.success(())) }
                }
            }
        }
        guard epoch == generation else { throw CancellationError() }
        running = true
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        while frames == 0 {
            try Task.checkCancellation()
            guard running, ProcessInfo.processInfo.systemUptime < deadline else {
                throw OpenCUError("AGENT_DESKTOP_LOST", "Agent desktop preview did not deliver a valid frame.")
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
    }
    func stop() async -> String? {
        generation += 1; running = false; stopping = true
        guard let old = stream else { return nil }
        let result: StopResult
        if let previous = stopResult { result = previous }
        else {
            result = StopResult(); stopResult = result
            old.stopCapture { error in
                Task { @MainActor in result.failure = error?.localizedDescription; result.completed = true }
            }
        }
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        while !result.completed && ProcessInfo.processInfo.systemUptime < deadline {
            try? await Task.sleep(nanoseconds: 25_000_000)
        }
        guard result.completed else { return "Preview stream stop was not confirmed within three seconds." }
        if let failure = result.failure { return failure }
        try? old.removeStreamOutput(self, type: .screen)
        stream = nil
        return nil
    }
    nonisolated func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let status = attachments.first?[.status] as? Int, status == SCFrameStatus.complete.rawValue,
              let buffer = sampleBuffer.imageBuffer else { return }
        let source = CIImage(cvPixelBuffer: buffer)
        // Local preview only: no encoding, files or MCP image delivery.
        let ratio = min(1, 960 / source.extent.width)
        let scaled = source.transformed(by: CGAffineTransform(scaleX: ratio, y: ratio))
        guard let image = context.createCGImage(scaled, from: scaled.extent) else { return }
        Task { @MainActor [weak self] in
            guard let self, !self.stopping, self.stream === stream, self.mayDisplayFrame?() == true else { return }
            self.frames += 1
            self.onFrame?(image)
        }
    }
    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        Task { @MainActor [weak self] in
            guard let self, !self.stopping, self.stream === stream else { return }
            self.running = false
            self.onFailure?(OpenCUError("AGENT_DESKTOP_LOST", "Agent desktop preview stopped: \(error.localizedDescription)"))
        }
    }
}
