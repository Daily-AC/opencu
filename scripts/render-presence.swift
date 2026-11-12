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
                    for entry in AgentSlotPalette.entries.prefix(3) {
                        let view = AgentCursorView(frame: NSRect(x: 0, y: 0, width: 172, height: 86))
                        view.hotspot = CGPoint(x: 42, y: 30)
                        view.press = entry.slot == 1 ? 0.85 : 0
                        view.ripple = entry.slot == 1 ? 0.45 : nil
                        view.agentRGB = entry.rgb
                        view.agentColor = entry.rgb.nsColor
                        view.tagText = entry.defaultName
                        if entry.slot == 0 {
                            let motion = CursorMotion(
                                start: CGPoint(x: 6, y: 12),
                                end: CGPoint(x: 42, y: 30),
                                began: 0,
                                duration: CursorMotion.defaultGlideDuration
                            )
                            view.trail = motion.cometTrail(at: 0.18)
                        } else if entry.slot == 2 {
                            view.waitingTurn = true
                            view.pulsePhase = 0.25
                        }
                        view.appearance = NSAppearance(named: appearance)
                        try render(view, to: output.appendingPathComponent("cursor-\(theme)-slot-\(entry.slot).png"))
                    }
                    let multiBadge = MultiAgentBadgeSample(strings: strings, dark: theme == "dark")
                    multiBadge.appearance = NSAppearance(named: appearance)
                    try render(multiBadge, to: output.appendingPathComponent("badge-\(language)-\(theme)-multi-agent.png"))
                    if language == "en" {
                        let canvas = MultiplayerCanvasSample(dark: theme == "dark")
                        canvas.appearance = NSAppearance(named: appearance)
                        try render(canvas, to: output.appendingPathComponent("multiplayer-canvas-\(theme).png"))

                        let cluster = ClusterSwarm16Sample(dark: theme == "dark")
                        cluster.appearance = NSAppearance(named: appearance)
                        try render(cluster, to: output.appendingPathComponent("cluster-swarm-16-\(theme).png"))
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

@MainActor
final class MultiAgentBadgeSample: NSView {
    override var isFlipped: Bool { true }
    let dark: Bool
    let sampleBounds = CGRect(x: 16, y: 20, width: 760, height: 96)
    let titleHeight: CGFloat = 28
    init(strings: PresenceStrings, dark: Bool) {
        self.dark = dark
        super.init(frame: CGRect(x: 0, y: 0, width: 792, height: 136))
        let peers: [(Int, String, BadgeAction)] = [
            (0, "Coder", BadgeAction(method: "click", label: "Save")),
            (1, "Reviewer", BadgeAction(method: "get_app_state")),
        ]
        var placedFrames: [CGRect] = []
        for (rank, (slot, name, action)) in peers.enumerated() {
            let text = "\(name) · \(action.localized(strings.text))"
            let layout = BadgeLayout(window: sampleBounds, titleBarHeight: titleHeight,
                                     textWidth: BadgeView.textWidth(text), peerIndex: rank, peerCount: peers.count)
            for other in placedFrames { precondition(!other.intersects(layout.frame), "Multi-agent badges must not overlap") }
            placedFrames.append(layout.frame)
            let badge = BadgeView(frame: layout.frame.insetBy(dx: -BadgeLayout.shadowInset, dy: -BadgeLayout.shadowInset))
            badge.text = text
            badge.accentColor = AgentSlotPalette.entry(for: slot).rgb.nsColor
            badge.glyphOnly = layout.glyphOnly
            addSubview(badge)
        }
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

@MainActor
final class MultiplayerCanvasSample: NSView {
    override var isFlipped: Bool { true }
    let dark: Bool
    init(dark: Bool) {
        self.dark = dark
        super.init(frame: CGRect(x: 0, y: 0, width: 680, height: 320))
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func draw(_ dirtyRect: NSRect) {
        (dark ? NSColor(srgbRed: 18/255, green: 19/255, blue: 24/255, alpha: 1)
              : NSColor(srgbRed: 244/255, green: 245/255, blue: 248/255, alpha: 1)).setFill()
        bounds.fill()

        let cardFill = dark ? NSColor(white: 0.16, alpha: 1) : NSColor.white
        let controlA = CGRect(x: 56, y: 58, width: 170, height: 42)
        let controlB = CGRect(x: 340, y: 64, width: 240, height: 34)
        let controlC = CGRect(x: 84, y: 188, width: 184, height: 44)
        let controlD = CGRect(x: 376, y: 188, width: 172, height: 44)
        for rect in [controlA, controlB, controlC, controlD] {
            cardFill.setFill()
            NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8).fill()
        }

        let agents: [(Int, String, CGRect, CGPoint, CGPoint, Bool)] = [
            (0, "Coder", controlA.insetBy(dx: -2, dy: -2), CGPoint(x: 42, y: 24), CGPoint(x: 138, y: 78), false),
            (1, "Designer", controlB.insetBy(dx: -4, dy: -4), CGPoint(x: 300, y: 40), CGPoint(x: 468, y: 81), false),
            (2, "Reviewer", controlC.insetBy(dx: -2, dy: -2), CGPoint(x: 54, y: 148), CGPoint(x: 172, y: 210), false),
            (3, "QA", controlD.insetBy(dx: -2, dy: -2), CGPoint(x: 340, y: 152), CGPoint(x: 454, y: 210), true),
        ]
        for (slot, name, selRect, from, to, waiting) in agents {
            let entry = AgentSlotPalette.entry(for: slot)
            PresenceArtwork.drawSelectionBox(rect: selRect, color: entry.rgb.nsColor, alpha: 1.0)
            let motion = CursorMotion(start: from, end: to, began: 0, duration: CursorMotion.defaultGlideDuration)
            let tip = motion.point(at: 0.19)
            let trail = motion.cometTrail(at: 0.19)
            PresenceArtwork.cursor(
                at: tip,
                press: slot == 0 ? 0.65 : 0,
                color: entry.rgb.nsColor,
                rgb: entry.rgb,
                ripple: slot == 0 ? 0.42 : nil,
                trail: trail,
                tag: name,
                flipTagLeft: false,
                waitingTurn: waiting,
                pulsePhase: 0.25
            )
        }
    }
}

/// 16-Agent Computer Use Cluster Studio preview (`980 × 620`) exercising `ClusterSwarmOverlayView`,
/// 16-color palette, curved Bézier comet trails, `+` crosshairs, dashed laser alignment guides,
/// `W × H` dimension pills, and the bottom floating HUD bar.
@MainActor
final class ClusterSwarm16Sample: NSView {
    override var isFlipped: Bool { true }
    let dark: Bool
    private let overlayView = ClusterSwarmOverlayView(frame: CGRect(x: 0, y: 0, width: 980, height: 620))

    init(dark: Bool) {
        self.dark = dark
        super.init(frame: CGRect(x: 0, y: 0, width: 980, height: 620))
        addSubview(overlayView)
        populateSwarm()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func populateSwarm() {
        let agentNames = [
            "Coder", "Designer", "Reviewer", "QA",
            "Planner", "Layout", "Router", "Perf",
            "Security", "Accessibility", "Schema", "Telemetry",
            "Builder", "Inspector", "Verifier", "Release"
        ]
        var items: [ClusterSwarmOverlayView.RenderItem] = []

        let targets: [(CGPoint, CGPoint, CGRect?, Bool, Bool)] = [
            (CGPoint(x: 92, y: 148), CGPoint(x: 316, y: 148), CGRect(x: 68, y: 126, width: 320, height: 44), true, true),
            (CGPoint(x: 64, y: 290), CGPoint(x: 196, y: 248), CGRect(x: 68, y: 218, width: 150, height: 58), true, false),
            (CGPoint(x: 210, y: 342), CGPoint(x: 312, y: 248), CGRect(x: 238, y: 218, width: 150, height: 58), false, true),
            (CGPoint(x: 78, y: 472), CGPoint(x: 216, y: 392), CGRect(x: 68, y: 356, width: 320, height: 68), true, false),
            (CGPoint(x: 490, y: 92),  CGPoint(x: 486, y: 158), CGRect(x: 446, y: 126, width: 108, height: 64), false, true),
            (CGPoint(x: 618, y: 78),  CGPoint(x: 610, y: 158), nil, false, false),
            (CGPoint(x: 760, y: 88),  CGPoint(x: 734, y: 158), CGRect(x: 694, y: 126, width: 108, height: 64), true, false),
            (CGPoint(x: 918, y: 96),  CGPoint(x: 858, y: 158), nil, false, true),
            (CGPoint(x: 432, y: 296), CGPoint(x: 486, y: 266), nil, false, false),
            (CGPoint(x: 560, y: 332), CGPoint(x: 610, y: 266), CGRect(x: 570, y: 234, width: 108, height: 64), true, true),
            (CGPoint(x: 716, y: 340), CGPoint(x: 734, y: 266), nil, false, false),
            (CGPoint(x: 936, y: 288), CGPoint(x: 858, y: 266), CGRect(x: 818, y: 234, width: 108, height: 64), false, true),
            (CGPoint(x: 444, y: 468), CGPoint(x: 486, y: 382), CGRect(x: 446, y: 350, width: 108, height: 64), false, false),
            (CGPoint(x: 590, y: 510), CGPoint(x: 610, y: 382), nil, false, true),
            (CGPoint(x: 748, y: 512), CGPoint(x: 734, y: 382), CGRect(x: 694, y: 350, width: 108, height: 64), true, false),
            (CGPoint(x: 930, y: 492), CGPoint(x: 858, y: 382), nil, false, true),
        ]

        for slot in 0..<16 {
            let entry = AgentSlotPalette.entry(for: slot)
            let (start, end, selRect, showGuides, clicking) = targets[slot]
            let isDrag = (slot == 0)
            let arc = CursorMotion.deterministicArcOffset(slot: slot, start: start, end: end, isDrag: isDrag)
            let motion = CursorMotion(start: start, end: end, began: 0, duration: 0.28, arcOffset: arc)
            let sampleTime = clicking ? 0.25 : 0.18
            let point = motion.point(at: sampleTime)
            let trail = motion.cometTrail(at: sampleTime)
            let (_, flipLeft) = PresenceArtwork.cursorCanvasRect(
                at: point,
                trail: [],
                tag: agentNames[slot],
                waitingTurn: false,
                within: CGRect(x: 0, y: 0, width: 980, height: 620)
            )
            items.append(
                ClusterSwarmOverlayView.RenderItem(
                    slot: slot,
                    point: point,
                    press: clicking ? 0.72 : 0,
                    ripple: clicking ? 0.42 : nil,
                    color: entry.rgb.nsColor,
                    rgb: entry.rgb,
                    trail: trail,
                    tag: agentNames[slot],
                    flipTagLeft: flipLeft,
                    alpha: 1.0,
                    selectionRect: selRect,
                    selectionAlpha: selRect != nil ? 0.96 : 0,
                    showGuides: showGuides
                )
            )
        }
        overlayView.items = items
        overlayView.hudText = "16 agents · 96 / 128 ops · 60 fps"
        overlayView.hudProgress = 0.75
    }

    override func draw(_ dirtyRect: NSRect) {
        (dark ? NSColor(srgbRed: 8/255, green: 10/255, blue: 15/255, alpha: 1)
              : NSColor(srgbRed: 242/255, green: 244/255, blue: 249/255, alpha: 1)).setFill()
        bounds.fill()

        let headerBg = dark ? NSColor(srgbRed: 14/255, green: 17/255, blue: 25/255, alpha: 1)
                            : NSColor(white: 0.96, alpha: 1)
        headerBg.setFill()
        CGRect(x: 0, y: 0, width: bounds.width, height: 42).fill()
        for (idx, dot) in [NSColor.systemRed, .systemYellow, .systemGreen].enumerated() {
            dot.setFill()
            NSBezierPath(ovalIn: CGRect(x: 16 + CGFloat(idx) * 18, y: 15, width: 11, height: 11)).fill()
        }
        let titleAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12.5, weight: .semibold),
            .foregroundColor: (dark ? NSColor.white : NSColor.black).withAlphaComponent(0.86),
        ]
        ("OpenCU × ibuki · 16-Agent Computer Use Cluster Studio" as NSString)
            .draw(at: CGPoint(x: 86, y: 13), withAttributes: titleAttrs)

        let cardColor = dark ? NSColor(srgbRed: 17/255, green: 21/255, blue: 32/255, alpha: 1)
                             : NSColor.white
        let strokeColor = (dark ? NSColor.white : NSColor.black).withAlphaComponent(0.08)
        let cardRects: [CGRect] = [
            CGRect(x: 68, y: 126, width: 320, height: 44),
            CGRect(x: 68, y: 218, width: 150, height: 58),
            CGRect(x: 238, y: 218, width: 150, height: 58),
            CGRect(x: 68, y: 356, width: 320, height: 68),
        ]
        for r in cardRects {
            let p = NSBezierPath(roundedRect: r, xRadius: 9, yRadius: 9)
            cardColor.setFill(); p.fill()
            strokeColor.setStroke(); p.lineWidth = 1; p.stroke()
        }
        NSColor.white.withAlphaComponent(dark ? 0.14 : 0.25).setFill()
        NSBezierPath(roundedRect: CGRect(x: 86, y: 145, width: 284, height: 6), xRadius: 3, yRadius: 3).fill()
        AgentSlotPalette.entry(for: 0).rgb.nsColor.setFill()
        NSBezierPath(roundedRect: CGRect(x: 86, y: 145, width: 230, height: 6), xRadius: 3, yRadius: 3).fill()

        let cols: [CGFloat] = [446, 570, 694, 818]
        let rows: [CGFloat] = [126, 234, 350]
        var cellIndex = 4
        for ry in rows {
            for cx in cols {
                let cell = CGRect(x: cx, y: ry, width: 108, height: 64)
                let p = NSBezierPath(roundedRect: cell, xRadius: 8, yRadius: 8)
                let accent = AgentSlotPalette.entry(for: cellIndex).rgb.nsColor
                accent.withAlphaComponent(dark ? 0.14 : 0.12).setFill()
                p.fill()
                accent.withAlphaComponent(0.32).setStroke()
                p.lineWidth = 1
                p.stroke()
                cellIndex += 1
            }
        }
    }
}
