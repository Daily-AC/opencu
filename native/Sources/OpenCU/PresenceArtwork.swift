import AppKit

extension AgentRGB {
    var nsColor: NSColor {
        NSColor(srgbRed: red, green: green, blue: blue, alpha: 1)
    }

    func tintedPillFill(alpha: CGFloat = 0.94) -> NSColor {
        let base: CGFloat = 20.0 / 255.0
        let mix: CGFloat = 0.20
        return NSColor(
            srgbRed: base * (1 - mix) + red * mix,
            green: base * (1 - mix) + green * mix,
            blue: (25.0 / 255.0) * (1 - mix) + blue * mix,
            alpha: alpha
        )
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
    static let vertices: [CGPoint] = [
        CGPoint(x: 0, y: 0),
        CGPoint(x: 1, y: 0.357),
        CGPoint(x: 0.411, y: 0.411),
        CGPoint(x: 0.357, y: 1),
    ]
    static let cursorArrowSize: CGFloat = 27
    static let tagFont = NSFont.systemFont(ofSize: 11.5, weight: .bold)

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

    /// Deterministic staggered anchor inside `bounds` so coexisting agents immediately
    /// park at visually distinct positions as soon as they observe a window.
    static func anchorPoint(forSlot slot: Int, within bounds: CGRect) -> CGPoint {
        guard !bounds.isEmpty, !bounds.isNull, bounds.width.isFinite, bounds.height.isFinite else {
            return .zero
        }
        let normalized = ((slot % AgentSlotPalette.count) + AgentSlotPalette.count) % AgentSlotPalette.count
        let anchors: [(CGFloat, CGFloat)] = [
            (0.24, 0.30),
            (0.68, 0.30),
            (0.46, 0.50),
            (0.26, 0.68),
            (0.70, 0.68),
            (0.48, 0.32),
        ]
        let (fx, fy) = anchors[normalized]
        let insetX = min(72, max(18, bounds.width * 0.14))
        let topInset = min(64, max(34, bounds.height * 0.16))
        let bottomInset = min(48, max(20, bounds.height * 0.12))
        let usableMinX = bounds.minX + insetX
        let usableMaxX = max(usableMinX, bounds.maxX - insetX)
        let usableMinY = bounds.minY + topInset
        let usableMaxY = max(usableMinY, bounds.maxY - bottomInset)
        return CGPoint(
            x: usableMinX + (usableMaxX - usableMinX) * fx,
            y: usableMinY + (usableMaxY - usableMinY) * fy
        )
    }

    static func entryPoint(forAnchor anchor: CGPoint, slot: Int, within bounds: CGRect) -> CGPoint {
        let offsets: [(CGFloat, CGFloat)] = [
            (-42, -26),
            (42, -26),
            (-36, 30),
            (-40, 26),
            (40, 26),
            (36, -28),
        ]
        let normalized = ((slot % offsets.count) + offsets.count) % offsets.count
        let (dx, dy) = offsets[normalized]
        let safe = bounds.insetBy(dx: min(16, bounds.width * 0.1), dy: min(16, bounds.height * 0.1))
        if safe.isNull || safe.isEmpty { return anchor }
        return CGPoint(
            x: min(safe.maxX, max(safe.minX, anchor.x + dx)),
            y: min(safe.maxY, max(safe.minY, anchor.y + dy))
        )
    }

    static func formattedTag(_ raw: String?, waitingTurn: Bool = false) -> String? {
        guard let raw else { return waitingTurn ? "⏳" : nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return waitingTurn ? "⏳" : nil }
        let clamped = trimmed.count > 16 ? String(trimmed.prefix(15)) + "…" : trimmed
        return waitingTurn ? "⏳ \(clamped)" : clamped
    }

    static func tagPillSize(for formattedLabel: String, showDot: Bool = true) -> NSSize {
        let size = (formattedLabel as NSString).size(withAttributes: [.font: tagFont])
        let leading: CGFloat = showDot ? 23 : 16
        return NSSize(width: ceil(size.width) + leading, height: 21)
    }

    static func cursorCanvasRect(
        at point: CGPoint,
        trail: [CursorMotion.CometDot] = [],
        tag: String?,
        waitingTurn: Bool = false,
        within windowBounds: CGRect
    ) -> (rect: CGRect, flipTagLeft: Bool) {
        let label = formattedTag(tag, waitingTurn: waitingTurn)
        var flip = false
        var minX = point.x - 28
        var maxX = point.x + 48
        var minY = point.y - 28
        var maxY = point.y + 52

        if let label {
            let pill = tagPillSize(for: label, showDot: !waitingTurn)
            let rightNeeded = 20 + pill.width + 8
            let leftNeeded = 10 + pill.width + 8
            flip = (point.x + rightNeeded > windowBounds.maxX) && (point.x - leftNeeded >= windowBounds.minX)
            if flip {
                minX = min(minX, point.x - leftNeeded)
                maxX = max(maxX, point.x + 36)
            } else {
                maxX = max(maxX, point.x + rightNeeded)
            }
            maxY = max(maxY, point.y + 18 + pill.height + 8)
        }

        for dot in trail {
            let pad = dot.radius + 6
            minX = min(minX, dot.point.x - pad)
            maxX = max(maxX, dot.point.x + pad)
            minY = min(minY, dot.point.y - pad)
            maxY = max(maxY, dot.point.y + pad)
        }

        let raw = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        return (raw.intersection(windowBounds), flip)
    }

    static func selectionCanvasRect(for rect: CGRect, within windowBounds: CGRect) -> CGRect {
        guard !rect.isNull, !rect.isEmpty else { return .null }
        let expanded = rect.insetBy(dx: -8, dy: -8)
        return expanded.intersection(windowBounds)
    }

    static func drawSelectionBox(rect: CGRect, color: NSColor, alpha: CGFloat = 1.0) {
        guard !rect.isNull, !rect.isEmpty, alpha > 0.01 else { return }
        let clampedAlpha = max(0, min(1, alpha))

        // 8% tint fill inside the targeted element/drag bounds.
        color.withAlphaComponent(0.08 * clampedAlpha).setFill()
        NSBezierPath(rect: rect).fill()

        // Subtle outer white contrast halo so the wireframe pops on dark canvases.
        let halo = NSBezierPath(rect: rect.insetBy(dx: -0.9, dy: -0.9))
        halo.lineWidth = 0.9
        NSColor.white.withAlphaComponent(0.45 * clampedAlpha).setStroke()
        halo.stroke()

        // Crisp 1.8pt agentColor wireframe stroke.
        let wireframe = NSBezierPath(rect: rect)
        wireframe.lineWidth = 1.8
        color.withAlphaComponent(0.95 * clampedAlpha).setStroke()
        wireframe.stroke()

        // Four 5x5 Figma-style corner handles.
        let handleSize: CGFloat = 5.0
        let corners = [
            CGPoint(x: rect.minX, y: rect.minY),
            CGPoint(x: rect.maxX, y: rect.minY),
            CGPoint(x: rect.minX, y: rect.maxY),
            CGPoint(x: rect.maxX, y: rect.maxY),
        ]
        for corner in corners {
            let handleRect = CGRect(
                x: corner.x - handleSize / 2,
                y: corner.y - handleSize / 2,
                width: handleSize,
                height: handleSize
            )
            NSColor.white.withAlphaComponent(0.98 * clampedAlpha).setFill()
            NSBezierPath(rect: handleRect).fill()
            let border = NSBezierPath(rect: handleRect)
            border.lineWidth = 1.5
            color.withAlphaComponent(0.98 * clampedAlpha).setStroke()
            border.stroke()
        }
    }

    /// Drawn in a flipped view: the point is the V's tip, the hotspot.
    static func cursor(
        at point: CGPoint,
        press: CGFloat,
        color: NSColor = AgentSlotPalette.entry(for: 0).rgb.nsColor,
        rgb: AgentRGB? = nil,
        ripple: CGFloat? = nil,
        trail: [CursorMotion.CometDot] = [],
        tag: String? = nil,
        flipTagLeft: Bool = false,
        waitingTurn: Bool = false,
        pulsePhase: Double = 0
    ) {
        // 1. 5-dot fading comet trail behind the flying cursor.
        for dot in trail.reversed() where dot.alpha > 0.01 && dot.radius > 0.2 {
            let haloRadius = dot.radius + 1.8
            let haloRect = CGRect(x: dot.point.x - haloRadius, y: dot.point.y - haloRadius,
                                  width: haloRadius * 2, height: haloRadius * 2)
            NSColor.white.withAlphaComponent(dot.alpha * 0.38).setFill()
            NSBezierPath(ovalIn: haloRect).fill()

            let dotRect = CGRect(x: dot.point.x - dot.radius, y: dot.point.y - dot.radius,
                                 width: dot.radius * 2, height: dot.radius * 2)
            color.withAlphaComponent(dot.alpha).setFill()
            NSBezierPath(ovalIn: dotRect).fill()
        }

        // 2. Waiting-turn subtle pulse halo around the cursor tip.
        if waitingTurn {
            let wave = CGFloat(0.5 + 0.5 * sin(pulsePhase * 6.0))
            let pulseRadius = 11 + 5 * wave
            let pulseRect = CGRect(x: point.x - pulseRadius, y: point.y - pulseRadius,
                                   width: pulseRadius * 2, height: pulseRadius * 2)
            color.withAlphaComponent(0.14 + 0.14 * wave).setFill()
            NSBezierPath(ovalIn: pulseRect).fill()
            let pulseRing = NSBezierPath(ovalIn: pulseRect)
            pulseRing.lineWidth = 1.4
            color.withAlphaComponent(0.45 + 0.30 * wave).setStroke()
            pulseRing.stroke()
        }

        // 3. Click glow and expanding click ripple around the V tip on press.
        if press > 0.01 || ripple != nil {
            if press > 0.01 {
                let glowRadius = 10 + 5 * press
                let glowRect = CGRect(x: point.x - glowRadius, y: point.y - glowRadius,
                                      width: glowRadius * 2, height: glowRadius * 2)
                color.withAlphaComponent(0.24 * press).setFill()
                NSBezierPath(ovalIn: glowRect).fill()
            }
            let progress = ripple ?? max(0, min(1, 0.55 * press))
            let ringRadius = 6 + 15 * progress
            let ringAlpha = ripple != nil ? (1 - progress) * 0.72 : 0.60 * press
            if ringAlpha > 0.01 {
                let ringRect = CGRect(x: point.x - ringRadius, y: point.y - ringRadius,
                                      width: ringRadius * 2, height: ringRadius * 2)
                let ring = NSBezierPath(ovalIn: ringRect)
                ring.lineWidth = 1.8
                color.withAlphaComponent(ringAlpha).setStroke()
                ring.stroke()
            }
        }

        // 4. Bold Figma-style V-arrow (~27pt) with crisp white outer stroke and vivid agent fill.
        let path = vPath(origin: point, size: cursorArrowSize * (1 - press * 0.1))
        path.lineWidth = 3.4
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.30)
        shadow.shadowBlurRadius = 3.0
        shadow.shadowOffset = NSSize(width: 0, height: -1.5)
        shadow.set()
        NSColor.white.setStroke()
        path.stroke()
        NSGraphicsContext.restoreGraphicsState()
        NSColor.white.setStroke()
        path.stroke()
        color.setFill()
        path.fill()

        // 5. Bold agentName pill tag beside the pointer tail.
        if let label = formattedTag(tag, waitingTurn: waitingTurn) {
            let showDot = !waitingTurn
            let pill = tagPillSize(for: label, showDot: showDot)
            let pillX = flipTagLeft ? (point.x - 8 - pill.width) : (point.x + 20)
            let pillY = point.y + 18
            let pillRect = CGRect(x: pillX, y: pillY, width: pill.width, height: pill.height)
            let radius = pill.height / 2
            let capsule = NSBezierPath(roundedRect: pillRect, xRadius: radius, yRadius: radius)
            NSGraphicsContext.saveGraphicsState()
            let pillShadow = NSShadow()
            pillShadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
            pillShadow.shadowBlurRadius = 4
            pillShadow.shadowOffset = NSSize(width: 0, height: -1.5)
            pillShadow.set()
            let pillFill = rgb?.tintedPillFill(alpha: 0.94)
                ?? NSColor(srgbRed: 22/255, green: 22/255, blue: 27/255, alpha: 0.94)
            pillFill.setFill()
            capsule.fill()
            NSGraphicsContext.restoreGraphicsState()

            let outerRim = NSBezierPath(roundedRect: pillRect.insetBy(dx: -0.4, dy: -0.4),
                                        xRadius: radius + 0.4, yRadius: radius + 0.4)
            outerRim.lineWidth = 0.7
            NSColor.white.withAlphaComponent(0.28).setStroke()
            outerRim.stroke()

            let border = NSBezierPath(roundedRect: pillRect.insetBy(dx: 0.75, dy: 0.75),
                                      xRadius: radius - 0.75, yRadius: radius - 0.75)
            border.lineWidth = 1.5
            color.withAlphaComponent(0.95).setStroke()
            border.stroke()

            var textX = pillRect.minX + 8
            if showDot {
                let dotRect = CGRect(x: pillRect.minX + 7, y: pillRect.midY - 3, width: 6, height: 6)
                color.setFill()
                NSBezierPath(ovalIn: dotRect).fill()
                textX = pillRect.minX + 16
            }
            let attrs: [NSAttributedString.Key: Any] = [
                .font: tagFont,
                .foregroundColor: NSColor.white.withAlphaComponent(0.98),
            ]
            let textSize = (label as NSString).size(withAttributes: attrs)
            (label as NSString).draw(
                at: CGPoint(x: textX, y: pillRect.midY - textSize.height / 2),
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
    var agentRGB: AgentRGB?
    var trail: [CursorMotion.CometDot] = []
    var tagText: String?
    var flipTagLeft = false
    var waitingTurn = false
    var pulsePhase: Double = 0

    override func draw(_ dirtyRect: NSRect) {
        PresenceArtwork.cursor(
            at: hotspot,
            press: press,
            color: agentColor,
            rgb: agentRGB,
            ripple: ripple,
            trail: trail,
            tag: tagText,
            flipTagLeft: flipTagLeft,
            waitingTurn: waitingTurn,
            pulsePhase: pulsePhase
        )
    }
}

@MainActor
final class SelectionOverlayView: NSView {
    override var isFlipped: Bool { true }
    var selectionRect: CGRect = .zero
    var agentColor: NSColor = AgentSlotPalette.entry(for: 0).rgb.nsColor
    var boxAlpha: CGFloat = 1.0

    override func draw(_ dirtyRect: NSRect) {
        PresenceArtwork.drawSelectionBox(rect: selectionRect, color: agentColor, alpha: boxAlpha)
    }
}
