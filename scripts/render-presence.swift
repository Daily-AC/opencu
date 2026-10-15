import AppKit

/// Offline renderer: no ordered windows, status items, capture APIs or TCC calls.
@main
struct PresenceRenderer {
    @MainActor static func main() throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let output = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        if CommandLine.arguments[1] == "icon" {
            for size in [16, 32, 128, 256, 512] {
                for scale in [1, 2] {
                    try image(PresenceArtwork.glyph(size: NSSize(width: size, height: size)), scale: scale,
                              to: output.appendingPathComponent("icon_\(size)x\(size)\(scale == 2 ? "@2x" : "").png"))
                }
            }
            return
        }
        let resources = Bundle(path: CommandLine.arguments[3])!
        for language in ["en", "zh-Hans"] {
            let strings = PresenceStrings(language: language, resources: resources)
            for (theme, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                try withAppearance(NSAppearance(named: appearance)!) {
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
                        try image(PresenceArtwork.glyph(size: NSSize(width: 24, height: 18)), scale: scale,
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
