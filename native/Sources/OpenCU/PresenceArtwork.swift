import AppKit

extension AgentRGB {
    var nsColor: NSColor {
        NSColor(srgbRed: red, green: green, blue: blue, alpha: 1)
    }
}

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
    static let tagFont = NSFont.systemFont(ofSize: 10.5, weight: .semibold)

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

    static func formattedTag(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return trimmed.count > 16 ? String(trimmed.prefix(15)) + "…" : trimmed
    }

    static func tagPillSize(for tag: String) -> NSSize {
        let size = (tag as NSString).size(withAttributes: [.font: tagFont])
        return NSSize(width: ceil(size.width) + 21, height: 18)
    }

    static func cursorCanvasRect(at point: CGPoint, tag: String?, within windowBounds: CGRect) -> (rect: CGRect, flipTagLeft: Bool) {
        guard let label = formattedTag(tag) else {
            let rect = CGRect(x: point.x - 22, y: point.y - 22, width: 64, height: 64).intersection(windowBounds)
            return (rect, false)
        }
        let pill = tagPillSize(for: label)
        let rightNeeded = 16 + pill.width + 6
        let leftNeeded = 8 + pill.width + 6
        let flip = (point.x + rightNeeded > windowBounds.maxX) && (point.x - leftNeeded >= windowBounds.minX)
        let minX = flip ? (point.x - leftNeeded) : (point.x - 22)
        let maxX = flip ? (point.x + 28) : (point.x + max(42, rightNeeded))
        let raw = CGRect(x: minX, y: point.y - 22, width: maxX - minX, height: 64)
        return (raw.intersection(windowBounds), flip)
    }

    /// Drawn in a flipped view: the point is the V's tip, the hotspot.
    static func cursor(
        at point: CGPoint,
        press: CGFloat,
        color: NSColor = AgentSlotPalette.entry(for: 0).rgb.nsColor,
        ripple: CGFloat? = nil,
        tag: String? = nil,
        flipTagLeft: Bool = false
    ) {
        // Subtle glow and click ripple around the V tip on press.
        if press > 0.01 || ripple != nil {
            if press > 0.01 {
                let glowRadius = 8 + 4 * press
                let glowRect = CGRect(x: point.x - glowRadius, y: point.y - glowRadius,
                                      width: glowRadius * 2, height: glowRadius * 2)
                color.withAlphaComponent(0.22 * press).setFill()
                NSBezierPath(ovalIn: glowRect).fill()
            }
            let progress = ripple ?? max(0, min(1, 0.55 * press))
            let ringRadius = 5 + 11 * progress
            let ringAlpha = ripple != nil ? (1 - progress) * 0.65 : 0.55 * press
            if ringAlpha > 0.01 {
                let ringRect = CGRect(x: point.x - ringRadius, y: point.y - ringRadius,
                                      width: ringRadius * 2, height: ringRadius * 2)
                let ring = NSBezierPath(ovalIn: ringRect)
                ring.lineWidth = 1.5
                color.withAlphaComponent(ringAlpha).setStroke()
                ring.stroke()
            }
        }

        // A click presses the V to 90% around its tip, with a crisp white outer stroke and vivid agent fill.
        let path = vPath(origin: point, size: 19 * (1 - press * 0.1))
        path.lineWidth = 3.0
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.26)
        shadow.shadowBlurRadius = 2.0
        shadow.shadowOffset = NSSize(width: 0, height: -1)
        shadow.set()
        NSColor.white.setStroke()
        path.stroke()
        NSGraphicsContext.restoreGraphicsState()
        NSColor.white.setStroke()
        path.stroke()
        color.setFill()
        path.fill()

        if let label = formattedTag(tag) {
            let pill = tagPillSize(for: label)
            let pillX = flipTagLeft ? (point.x - 6 - pill.width) : (point.x + 15)
            let pillY = point.y + 13
            let pillRect = CGRect(x: pillX, y: pillY, width: pill.width, height: pill.height)
            let capsule = NSBezierPath(roundedRect: pillRect, xRadius: 9, yRadius: 9)
            NSGraphicsContext.saveGraphicsState()
            let pillShadow = NSShadow()
            pillShadow.shadowColor = NSColor.black.withAlphaComponent(0.22)
            pillShadow.shadowBlurRadius = 3
            pillShadow.shadowOffset = NSSize(width: 0, height: -1)
            pillShadow.set()
            NSColor(srgbRed: 24/255, green: 24/255, blue: 28/255, alpha: 0.90).setFill()
            capsule.fill()
            NSGraphicsContext.restoreGraphicsState()
            let border = NSBezierPath(roundedRect: pillRect.insetBy(dx: 0.5, dy: 0.5), xRadius: 8.5, yRadius: 8.5)
            border.lineWidth = 1.0
            color.withAlphaComponent(0.85).setStroke()
            border.stroke()
            let dotRect = CGRect(x: pillRect.minX + 6, y: pillRect.midY - 2.5, width: 5, height: 5)
            color.setFill()
            NSBezierPath(ovalIn: dotRect).fill()
            let attrs: [NSAttributedString.Key: Any] = [
                .font: tagFont,
                .foregroundColor: NSColor.white.withAlphaComponent(0.95),
            ]
            let textSize = (label as NSString).size(withAttributes: attrs)
            (label as NSString).draw(
                at: CGPoint(x: pillRect.minX + 14, y: pillRect.midY - textSize.height / 2),
                withAttributes: attrs
            )
        }
    }
}

@MainActor
final class AgentCursorView: NSView {
    override var isFlipped: Bool { true }
    var hotspot = CGPoint(x: 20, y: 20)
    var press: CGFloat = 0
    var ripple: CGFloat?
    var agentColor: NSColor = AgentSlotPalette.entry(for: 0).rgb.nsColor
    var tagText: String?
    var flipTagLeft = false

    override func draw(_ dirtyRect: NSRect) {
        PresenceArtwork.cursor(
            at: hotspot,
            press: press,
            color: agentColor,
            ripple: ripple,
            tag: tagText,
            flipTagLeft: flipTagLeft
        )
    }
}
