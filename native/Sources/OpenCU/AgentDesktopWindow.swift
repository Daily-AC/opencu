import AppKit

@MainActor
private final class AgentDesktopPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Local watch-only presentation. No target event forwarding or activation.
@MainActor
final class AgentDesktopWindow: NSObject, NSWindowDelegate {
    private var panel: NSPanel?
    private let image = NSImageView()
    private let message = NSTextField(wrappingLabelWithString: "Starting…")
    private let allow = NSButton(title: "Move once", target: nil, action: nil)
    private let decline = NSButton(title: "Keep here", target: nil, action: nil)
    private var decision: ((Bool) -> Void)?
    var onStop: (() -> Void)?
    var visible: Bool { panel?.isVisible == true && panel?.isMiniaturized == false }
    var windowID: Int? { panel?.windowNumber }

    func show() throws {
        guard let screen = NSScreen.screens.first else {
            throw OpenCUError("AGENT_DESKTOP_UNAVAILABLE", "No physical screen is available for the agent desktop window.")
        }
        let frame = NSRect(x: screen.visibleFrame.maxX - 496, y: screen.visibleFrame.maxY - 450, width: 480, height: 430)
        let panel = AgentDesktopPanel(contentRect: frame, styleMask: [.titled, .closable, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = "OpenCU agent desktop"
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.delegate = self
        image.imageScaling = .scaleProportionallyUpOrDown
        image.setContentHuggingPriority(.defaultLow, for: .vertical)
        image.translatesAutoresizingMaskIntoConstraints = false
        image.heightAnchor.constraint(equalToConstant: 260).isActive = true
        let title = NSTextField(labelWithString: "Watch only · Close this window to stop")
        title.textColor = .secondaryLabelColor
        message.font = .systemFont(ofSize: 12)
        message.maximumNumberOfLines = 4
        allow.target = self; allow.action = #selector(approve)
        decline.target = self; decline.action = #selector(reject)
        let stop = NSButton(title: "Stop", target: self, action: #selector(stop))
        let buttons = NSStackView(views: [allow, decline, stop])
        buttons.orientation = .horizontal
        let stack = NSStackView(views: [title, image, message, buttons])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView(); panel.contentView = content
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -12),
            image.widthAnchor.constraint(equalTo: stack.widthAnchor),
            message.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        self.panel = panel
        clearConsent()
        panel.orderFrontRegardless() // Nonactivating and never key/main.
    }
    func showFrame(_ frame: CGImage) { image.image = NSImage(cgImage: frame, size: .zero) }
    func clearFrame() { image.image = nil }
    func status(_ text: String) { if decision == nil { message.stringValue = text } }
    func ask(_ proposal: AgentDisplay.Proposal, answer: @escaping (Bool) -> Void) {
        decision = answer
        let title = String(proposal.title.replacingOccurrences(of: "\n", with: " ").prefix(80))
        let appName = String(proposal.app.name.prefix(48))
        allow.title = proposal.requiresMove ? "Move once" : "Allow once"
        message.stringValue = proposal.requiresMove
            ? "Move ‘\(title)’ from \(appName) to the agent desktop? It will return when this desktop closes. The app stays open. Keep the mouse still for 2 seconds after clicking."
            : "Allow this window for the agent? ‘\(title)’ from \(appName) is already on the agent display. OpenCU will not move or restore it."
        allow.isHidden = false; decline.isHidden = false
    }
    func clearConsent() {
        decision = nil; allow.isHidden = true; decline.isHidden = true
        message.stringValue = "Waiting for the agent"
    }
    @objc private func approve() { answer(true) }
    @objc private func reject() { answer(false) }
    private func answer(_ value: Bool) { let callback = decision; clearConsent(); callback?(value) }
    @objc private func stop() { onStop?() }
    func windowWillClose(_ notification: Notification) { onStop?() }
    func windowDidMiniaturize(_ notification: Notification) { onStop?() }
    func close() {
        decision = nil
        panel?.delegate = nil
        panel?.close(); panel = nil
        clearFrame()
    }
}
