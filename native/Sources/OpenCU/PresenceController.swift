import AppKit

@MainActor
private final class CursorWindow: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Owns only OpenCU UI. Input delivery is reported through one small callback;
/// this class never sends events, changes the real cursor or activates a target.
@MainActor
final class PresenceController: NSObject, NSMenuDelegate, NSApplicationDelegate {
    static let overlayWindowLevel: NSWindow.Level = .statusBar

    private(set) var state = PresenceState(cursorHoldDuration: 12)
    let hub: AgentHub
    let setup = PermissionSetup()
    var desktopVisible = false {
        didSet {
            if desktopVisible { called(target: nil, name: PresenceStrings().text("agent desktop")); finishedCall() }
            else if !trackingMenu { statusItem?.menu = makeMenu() }
        }
    }
    var onStop: (() -> Void)?
    var onShowDesktop: (() -> Void)?
    var onPersonInteraction: (() -> Void)?
    private var statusItem: NSStatusItem?
    private var timer: Timer?
    private var overlay: CursorWindow?
    private var selectionPanel: CursorWindow?
    private let selectionView = SelectionOverlayView(frame: .zero)
    private var selection: CursorMotion.SelectionHighlight?
    private var swarmPanel: CursorWindow?
    private let swarmView = ClusterSwarmOverlayView(frame: .zero)
    private(set) var swarmAgents: [String: SwarmAgentState] = [:]
    private var swarmHudText: String?
    private var swarmHudProgress: Double?
    private var badgePanel: CursorWindow?
    private let badgeView = BadgeView()
    private var badgeLifetime = BadgeLifetime(holdDuration: 8)
    private var badgeTitleHeight: CGFloat?
    private var lastBadgeActionText: String?
    private let cursor = AgentCursorView(frame: NSRect(x: 0, y: 0, width: 60, height: 60))
    private var motion: CursorMotion?
    private var dragStepTrail: [CursorMotion.CometDot] = []
    private var pressBegan: TimeInterval?
    private var targetWindow: CGWindowID?
    private var targetPID: pid_t?
    private var targetBounds: CGRect = .zero
    private var targetName = ""
    private var needsZOrderRaise = false
    private var prompted = false
    private var trackingMenu = false
    private var now: TimeInterval { ProcessInfo.processInfo.systemUptime }
    private var panelSharingType: NSWindow.SharingType {
        AgentConfig.captureOverlayEnabled() ? .readOnly : .none
    }

    init(hub: AgentHub = AgentHub()) {
        self.hub = hub
        super.init()
        NSApp.delegate = self
        setup.willShow = { [weak self] in self?.onPersonInteraction?() }
        syncAgentIdentity()
    }

    func syncAgentIdentity() {
        let rgb = hub.identity.rgb
        let color = rgb.nsColor
        cursor.agentRGB = rgb
        cursor.agentColor = color
        selectionView.agentColor = color
        badgeView.accentColor = color
    }

    func setWaitingTurn(_ waiting: Bool) {
        let time = now
        state.setWaitingTurn(waiting, now: time)
        badgeLifetime.setWaitingTurn(waiting, now: time)
        refreshBadgeDisplayText()
        if waiting { needsZOrderRaise = true }
        if state.cursorVisible(at: time) || badgeLifetime.opacity(at: time) > 0 || selectionActive(at: time) || swarmActive(at: time) {
            startTimer(); tick()
        }
    }

    func beginCall(query: String) {
        // Never hide an active cursor on consecutive calls before app resolution;
        // `called(target:)` and `observed(_:)` hide only when switching targets.
        let resolvedPID = AppTarget.processID(query).map(String.init)
        if let resolvedPID, let existing = state.target, existing != resolvedPID {
            hideCursor(); hideSelection(); hideSwarm(); hideBadge()
        }
        called(target: resolvedPID, name: targetName.isEmpty ? query : targetName)
    }

    func called(target: String?, name: String) {
        guard state.connected else { return }
        if let target, let existing = state.target, existing != target {
            hideCursor(); hideSelection(); hideSwarm(); hideBadge()
        }
        state.call(target: target ?? state.target ?? name, now: now)
        targetName = name
        needsZOrderRaise = true
        if statusItem == nil {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            item.button?.image = PresenceArtwork.statusGlyph(size: NSSize(width: 18, height: 18))
            item.button?.setAccessibilityLabel("OpenCU")
            statusItem = item
        }
        if !trackingMenu { statusItem?.menu = makeMenu() }
        startTimer()
    }

    func finishedCall() { state.finished(now: now) }

    func observed(_ snapshot: WindowSnapshot) {
        let switchingTarget = targetWindow != nil && (targetWindow != snapshot.windowID || targetPID != snapshot.app.pid)
        if switchingTarget {
            hideCursor(); hideSelection(); hideSwarm(); hideBadge()
        }
        let oldBounds = targetBounds
        targetWindow = snapshot.windowID
        targetPID = snapshot.app.pid
        targetBounds = snapshot.bounds
        hub.updateTarget(windowID: snapshot.windowID, targetPID: snapshot.app.pid)
        syncAgentIdentity()

        guard state.connected, !state.stopped, snapshot.windowID != nil,
              !snapshot.bounds.isEmpty, !snapshot.bounds.isNull else {
            if snapshot.windowID == nil { hideCursor(); hideSelection(); hideSwarm(); hideBadge() }
            return
        }

        let time = now
        needsZOrderRaise = true
        if state.cursorVisible(at: time), let existing = motion {
            // Keep the cursor persistently visible across consecutive observations.
            // If the window translated on screen, carry the cursor along with it.
            let dx = (!oldBounds.isEmpty && oldBounds.size == snapshot.bounds.size) ? (snapshot.bounds.minX - oldBounds.minX) : 0
            let dy = (!oldBounds.isEmpty && oldBounds.size == snapshot.bounds.size) ? (snapshot.bounds.minY - oldBounds.minY) : 0
            if abs(dx) > 0.5 || abs(dy) > 0.5 {
                let cur = existing.point(at: time)
                let shifted = CGPoint(x: cur.x + dx, y: cur.y + dy)
                motion = CursorMotion(start: shifted, end: shifted, began: time, duration: CursorMotion.defaultGlideDuration)
            } else if !snapshot.bounds.insetBy(dx: 8, dy: 8).contains(existing.end) {
                let cur = clampPoint(existing.point(at: time), inside: snapshot.bounds)
                let anchor = PresenceArtwork.anchorPoint(forSlot: hub.identity.slot, within: snapshot.bounds)
                let arc = CursorMotion.deterministicArcOffset(slot: hub.identity.slot, start: cur, end: anchor, isDrag: false)
                motion = CursorMotion(start: cur, end: anchor, began: time, duration: CursorMotion.defaultGlideDuration, arcOffset: arc)
            }
            state.pointer(now: time)
        } else {
            let anchor = PresenceArtwork.anchorPoint(forSlot: hub.identity.slot, within: snapshot.bounds)
            let entry = PresenceArtwork.entryPoint(forAnchor: anchor, slot: hub.identity.slot, within: snapshot.bounds)
            let arc = CursorMotion.deterministicArcOffset(slot: hub.identity.slot, start: entry, end: anchor, isDrag: false)
            motion = CursorMotion(start: entry, end: anchor, began: time, duration: CursorMotion.defaultGlideDuration, arcOffset: arc)
            dragStepTrail = []
            state.pointer(now: time)
        }
        startTimer(); tick()
    }

    /// Initiates smooth 280ms curved Bézier (or straight drag) cursor flight and optional target wireframe selection
    /// BEFORE acquiring `pid-<pid>.lock`, returning flight distance in screen points.
    @discardableResult
    func glideTo(
        _ targetPoint: CGPoint?,
        selectionRect: CGRect?,
        snapshot: WindowSnapshot,
        click: Bool = false,
        isDrag: Bool = false,
        guideLines: Bool = true
    ) -> CGFloat {
        guard !state.stopped, state.connected, snapshot.windowID != nil else { return 0 }
        observed(snapshot)
        syncAgentIdentity()
        let time = now
        needsZOrderRaise = true
        if let selectionRect, !selectionRect.isEmpty, !selectionRect.isNull {
            selection = CursorMotion.SelectionHighlight(rect: selectionRect, began: time, guideLines: guideLines)
        }
        guard let targetPoint else {
            startTimer(); tick()
            return 0
        }
        let previous = currentCursorPoint(at: time, within: snapshot.bounds)
            ?? PresenceArtwork.entryPoint(forAnchor: targetPoint, slot: hub.identity.slot, within: snapshot.bounds)
        let distance = hypot(targetPoint.x - previous.x, targetPoint.y - previous.y)
        if distance > 0.5 {
            let arc = CursorMotion.deterministicArcOffset(slot: hub.identity.slot, start: previous, end: targetPoint, isDrag: isDrag)
            motion = CursorMotion(start: previous, end: targetPoint, began: time, duration: CursorMotion.defaultGlideDuration, arcOffset: arc)
        } else if motion == nil {
            let start = PresenceArtwork.entryPoint(forAnchor: targetPoint, slot: hub.identity.slot, within: snapshot.bounds)
            let arc = CursorMotion.deterministicArcOffset(slot: hub.identity.slot, start: start, end: targetPoint, isDrag: isDrag)
            motion = CursorMotion(start: start, end: targetPoint, began: time, duration: CursorMotion.defaultGlideDuration, arcOffset: arc)
        }
        dragStepDeliveredReset()
        if click { pressBegan = time }
        state.pointer(now: time)
        startTimer(); tick()
        return distance
    }

    func highlightSelection(_ rect: CGRect?, snapshot: WindowSnapshot, guideLines: Bool = true) {
        guard !state.stopped, state.connected, let rect, !rect.isEmpty, !rect.isNull else { return }
        observed(snapshot)
        selection = CursorMotion.SelectionHighlight(rect: rect, began: now, guideLines: guideLines)
        needsZOrderRaise = true
        startTimer(); tick()
    }

    private func dragStepDeliveredReset() {
        dragStepTrail = []
    }

    private func currentCursorPoint(at time: TimeInterval, within bounds: CGRect) -> CGPoint? {
        if let motion {
            return clampPoint(motion.point(at: time), inside: bounds)
        }
        return nil
    }

    private func clampPoint(_ point: CGPoint, inside bounds: CGRect) -> CGPoint {
        guard !bounds.isEmpty, !bounds.isNull else { return point }
        let safe = bounds.insetBy(dx: min(10, bounds.width * 0.05), dy: min(10, bounds.height * 0.05))
        if safe.isNull || safe.isEmpty { return point }
        return CGPoint(
            x: min(safe.maxX, max(safe.minX, point.x)),
            y: min(safe.maxY, max(safe.minY, point.y))
        )
    }

    static func menu(strings: PresenceStrings, name: String, stopped: Bool, target: AnyObject? = nil,
                     stop: Selector? = nil, permissions: Selector? = nil, showDesktop: Selector? = nil) -> NSMenu {
        let menu = NSMenu()
        let status = stopped ? strings.text("OpenCU is stopped") : String(format: strings.text("OpenCU is using %@"), name)
        let heading = NSMenuItem(title: status, action: nil, keyEquivalent: "")
        heading.isEnabled = false; menu.addItem(heading)
        if let showDesktop, !stopped {
            let show = NSMenuItem(title: strings.text("Show agent desktop"), action: showDesktop, keyEquivalent: "")
            show.target = target; menu.addItem(show)
        }
        let stopItem = NSMenuItem(title: strings.text("Stop"), action: stop, keyEquivalent: "")
        stopItem.target = target; stopItem.isEnabled = !stopped
        menu.addItem(stopItem); menu.addItem(.separator())
        let settings = NSMenuItem(title: strings.text("Permissions…"), action: permissions, keyEquivalent: "")
        settings.target = target; menu.addItem(settings)
        menu.autoenablesItems = false
        return menu
    }
    private func makeMenu() -> NSMenu {
        let menu = Self.menu(strings: PresenceStrings(), name: targetName, stopped: state.stopped,
                             target: self, stop: #selector(stop), permissions: #selector(permissions),
                             showDesktop: desktopVisible ? #selector(showDesktop) : nil)
        menu.delegate = self
        return menu
    }
    func menuWillOpen(_ menu: NSMenu) { trackingMenu = true; onPersonInteraction?() }
    func menuDidClose(_ menu: NSMenu) { trackingMenu = false }
    @objc func stop() {
        state.stop(); hideCursor(); hideSelection(); hideSwarm()
        badgeLifetime.stop(now: now)
        lastBadgeActionText = nil
        badgeView.text = BadgeAction(method: "stopped").localized(PresenceStrings().text)
        badgeView.stopped = true
        needsZOrderRaise = true
        startTimer(); tickBadge(at: now)
        onPersonInteraction?(); onStop?()
        // Update the existing menu after tracking ends, without reopening it.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }; self.statusItem?.menu = self.makeMenu()
        }
    }
    @objc private func permissions() { setup.show(activate: true) }
    @objc private func showDesktop() { onShowDesktop?() }
    func applicationDidBecomeActive(_ notification: Notification) { if desktopVisible { onShowDesktop?() } }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if desktopVisible { onShowDesktop?() }
        return false
    }

    func permissionFailure(_ error: OpenCUError) -> OpenCUError {
        guard state.connected else { return error }
        guard ["ACCESSIBILITY_PERMISSION_REQUIRED", "SCREEN_RECORDING_PERMISSION_REQUIRED"].contains(error.code) else { return error }
        if !prompted { prompted = true; setup.show(activate: false) }
        return OpenCUError(error.code, error.message + (setup.isOpen
            ? " A setup window is open on the Mac. The person must allow access there; wait for them before trying again."
            : " The setup window was closed. Ask the person to open OpenCU Permissions or run opencu setup; do not retry on your own."))
    }

    func pointer(_ point: CGPoint, snapshot: WindowSnapshot, click: Bool) {
        guard !state.stopped, state.connected, let id = snapshot.windowID else { return }
        observed(snapshot)
        syncAgentIdentity()
        let time = now
        let previous = currentCursorPoint(at: time, within: snapshot.bounds)
            ?? PresenceArtwork.anchorPoint(forSlot: hub.identity.slot, within: snapshot.bounds)
        let distance = hypot(point.x - previous.x, point.y - previous.y)
        if !click, let existing = motion, time - existing.began < 0.25, distance <= 64 {
            // Live 60Hz drag steps: lock cursor tip with 0ms lag onto the slider knob in a dead-straight line.
            if distance > 0.25 {
                recordDragTrailSample(previous)
            }
            motion = CursorMotion(start: point, end: point, began: time, duration: 0.016, arcOffset: 0)
        } else if distance > 2.5 {
            dragStepTrail = []
            let arc = CursorMotion.deterministicArcOffset(slot: hub.identity.slot, start: previous, end: point, isDrag: !click)
            motion = CursorMotion(start: previous, end: point, began: time, duration: CursorMotion.defaultGlideDuration, arcOffset: arc)
        } else if let existing = motion {
            // Pre-lock glide already reached (or is finishing at) `point`: preserve its smooth tail!
            if hypot(existing.end.x - point.x, existing.end.y - point.y) > 2.5 {
                motion = CursorMotion(start: previous, end: point, began: time, duration: 0.12, arcOffset: 0)
            }
        } else {
            let entry = PresenceArtwork.entryPoint(forAnchor: point, slot: hub.identity.slot, within: snapshot.bounds)
            let arc = CursorMotion.deterministicArcOffset(slot: hub.identity.slot, start: entry, end: point, isDrag: !click)
            motion = CursorMotion(start: entry, end: point, began: time, duration: CursorMotion.defaultGlideDuration, arcOffset: arc)
        }
        if click { pressBegan = time }
        if var activeSelection = selection, time - activeSelection.began > 0.15 {
            activeSelection.began = time - 0.10
            selection = activeSelection
        }
        state.pointer(now: time)
        targetWindow = id
        needsZOrderRaise = true
        startTimer(); tick()
    }

    private func recordDragTrailSample(_ point: CGPoint) {
        if let first = dragStepTrail.first, hypot(first.point.x - point.x, first.point.y - point.y) < 3.0 {
            return
        }
        let existingPoints = [point] + dragStepTrail.prefix(4).map(\.point)
        dragStepTrail = existingPoints.enumerated().map { index, sample in
            let fraction = CGFloat(index) / 4.0
            return CursorMotion.CometDot(
                point: sample,
                radius: 4.5 - 2.4 * fraction,
                alpha: 0.52 - 0.38 * fraction
            )
        }
    }

    struct SwarmAgentSpec {
        var agentId: String
        var agentName: String
        var colorHex: String
        var rgb: AgentRGB
        var slot: Int
        var mode: SwarmAgentMode
        var point: CGPoint?
        var fromPoint: CGPoint?
        var toPoint: CGPoint?
        var duration: TimeInterval
        var delay: TimeInterval
        var orbitRadius: CGFloat?
        var orbitAngularSpeed: Double?
        var orbitPhase: Double?
        var selectionRect: CGRect?
        var guideLines: Bool
        var showTag: Bool
        var holdDuration: TimeInterval
        var emitCompanion: Bool
    }

    @discardableResult
    func applySwarm(
        specs: [SwarmAgentSpec],
        snapshot: WindowSnapshot,
        clearExisting: Bool = false,
        hideHostCursor: Bool = false,
        hudText: String? = nil,
        updateHudText: Bool = false,
        hudProgress: Double? = nil,
        updateHudProgress: Bool = false
    ) -> [SwarmAgentState] {
        guard !state.stopped, state.connected, snapshot.windowID != nil,
              !snapshot.bounds.isEmpty, !snapshot.bounds.isNull else {
            return []
        }
        let switchingTarget = targetWindow != nil && (targetWindow != snapshot.windowID || targetPID != snapshot.app.pid)
        if switchingTarget {
            hideCursor(); hideSelection(); hideSwarm(); hideBadge()
        }
        targetWindow = snapshot.windowID
        targetPID = snapshot.app.pid
        targetBounds = snapshot.bounds
        hub.updateTarget(windowID: snapshot.windowID, targetPID: snapshot.app.pid)
        syncAgentIdentity()
        if hideHostCursor {
            hideCursor()
            hideSelection()
        }

        let time = now
        var disconnectedStates: [SwarmAgentState] = []
        if clearExisting {
            disconnectedStates.append(contentsOf: swarmAgents.values.filter(\.companionConnected))
            swarmAgents.removeAll()
        }
        if updateHudText {
            let trimmed = hudText?.trimmingCharacters(in: .whitespacesAndNewlines)
            swarmHudText = (trimmed?.isEmpty == false) ? trimmed : nil
        }
        if updateHudProgress {
            swarmHudProgress = hudProgress
        }

        let totalSpecs = max(1, specs.count)
        for (idx, spec) in specs.enumerated() {
            let existing = swarmAgents[spec.agentId]
            if spec.mode == .dismiss {
                if var entry = existing {
                    entry.mode = .dismiss
                    entry.dismissBegan = time + max(0, spec.delay)
                    entry.lastUpdatedAt = time
                    swarmAgents[spec.agentId] = entry
                    if entry.companionConnected {
                        disconnectedStates.append(entry)
                        swarmAgents[spec.agentId]?.companionConnected = false
                    }
                }
                continue
            }

            let began = time + max(0, spec.delay)
            let liveCurrent = existing.map { clampPoint($0.point(at: time), inside: snapshot.bounds) }
            let defaultAnchor = PresenceArtwork.anchorPoint(forSlot: spec.slot, within: snapshot.bounds)
            let fallbackStart = spec.fromPoint
                ?? liveCurrent
                ?? PresenceArtwork.entryPoint(forAnchor: spec.toPoint ?? spec.point ?? defaultAnchor, slot: spec.slot, within: snapshot.bounds)
            let destination = spec.toPoint ?? spec.point ?? liveCurrent ?? defaultAnchor
            let flightDuration = max(0.04, spec.duration)
            let isDragMode = spec.mode == .drag
            let arc = CursorMotion.deterministicArcOffset(slot: spec.slot, start: fallbackStart, end: destination, isDrag: isDragMode)
            let motion = CursorMotion(
                start: fallbackStart,
                end: destination,
                began: began,
                duration: flightDuration,
                arcOffset: arc
            )

            var entry = existing ?? SwarmAgentState(
                agentId: spec.agentId,
                agentName: spec.agentName,
                colorHex: spec.colorHex,
                rgb: spec.rgb,
                slot: spec.slot,
                mode: spec.mode,
                motion: motion,
                lastUpdatedAt: time
            )
            entry.agentName = spec.agentName
            entry.colorHex = spec.colorHex
            entry.rgb = spec.rgb
            entry.slot = spec.slot
            entry.mode = spec.mode
            entry.motion = motion
            entry.dismissBegan = nil
            entry.showTag = spec.showTag
            entry.holdDuration = max(1.5, spec.holdDuration)
            entry.lastUpdatedAt = max(time, began + flightDuration)
            if spec.emitCompanion {
                entry.emitCompanion = true
            }

            if let selRect = spec.selectionRect, !selRect.isEmpty, !selRect.isNull {
                entry.selection = CursorMotion.SelectionHighlight(
                    rect: selRect,
                    began: began,
                    holdDuration: max(1.35, flightDuration + 1.05),
                    guideLines: spec.guideLines
                )
            } else if spec.mode != .ripple {
                entry.selection = nil
            }

            switch spec.mode {
            case .orbit:
                let center = spec.point
                    ?? spec.toPoint
                    ?? CGPoint(x: snapshot.bounds.midX, y: snapshot.bounds.midY)
                entry.orbitCenter = center
                let maxOrbitR = min(snapshot.bounds.width, snapshot.bounds.height) * 0.36
                entry.orbitRadius = spec.orbitRadius ?? min(maxOrbitR, max(54, min(snapshot.bounds.width, snapshot.bounds.height) * 0.19))
                entry.orbitAngularSpeed = spec.orbitAngularSpeed ?? 2.35
                entry.orbitPhase = spec.orbitPhase ?? (Double(idx) * (2.0 * .pi / Double(totalSpecs)))
                entry.orbitBegan = began
                entry.pendingClickAt = nil
            case .click:
                let distance = hypot(destination.x - fallbackStart.x, destination.y - fallbackStart.y)
                if distance <= 3.0 && spec.delay <= 0.005 {
                    entry.pressBegan = time
                    entry.pendingClickAt = nil
                } else {
                    entry.pendingClickAt = began + flightDuration * 0.92
                }
            case .ripple:
                entry.motion = CursorMotion(start: destination, end: destination, began: began, duration: 0.05, arcOffset: 0)
                if spec.delay <= 0.005 {
                    entry.pressBegan = time
                    entry.pendingClickAt = nil
                } else {
                    entry.pendingClickAt = began
                }
            case .glide, .drag, .dismiss:
                entry.pendingClickAt = nil
            }

            swarmAgents[spec.agentId] = entry
        }

        needsZOrderRaise = true
        startTimer(); tick()
        return disconnectedStates
    }

    func markSwarmCompanionConnected(agentId: String) {
        swarmAgents[agentId]?.companionConnected = true
    }

    func updateSwarmAgentLivePoint(agentId: String, point: CGPoint, click: Bool = false) {
        guard var entry = swarmAgents[agentId] else { return }
        let time = now
        let prev = entry.point(at: time)
        entry.motion = CursorMotion(start: prev, end: point, began: time - 0.012, duration: 0.024, arcOffset: 0)
        entry.lastUpdatedAt = time
        if click {
            entry.pressBegan = time
            entry.pendingClickAt = nil
        }
        if var sel = entry.selection {
            sel.began = time - 0.08
            entry.selection = sel
        }
        swarmAgents[agentId] = entry
        startTimer(); tick()
    }

    func clearSwarm() -> [SwarmAgentState] {
        let connected = swarmAgents.values.filter(\.companionConnected)
        hideSwarm()
        return connected
    }

    private func swarmActive(at time: TimeInterval) -> Bool {
        if swarmHudText != nil { return true }
        return swarmAgents.values.contains { $0.opacity(at: time) > 0.005 }
    }

    private func hideSwarm() {
        swarmAgents.removeAll()
        swarmHudText = nil
        swarmHudProgress = nil
        if swarmPanel?.isVisible == true {
            swarmPanel?.orderOut(nil)
        }
    }

    private func refreshBadgeDisplayText() {
        guard !badgeView.stopped, let actionText = lastBadgeActionText else { return }
        if hub.shouldShowCursorTag() {
            let prefix = state.waitingTurn ? "⏳ \(hub.identity.agentName)" : hub.identity.agentName
            badgeView.text = "\(prefix) · \(actionText)"
        } else {
            badgeView.text = state.waitingTurn ? "⏳ \(actionText)" : actionText
        }
    }

    func badge(method: String, args: Arguments, snapshot: WindowSnapshot) {
        guard state.connected else { return }
        observed(snapshot)
        guard !state.stopped, let id = snapshot.windowID, let window = snapshot.window else { return }
        guard let selected = axSelectedWindow(AXUIElementCreateApplication(snapshot.app.pid)), CFEqual(selected, window) else {
            hideBadge(); return
        }
        syncAgentIdentity()
        let actionText = BadgeAccessibility.action(method: method, args: args, snapshot: snapshot).localized(PresenceStrings().text)
        lastBadgeActionText = actionText
        badgeView.stopped = false
        refreshBadgeDisplayText()
        badgeTitleHeight = BadgeAccessibility.titleBarHeight(window: window, bounds: snapshot.bounds)
        badgeLifetime.call(target: "\(snapshot.app.pid):\(id)", now: now)
        needsZOrderRaise = true
        startTimer(); tickBadge(at: now)
    }

    private func makeOverlayPanel(contentView: NSView) -> CursorWindow {
        let panel = CursorWindow(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.sharingType = panelSharingType
        panel.level = Self.overlayWindowLevel
        panel.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle, .fullScreenAuxiliary]
        panel.contentView = contentView
        return panel
    }

    private func liveWindowBounds(id: CGWindowID, pid: pid_t) -> CGRect? {
        guard let records = CGWindowListCopyWindowInfo(.optionIncludingWindow, id) as? [[String: Any]],
              let record = records.first(where: { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value == id }),
              (record[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid,
              record[kCGWindowIsOnscreen as String] as? Bool == true,
              let raw = record[kCGWindowBounds as String] as? NSDictionary,
              let bounds = CGRect(dictionaryRepresentation: raw as CFDictionary),
              abs(bounds.width - targetBounds.width) <= 2,
              abs(bounds.height - targetBounds.height) <= 2 else {
            return nil
        }
        return bounds
    }

    private func selectionActive(at time: TimeInterval) -> Bool {
        guard let selection else { return false }
        return selection.opacity(at: time, waitingTurn: state.waitingTurn) > 0.01
    }

    private func tickSelection(at time: TimeInterval, bounds: CGRect?, raise: Bool) {
        guard !state.stopped, state.connected, let bounds, let currentSelection = selection else {
            if selectionPanel?.isVisible == true { selectionPanel?.orderOut(nil) }
            return
        }
        let alpha = currentSelection.opacity(at: time, waitingTurn: state.waitingTurn)
        guard alpha > 0.01 else {
            selection = nil
            if selectionPanel?.isVisible == true { selectionPanel?.orderOut(nil) }
            return
        }
        let canvas = PresenceArtwork.selectionCanvasRect(
            for: currentSelection.rect,
            within: bounds,
            showGuides: currentSelection.guideLines
        )
        guard !canvas.isNull, !canvas.isEmpty else {
            if selectionPanel?.isVisible == true { selectionPanel?.orderOut(nil) }
            return
        }
        if selectionPanel == nil {
            selectionPanel = makeOverlayPanel(contentView: selectionView)
        }
        guard let panel = selectionPanel else { return }
        selectionView.selectionRect = CGRect(
            x: currentSelection.rect.minX - canvas.minX,
            y: currentSelection.rect.minY - canvas.minY,
            width: currentSelection.rect.width,
            height: currentSelection.rect.height
        )
        selectionView.agentColor = hub.identity.rgb.nsColor
        selectionView.boxAlpha = alpha
        selectionView.showGuides = currentSelection.guideLines
        selectionView.needsDisplay = true
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        panel.sharingType = panelSharingType
        panel.level = Self.overlayWindowLevel
        panel.setFrame(CursorMotion.appKitRect(canvas, primaryHeight: primaryHeight), display: false)
        if NSApp.isHidden { NSApp.unhideWithoutActivation() }
        if !panel.isVisible || raise {
            panel.orderFrontRegardless()
        }
    }

    private func tickSwarm(at time: TimeInterval, bounds: CGRect?, raise: Bool) {
        guard !state.stopped, state.connected, let bounds, !bounds.isEmpty, !bounds.isNull else {
            if swarmPanel?.isVisible == true { swarmPanel?.orderOut(nil) }
            return
        }
        var expiredIDs: [String] = []
        var renderItems: [ClusterSwarmOverlayView.RenderItem] = []
        renderItems.reserveCapacity(swarmAgents.count)

        let sortedKeys = swarmAgents.keys.sorted { lhs, rhs in
            let a = swarmAgents[lhs]!
            let b = swarmAgents[rhs]!
            if a.slot != b.slot { return a.slot < b.slot }
            return a.agentId < b.agentId
        }

        for key in sortedKeys {
            guard var agent = swarmAgents[key] else { continue }
            agent.advanceEffects(at: time)
            let alpha = agent.opacity(at: time)
            if alpha <= 0.005 {
                expiredIDs.append(key)
                continue
            }
            swarmAgents[key] = agent

            let screenPoint = clampPoint(agent.point(at: time), inside: bounds)
            let localPoint = CGPoint(x: screenPoint.x - bounds.minX, y: screenPoint.y - bounds.minY)
            let localTrail = agent.trail(at: time).map {
                CursorMotion.CometDot(
                    point: CGPoint(x: $0.point.x - bounds.minX, y: $0.point.y - bounds.minY),
                    radius: $0.radius,
                    alpha: $0.alpha
                )
            }
            let tag: String? = agent.showTag ? agent.agentName : nil
            let (_, flipLeft) = PresenceArtwork.cursorCanvasRect(
                at: screenPoint,
                trail: [],
                tag: tag,
                waitingTurn: false,
                within: bounds
            )

            var localSelRect: CGRect?
            var selAlpha: CGFloat = 0
            var showGuides = false
            if let sel = agent.selection, time >= sel.began {
                let rawAlpha = sel.opacity(at: time, waitingTurn: false)
                if rawAlpha > 0.01 {
                    localSelRect = CGRect(
                        x: sel.rect.minX - bounds.minX,
                        y: sel.rect.minY - bounds.minY,
                        width: sel.rect.width,
                        height: sel.rect.height
                    )
                    selAlpha = rawAlpha
                    showGuides = sel.guideLines
                }
            }

            renderItems.append(
                ClusterSwarmOverlayView.RenderItem(
                    slot: agent.slot,
                    point: localPoint,
                    press: CursorMotion.press(at: time, began: agent.pressBegan),
                    ripple: CursorMotion.rippleProgress(at: time, began: agent.pressBegan),
                    color: agent.rgb.nsColor,
                    rgb: agent.rgb,
                    trail: localTrail,
                    tag: tag,
                    flipTagLeft: flipLeft,
                    alpha: alpha,
                    selectionRect: localSelRect,
                    selectionAlpha: selAlpha,
                    showGuides: showGuides
                )
            )
        }

        for id in expiredIDs {
            swarmAgents.removeValue(forKey: id)
        }

        guard !renderItems.isEmpty || swarmHudText != nil else {
            if swarmPanel?.isVisible == true { swarmPanel?.orderOut(nil) }
            return
        }

        if swarmPanel == nil {
            swarmPanel = makeOverlayPanel(contentView: swarmView)
        }
        guard let panel = swarmPanel else { return }
        swarmView.items = renderItems
        swarmView.pulsePhase = time
        swarmView.hudText = swarmHudText
        swarmView.hudProgress = swarmHudProgress
        swarmView.needsDisplay = true

        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        panel.sharingType = panelSharingType
        panel.level = Self.overlayWindowLevel
        panel.setFrame(CursorMotion.appKitRect(bounds, primaryHeight: primaryHeight), display: false)
        if NSApp.isHidden { NSApp.unhideWithoutActivation() }
        if !panel.isVisible || raise {
            panel.orderFrontRegardless()
        }
    }

    private func tickBadge(at time: TimeInterval, liveBounds: CGRect? = nil, raise: Bool = false) {
        let opacity = badgeLifetime.opacity(at: time)
        let resolvedBounds: CGRect?
        if let liveBounds {
            resolvedBounds = liveBounds
        } else if let id = targetWindow, let pid = targetPID {
            resolvedBounds = liveWindowBounds(id: id, pid: pid)
        } else {
            resolvedBounds = nil
        }
        guard opacity > 0, let id = targetWindow, let bounds = resolvedBounds else {
            if badgePanel?.isVisible == true { badgePanel?.orderOut(nil) }
            return
        }
        let placement = hub.peerPlacement(for: id)
        let layout = BadgeLayout(window: bounds, titleBarHeight: badgeTitleHeight,
                                 textWidth: BadgeView.textWidth(badgeView.text),
                                 peerIndex: placement.peerIndex, peerCount: placement.peerCount)
        guard layout.frame.width >= 29 else { hideBadge(); return }
        if badgePanel == nil {
            badgePanel = makeOverlayPanel(contentView: badgeView)
        }
        guard let panel = badgePanel else { return }
        let frame = layout.frame.insetBy(dx: -BadgeLayout.shadowInset, dy: -BadgeLayout.shadowInset)
        panel.sharingType = panelSharingType
        panel.level = Self.overlayWindowLevel
        panel.setFrame(CursorMotion.appKitRect(frame, primaryHeight: NSScreen.screens.first?.frame.height ?? 0), display: false)
        panel.alphaValue = opacity
        badgeView.accentColor = hub.identity.rgb.nsColor
        badgeView.glyphOnly = layout.glyphOnly
        badgeView.needsDisplay = true
        if NSApp.isHidden { NSApp.unhideWithoutActivation() }
        if !panel.isVisible || raise {
            panel.orderFrontRegardless()
        }
    }

    private func hideSelection() {
        selection = nil
        if selectionPanel?.isVisible == true { selectionPanel?.orderOut(nil) }
    }

    private func hideBadge() {
        badgeLifetime.hide()
        lastBadgeActionText = nil
        if badgePanel?.isVisible == true { badgePanel?.orderOut(nil) }
    }

    private func startTimer() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        // Menu tracking must not pause Stop-related cleanup or the idle timeout.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func tick() {
        dispatchPrecondition(condition: .onQueue(.main))
        let time = now
        let raise = needsZOrderRaise
        needsZOrderRaise = false

        if !desktopVisible, !state.menuVisible(at: time), !trackingMenu, let item = statusItem {
            NSStatusBar.system.removeStatusItem(item); statusItem = nil
        }

        let bounds: CGRect?
        if let id = targetWindow, let pid = targetPID {
            bounds = liveWindowBounds(id: id, pid: pid)
            if let bounds, bounds.origin != targetBounds.origin {
                let dx = bounds.minX - targetBounds.minX
                let dy = bounds.minY - targetBounds.minY
                targetBounds = bounds
                if let existing = motion, abs(dx) > 0.5 || abs(dy) > 0.5 {
                    motion = CursorMotion(
                        start: CGPoint(x: existing.start.x + dx, y: existing.start.y + dy),
                        end: CGPoint(x: existing.end.x + dx, y: existing.end.y + dy),
                        began: existing.began,
                        duration: existing.duration,
                        arcOffset: existing.arcOffset
                    )
                }
                if var activeSelection = selection, abs(dx) > 0.5 || abs(dy) > 0.5 {
                    activeSelection.rect = activeSelection.rect.offsetBy(dx: dx, dy: dy)
                    selection = activeSelection
                }
                if abs(dx) > 0.5 || abs(dy) > 0.5 {
                    for key in Array(swarmAgents.keys) {
                        guard var agent = swarmAgents[key] else { continue }
                        agent.orbitCenter = CGPoint(x: agent.orbitCenter.x + dx, y: agent.orbitCenter.y + dy)
                        agent.motion = CursorMotion(
                            start: CGPoint(x: agent.motion.start.x + dx, y: agent.motion.start.y + dy),
                            end: CGPoint(x: agent.motion.end.x + dx, y: agent.motion.end.y + dy),
                            began: agent.motion.began,
                            duration: agent.motion.duration,
                            arcOffset: agent.motion.arcOffset
                        )
                        if var sel = agent.selection {
                            sel.rect = sel.rect.offsetBy(dx: dx, dy: dy)
                            agent.selection = sel
                        }
                        swarmAgents[key] = agent
                    }
                }
            }
        } else {
            bounds = nil
        }

        // Order badge -> selection -> swarm canvas -> primary cursor so level-25 layers stack cleanly.
        tickBadge(at: time, liveBounds: bounds, raise: raise)
        tickSelection(at: time, bounds: bounds, raise: raise)
        tickSwarm(at: time, bounds: bounds, raise: raise)

        if state.cursorVisible(at: time), let motion, let bounds {
            let point = motion.point(at: time)
            let computedTrail = motion.cometTrail(at: time)
            let activeTrail = computedTrail.isEmpty ? dragStepTrail : computedTrail
            if computedTrail.isEmpty, time - motion.began > 0.12 {
                dragStepTrail = []
            }
            let tag = (hub.shouldShowCursorTag() || !swarmAgents.isEmpty) ? hub.identity.agentName : nil
            let (rect, flipLeft) = PresenceArtwork.cursorCanvasRect(
                at: point,
                trail: activeTrail,
                tag: tag,
                waitingTurn: state.waitingTurn,
                within: bounds
            )
            if !rect.isNull && !rect.isEmpty {
                if overlay == nil {
                    overlay = makeOverlayPanel(contentView: cursor)
                }
                if let panel = overlay {
                    cursor.hotspot = CGPoint(x: point.x - rect.minX, y: point.y - rect.minY)
                    cursor.press = CursorMotion.press(at: time, began: pressBegan)
                    cursor.ripple = CursorMotion.rippleProgress(at: time, began: pressBegan)
                    cursor.agentRGB = hub.identity.rgb
                    cursor.agentColor = hub.identity.rgb.nsColor
                    cursor.trail = activeTrail.map {
                        CursorMotion.CometDot(
                            point: CGPoint(x: $0.point.x - rect.minX, y: $0.point.y - rect.minY),
                            radius: $0.radius,
                            alpha: $0.alpha
                        )
                    }
                    cursor.tagText = tag
                    cursor.flipTagLeft = flipLeft
                    cursor.waitingTurn = state.waitingTurn
                    cursor.pulsePhase = time
                    let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
                    panel.sharingType = panelSharingType
                    panel.level = Self.overlayWindowLevel
                    panel.setFrame(CursorMotion.appKitRect(rect, primaryHeight: primaryHeight), display: false)
                    cursor.needsDisplay = true
                    if NSApp.isHidden { NSApp.unhideWithoutActivation() }
                    if !panel.isVisible || raise {
                        panel.orderFrontRegardless()
                    }
                }
            } else if overlay?.isVisible == true {
                overlay?.orderOut(nil)
            }
        } else {
            if !state.cursorVisible(at: time) { hideCursor() }
            else if overlay?.isVisible == true { overlay?.orderOut(nil) }
        }

        if statusItem == nil && !state.cursorVisible(at: time) && badgeLifetime.opacity(at: time) == 0 && !selectionActive(at: time) && !swarmActive(at: time) {
            timer?.invalidate(); timer = nil
        }
    }

    func hideCursor() {
        state.hideCursor()
        if overlay?.isVisible == true { overlay?.orderOut(nil) }
        motion = nil; dragStepTrail = []; pressBegan = nil
    }

    func disconnect() {
        state.disconnect(); badgeLifetime.disconnect(); hideBadge(); hideSelection(); hideSwarm(); hideCursor(); timer?.invalidate(); timer = nil
        if let item = statusItem { NSStatusBar.system.removeStatusItem(item); statusItem = nil }
        setup.close()
    }
}
