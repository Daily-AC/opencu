import AppKit

/// Original OpenCU artwork. One shape everywhere: a V-shaped pointer tip
/// without a tail. The app icon is `native/Artwork/AppIcon-1024.png`; the
/// status item and agent cursor draw the same V in code. No symbol font or
/// third-party image is used.
@MainActor
enum PresenceArtwork {
    /// The V in unit coordinates, y down: tip, right wing, notch, bottom wing.
    /// The tip is the cursor hotspot.
    static let vertices: [CGPoint] = [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 0.357),
                                      CGPoint(x: 0.411, y: 0.411), CGPoint(x: 0.357, y: 1)]

    static func vPath(origin: CGPoint, size: CGFloat) -> NSBezierPath {
        let path = NSBezierPath()
        for (index, vertex) in vertices.enumerated() {
            let point = CGPoint(x: origin.x + vertex.x * size, y: origin.y + vertex.y * size)
            if index == 0 { path.move(to: point) } else { path.line(to: point) }
        }
        path.close()
        path.lineJoinStyle = .round
        return path
    }

    /// Set by the offline renderer; the engine uses its bundle icon.
    static var iconOverride: NSImage?

    static var appIcon: NSImage { iconOverride ?? NSApp.applicationIconImage }

    /// Monochrome template: the menu bar tints it for light and dark.
    static func statusGlyph(size: NSSize) -> NSImage {
        let image = NSImage(size: size, flipped: true) { rect in
            let side = min(rect.width, rect.height) * 0.74
            let origin = CGPoint(x: rect.midX - side * 0.46, y: rect.midY - side * 0.46)
            NSColor.black.setFill()
            NSColor.black.setStroke()
            let path = vPath(origin: origin, size: side)
            path.lineWidth = 1
            path.fill(); path.stroke()
            return true
        }
        image.isTemplate = true
        return image
    }

    /// Drawn in a flipped view: the point is the V's tip, the hotspot.
    static func cursor(at point: CGPoint, press: CGFloat) {
        // A click presses the V to 90% around its tip.
        let path = vPath(origin: point, size: 19 * (1 - press * 0.1))
        path.lineWidth = 1.6
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.24)
        shadow.shadowBlurRadius = 1.6
        shadow.shadowOffset = NSSize(width: 0, height: -1)
        shadow.set()
        NSColor.white.setStroke()
        path.stroke()
        NSGraphicsContext.restoreGraphicsState()
        NSColor(srgbRed: 0.08, green: 0.08, blue: 0.09, alpha: 1).setFill()
        NSColor.white.setStroke()
        path.stroke(); path.fill()
    }
}

@MainActor
final class AgentCursorView: NSView {
    override var isFlipped: Bool { true }
    var hotspot = CGPoint(x: 20, y: 20)
    var press: CGFloat = 0
    override func draw(_ dirtyRect: NSRect) { PresenceArtwork.cursor(at: hotspot, press: press) }
}
