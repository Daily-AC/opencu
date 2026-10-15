import AppKit

/// Original OpenCU artwork. The monitor glyph is shared by the app, setup and
/// status item; no symbol font or third-party image is used.
@MainActor
enum PresenceArtwork {
    static func glyph(size: NSSize) -> NSImage {
        let image = NSImage(size: size, flipped: false) { rect in
            NSColor.systemPurple.setFill()
            NSBezierPath(roundedRect: rect, xRadius: rect.height * 0.23, yRadius: rect.height * 0.23).fill()
            let s = min(rect.width, rect.height)
            let monitor = NSRect(x: rect.midX - s * 0.29, y: rect.midY - s * 0.14,
                                 width: s * 0.58, height: s * 0.40)
            NSColor.white.setStroke()
            let screen = NSBezierPath(roundedRect: monitor, xRadius: s * 0.05, yRadius: s * 0.05)
            screen.lineWidth = s * 0.055
            screen.stroke()
            let stand = NSBezierPath()
            stand.lineWidth = s * 0.055
            stand.lineCapStyle = .round
            stand.move(to: NSPoint(x: rect.midX, y: monitor.minY))
            stand.line(to: NSPoint(x: rect.midX, y: rect.midY - s * 0.27))
            stand.move(to: NSPoint(x: rect.midX - s * 0.13, y: rect.midY - s * 0.27))
            stand.line(to: NSPoint(x: rect.midX + s * 0.13, y: rect.midY - s * 0.27))
            stand.stroke()
            return true
        }
        image.isTemplate = false
        return image
    }

    /// Drawn in a flipped view: the point is the arrow's hotspot, not its centre.
    static func cursor(at point: CGPoint, press: CGFloat) {
        NSGraphicsContext.saveGraphicsState()
        let transform = NSAffineTransform()
        transform.translateX(by: point.x, yBy: point.y)
        transform.concat()
        if press > 0 {
            NSColor.systemPurple.withAlphaComponent(0.18 * press).setFill()
            let r = 8 + 9 * press
            NSBezierPath(ovalIn: NSRect(x: -r, y: -r, width: 2*r, height: 2*r)).fill()
        }
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.30)
        shadow.shadowBlurRadius = 2
        shadow.shadowOffset = NSSize(width: 0, height: -1)
        shadow.set()
        let arrow = NSBezierPath()
        let scale = 1 - press * 0.12
        let vertices: [CGPoint] = [.zero, CGPoint(x: 1, y: 22), CGPoint(x: 6, y: 17),
                                   CGPoint(x: 10, y: 25), CGPoint(x: 14, y: 23),
                                   CGPoint(x: 10, y: 15), CGPoint(x: 18, y: 14)]
        arrow.move(to: .zero)
        for v in vertices.dropFirst() { arrow.line(to: CGPoint(x: v.x * scale, y: v.y * scale)) }
        arrow.close()
        NSColor.systemPurple.setFill()
        NSColor.white.setStroke()
        arrow.lineWidth = 1
        arrow.lineJoinStyle = .round
        arrow.fill(); arrow.stroke()
        NSGraphicsContext.restoreGraphicsState()
    }
}

@MainActor
final class AgentCursorView: NSView {
    override var isFlipped: Bool { true }
    var hotspot = CGPoint(x: 20, y: 20)
    var press: CGFloat = 0
    override func draw(_ dirtyRect: NSRect) { PresenceArtwork.cursor(at: hotspot, press: press) }
}
