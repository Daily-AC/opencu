import AppKit
@preconcurrency import ScreenCaptureKit
import CoreMedia
import CoreVideo

/// Screen-only preview of the owned display. Normal window screenshots keep their
/// independent exact-window path in MacObserver. No picker, recording or fallback.
@MainActor
final class AgentDesktopCapture: NSObject, SCStreamOutput, SCStreamDelegate {
    private var stream: SCStream?
    private var lastStreamID: ObjectIdentifier?
    private var generation = 0
    private var stopping = false
    @MainActor private final class StopResult {
        var completed = false
        var failure: String?
    }
    private var policy = AgentDesktopCapturePolicy()

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
    var onPersonStop: (() -> Void)?
    var onFailure: ((OpenCUError) -> Void)?
    var mayDisplayFrame: (() -> Bool)?
    private let queue = DispatchQueue(label: "dev.opencu.agent-desktop.preview")

    func start(displayID: CGDirectDisplayID) async throws {
        try EngineResponsibility.requireCapture()
        frames = 0; stopping = false; policy.begin()
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
        let size = AgentDesktopCapturePolicy.previewSize(width: display.width, height: display.height)
        configuration.width = size.width
        configuration.height = size.height
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 10)
        configuration.queueDepth = 3
        configuration.capturesAudio = false
        configuration.showsCursor = false
        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        self.stream = stream
        lastStreamID = ObjectIdentifier(stream)
        generation += 1
        let epoch = generation
        try EngineResponsibility.requireCapture()
        try await bounded { (complete: @escaping (Result<Void, Error>) -> Void) in
            stream.startCapture { error in
                Task { @MainActor [weak self] in
                    // A cancelled start may complete late; never leave that stream running.
                    if self?.generation != epoch {
                        if error == nil { stream.stopCapture(completionHandler: nil) }
                    } else if error != nil { self?.policy.stopped() }
                    if let error { complete(.failure(error)) } else { complete(.success(())) }
                }
            }
        }
        guard epoch == generation, policy.started() else { throw CancellationError() }
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
        let needsStop = policy.requestStop()
        stream = nil
        defer { try? old.removeStreamOutput(self, type: .screen) }
        // Never-started, failed-start and terminal streams have no running capture.
        // A late start callback retains its own stream and stops it separately.
        guard needsStop else { return nil }
        let result = StopResult()
        old.stopCapture { error in
            Task { @MainActor in
                result.failure = error.flatMap { AgentDesktopCapturePolicy.alreadyStopped($0) ? nil : $0.localizedDescription }
                result.completed = true
            }
        }
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        while !result.completed && ProcessInfo.processInfo.systemUptime < deadline {
            try? await Task.sleep(nanoseconds: 25_000_000)
        }
        guard result.completed else { return "Preview stream stop was not confirmed within three seconds." }
        if let failure = result.failure { return failure }
        return nil
    }
    nonisolated func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let status = attachments.first?[.status] as? Int, status == SCFrameStatus.complete.rawValue,
              let buffer = sampleBuffer.imageBuffer else { return }
        // SCK already produces preview-size BGRA frames; copy only that small buffer.
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return }
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        let bytes = Data(bytes: base, count: stride * height)
        guard let provider = CGDataProvider(data: bytes as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                bytesPerRow: stride, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue).union(.byteOrder32Little),
                provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) else { return }
        Task { @MainActor [weak self] in
            guard let self, !self.stopping, self.stream === stream, self.mayDisplayFrame?() == true else { return }
            self.frames += 1
            self.onFrame?(image)
        }
    }
    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        Task { @MainActor [weak self] in
            guard let self, self.lastStreamID == ObjectIdentifier(stream) else { return }
            let personStop = AgentDesktopCapturePolicy.personStopped(error)
            // A person's stop wins even if it races a tool-initiated teardown.
            guard personStop || !self.stopping && self.stream === stream else { return }
            self.running = false
            self.policy.stopped()
            self.stream = nil
            try? stream.removeStreamOutput(self, type: .screen)
            if personStop { self.onPersonStop?(); return }
            self.onFailure?(OpenCUError("AGENT_DESKTOP_LOST", "Agent desktop preview stopped: \(error.localizedDescription)"))
        }
    }
}
