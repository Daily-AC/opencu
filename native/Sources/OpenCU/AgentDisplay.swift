import AppKit
import ApplicationServices

@MainActor
final class AgentDisplay {
    private var display: AnyObject?
    private var ledger = AgentDisplayLedger()
    struct Proposal {
        let app: TargetApp
        let window: AXUIElement
        let windowID: UInt32
        let frame: CGRect
        let displayID: UInt32
        let destination: CGRect
        let title: String
        var key: String { "\(app.pid):\(app.application.launchDate?.timeIntervalSince1970 ?? 0):\(windowID)" }
    }
    private var targets: [UInt32: Proposal] = [:]
    private var admitted = Set<UInt32>()
    private var agentFrame: CGRect?
    var multipleWindows = false
    var beforeMutation: (() throws -> Void)?
    var id: UInt32? { ledger.displayID }
    var frame: CGRect? { agentFrame }
    var restorePending: Bool { ledger.restorePending }
    var savedWindows: [Arguments] { ledger.pending.map { saved in
        ["windowID": saved.windowID, "app": targets[saved.windowID]?.app.id ?? "",
         "originalFrame": agentDisplayRectJSON(saved.frame), "originalDisplayID": saved.displayID,
         "restorePending": true, "state": admitted.contains(saved.windowID) ? "admitted" : "restore_pending"]
    } }

    private var requestedFrame: CGRect?
    private var baseline: [Display] = []
    private var scale = 1
    private var lastMove: Arguments?
    private var lastRemoval: Arguments?
    private let reconfiguration = DisplayReconfiguration()

    private typealias Display = OnlineDisplay
    // Once this process has released a display, its CG cache is not a reliable
    // inventory even after callbacks/run-loop service. All later reads use a
    // fresh process too, including status and idempotent destroy responses.
    private var requiresFreshDisplayList = false

    private func displays() throws -> [Display] {
        try requiresFreshDisplayList ? FreshOnlineDisplays.list() : OnlineDisplays.current()
    }

    // No window titles. Owner names explain movement warnings in local evidence;
    // a changing frame alone cannot distinguish display effects from user input.
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
            return ["id": id, "pid": pid, "ownerName": record[kCGWindowOwnerName as String] as? String ?? "PID \(pid)",
                    "layer": layer, "onScreen": record[kCGWindowIsOnscreen as String] ?? NSNull(),
                    "frame": agentDisplayRectJSON(rect)]
        }
    }

    func status(displaySnapshot: [OnlineDisplay]? = nil) throws -> Arguments {
        let current = try displaySnapshot ?? displays()
        var result: Arguments = ["displays": current.map(\.json), "windowFrames": try windowFrames(),
                                 "restorePending": ledger.restorePending, "backingScale": scale,
                                 "agentDisplayID": ledger.displayID.map { $0 as Any } ?? NSNull()]
        if let lastMove { result["lastMove"] = lastMove }
        if let lastRemoval { result["lastRemoval"] = lastRemoval }
        result["displayReconfigurationEvents"] = reconfiguration.snapshot()
        if let requestedFrame { result["requestedFrame"] = agentDisplayRectJSON(requestedFrame) }
        if let agent = current.first(where: { $0.id == ledger.displayID }) {
            result["actualFrame"] = agentDisplayRectJSON(agent.frame)
            result["placementAdjustedByOS"] = requestedFrame != agent.frame
        }
        if let saved = ledger.saved, let target = targets[saved.windowID] {
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
                info["windowServerDisplayIDs"] = current.filter { area($0.frame.intersection(frame)) > 0 }.map(\.id)
            }
            result["target"] = info
        }
        return result
    }

    func create() async throws -> Arguments {
        try requireAccessibility()
        let checkDesktop = quietDesktopCheck()
        guard display == nil, ledger.displayID == nil, !ledger.restorePending else {
            throw OpenCUError("AGENT_DISPLAY_BUSY", "Restore and destroy the previous display first.")
        }
        try reconfiguration.start()
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
        targets.removeAll()
        admitted.removeAll()
        lastMove = nil
        lastRemoval = nil
        do {
            try checkDesktop()
            // Keep the sole owning reference in this controller. Do not let an
            // async local extend its lifetime past destroy's release.
            try autoreleasepool {
                let created = try AgentDisplaySPI.create(scale: scale)
                display = created.object
                try ledger.created(created.id)
            }
            try await settle { try self.displays().contains { $0.id == self.ledger.displayID } }
            try checkDesktop()
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
            try checkDesktop()
            let current = try displays()
            guard current.filter({ $0.id != ledger.displayID }) == baseline,
                  let agent = current.first(where: { $0.id == ledger.displayID }), !agent.main, !agent.mirrored,
                  agent.frame.size == CGSize(width: 1728, height: 1117),
                  NSScreen.screens.first(where: { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32) == agent.id })?.backingScaleFactor == CGFloat(scale),
                  !baseline.contains(where: { let i = $0.frame.intersection(agent.frame); return !i.isNull && i.width > 0 && i.height > 0 }) else {
                throw OpenCUError("AGENT_DISPLAY_LAYOUT_CHANGED", "macOS changed the original layout, main display, mirroring, or requested logical size.")
            }
            agentFrame = current.first(where: { $0.id == ledger.displayID })?.frame
            let after = try windowFrames()
            var warnings: [Arguments] = []
            for before in windowsBefore {
                if let now = after.first(where: { ($0["id"] as? UInt32) == (before["id"] as? UInt32) && ($0["pid"] as? Int) == (before["pid"] as? Int) }),
                   (now["frame"] as? [String: Double]) != (before["frame"] as? [String: Double]) {
                    warnings.append(["windowID": before["id"]!, "pid": before["pid"]!,
                                     "ownerName": now["ownerName"]!, "before": before["frame"]!, "after": now["frame"]!,
                                     "beforeOnScreen": before["onScreen"]!, "afterOnScreen": now["onScreen"]!,
                                     "beforeSize": (before["frame"] as! [String: Double]).filter { ["width", "height"].contains($0.key) },
                                     "reason": "Window movement observed; cause cannot be attributed to the probe."])
                }
            }
            var result = try status()
            result["windowMovementWarnings"] = warnings
            return result
        } catch {
            let cleanup = await destroy()
            throw OpenCUError((error as? OpenCUError)?.code ?? "AGENT_DISPLAY_CREATE_FAILED",
                              "\(error.localizedDescription) Cleanup: \(cleanup)")
        }
    }

    func moveWindow(_ app: TargetApp, proposal: Proposal? = nil) async throws -> Arguments {
        try requireAccessibility()
        let checkDesktop = quietDesktopCheck()
        let started = ProcessInfo.processInfo.systemUptime
        var diagnostic: Arguments = ["pid": app.pid, "elapsedMs": 0]
        var writes: [Arguments] = [], observations: [Arguments] = []
        var selected: AXUIElement?
        var resolvedID: CGWindowID?
        func observation() -> Arguments {
            var value = windowEvidence(pid: app.pid, window: selected, id: resolvedID)
            value["elapsedMs"] = (ProcessInfo.processInfo.systemUptime - started) * 1000
            return value
        }
        do {
            guard let id = ledger.displayID, let agent = try displays().first(where: { $0.id == id }), !agent.main else {
                throw OpenCUError("AGENT_DISPLAY_REQUIRED", "Create an agent display first.")
            }
            let root = AXUIElementCreateApplication(app.pid)
            AXUIElementSetMessagingTimeout(root, 1)
            // Like ordinary observation, allow AX to publish a newly launched
            // background window. No raise, focus, activation or visibility filter.
            for _ in 0..<20 {
                selected = proposal?.window ?? axSelectedWindow(root)
                if selected != nil { break }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            if let proposal { try validateProposal(proposal) }
            diagnostic["before"] = observation()
            guard let window = selected else {
                throw OpenCUError("AGENT_DISPLAY_AX_WINDOW_UNAVAILABLE", "AX exposes no selected or sole window; see attribute errors and CG candidates in move diagnostics.")
            }
            guard axString(window, kAXRoleAttribute) == kAXWindowRole,
                  (axValue(window, kAXMinimizedAttribute) as? Bool) != true,
                  (axValue(window, "AXFullScreen") as? Bool) != true else {
                throw OpenCUError("AGENT_DISPLAY_UNSUPPORTED_WINDOW", "The AX window is minimized, full-screen, or not an ordinary window; see move diagnostics.")
            }
            guard let frame = axRect(window), AgentDisplayGeometry.valid(frame) else {
                throw OpenCUError("AGENT_DISPLAY_AX_BOUNDS_UNAVAILABLE", "AX position/size is unavailable; see move diagnostics.")
            }
            let identity = try resolveIdentity(window, pid: app.pid, frame: frame)
            resolvedID = identity.id
            diagnostic["identitySource"] = identity.source
            diagnostic["windowID"] = identity.id
            diagnostic["before"] = observation()
            let originals = try displays().filter { $0.id != id }
            // An offscreen AX frame may overlap no display. Keep the exact frame
            // and record the nearest original display, without rejecting it.
            guard let originalDisplay = originals.min(by: {
                distance(frame, to: $0.frame) < distance(frame, to: $1.frame)
            }) else { throw OpenCUError("AGENT_DISPLAY_ORIGINAL_DISPLAY_MISSING", "No original display remains.") }
            let destination = try AgentDisplayGeometry.destination(original: frame, display: agent.frame)
            diagnostic["requestedFrame"] = agentDisplayRectJSON(destination)
            diagnostic["requestedDisplayID"] = id
            diagnostic["originalDisplayInferred"] = area(originalDisplay.frame.intersection(frame)) == 0
            try ledger.remember(.init(windowID: identity.id, displayID: originalDisplay.id, frame: frame), multiple: multipleWindows)
            targets[identity.id] = proposal ?? Proposal(app: app, window: window, windowID: identity.id,
                frame: frame, displayID: originalDisplay.id, destination: destination,
                title: axString(window, kAXTitleAttribute) ?? "Untitled window")
            let writeGuard = {
                try checkDesktop()
                if let proposal {
                    guard !proposal.app.application.isTerminated,
                          let current = axSelectedWindow(root), CFEqual(current, proposal.window),
                          let bounds = axRect(proposal.window),
                          (try? self.resolveIdentity(proposal.window, pid: app.pid, frame: bounds).id) == proposal.windowID else {
                        throw OpenCUError("WINDOW_CHANGED", "Approved window identity changed before a geometry write.")
                    }
                }
            }
            try setFrame(window, destination, shouldWrite: writeGuard) { attribute, result in
                writes.append(["attribute": attribute, "axError": result.rawValue, "state": observation()])
            }
            try await settle(seconds: 5) {
                try checkDesktop()
                let value = observation()
                observations.append(value)
                guard let actual = axRect(window), AgentDisplayGeometry.close(actual, destination),
                      let record = windowRecords(pid: app.pid).first(where: { $0.id == identity.id }) else { return false }
                return record.onScreen && agent.frame.contains(record.frame)
            }
            admitted.insert(identity.id)
            diagnostic["ok"] = true
            diagnostic["elapsedMs"] = (ProcessInfo.processInfo.systemUptime - started) * 1000
            diagnostic["after"] = observation()
            diagnostic["writes"] = writes
            diagnostic["observations"] = observations
            lastMove = diagnostic
            return try status()
        } catch {
            diagnostic["ok"] = false
            diagnostic["elapsedMs"] = (ProcessInfo.processInfo.systemUptime - started) * 1000
            diagnostic["error"] = error.localizedDescription
            diagnostic["after"] = observation()
            diagnostic["writes"] = writes
            diagnostic["observations"] = observations
            lastMove = diagnostic
            throw OpenCUError((error as? OpenCUError)?.code ?? "AGENT_DISPLAY_MOVE_FAILED",
                              error.localizedDescription, details: ["move": diagnostic])
        }
    }

    private func windowRecords(pid: pid_t) -> [AgentDisplayWindowIdentity.Candidate] {
        let records = CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as? [Arguments] ?? []
        return records.compactMap { record in
            guard (record[kCGWindowOwnerPID as String] as? Int32) == pid,
                  (record[kCGWindowLayer as String] as? Int) == 0,
                  let id = record[kCGWindowNumber as String] as? UInt32,
                  let dictionary = record[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: dictionary as CFDictionary) else { return nil }
            return .init(id: id, pid: pid, title: record[kCGWindowName as String] as? String,
                         frame: frame, onScreen: record[kCGWindowIsOnscreen as String] as? Bool ?? false)
        }
    }

    private func resolveIdentity(_ window: AXUIElement, pid: pid_t, frame: CGRect) throws -> (id: UInt32, source: String) {
        try AgentDisplayWindowIdentity.resolve(pid: pid, title: axString(window, kAXTitleAttribute), frame: frame,
            exactID: exactWindowID(window, pid: pid), candidates: windowRecords(pid: pid))
    }

    private func windowEvidence(pid: pid_t, window: AXUIElement?, id: CGWindowID?) -> Arguments {
        let current = (try? displays()) ?? []
        func screenIDs(_ frame: CGRect) -> [UInt32] { current.filter { area($0.frame.intersection(frame)) > 0 }.map(\.id) }
        var result: Arguments = ["cgCandidates": windowRecords(pid: pid).map { record -> Arguments in
            ["id": record.id, "title": record.title as Any? ?? NSNull(), "frame": agentDisplayRectJSON(record.frame),
             "onScreen": record.onScreen, "displayIDs": screenIDs(record.frame)]
        }]
        let root = AXUIElementCreateApplication(pid)
        // Preserve the AX error for every precondition, rather than collapsing
        // permissions, unavailable roles, and missing window IDs into one error.
        var errors: Arguments = [:]
        for key in [kAXWindowsAttribute, kAXFocusedWindowAttribute, kAXMainWindowAttribute] {
            var value: CFTypeRef?
            errors[key] = AXUIElementCopyAttributeValue(root, key as CFString, &value).rawValue
        }
        result["applicationAXErrors"] = errors
        result["axWindowCount"] = axWindows(root).count
        if let window {
            var values: Arguments = [:]
            for key in [kAXRoleAttribute, kAXTitleAttribute, kAXMinimizedAttribute, "AXFullScreen", kAXPositionAttribute, kAXSizeAttribute] {
                var value: CFTypeRef?
                let error = AXUIElementCopyAttributeValue(window, key as CFString, &value)
                values[key] = ["error": error.rawValue, "value": value.map { String(describing: $0) } ?? "unavailable"]
            }
            result["axAttributes"] = values
            if let frame = axRect(window) { result["axFrame"] = agentDisplayRectJSON(frame); result["axDisplayIDs"] = screenIDs(frame) }
            result["exactAXWindowID"] = exactWindowID(window, pid: pid).map { $0 as Any } ?? NSNull()
        }
        if let id, let record = windowRecords(pid: pid).first(where: { $0.id == id }) {
            result["windowServerFrame"] = agentDisplayRectJSON(record.frame)
            result["windowServerOnScreen"] = record.onScreen
            result["windowServerDisplayIDs"] = screenIDs(record.frame)
        }
        return result
    }

    private func distance(_ frame: CGRect, to display: CGRect) -> Double {
        if area(frame.intersection(display)) > 0 { return -area(frame.intersection(display)) }
        return hypot(max(display.minX - frame.maxX, frame.minX - display.maxX, 0),
                     max(display.minY - frame.maxY, frame.minY - display.maxY, 0))
    }

    func propose(_ app: TargetApp) throws -> Proposal? {
        guard let agent = agentFrame, ledger.displayID != nil else {
            throw OpenCUError("AGENT_DISPLAY_REQUIRED", "Create an agent display first.")
        }
        guard let window = axSelectedWindow(AXUIElementCreateApplication(app.pid)) else { return nil }
        guard axString(window, kAXRoleAttribute) == kAXWindowRole,
              (axValue(window, kAXMinimizedAttribute) as? Bool) != true,
              (axValue(window, "AXFullScreen") as? Bool) != true else {
            throw OpenCUError("AGENT_DISPLAY_UNSUPPORTED_WINDOW", "Only ordinary, non-minimized windows can move to the agent desktop.")
        }
        guard let frame = axRect(window), AgentDisplayGeometry.valid(frame) else {
            throw OpenCUError("AGENT_DISPLAY_AX_BOUNDS_UNAVAILABLE", "Window position or size is unavailable.")
        }
        let id = try resolveIdentity(window, pid: app.pid, frame: frame).id
        let originals = try displays().filter { $0.id != ledger.displayID }
        guard let source = originals.min(by: { distance(frame, to: $0.frame) < distance(frame, to: $1.frame) }) else {
            throw OpenCUError("AGENT_DISPLAY_ORIGINAL_DISPLAY_MISSING", "No original display remains.")
        }
        return Proposal(app: app, window: window, windowID: id, frame: frame, displayID: source.id,
            destination: try AgentDisplayGeometry.destination(original: frame, display: agent),
            title: axString(window, kAXTitleAttribute) ?? "Untitled window")
    }

    func validateProposal(_ proposal: Proposal) throws {
        guard !proposal.app.application.isTerminated,
              let selected = axSelectedWindow(AXUIElementCreateApplication(proposal.app.pid)),
              CFEqual(selected, proposal.window), let frame = axRect(proposal.window),
              AgentDisplayGeometry.close(frame, proposal.frame),
              (try? resolveIdentity(proposal.window, pid: proposal.app.pid, frame: frame).id) == proposal.windowID,
              try displays().contains(where: { $0.id == proposal.displayID }) else {
            throw OpenCUError("WINDOW_CHANGED", "The window changed while consent was pending. No replacement window was moved.")
        }
    }

    func contains(_ proposal: Proposal) -> Bool {
        guard admitted.contains(proposal.windowID), let target = targets[proposal.windowID],
              !target.app.application.isTerminated, target.app.application == proposal.app.application,
              CFEqual(target.window, proposal.window), let agentFrame,
              let frame = axRect(proposal.window), agentFrame.contains(frame),
              let record = windowRecords(pid: target.app.pid).first(where: { $0.id == proposal.windowID }),
              record.onScreen, agentFrame.contains(record.frame) else { return false }
        return true
    }

    func requireAdmitted(_ snapshot: WindowSnapshot) throws {
        guard let window = snapshot.window, let id = snapshot.windowID, let target = targets[id],
              target.app.pid == snapshot.app.pid, CFEqual(target.window, window), contains(target),
              let selected = axSelectedWindow(AXUIElementCreateApplication(snapshot.app.pid)), CFEqual(selected, window) else {
            throw OpenCUError("AGENT_DESKTOP_CONSENT_REQUIRED", "This exact window is not admitted on the agent desktop. Read its state; no input was sent.")
        }
    }

    /// A person/app moving an admitted window out revokes both input and restoration.
    /// A partially failed OpenCU move is never mistaken for an external return.
    func externalReturns() -> [Proposal] {
        var returned: [Proposal] = []
        guard let agentFrame else { return returned }
        for id in Array(admitted) {
            guard let target = targets[id] else { continue }
            if target.app.application.isTerminated {
                admitted.remove(id); ledger.restored(id); continue
            }
            if let frame = axRect(target.window), !agentFrame.contains(frame) {
                admitted.remove(id); ledger.restored(id); returned.append(target)
            }
        }
        return returned
    }

    func validateLayout() throws {
        let current = try displays()
        guard current.filter({ $0.id != ledger.displayID }) == baseline,
              let agent = current.first(where: { $0.id == ledger.displayID }),
              agent.frame == agentFrame, !agent.main, !agent.mirrored else {
            throw OpenCUError("AGENT_DISPLAY_LAYOUT_CHANGED", "The display layout changed. Agent desktop is being stopped; no replacement display is created.")
        }
    }

    func restore() async throws -> Arguments {
        let deadline = ProcessInfo.processInfo.systemUptime + 10
        var errors: [String] = []
        // Check manual returns before touching geometry, including immediately after EOF.
        if multipleWindows { _ = externalReturns() }
        for saved in ledger.pending.reversed() {
            guard let target = targets[saved.windowID] else { continue }
            do {
                guard ProcessInfo.processInfo.systemUptime < deadline else {
                    throw OpenCUError("AGENT_DISPLAY_TIMEOUT", "Window restoration budget expired.")
                }
                if target.app.application.isTerminated { ledger.restored(saved.windowID); continue }
                let root = AXUIElementCreateApplication(target.app.pid)
                AXUIElementSetMessagingTimeout(root, 0.5)
                AXUIElementSetMessagingTimeout(target.window, 0.5)
                let windows = axWindows(root)
                var rawWindows: CFTypeRef?
                let windowsError = AXUIElementCopyAttributeValue(root, kAXWindowsAttribute as CFString, &rawWindows)
                if windowsError == .success, let exactWindows = rawWindows as? [AXUIElement],
                   !exactWindows.contains(where: { CFEqual($0, target.window) }),
                   let records = CGWindowListCopyWindowInfo(.optionIncludingWindow, saved.windowID) as? [Arguments],
                   !records.contains(where: { ($0[kCGWindowNumber as String] as? UInt32) == saved.windowID }) {
                    ledger.restored(saved.windowID); admitted.remove(saved.windowID); continue
                }
                guard windows.contains(where: { CFEqual($0, target.window) }),
                      let frame = axRect(target.window),
                      (try? resolveIdentity(target.window, pid: target.app.pid, frame: frame).id) == saved.windowID else {
                    throw OpenCUError("AGENT_DISPLAY_TARGET_LOST", "Original window identity cannot be verified; no replacement was moved.")
                }
                guard try displays().contains(where: { $0.id == saved.displayID }) else {
                    throw OpenCUError("AGENT_DISPLAY_ORIGINAL_DISPLAY_MISSING", "Original display is disconnected; no fallback placement was attempted.")
                }
                AXUIElementSetMessagingTimeout(target.window, 0.5)
                try setFrame(target.window, saved.frame, shouldWrite: {
                    guard ProcessInfo.processInfo.systemUptime < deadline else {
                        throw OpenCUError("AGENT_DISPLAY_TIMEOUT", "Window restoration budget expired before the next write.")
                    }
                })
                try await settle(seconds: max(0, min(2, deadline - ProcessInfo.processInfo.systemUptime))) {
                    axRect(target.window).map { AgentDisplayGeometry.close($0, saved.frame) } ?? false
                }
                ledger.restored(saved.windowID); admitted.remove(saved.windowID)
            } catch { errors.append("Window \(saved.windowID): \(error.localizedDescription)") }
        }
        if !errors.isEmpty {
            throw OpenCUError("AGENT_DESKTOP_CLEANUP_FAILED", errors.joined(separator: "; "), details: ["windows": savedWindows])
        }
        return try status()
    }

    /// Always release, even if AX restoration fails. Report errors; do not hide a
    /// failed restoration or keep an invisible display alive awaiting the caller.
    func destroy() async -> Arguments {
        var errors: [String] = []
        let removedID = ledger.displayID
        var removalStarted: TimeInterval?
        var freshSnapshot: [OnlineDisplay]?
        for step in ledger.cleanupSteps {
            switch step {
            case .restore:
                do { _ = try await restore() } catch { errors.append(error.localizedDescription) }
            case .releaseDisplay:
                removalStarted = ProcessInfo.processInfo.systemUptime
                requiresFreshDisplayList = true
                autoreleasepool { display = nil }
            }
        }
        if let removedID {
            let started = removalStarted ?? ProcessInfo.processInfo.systemUptime
            let confirmation = await DisplayRemovalPoll.wait(for: removedID, started: started) { budget in
                // No blocking child pipe/waitpid on the main actor. Every check
                // spawns a new metadata-only process, even after a prior timeout.
                try await Task.detached { try FreshOnlineDisplays.list(timeout: budget) }.value
            }
            freshSnapshot = confirmation.displays
            if confirmation.removed { ledger.released() }
            if let error = confirmation.error { errors.append("Display removal was not observed: \(error)") }
            lastRemoval = ["displayID": removedID, "elapsedMs": confirmation.elapsedMs,
                           "timeoutMs": 10000, "checks": confirmation.checks, "removed": confirmation.removed,
                           "observationMechanism": "fresh posix_spawn --online-displays process per check",
                           "reconfigurationEvents": reconfiguration.snapshot(since: started * 1000)]
        }
        var result: Arguments = [:]
        do { result = try status(displaySnapshot: freshSnapshot) }
        catch { errors.append("Cleanup status unavailable: \(error.localizedDescription)") }
        result["cleanupErrors"] = errors
        result["ok"] = errors.isEmpty
        return result
    }

    private func area(_ rect: CGRect) -> Double { rect.isNull ? 0 : rect.width * rect.height }
    private func settle(seconds: Double = 2, _ check: () throws -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + seconds
        while true {
            if try check() { return }
            if ProcessInfo.processInfo.systemUptime >= deadline { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        throw OpenCUError("AGENT_DISPLAY_TIMEOUT", "The requested display/window state did not settle within \(seconds) seconds.")
    }
    private func quietDesktopCheck() -> () throws -> Void {
        let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let pointer = CGEvent(source: nil)?.location
        return {
            try Task.checkCancellation()
            try self.beforeMutation?()
            guard let pointer, CGEvent(source: nil)?.location == pointer,
                  NSWorkspace.shared.frontmostApplication?.processIdentifier == front else {
                throw OpenCUError("AGENT_DISPLAY_PERSON_ACTIVE", "Foreground or pointer changed; further display/window mutations stopped. Cleanup remains enabled.")
            }
        }
    }

    private func setFrame(_ window: AXUIElement, _ frame: CGRect, shouldWrite: (() throws -> Void)? = nil,
                          didWrite: ((String, AXError) -> Void)? = nil) throws {
        var point = frame.origin, size = frame.size
        // Position first so the old display's bounds do not clamp a larger size.
        for (attribute, value) in [(kAXPositionAttribute, AXValueCreate(.cgPoint, &point)),
                                   (kAXSizeAttribute, AXValueCreate(.cgSize, &size)),
                                   (kAXPositionAttribute, AXValueCreate(.cgPoint, &point))] {
            try shouldWrite?()
            guard let value else { throw OpenCUError("AGENT_DISPLAY_AX_FAILED", "Cannot encode AX frame.") }
            let result = AXUIElementSetAttributeValue(window, attribute as CFString, value)
            didWrite?(attribute, result)
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
