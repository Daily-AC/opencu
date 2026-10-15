import AppKit

@MainActor
private final class CursorWindow: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Owns only OpenCU UI. Input delivery is reported through one small callback;
/// this class never sends events, changes the real cursor or activates a target.
@MainActor
final class PresenceController: NSObject, NSMenuDelegate {
    private(set) var state = PresenceState()
    let setup = PermissionSetup()
    var onStop: (() -> Void)?
    var onPersonInteraction: (() -> Void)?
    private var statusItem: NSStatusItem?
    private var timer: Timer?
    private var overlay: CursorWindow?
    private let cursor = AgentCursorView(frame: NSRect(x: 0, y: 0, width: 60, height: 60))
    private var motion: CursorMotion?
    private var pressBegan: TimeInterval?
    private var targetWindow: CGWindowID?
    private var targetPID: pid_t?
    private var targetBounds: CGRect = .zero
    private var targetName = ""
    private var lastQuery: String?
    private var prompted = false
    private var trackingMenu = false
    private var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    override init() {
        super.init()
        setup.willShow = { [weak self] in self?.onPersonInteraction?() }
    }
    func beginCall(query: String) {
        if lastQuery != query { hideCursor() }
        lastQuery = query
        called(target: nil, name: query)
    }
    func called(target: String?, name: String) {
        guard state.connected else { return }
        if let target, state.target != target { hideCursor() }
        state.call(target: target ?? state.target ?? name, now: now)
        targetName = name
        if statusItem == nil {
            let item = NSStatusBar.system.statusItem(withLength: 28)
            item.button?.image = PresenceArtwork.glyph(size: NSSize(width: 24, height: 18))
            item.button?.setAccessibilityLabel("OpenCU")
            statusItem = item
        }
        if !trackingMenu { statusItem?.menu = makeMenu() }
        startTimer()
    }
    func finishedCall() { state.finished(now: now) }
    func observed(_ snapshot: WindowSnapshot) {
        if targetWindow != snapshot.windowID || targetPID != snapshot.app.pid || targetBounds != snapshot.bounds { hideCursor() }
        targetWindow = snapshot.windowID; targetPID = snapshot.app.pid
        targetBounds = snapshot.bounds
    }
    static func menu(strings: PresenceStrings, name: String, stopped: Bool, target: AnyObject? = nil,
                     stop: Selector? = nil, permissions: Selector? = nil) -> NSMenu {
        let menu = NSMenu()
        let status = stopped ? strings.text("OpenCU is stopped") : String(format: strings.text("OpenCU is using %@"), name)
        let heading = NSMenuItem(title: status, action: nil, keyEquivalent: "")
        heading.isEnabled = false; menu.addItem(heading)
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
                             target: self, stop: #selector(stop), permissions: #selector(permissions))
        menu.delegate = self
        return menu
    }
    func menuWillOpen(_ menu: NSMenu) { trackingMenu = true; onPersonInteraction?() }
    func menuDidClose(_ menu: NSMenu) { trackingMenu = false }
    @objc private func stop() {
        state.stop(); hideCursor(); onPersonInteraction?(); onStop?()
        // Update the existing menu after tracking ends, without reopening it.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }; self.statusItem?.menu = self.makeMenu()
        }
    }
    @objc private func permissions() { setup.show(activate: true) }

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
        let time = now
        let previous = state.cursorVisible(at: time) ? motion?.point(at: time) : nil
        motion = CursorMotion(start: previous ?? point, end: point, began: time)
        if click { pressBegan = time }
        state.pointer(now: time)
        targetWindow = id
        startTimer(); tick()
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
        let time = now
        if !state.menuVisible(at: time), !trackingMenu, let item = statusItem {
            NSStatusBar.system.removeStatusItem(item); statusItem = nil
        }
        if state.cursorVisible(at: time), let motion, let id = targetWindow, let pid = targetPID,
           let records = CGWindowListCopyWindowInfo(.optionIncludingWindow, id) as? [[String: Any]],
           let record = records.first(where: { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value == id }),
           (record[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid,
           record[kCGWindowIsOnscreen as String] as? Bool == true,
           let raw = record[kCGWindowBounds as String] as? NSDictionary,
           let bounds = CGRect(dictionaryRepresentation: raw as CFDictionary), bounds == targetBounds {
            let point = motion.point(at: time)
            // Clip at the target edge. A small window avoids making the entire
            // target look covered to window-occlusion heuristics in other apps.
            let rect = CGRect(x: point.x - 20, y: point.y - 20, width: 60, height: 60).intersection(bounds)
            if !rect.isNull && !rect.isEmpty {
                if overlay == nil {
                    let panel = CursorWindow(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
                    panel.isOpaque = false; panel.backgroundColor = .clear
                    panel.hasShadow = false; panel.ignoresMouseEvents = true
                    panel.hidesOnDeactivate = false; panel.becomesKeyOnlyIfNeeded = true
                    panel.sharingType = .none
                    panel.collectionBehavior = [.transient, .ignoresCycle, .fullScreenAuxiliary]
                    panel.contentView = cursor
                    overlay = panel
                }
                cursor.hotspot = CGPoint(x: point.x - rect.minX, y: point.y - rect.minY)
                cursor.press = CursorMotion.press(at: time, began: pressBegan)
                let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
                overlay?.setFrame(CursorMotion.appKitRect(rect, primaryHeight: primaryHeight), display: false)
                // Preserve the target's level and immediate neighbour relationship;
                // never orderFront, float above another app, or become key/main.
                overlay?.level = NSWindow.Level(rawValue: (record[kCGWindowLayer as String] as? Int) ?? 0)
                cursor.needsDisplay = true
                if NSApp.isHidden { NSApp.unhideWithoutActivation() }
                overlay?.order(.above, relativeTo: Int(id))
            } else { hideCursor() }
        } else { hideCursor() }
        if statusItem == nil && !state.cursorVisible(at: time) { timer?.invalidate(); timer = nil }
    }
    func hideCursor() {
        state.hideCursor()
        if overlay?.isVisible == true { overlay?.orderOut(nil) }
        motion = nil; pressBegan = nil
    }
    func disconnect() {
        state.disconnect(); hideCursor(); timer?.invalidate(); timer = nil
        if let item = statusItem { NSStatusBar.system.removeStatusItem(item); statusItem = nil }
        setup.close()
    }
}
