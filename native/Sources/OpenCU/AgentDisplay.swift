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
        let requiresMove: Bool
        var key: String { "\(app.pid):\(app.application.launchDate?.timeIntervalSince1970 ?? 0):\(windowID)" }
    }
    private var targets: [UInt32: Proposal] = [:]
    private var admitted = Set<UInt32>()
    private var agentFrame: CGRect?
    var beforeMutation: (() throws -> Void)?
    var id: UInt32? { ledger.displayID }
    var frame: CGRect? { agentFrame }
    var restorePending: Bool { ledger.restorePending }
    var savedWindows: [Arguments] {
        targets.values.filter { target in admitted.contains(target.windowID) || ledger.pending.contains { $0.windowID == target.windowID } }.map { target in
            let saved = ledger.pending.first { $0.windowID == target.windowID }
            var result: Arguments = ["windowID": target.windowID, "app": target.app.id,
                "restorePending": saved != nil, "state": admitted.contains(target.windowID) ? "admitted" : "restore_pending"]
            if let saved { result["originalFrame"] = agentDisplayRectJSON(saved.frame); result["originalDisplayID"] = saved.displayID }
            return result
        }
    }

    private var requestedFrame: CGRect?
    private var baseline: [Display] = []
    private var scale = 1
    private var lastMove: Arguments?
    private var lastRemoval: Arguments?
    private let reconfiguration = DisplayReconfiguration()

    private typealias Display = OnlineDisplay
    // The owner CG cache can outlive a released display. Preserve the confirmed
    // fresh snapshot for status/idempotent cleanup; unresolved restorations refresh
    // it off the main actor. Never reintroduce the stale owner inventory.
    private var requiresFreshDisplayList = false
    private var lastFreshDisplays: [OnlineDisplay]?
    private var monitorCursor = 0

    private func displays() throws -> [Display] {
        if requiresFreshDisplayList {
            guard let lastFreshDisplays else { throw OpenCUError("AGENT_DISPLAY_STATUS_FAILED", "No confirmed fresh display snapshot is available.") }
            return lastFreshDisplays
        }
        return try OnlineDisplays.current()
    }

    /// No AX reads or child process on the main actor, including repeated destroy.
    private func status(displaySnapshot: [OnlineDisplay]? = nil) -> Arguments {
        var result: Arguments = ["agentDisplayID": ledger.displayID.map { $0 as Any } ?? NSNull(),
            "restorePending": ledger.restorePending, "windows": savedWindows,
            "displays": (displaySnapshot ?? lastFreshDisplays ?? []).map(\.json)]
        if let lastRemoval { result["lastRemoval"] = lastRemoval }
        return result
    }

    func create() async throws -> Arguments {
        try requireAccessibility()
        let checkDesktop = personGuard()
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
            return status()
        } catch {
            let cleanup = await destroy()
            throw OpenCUError((error as? OpenCUError)?.code ?? "AGENT_DISPLAY_CREATE_FAILED",
                              "\(error.localizedDescription) Cleanup: \(cleanup)")
        }
    }

    func moveWindow(_ proposal: Proposal) async throws -> Arguments {
        try requireAccessibility()
        let app = proposal.app
        let started = ProcessInfo.processInfo.systemUptime
        var diagnostic: Arguments = ["pid": app.pid, "elapsedMs": 0]
        var writes: [Arguments] = [], observations: [Arguments] = []
        var selected: AXUIElement?
        let checkDesktop = personGuard(pid: app.pid) { selected.flatMap { axRect($0) } }
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
            selected = proposal.window
            try validateProposal(proposal)
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
            try ledger.remember(.init(windowID: identity.id, displayID: originalDisplay.id, frame: frame))
            targets[identity.id] = proposal
            let writeGuard = {
                try checkDesktop()
                do {
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
            AXUIElementSetMessagingTimeout(window, 0.25)
            admitted.insert(identity.id)
            diagnostic["ok"] = true
            diagnostic["elapsedMs"] = (ProcessInfo.processInfo.systemUptime - started) * 1000
            diagnostic["after"] = observation()
            diagnostic["writes"] = writes
            diagnostic["observations"] = observations
            lastMove = diagnostic
            return status()
        } catch {
            diagnostic["ok"] = false
            diagnostic["elapsedMs"] = (ProcessInfo.processInfo.systemUptime - started) * 1000
            diagnostic["error"] = error.localizedDescription
            diagnostic["after"] = observation()
            diagnostic["writes"] = writes
            diagnostic["observations"] = observations
            lastMove = diagnostic
            if error is CancellationError { throw error }
            throw OpenCUError((error as? OpenCUError)?.code ?? "AGENT_DISPLAY_MOVE_FAILED",
                              error.localizedDescription, details: ["move": diagnostic])
        }
    }

    private func windowRecords(pid: pid_t, id: CGWindowID? = nil) -> [AgentDisplayWindowIdentity.Candidate] {
        let records = CGWindowListCopyWindowInfo(id == nil ? .optionAll : .optionIncludingWindow, id ?? kCGNullWindowID) as? [Arguments] ?? []
        return records.compactMap { record in
            guard (record[kCGWindowOwnerPID as String] as? Int32) == pid,
                  (id != nil || (record[kCGWindowLayer as String] as? Int) == 0),
                  let id = record[kCGWindowNumber as String] as? UInt32,
                  let dictionary = record[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: dictionary as CFDictionary) else { return nil }
            return .init(id: id, pid: pid, title: record[kCGWindowName as String] as? String,
                         frame: frame, onScreen: record[kCGWindowIsOnscreen as String] as? Bool ?? false)
        }
    }

    private func resolveIdentity(_ window: AXUIElement, pid: pid_t, frame: CGRect) throws -> (id: UInt32, source: String) {
        let exact = exactWindowID(window, pid: pid)
        return try AgentDisplayWindowIdentity.resolve(pid: pid, title: axString(window, kAXTitleAttribute), frame: frame,
            exactID: exact, candidates: windowRecords(pid: pid, id: exact))
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
        guard let agent = agentFrame, let agentID = ledger.displayID else {
            throw OpenCUError("AGENT_DISPLAY_REQUIRED", "Create an agent display first.")
        }
        let root = AXUIElementCreateApplication(app.pid)
        AXUIElementSetMessagingTimeout(root, 0.25)
        guard let window = axSelectedWindow(root) else { return nil }
        AXUIElementSetMessagingTimeout(window, 0.25)
        guard let frame = axRect(window), AgentDisplayGeometry.valid(frame) else {
            throw OpenCUError("AGENT_DISPLAY_AX_BOUNDS_UNAVAILABLE", "Window position or size is unavailable.")
        }
        let onDisplay = agent.contains(frame)
        let role = axString(window, kAXRoleAttribute)
        guard AgentDesktopAdmissionPolicy.usableWindow(role: role,
            minimized: (axValue(window, kAXMinimizedAttribute) as? Bool) == true,
            fullScreen: (axValue(window, "AXFullScreen") as? Bool) == true, onDisplay: onDisplay) else {
            throw OpenCUError("AGENT_DISPLAY_UNSUPPORTED_WINDOW", "This minimized, full-screen or focused sheet window cannot be moved; text-only state remains available.")
        }
        let id = try resolveIdentity(window, pid: app.pid, frame: frame).id
        let originals = try displays().filter { $0.id != agentID }
        guard onDisplay || !originals.isEmpty else {
            throw OpenCUError("AGENT_DISPLAY_ORIGINAL_DISPLAY_MISSING", "No original display remains.")
        }
        let source = originals.min(by: { distance(frame, to: $0.frame) < distance(frame, to: $1.frame) })
        return Proposal(app: app, window: window, windowID: id, frame: frame, displayID: onDisplay ? agentID : source!.id,
            destination: onDisplay ? frame : try AgentDisplayGeometry.destination(original: frame, display: agent),
            title: axString(window, kAXTitleAttribute) ?? "Untitled window", requiresMove: !onDisplay)
    }

    func hasAdmittedProcess(_ app: TargetApp) -> Bool {
        admitted.contains { id in
            guard let target = targets[id], target.app.application == app.application,
                  !target.app.application.isTerminated, let agentFrame, let frame = axRect(target.window) else { return false }
            // A covered/minimized parent can open a new window. Visibility is an
            // input condition, not a reason to discard this process's admission.
            return agentFrame.contains(frame)
        }
    }

    func admitWithoutMoving(_ proposal: Proposal) throws {
        try validateProposal(proposal)
        guard !proposal.requiresMove, let agentFrame, agentFrame.contains(proposal.frame),
              let record = windowRecords(pid: proposal.app.pid, id: proposal.windowID).first, record.onScreen,
              agentFrame.contains(record.frame) else {
            throw OpenCUError("WINDOW_CHANGED", "The window no longer resides on the agent display.")
        }
        AXUIElementSetMessagingTimeout(proposal.window, 0.25)
        targets[proposal.windowID] = proposal
        admitted.insert(proposal.windowID) // No geometry write and no restoration record.
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
              let record = windowRecords(pid: target.app.pid, id: proposal.windowID).first,
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
    func externalReturns(frames: [UInt32: CGRect]? = nil) -> [Proposal] {
        var returned: [Proposal] = []
        guard let agentFrame else { return returned }
        for id in Array(admitted) {
            guard let target = targets[id] else { continue }
            if target.app.application.isTerminated {
                admitted.remove(id); ledger.restored(id); continue
            }
            if let frame = frames != nil ? frames?[id] : axRect(target.window), !agentFrame.contains(frame) {
                admitted.remove(id); ledger.restored(id); returned.append(target)
            }
        }
        return returned
    }

    /// Read at most two bounded AX targets off the main actor per timer tick.
    func sampleFrames(observedID: UInt32?) async -> [UInt32: CGRect] {
        let ids = AgentDesktopMonitoring.batch(ids: admitted.sorted(), cursor: &monitorCursor, observed: observedID)
        let windows = ids.compactMap { id in targets[id].map { (id, $0.window) } }
        return await Task.detached {
            var frames: [UInt32: CGRect] = [:]
            for (id, window) in windows {
                if let frame = axRect(window) { frames[id] = frame }
            }
            return frames
        }.value
    }

    func validateLayout() throws {
        let current = try displays()
        guard current.filter({ $0.id != ledger.displayID }) == baseline,
              let agent = current.first(where: { $0.id == ledger.displayID }),
              agent.frame == agentFrame, !agent.main, !agent.mirrored else {
            throw OpenCUError("AGENT_DISPLAY_LAYOUT_CHANGED", "The display layout changed. Agent desktop is being stopped; no replacement display is created.")
        }
    }

    func restore(windowID: UInt32? = nil) async throws -> Arguments {
        if requiresFreshDisplayList && ledger.restorePending {
            lastFreshDisplays = try await Task.detached { try FreshOnlineDisplays.list() }.value
        }
        let deadline = ProcessInfo.processInfo.systemUptime + 10
        var errors: [String] = []
        // Check manual returns before touching geometry, including immediately after EOF.
        if windowID == nil { _ = externalReturns() }
        for saved in ledger.restorations(windowID: windowID) {
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
        return status()
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
            if let freshSnapshot { lastFreshDisplays = freshSnapshot }
            if confirmation.removed { ledger.released() }
            if let error = confirmation.error { errors.append("Display removal was not observed: \(error)") }
            lastRemoval = ["displayID": removedID, "elapsedMs": confirmation.elapsedMs,
                           "timeoutMs": 10000, "checks": confirmation.checks, "removed": confirmation.removed,
                           "observationMechanism": "fresh posix_spawn --online-displays process per check",
                           "reconfigurationEvents": reconfiguration.snapshot(since: started * 1000)]
        }
        var result = status(displaySnapshot: freshSnapshot)
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
    /// Cancellation, stop and lock always end a mutation. A move also stops once the
    /// person starts using that window: its app comes forward, or a mouse button is
    /// held over it. Other pointer movement and app switching are the person's own
    /// work and never interrupt the agent.
    private func personGuard(pid: pid_t? = nil, frame: @escaping () -> CGRect? = { nil }) -> () throws -> Void {
        let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
        return {
            try Task.checkCancellation()
            try self.beforeMutation?()
            guard let pid else { return }
            let activated = front != pid && NSWorkspace.shared.frontmostApplication?.processIdentifier == pid
            let held = NSEvent.pressedMouseButtons != 0
                && (CGEvent(source: nil)?.location).map { frame()?.contains($0) == true } == true
            guard !activated && !held else {
                throw OpenCUError("AGENT_DISPLAY_PERSON_ACTIVE", "The person started using this window (its app came forward or a mouse button was held over it); further display/window mutations stopped. Cleanup remains enabled.")
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
