import AppKit
import ApplicationServices

struct PresenceStrings {
    let bundle: Bundle
    init(language: String? = nil, resources: Bundle = .main) {
        if let language, let path = resources.path(forResource: language, ofType: "lproj"), let localized = Bundle(path: path) {
            bundle = localized
        } else { bundle = resources }
    }
    func text(_ key: String) -> String { bundle.localizedString(forKey: key, value: key, table: "Presence") }
}

@MainActor
final class SetupContentView: NSView {
    private let strings: PresenceStrings
    private let axStatus = NSTextField(labelWithString: "")
    private let screenStatus = NSTextField(labelWithString: "")
    private let axButton: NSButton
    private let screenButton: NSButton
    private let footer = NSTextField(wrappingLabelWithString: "")
    private let done: NSButton
    var allowAccessibility: (() -> Void)?
    var allowScreenRecording: (() -> Void)?
    var finish: (() -> Void)?

    init(strings: PresenceStrings = PresenceStrings(), status: PermissionStatus) {
        self.strings = strings
        axButton = NSButton(title: strings.text("Allow…"), target: nil, action: nil)
        screenButton = NSButton(title: strings.text("Allow…"), target: nil, action: nil)
        done = NSButton(title: strings.text("Done"), target: nil, action: nil)
        super.init(frame: NSRect(x: 0, y: 0, width: 500, height: 360))
        let icon = NSImageView()
        icon.image = PresenceArtwork.appIcon
        icon.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([icon.widthAnchor.constraint(equalToConstant: 56), icon.heightAnchor.constraint(equalToConstant: 56)])
        let title = NSTextField(labelWithString: strings.text("Set up OpenCU"))
        title.font = .systemFont(ofSize: 23, weight: .semibold)
        let intro = NSTextField(wrappingLabelWithString: strings.text("OpenCU runs locally, needs no account, and uses the same permissions whichever agent starts it."))
        intro.textColor = .secondaryLabelColor
        intro.font = .systemFont(ofSize: 13)
        let header = NSStackView(views: [icon, NSStackView(views: [title, intro])])
        let heading = header.arrangedSubviews[1] as! NSStackView
        heading.orientation = .vertical; heading.alignment = .leading; heading.spacing = 7
        header.orientation = .horizontal; header.spacing = 18; header.alignment = .centerY
        func row(_ name: String, _ purpose: String, _ label: NSTextField, _ button: NSButton) -> NSView {
            let title = NSTextField(labelWithString: strings.text(name))
            title.font = .systemFont(ofSize: 14, weight: .semibold)
            let detail = NSTextField(labelWithString: strings.text(purpose))
            detail.font = .systemFont(ofSize: 12); detail.textColor = .secondaryLabelColor
            let text = NSStackView(views: [title, detail])
            text.orientation = .vertical; text.alignment = .leading; text.spacing = 5
            let controls = NSStackView(views: [label, button])
            controls.orientation = .horizontal
            let row = NSStackView(views: [text, NSView(), controls])
            row.orientation = .horizontal; row.alignment = .centerY
            button.bezelStyle = .rounded
            label.font = .systemFont(ofSize: 13)
            return row
        }
        let ax = row("Accessibility", "To read and operate app controls", axStatus, axButton)
        let screen = row("Screen Recording", "To see app windows", screenStatus, screenButton)
        let divider = NSBox(); divider.boxType = .separator
        footer.font = .systemFont(ofSize: 12); footer.textColor = .secondaryLabelColor
        done.bezelStyle = .rounded; done.keyEquivalent = "\r"
        let bottom = NSStackView(views: [footer, NSView(), done]); bottom.orientation = .horizontal
        let stack = NSStackView(views: [header, divider, ax, screen, bottom])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 24
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 28),
                                     stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -28),
                                     stack.topAnchor.constraint(equalTo: topAnchor, constant: 28),
                                     stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -24)])
        for view in [header, divider, ax, screen, bottom] {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        intro.widthAnchor.constraint(equalToConstant: 334).isActive = true
        footer.widthAnchor.constraint(lessThanOrEqualToConstant: 340).isActive = true
        axButton.target = self; axButton.action = #selector(requestAX)
        screenButton.target = self; screenButton.action = #selector(requestScreen)
        done.target = self; done.action = #selector(closeSetup)
        update(status)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func draw(_ dirtyRect: NSRect) { NSColor.windowBackgroundColor.setFill(); bounds.fill() }
    func update(_ status: PermissionStatus) {
        for (granted, label, button) in [(status.accessibility, axStatus, axButton), (status.screenRecording, screenStatus, screenButton)] {
            label.stringValue = "✓ " + strings.text("Allowed")
            label.textColor = .systemGreen
            label.isHidden = !granted; button.isHidden = granted
        }
        footer.stringValue = strings.text(status.reconnect ? "Reconnect your agent to finish" : status.ready ? "OpenCU is ready" : "Allow both permissions in System Settings.")
        done.isHidden = !(status.accessibility && status.screenRecording)
        layoutSubtreeIfNeeded()
    }
    @objc private func requestAX() { allowAccessibility?() }
    @objc private func requestScreen() { allowScreenRecording?() }
    @objc private func closeSetup() { finish?() }
}

@MainActor
final class PermissionSetup: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private var content: SetupContentView?
    private var timer: Timer?
    private let recordingAtLaunch = CGPreflightScreenCaptureAccess()
    private var requestedRecording = false
    var willShow: (() -> Void)?
    var didClose: (() -> Void)?
    var isOpen: Bool { window?.isVisible == true }

    private func status() -> PermissionStatus {
        let recording = CGPreflightScreenCaptureAccess()
        // Preflight can stay stale until relaunch. Never claim ready after a
        // Screen Recording request in this process; no TCC database inspection.
        return PermissionStatus(accessibility: AXIsProcessTrusted(), screenRecording: recording,
                                reconnect: !recordingAtLaunch && (recording || requestedRecording))
    }
    func show(activate: Bool) {
        willShow?()
        if window == nil {
            let view = SetupContentView(status: status())
            let window = NSWindow(contentRect: view.bounds, styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = PresenceStrings().text("Set up OpenCU")
            window.isReleasedWhenClosed = false
            window.level = .normal
            window.contentView = view
            window.delegate = self
            window.center()
            view.allowAccessibility = { [weak self] in self?.requestAccessibility() }
            view.allowScreenRecording = { [weak self] in self?.requestScreenRecording() }
            view.finish = { [weak self] in self?.window?.close() }
            self.window = window; content = view
        }
        refresh()
        if NSApp.isHidden { NSApp.unhideWithoutActivation() }
        if activate {
            NSApp.activate(ignoringOtherApps: true)
            window?.makeKeyAndOrderFront(nil)
        } else {
            // Automatic setup is visible at normal level, but a failed tool call
            // must not take the person's foreground. They can click the window.
            window?.orderFrontRegardless()
        }
        timer?.invalidate()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }
    private func refresh() { content?.update(status()) }
    private func requestAccessibility() {
        _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
        refresh()
    }
    private func requestScreenRecording() {
        requestedRecording = true
        _ = CGRequestScreenCaptureAccess()
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
        refresh()
    }
    func close() { window?.close() }
    func windowWillClose(_ notification: Notification) {
        timer?.invalidate(); timer = nil
        if NSWorkspace.shared.frontmostApplication?.processIdentifier == getpid() { NSApp.hide(nil) }
        didClose?()
    }
}
