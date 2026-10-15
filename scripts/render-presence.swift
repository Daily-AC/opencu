import AppKit

/// Offline renderer: no ordered windows, status items, capture APIs or TCC calls.
@main
struct PresenceRenderer {
    @MainActor static func main() throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let output = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let resources = Bundle(path: CommandLine.arguments[3])!
        PresenceArtwork.iconOverride = NSImage(contentsOfFile: CommandLine.arguments[4])
        for language in ["en", "zh-Hans"] {
            let strings = PresenceStrings(language: language, resources: resources)
            for (theme, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                try withAppearance(NSAppearance(named: appearance)!) {
                    for (name, action, width, titleHeight) in Self.badgeExamples {
                        let sample = BadgeTitleBarSample(text: action.localized(strings.text), width: width,
                                                         titleHeight: titleHeight, dark: theme == "dark", stopped: name == "stopped")
                        sample.appearance = NSAppearance(named: appearance)
                        try render(sample, to: output.appendingPathComponent("badge-\(language)-\(theme)-\(name).png"))
                    }
                    let states: [(String, PermissionStatus)] = [
                        ("none-granted", PermissionStatus(accessibility: false, screenRecording: false)),
                        ("accessibility-granted", PermissionStatus(accessibility: true, screenRecording: false)),
                        ("screen-recording-granted", PermissionStatus(accessibility: false, screenRecording: true)),
                        ("ready", PermissionStatus(accessibility: true, screenRecording: true)),
                        ("reconnect", PermissionStatus(accessibility: true, screenRecording: true, reconnect: true))]
                    for (name, status) in states {
                        let view = SetupContentView(strings: strings, status: status)
                        view.appearance = NSAppearance(named: appearance)
                        try render(view, to: output.appendingPathComponent("setup-\(language)-\(theme)-\(name).png"))
                    }
                    // Native menus cannot be displayed offscreen without running
                    // menu tracking. This is a labelled layout preview generated
                    // from the actual NSMenu's item titles, order and enabled state.
                    let menu = PresenceController.menu(strings: strings, name: "TextEdit", stopped: false)
                    let preview = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 132))
                    preview.wantsLayer = true
                    preview.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
                    var y: CGFloat = 102
                    for item in menu.items {
                        if item.isSeparatorItem {
                            let line = NSBox(frame: NSRect(x: 10, y: y + 12, width: 280, height: 1))
                            line.boxType = .separator; preview.addSubview(line); y -= 12
                        } else {
                            let label = NSTextField(labelWithString: item.title)
                            label.font = .menuFont(ofSize: 13)
                            label.textColor = item.isEnabled ? .labelColor : .secondaryLabelColor
                            label.frame = NSRect(x: 16, y: y, width: 270, height: 22)
                            preview.addSubview(label); y -= 28
                        }
                    }
                    preview.appearance = NSAppearance(named: appearance)
                    try render(preview, to: output.appendingPathComponent("menu-layout-\(language)-\(theme).png"))
                    for scale in [1, 2] {
                        try image(PresenceArtwork.statusGlyph(size: NSSize(width: 18, height: 18)), scale: scale,
                                  to: output.appendingPathComponent("menu-item-\(theme)@\(scale)x.png"))
                    }
                    for (name, press) in [("rest", CGFloat(0)), ("mid-press", CGFloat(1))] {
                        let view = AgentCursorView(frame: NSRect(x: 0, y: 0, width: 60, height: 60))
                        view.press = press; view.appearance = NSAppearance(named: appearance)
                        try render(view, to: output.appendingPathComponent("cursor-\(theme)-\(name).png"))
                    }
                }
            }
        }
        precondition(NSApp.windows.allSatisfy { !$0.isVisible }, "Review must never show a window")
    }
    static var badgeExamples: [(String, BadgeAction, CGFloat, CGFloat?)] { [
        ("reading", BadgeAction(method: "get_app_state"), 720, nil),
        ("click", BadgeAction(method: "click"), 720, nil),
        ("click-label", BadgeAction(method: "click", label: "Save"), 720, nil),
        ("double-click", BadgeAction(method: "click", doubleClick: true), 720, nil),
        ("double-click-label", BadgeAction(method: "click", label: "Document", doubleClick: true), 720, nil),
        ("right-click", BadgeAction(method: "click", rightClick: true), 720, nil),
        ("right-click-label", BadgeAction(method: "click", label: "Document", rightClick: true), 720, nil),
        ("type-short", BadgeAction(method: "type_text", text: "Hello 世界", secure: false), 720, nil),
        ("type-long", BadgeAction(method: "type_text", text: "Hello from a local fixture document", secure: false), 720, nil),
        ("type-secure", BadgeAction(method: "type_text", text: "fixture-password", secure: true), 720, nil),
        ("paste", BadgeAction(method: "paste", text: "A sample paragraph for this fixture", secure: false), 720, nil),
        ("paste-secure", BadgeAction(method: "paste", text: "fixture-password", secure: true), 720, nil),
        ("key-command", BadgeAction(method: "press_key", key: "super+a"), 720, nil),
        ("key-save", BadgeAction(method: "press_key", key: "shift+super+s"), 720, nil),
        ("key-return", BadgeAction(method: "press_key", key: "Return"), 720, nil),
        ("key-tab", BadgeAction(method: "press_key", key: "Tab"), 720, nil),
        ("key-escape", BadgeAction(method: "press_key", key: "Escape"), 720, nil),
        ("menu", BadgeAction(method: "click", menuPath: ["File", "Export", "PDF"]), 720, nil),
        ("scroll", BadgeAction(method: "scroll"), 720, nil),
        ("drag", BadgeAction(method: "drag"), 720, nil),
        ("set-value", BadgeAction(method: "set_value", label: "Filename"), 720, nil),
        ("select-text", BadgeAction(method: "select_text"), 720, nil),
        ("secondary-action", BadgeAction(method: "perform_secondary_action", label: "Show Menu"), 720, nil),
        ("activate", BadgeAction(method: "activate_app"), 720, nil),
        ("truncated", BadgeAction(method: "click", label: "A very long fixture control label that cannot fit in the capsule"), 420, nil),
        ("toolbar", BadgeAction(method: "get_app_state"), 720, 52),
        ("narrow", BadgeAction(method: "get_app_state"), 240, nil),
        ("stopped", BadgeAction(method: "stopped"), 720, nil)
    ] }
    @MainActor static func withAppearance(_ appearance: NSAppearance, body: () throws -> Void) throws {
        var failure: Error?
        appearance.performAsCurrentDrawingAppearance { do { try body() } catch { failure = error } }
        if let failure { throw failure }
    }
    @MainActor static func render(_ view: NSView, to url: URL) throws {
        // Attaching to an unordered window gives standard AppKit controls their
        // normal layout/backing context. Nothing is ever sent to the screen.
        let window = NSWindow(contentRect: view.bounds, styleMask: [.borderless], backing: .buffered, defer: true)
        window.appearance = view.appearance
        window.contentView = view
        view.layoutSubtreeIfNeeded()
        func validateControls(_ child: NSView) {
            if child is NSControl && !child.isHiddenOrHasHiddenAncestor {
                let rect = child.convert(child.bounds, to: view)
                precondition(view.bounds.insetBy(dx: -1, dy: -1).contains(rect), "Control outside review bounds: \(child)")
            }
            child.subviews.forEach(validateControls)
        }
        validateControls(view)
        let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try bitmap.representation(using: .png, properties: [:])!.write(to: url)
        precondition(!window.isVisible)
    }
    @MainActor static func image(_ image: NSImage, scale: Int, to url: URL) throws {
        let pixels = NSSize(width: image.size.width * CGFloat(scale), height: image.size.height * CGFloat(scale))
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(pixels.width), pixelsHigh: Int(pixels.height),
                                      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                      colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        bitmap.size = image.size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        image.draw(in: NSRect(origin: .zero, size: image.size))
        NSGraphicsContext.restoreGraphicsState()
        try bitmap.representation(using: .png, properties: [:])!.write(to: url)
    }
}


/// Synthetic fixture title bar, not a screenshot of any person's application.
@MainActor
final class BadgeTitleBarSample: NSView {
    override var isFlipped: Bool { true }
    let dark: Bool
    let sampleBounds: CGRect
    let titleHeight: CGFloat
    init(text: String, width: CGFloat, titleHeight: CGFloat?, dark: Bool, stopped: Bool) {
        self.dark = dark
        self.titleHeight = titleHeight ?? 28
        sampleBounds = CGRect(x: 16, y: 20, width: width, height: 96)
        super.init(frame: CGRect(x: 0, y: 0, width: width + 32, height: 136))
        let layout = BadgeLayout(window: sampleBounds, titleBarHeight: titleHeight, textWidth: BadgeView.textWidth(text))
        let badge = BadgeView(frame: layout.frame.insetBy(dx: -BadgeLayout.shadowInset, dy: -BadgeLayout.shadowInset))
        badge.text = text; badge.stopped = stopped; badge.glyphOnly = layout.glyphOnly
        addSubview(badge)
        precondition(layout.frame.height == 22 && layout.frame.width <= width * 0.45)
        precondition(abs(sampleBounds.maxX - layout.frame.maxX - 10) < 0.01)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func draw(_ dirtyRect: NSRect) {
        (dark ? NSColor(white: 0.10, alpha: 1) : NSColor(white: 0.90, alpha: 1)).setFill(); bounds.fill()
        (dark ? NSColor(white: 0.18, alpha: 1) : NSColor.white).setFill()
        NSBezierPath(roundedRect: sampleBounds, xRadius: 10, yRadius: 10).fill()
        (dark ? NSColor(white: 0.22, alpha: 1) : NSColor(white: 0.97, alpha: 1)).setFill()
        CGRect(x: sampleBounds.minX, y: sampleBounds.minY, width: sampleBounds.width, height: titleHeight).fill()
        for (index, color) in [NSColor.systemRed, .systemYellow, .systemGreen].enumerated() {
            color.setFill()
            NSBezierPath(ovalIn: CGRect(x: sampleBounds.minX + 12 + CGFloat(index)*20,
                                       y: sampleBounds.minY + titleHeight/2 - 5, width: 10, height: 10)).fill()
        }
        ("Fixture.txt" as NSString).draw(at: CGPoint(x: sampleBounds.minX + 90, y: sampleBounds.minY + titleHeight/2 - 8),
            withAttributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: dark ? NSColor.white : NSColor.darkGray])
    }
}
