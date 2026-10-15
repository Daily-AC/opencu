import AppKit
import ApplicationServices

@MainActor
final class AgentDisplay {
    private var display: AnyObject?
    private var ledger = AgentDisplayLedger()
    private var target: (app: TargetApp, window: AXUIElement)?
    private var requestedFrame: CGRect?
    private var baseline: [Display] = []
    private var scale = 1

    struct Display: Equatable {
        let id: CGDirectDisplayID
        let frame: CGRect
        let main: Bool
        let mirrored: Bool
        var json: Arguments {
            ["id": id, "frame": agentDisplayRectJSON(frame), "main": main, "mirrored": mirrored,
             "pixelWidth": CGDisplayCopyDisplayMode(id)?.pixelWidth ?? 0,
             "pixelHeight": CGDisplayCopyDisplayMode(id)?.pixelHeight ?? 0]
        }
    }

    private func displays() throws -> [Display] {
        var ids = [CGDirectDisplayID](repeating: 0, count: 64), count: UInt32 = 0
        guard CGGetOnlineDisplayList(UInt32(ids.count), &ids, &count) == .success, count < ids.count else {
            throw OpenCUError("AGENT_DISPLAY_STATUS_FAILED", "Could not enumerate all online displays.")
        }
        return ids.prefix(Int(count)).map {
            Display(id: $0, frame: CGDisplayBounds($0), main: $0 == CGMainDisplayID(), mirrored: CGDisplayIsInMirrorSet($0) != 0)
        }.sorted { $0.id < $1.id }
    }

    // No titles or app inventories in the response. These bounds allow the probe
    // to detect collateral movement without ever changing another window.
    private func windowFrames() throws -> [Arguments] {
        guard let records = CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as? [Arguments] else {
            throw OpenCUError("AGENT_DISPLAY_STATUS_FAILED", "WindowServer window frames are unavailable; collateral movement cannot be checked.")
        }
        return records.compactMap { record in
            guard let layer = record[kCGWindowLayer as String] as? Int,
                  [0, Int(CGWindowLevelForKey(.dockWindow)), Int(CGWindowLevelForKey(.mainMenuWindow))].contains(layer),
                  let id = record[kCGWindowNumber as String] as? UInt32,
                  let pid = record[kCGWindowOwnerPID as String] as? Int,
                  let dictionary = record[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: dictionary as CFDictionary) else { return nil }
            return ["id": id, "pid": pid, "layer": layer, "frame": agentDisplayRectJSON(rect)]
        }
    }

    func status() throws -> Arguments {
        let current = try displays()
        var result: Arguments = ["displays": current.map(\.json), "windowFrames": try windowFrames(),
                                 "restorePending": ledger.restorePending, "backingScale": scale,
                                 "agentDisplayID": ledger.displayID.map { $0 as Any } ?? NSNull()]
        if let requestedFrame { result["requestedFrame"] = agentDisplayRectJSON(requestedFrame) }
        if let agent = current.first(where: { $0.id == ledger.displayID }) {
            result["actualFrame"] = agentDisplayRectJSON(agent.frame)
            result["placementAdjustedByOS"] = requestedFrame != agent.frame
        }
        if let saved = ledger.saved, let target {
            let rect = !target.app.application.isTerminated ? axRect(target.window) : nil
            let record = (CGWindowListCopyWindowInfo(.optionIncludingWindow, saved.windowID) as? [Arguments])?
                .first { ($0[kCGWindowNumber as String] as? UInt32) == saved.windowID
                    && ($0[kCGWindowOwnerPID as String] as? Int32) == target.app.pid }
            var info: Arguments = ["pid": target.app.pid, "windowID": saved.windowID,
                                   "originalDisplayID": saved.displayID, "originalFrame": agentDisplayRectJSON(saved.frame),
                                   "frame": rect.map { agentDisplayRectJSON($0) as Any } ?? NSNull(),
                                   "windowServerOnScreen": record?[kCGWindowIsOnscreen as String] ?? NSNull(),
                                   "displayIDs": rect.map { rect in current.filter { $0.frame.intersects(rect) }.map(\.id) } ?? []]
            if let dictionary = record?[kCGWindowBounds as String] as? NSDictionary,
               let frame = CGRect(dictionaryRepresentation: dictionary as CFDictionary) {
                info["windowServerFrame"] = agentDisplayRectJSON(frame)
            }
            result["target"] = info
        }
        return result
    }

    func create() async throws -> Arguments {
        try requireAccessibility()
        guard display == nil, ledger.displayID == nil, !ledger.restorePending else {
            throw OpenCUError("AGENT_DISPLAY_BUSY", "Restore and destroy the previous display first.")
        }
        baseline = try displays()
        guard let main = baseline.first(where: \.main), !baseline.contains(where: \.mirrored),
              let screen = NSScreen.screens.first(where: { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32) == main.id }),
              [CGFloat(1), CGFloat(2)].contains(screen.backingScaleFactor) else {
            throw OpenCUError("AGENT_DISPLAY_UNSUPPORTED_LAYOUT", "A non-mirrored main display with 1x or 2x backing scale is required.")
        }
        scale = Int(screen.backingScaleFactor)
        requestedFrame = try AgentDisplayGeometry.placement(main: main.frame,
            others: baseline.filter { !$0.main }.map(\.frame), size: CGSize(width: 1728, height: 1117))
        let windowsBefore = try windowFrames()
        target = nil
        do {
            // Keep the sole owning reference in this controller. Do not let an
            // async local extend its lifetime past destroy's release.
            try autoreleasepool {
                let created = try AgentDisplaySPI.create(scale: scale)
                display = created.object
                try ledger.created(created.id)
            }
            try await settle { try self.displays().contains { $0.id == self.ledger.displayID } }
            guard try displays().filter({ $0.id != ledger.displayID }) == baseline else {
                throw OpenCUError("AGENT_DISPLAY_LAYOUT_CHANGED", "Creating the display changed an existing display. Removing the agent display.")
            }
            var config: CGDisplayConfigRef?
            guard CGBeginDisplayConfiguration(&config) == .success, let config else {
                throw OpenCUError("AGENT_DISPLAY_CONFIG_FAILED", "Could not begin display configuration.")
            }
            let point = requestedFrame!.origin
            let configured = CGConfigureDisplayOrigin(config, ledger.displayID!, Int32(point.x), Int32(point.y))
            guard configured == .success else {
                CGCancelDisplayConfiguration(config)
                throw OpenCUError("AGENT_DISPLAY_CONFIG_FAILED", "CoreGraphics refused the agent display origin: \(configured.rawValue).")
            }
            guard CGCompleteDisplayConfiguration(config, .forSession) == .success else {
                throw OpenCUError("AGENT_DISPLAY_CONFIG_FAILED", "Could not apply the session-only display arrangement.")
            }
            try await Task.sleep(nanoseconds: 500_000_000)
            let current = try displays()
            guard current.filter({ $0.id != ledger.displayID }) == baseline,
                  let agent = current.first(where: { $0.id == ledger.displayID }), !agent.main, !agent.mirrored,
                  agent.frame.size == CGSize(width: 1728, height: 1117),
                  NSScreen.screens.first(where: { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32) == agent.id })?.backingScaleFactor == CGFloat(scale),
                  !baseline.contains(where: { let i = $0.frame.intersection(agent.frame); return !i.isNull && i.width > 0 && i.height > 0 }) else {
                throw OpenCUError("AGENT_DISPLAY_LAYOUT_CHANGED", "macOS changed the original layout, main display, mirroring, or requested logical size.")
            }
            let after = try windowFrames()
            for before in windowsBefore {
                if let now = after.first(where: { ($0["id"] as? UInt32) == (before["id"] as? UInt32) && ($0["pid"] as? Int) == (before["pid"] as? Int) }),
                   (now["frame"] as? [String: Double]) != (before["frame"] as? [String: Double]) {
                    throw OpenCUError("AGENT_DISPLAY_WINDOW_CHANGED", "WindowServer reports another window moved during display creation.")
                }
            }
            return try status()
        } catch {
            let cleanup = await destroy()
            throw OpenCUError((error as? OpenCUError)?.code ?? "AGENT_DISPLAY_CREATE_FAILED",
                              "\(error.localizedDescription) Cleanup: \(cleanup)")
        }
    }

    func moveWindow(_ app: TargetApp) async throws -> Arguments {
        try requireAccessibility()
        guard let id = ledger.displayID, let agent = try displays().first(where: { $0.id == id }), !agent.main else {
            throw OpenCUError("AGENT_DISPLAY_REQUIRED", "Create an agent display first.")
        }
        let root = AXUIElementCreateApplication(app.pid)
        guard let window = axSelectedWindow(root), axString(window, kAXRoleAttribute) == kAXWindowRole,
              (axValue(window, kAXMinimizedAttribute) as? Bool) != true,
              (axValue(window, "AXFullScreen") as? Bool) != true,
              let frame = axRect(window), AgentDisplayGeometry.valid(frame),
              let windowID = exactWindowID(window, pid: app.pid) else {
            throw OpenCUError("AGENT_DISPLAY_WINDOW_UNAVAILABLE", "Select an ordinary, non-minimized, non-full-screen app window with an exact WindowServer identity.")
        }
        guard let originalDisplay = try displays().filter({ $0.id != id }).max(by: {
            area($0.frame.intersection(frame)) < area($1.frame.intersection(frame))
        }), area(originalDisplay.frame.intersection(frame)) > 0 else {
            throw OpenCUError("AGENT_DISPLAY_WINDOW_UNAVAILABLE", "The selected window is not on an original display.")
        }
        let destination = try AgentDisplayGeometry.destination(original: frame, display: agent.frame)
        try ledger.remember(.init(windowID: windowID, displayID: originalDisplay.id, frame: frame))
        target = (app, window)
        // On partial failure the original record survives for restore/destroy.
        try setFrame(window, destination)
        try await settle { axRect(window).map { AgentDisplayGeometry.close($0, destination) } ?? false }
        return try status()
    }

    func restore() async throws -> Arguments {
        guard ledger.restorePending, let saved = ledger.saved, let target else { return try status() }
        // Never resolve a replacement window by title, PID reuse, or selection.
        if target.app.application.isTerminated { ledger.restored(); return try status() }
        guard axWindows(AXUIElementCreateApplication(target.app.pid)).contains(where: { CFEqual($0, target.window) }),
              exactWindowID(target.window, pid: target.app.pid) == saved.windowID else {
            throw OpenCUError("AGENT_DISPLAY_TARGET_LOST", "Original target no longer exists or its identity cannot be verified; no replacement window was moved.")
        }
        guard try displays().contains(where: { $0.id == saved.displayID }) else {
            throw OpenCUError("AGENT_DISPLAY_ORIGINAL_DISPLAY_MISSING", "Original display is disconnected; no fallback placement was attempted.")
        }
        try setFrame(target.window, saved.frame)
        try await settle { axRect(target.window).map { AgentDisplayGeometry.close($0, saved.frame) } ?? false }
        ledger.restored()
        return try status()
    }

    /// Always release, even if AX restoration fails. Report errors; do not hide a
    /// failed restoration or keep an invisible display alive awaiting the caller.
    func destroy() async -> Arguments {
        var errors: [String] = []
        let removedID = ledger.displayID
        for step in ledger.cleanupSteps {
            switch step {
            case .restore:
                do { _ = try await restore() } catch { errors.append(error.localizedDescription) }
            case .releaseDisplay:
                autoreleasepool { display = nil }
            }
        }
        if let removedID {
            do {
                try await settle { try !self.displays().contains { $0.id == removedID } }
                ledger.released()
            }
            catch { errors.append("Display removal was not observed: \(error.localizedDescription)") }
        }
        var result: Arguments = [:]
        do { result = try status() }
        catch { errors.append("Cleanup status unavailable: \(error.localizedDescription)") }
        result["cleanupErrors"] = errors
        result["ok"] = errors.isEmpty
        return result
    }

    private func area(_ rect: CGRect) -> Double { rect.isNull ? 0 : rect.width * rect.height }
    private func settle(_ check: () throws -> Bool) async throws {
        for _ in 0..<40 {
            if try check() { return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        throw OpenCUError("AGENT_DISPLAY_TIMEOUT", "The requested display/window state did not settle within two seconds.")
    }
    private func setFrame(_ window: AXUIElement, _ frame: CGRect) throws {
        var point = frame.origin, size = frame.size
        // Position first so the old display's bounds do not clamp a larger size.
        for (attribute, value) in [(kAXPositionAttribute, AXValueCreate(.cgPoint, &point)),
                                   (kAXSizeAttribute, AXValueCreate(.cgSize, &size)),
                                   (kAXPositionAttribute, AXValueCreate(.cgPoint, &point))] {
            guard let value else { throw OpenCUError("AGENT_DISPLAY_AX_FAILED", "Cannot encode AX frame.") }
            let result = AXUIElementSetAttributeValue(window, attribute as CFString, value)
            guard result == .success else {
                throw OpenCUError("AGENT_DISPLAY_AX_FAILED", "\(attribute) failed: \(result.rawValue). Original frame remains recorded for cleanup.")
            }
        }
    }
    private func exactWindowID(_ window: AXUIElement, pid: pid_t) -> CGWindowID? {
        var owner: pid_t = 0
        guard AXUIElementGetPid(window, &owner) == .success, owner == pid,
              let library = dlopen("/System/Library/Frameworks/ApplicationServices.framework/Frameworks/HIServices.framework/HIServices", RTLD_LAZY | RTLD_LOCAL) else { return nil }
        defer { dlclose(library) }
        guard let symbol = dlsym(library, "_AXUIElementGetWindow") else { return nil }
        typealias GetWindow = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> Int32
        var id: CGWindowID = 0
        return unsafeBitCast(symbol, to: GetWindow.self)(window, &id) == 0 && id != 0 ? id : nil
    }
}
