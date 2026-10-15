import Foundation
import Darwin
import CoreGraphics

/// Pure policy. A spawn marker is not evidence of the OS's responsible process.
enum CaptureSafety {
    static func requireVerifiedEngine(respawned: Bool, pid: Int32, responsiblePID: Int32?) throws {
        guard respawned, pid > 0, responsiblePID == pid else {
            throw OpenCUError("CAPTURE_RESPONSIBILITY_UNVERIFIED",
                "Screen capture refused before ScreenCaptureKit: OpenCU has not verified its disclaimed responsibility (pid \(pid), responsible PID \(responsiblePID.map(String.init) ?? "unavailable")). No capture or permission request was made.")
        }
    }

    static func requireNoninteractiveCapture(osMajorVersion: Int, screenRecordingGranted: Bool) throws {
        guard screenRecordingGranted else {
            throw OpenCUError("SCREEN_RECORDING_PERMISSION_REQUIRED", "Screenshots need OpenCU's Screen Recording grant. Use opencu setup explicitly; no permission request was made by capture.")
        }
        // Preflight checks TCC, not the periodic private-picker bypass reminder.
        // No supported API establishes that a direct SCK capture will not prompt
        // on these systems. Do not invoke even shareable-content enumeration.
        guard osMajorVersion == 14 else {
            throw OpenCUError("CAPTURE_REQUIRES_INTERACTIVE_AUTHORIZATION",
                "Background screenshots are disabled on macOS \(osMajorVersion): direct ScreenCaptureKit access can show the private-window-picker bypass prompt even with Screen Recording granted. No capture API was called. Text-only observation and indexed actions remain available; a verified non-prompting capture route is required.")
        }
    }
}

enum EngineResponsibility {
    // Set only in the respawn branch; independently corroborated by the OS.
    static var respawned = false

    static func responsiblePID() -> pid_t? {
        guard let library = dlopen("/usr/lib/system/libquarantine.dylib", RTLD_LAZY | RTLD_LOCAL) else { return nil }
        defer { dlclose(library) }
        guard let symbol = dlsym(library, "responsibility_get_pid_responsible_for_pid") else { return nil }
        typealias GetResponsiblePID = @convention(c) (pid_t) -> pid_t
        let result = unsafeBitCast(symbol, to: GetResponsiblePID.self)(getpid())
        return result > 0 ? result : nil
    }

    static var verified: Bool { respawned && responsiblePID() == getpid() }
    static var json: Arguments {
        ["pid": getpid(), "responsiblePID": responsiblePID().map { $0 as Any } ?? NSNull(),
         "respawnMarkerSeen": respawned, "verifiedSelfResponsible": verified,
         "capturePolicy": ProcessInfo.processInfo.operatingSystemVersion.majorVersion == 14
            ? "verified-engine-and-existing-grant" : "refuse-before-ScreenCaptureKit-private-picker-risk"]
    }

    static func requireCapture() throws {
        do {
            try CaptureSafety.requireVerifiedEngine(respawned: respawned, pid: getpid(), responsiblePID: responsiblePID())
            try CaptureSafety.requireNoninteractiveCapture(osMajorVersion: ProcessInfo.processInfo.operatingSystemVersion.majorVersion,
                                                          screenRecordingGranted: CGPreflightScreenCaptureAccess())
        } catch let error as OpenCUError {
            throw OpenCUError(error.code, error.message, details: ["captureContext": json])
        }
    }
}
