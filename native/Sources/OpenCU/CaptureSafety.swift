import Foundation
import Darwin
import CoreGraphics

/// Pure policy. A spawn marker is not evidence of the OS's responsible process.
enum CaptureSafety {
    static func requireVerifiedEngine(worker: Bool, pid: Int32, responsiblePID: Int32?) throws {
        guard worker, pid > 0, responsiblePID == pid else {
            throw OpenCUError("CAPTURE_RESPONSIBILITY_UNVERIFIED",
                "Screen capture refused before ScreenCaptureKit: OpenCU has not verified its independent worker responsibility (pid \(pid), responsible PID \(responsiblePID.map(String.init) ?? "unavailable")). No capture or permission request was made.")
        }
    }

    // Preflight checks TCC only. On macOS 15+ the system may still show its periodic
    // private-picker reminder for the verified responsible app; that is expected.
    static func requireScreenRecordingGrant(_ granted: Bool) throws {
        guard granted else {
            throw OpenCUError("SCREEN_RECORDING_PERMISSION_REQUIRED", "Screenshots need OpenCU's Screen Recording grant. Use opencu setup explicitly; no permission request was made by capture.")
        }
    }
}

enum EngineResponsibility {
    // Set only after attaching the worker transport; independently corroborated by the OS.
    static var worker = false

    static func responsiblePID() -> pid_t? {
        guard let library = dlopen("/usr/lib/system/libquarantine.dylib", RTLD_LAZY | RTLD_LOCAL) else { return nil }
        defer { dlclose(library) }
        guard let symbol = dlsym(library, "responsibility_get_pid_responsible_for_pid") else { return nil }
        typealias GetResponsiblePID = @convention(c) (pid_t) -> pid_t
        let result = unsafeBitCast(symbol, to: GetResponsiblePID.self)(getpid())
        return result > 0 ? result : nil
    }

    static var verified: Bool { worker && responsiblePID() == getpid() }
    static var json: Arguments {
        ["pid": getpid(), "responsiblePID": responsiblePID().map { $0 as Any } ?? NSNull(),
         "workerMarkerSeen": worker, "launchedBy": worker ? "launchd" : "direct", "verifiedSelfResponsible": verified,
         "capturePolicy": "verified-engine-and-existing-grant"]
    }

    static func requireCapture() throws {
        do {
            try CaptureSafety.requireVerifiedEngine(worker: worker, pid: getpid(), responsiblePID: responsiblePID())
            try CaptureSafety.requireScreenRecordingGrant(CGPreflightScreenCaptureAccess())
        } catch let error as OpenCUError {
            throw OpenCUError(error.code, error.message, details: ["captureContext": json])
        }
    }
}
