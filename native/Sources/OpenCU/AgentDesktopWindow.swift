import AppKit

/// Reports pointer presence so the clean view can reveal its title bar on hover.
@MainActor
private final class HoverView: NSView {
    var onHover: ((Bool) -> Void)?
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { onHover?(true) }
    override func mouseExited(with event: NSEvent) { onHover?(false) }
}

/// The preview's own controls act on the first click, even while OpenCU is in the background.
@MainActor
private final class FirstMouseButton: NSButton {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Local watch-only presentation. No target event forwarding or activation.
/// An ordinary window: closing tucks it into the Dock like minimizing, and its Dock
/// tile or the menu bar shows it again. Only Stop, the menu-bar Stop and macOS Stop
/// Sharing end the desktop.
@MainActor
final class AgentDesktopWindow: NSObject, NSWindowDelegate {
    private static let frameName = "OpenCU agent desktop"
    private static let keepOnTopKey = "AgentDesktopKeepOnTop"
    private static let cleanViewKey = "AgentDesktopCleanView"
    private let strings = PresenceStrings()
    private let defaults = UserDefaults.standard
    private var window: NSWindow?
    private let image = NSImageView()
    private lazy var message = NSTextField(wrappingLabelWithString: strings.text(AgentDesktopStatusText.starting.rawValue))
    private lazy var allow = FirstMouseButton(title: strings.text("Move once"), target: nil, action: nil)
    private lazy var decline = FirstMouseButton(title: strings.text("Keep here"), target: nil, action: nil)
    private lazy var pin = symbolButton(strings.text("Keep on top"), #selector(togglePin))
    private lazy var clean = symbolButton(strings.text("Clean view"), #selector(toggleClean))
    private let bar = NSStackView()
    private var accessory: NSTitlebarAccessoryViewController?
    private var top: (normal: NSLayoutConstraint, clean: NSLayoutConstraint)?
    private var hovering = false
    private var minimizeAfterFullScreen = false
    private var decision: ((Bool) -> Void)?
    var onStop: (() -> Void)?
    /// Reports the picture's on-screen size in pixels after each settled resize.
    var onPictureSize: ((CGSize) -> Void)?
    var windowID: Int? { window?.windowNumber }

    private var keepOnTop: Bool { defaults.bool(forKey: Self.keepOnTopKey) }
    /// A pending consent always shows its card and buttons.
    private var cleanActive: Bool { defaults.bool(forKey: Self.cleanViewKey) && decision == nil }

    func show() throws {
        guard let screen = NSScreen.screens.first else {
            throw OpenCUError("AGENT_DESKTOP_UNAVAILABLE", "No physical screen is available for the agent desktop window.")
        }
        let initial = NSRect(x: screen.visibleFrame.maxX - 496, y: screen.visibleFrame.maxY - 366, width: 480, height: 350)
        let window = NSWindow(contentRect: initial, styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.title = strings.text("OpenCU agent desktop")
        window.hidesOnDeactivate = false
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 320, height: 220)
        // Only restore a size/position that is fully on a physical screen now.
        if !window.setFrameUsingName(Self.frameName)
            || !NSScreen.screens.contains(where: { $0.visibleFrame.contains(window.frame) }) {
            window.setFrame(window.frameRect(forContentRect: initial), display: false)
        }
        window.setFrameAutosaveName(Self.frameName)
        window.delegate = self
        image.imageScaling = .scaleProportionallyUpOrDown
        for orientation in [NSLayoutConstraint.Orientation.horizontal, .vertical] {
            image.setContentHuggingPriority(.init(1), for: orientation)
            image.setContentCompressionResistancePriority(.init(1), for: orientation)
        }
        message.font = .systemFont(ofSize: 12)
        message.maximumNumberOfLines = 0
        allow.target = self; allow.action = #selector(approve)
        decline.target = self; decline.action = #selector(reject)
        let stop = FirstMouseButton(title: strings.text("Stop"), target: self, action: #selector(stop))
        let buttons = NSStackView(views: [allow, decline, stop])
        buttons.orientation = .horizontal
        bar.setViews([message, buttons], in: .top)
        bar.orientation = .vertical; bar.alignment = .leading; bar.spacing = 8
        bar.edgeInsets = NSEdgeInsets(top: 10, left: 16, bottom: 12, right: 16)
        bar.setContentCompressionResistancePriority(.required, for: .vertical)
        let stack = NSStackView(views: [image, bar])
        stack.orientation = .vertical; stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        let content = HoverView()
        content.onHover = { [weak self] inside in self?.hovering = inside; self?.updateChrome() }
        window.contentView = content
        content.addSubview(stack)
        let guide = window.contentLayoutGuide as! NSLayoutGuide
        top = (stack.topAnchor.constraint(equalTo: guide.topAnchor), stack.topAnchor.constraint(equalTo: content.topAnchor))
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            image.widthAnchor.constraint(equalTo: stack.widthAnchor),
            bar.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        let controls = NSStackView(views: [pin, clean])
        controls.spacing = 6
        controls.edgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 10)
        controls.frame = NSRect(origin: .zero, size: controls.fittingSize)
        let accessory = NSTitlebarAccessoryViewController()
        accessory.view = controls
        accessory.layoutAttribute = .trailing
        window.addTitlebarAccessoryViewController(accessory)
        self.accessory = accessory
        self.window = window
        applyKeepOnTop(); clearConsent()
        window.orderFrontRegardless() // Shown without activating OpenCU or taking focus.
        window.layoutIfNeeded(); reportPictureSize()
    }
    /// Shows a hidden or minimized window again without activating OpenCU.
    func reveal() {
        guard let window else { return }
        minimizeAfterFullScreen = false
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.orderFrontRegardless()
    }
    func showFrame(_ frame: CGImage) { image.image = NSImage(cgImage: frame, size: .zero) }
    func clearFrame() { image.image = nil }
    func status(_ status: AgentDesktopStatusText) { if decision == nil { setMessage(strings.text(status.rawValue)) } }
    func ask(_ proposal: AgentDisplay.Proposal, answer: @escaping (Bool) -> Void) {
        decision = answer
        let title = proposal.title == "Untitled window" ? strings.text("Untitled window")
            : String(proposal.title.replacingOccurrences(of: "\n", with: " ").prefix(80))
        let appName = String(proposal.app.name.prefix(48))
        allow.title = strings.text(proposal.requiresMove ? "Move once" : "Allow once")
        let consentText = proposal.requiresMove
            ? strings.format("Move ‘%@’ from %@ to the agent desktop? It will return when this desktop closes. The app stays open.", title, appName)
            : strings.format("Allow this window for the agent? ‘%@’ from %@ is already on the agent display. OpenCU will not move or restore it.", title, appName)
        allow.isHidden = false; decline.isHidden = false
        applyClean()
        setMessage(consentText)
        reveal() // The person must see a pending consent even after hiding the window.
    }
    func clearConsent() {
        decision = nil; allow.isHidden = true; decline.isHidden = true
        applyClean()
        setMessage(strings.text(AgentDesktopStatusText.waiting.rawValue))
    }
    private func setMessage(_ text: String) {
        message.stringValue = text
        // Consent must not lose its return/ownership terms to a cutoff when
        // localized wording or an application/window name wraps.
        guard let window, !bar.isHidden else { return }
        message.preferredMaxLayoutWidth = window.contentLayoutRect.width - 32
        let needed = bar.fittingSize.height + 120 + (window.frame.height - window.contentLayoutRect.height)
        guard !window.styleMask.contains(.fullScreen), window.frame.height < needed else { return }
        var frame = window.frame
        frame.origin.y -= needed - frame.height; frame.size.height = needed
        window.setFrame(frame, display: true)
    }
    func windowDidResize(_ notification: Notification) {
        guard let window else { return }
        message.preferredMaxLayoutWidth = window.contentLayoutRect.width - 32
        if !window.inLiveResize { reportPictureSize() } // Includes zoom and full-screen transitions.
    }
    func windowDidEndLiveResize(_ notification: Notification) { reportPictureSize() }
    private func reportPictureSize() {
        guard let window else { return }
        let size = image.bounds.size, scale = window.backingScaleFactor
        onPictureSize?(CGSize(width: size.width * scale, height: size.height * scale))
    }
    private func symbolButton(_ tip: String, _ action: Selector) -> NSButton {
        let button = FirstMouseButton(image: NSImage(), target: self, action: action)
        button.isBordered = false
        button.toolTip = tip
        button.setAccessibilityLabel(tip)
        return button
    }
    private func symbol(_ name: String, _ tip: String) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: tip)?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .regular))
    }
    @objc private func togglePin() { defaults.set(!keepOnTop, forKey: Self.keepOnTopKey); applyKeepOnTop() }
    @objc private func toggleClean() {
        defaults.set(!defaults.bool(forKey: Self.cleanViewKey), forKey: Self.cleanViewKey); applyClean()
    }
    private func applyKeepOnTop() {
        guard let window else { return }
        pin.image = symbol(keepOnTop ? "pin.fill" : "pin", pin.toolTip ?? "")
        pin.contentTintColor = keepOnTop ? .controlAccentColor : .secondaryLabelColor
        pin.state = keepOnTop ? .on : .off
        guard !window.styleMask.contains(.fullScreen) else { return }
        // Kept on top: above other apps on every Space, like the earlier preview.
        // Otherwise an ordinary window that can use its own full-screen Space.
        window.level = keepOnTop ? .floating : .normal
        window.collectionBehavior = keepOnTop ? [.canJoinAllSpaces, .fullScreenAuxiliary] : [.fullScreenPrimary]
    }
    private func applyClean() {
        guard let window, let top else { return }
        let on = cleanActive
        clean.image = symbol(on ? "rectangle.inset.filled" : "rectangle", clean.toolTip ?? "")
        clean.contentTintColor = defaults.bool(forKey: Self.cleanViewKey) ? .controlAccentColor : .secondaryLabelColor
        clean.state = on ? .on : .off
        bar.isHidden = on
        NSLayoutConstraint.deactivate([on ? top.normal : top.clean])
        NSLayoutConstraint.activate([on ? top.clean : top.normal])
        window.titlebarAppearsTransparent = on
        window.titleVisibility = on ? .hidden : .visible
        window.isMovableByWindowBackground = on
        window.backgroundColor = on ? .black : .windowBackgroundColor
        updateChrome()
    }
    /// The clean view shows only the picture; its title bar returns on hover.
    private func updateChrome() {
        guard let window else { return }
        let hidden = cleanActive && !hovering && !window.styleMask.contains(.fullScreen)
        for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            window.standardWindowButton(kind)?.isHidden = hidden
        }
        accessory?.view.isHidden = hidden
    }
    @objc private func approve() { answer(true) }
    @objc private func reject() { answer(false) }
    private func answer(_ value: Bool) { let callback = decision; clearConsent(); callback?(value) }
    @objc private func stop() { onStop?() }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        // Closing tucks the preview into the Dock, where its tile brings it back.
        // A hidden window would be lost when menu-bar items overflow behind a notch.
        if sender.styleMask.contains(.fullScreen) { minimizeAfterFullScreen = true; sender.toggleFullScreen(nil) }
        else { sender.miniaturize(nil) }
        return false
    }
    func windowWillEnterFullScreen(_ notification: Notification) { pin.isEnabled = false; updateChrome() }
    func windowDidExitFullScreen(_ notification: Notification) {
        pin.isEnabled = true; applyKeepOnTop(); updateChrome()
        if minimizeAfterFullScreen { minimizeAfterFullScreen = false; window?.miniaturize(nil) }
    }
    func close() {
        decision = nil
        window?.delegate = nil
        window?.close(); window = nil
        clearFrame()
    }
}
