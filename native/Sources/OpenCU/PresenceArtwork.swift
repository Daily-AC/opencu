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
    /// park at visually distinct positions as soon as they observe a window (up to 24 slots).
    static func anchorPoint(forSlot slot: Int, within bounds: CGRect) -> CGPoint {
        guard !bounds.isEmpty, !bounds.isNull, bounds.width.isFinite, bounds.height.isFinite else {
            return .zero
        }
        let maxSlots = AgentSlotPalette.maxSlots
        let normalized = ((slot % maxSlots) + maxSlots) % maxSlots
        let baseAnchors: [(CGFloat, CGFloat)] = [
            (0.24, 0.30),
            (0.68, 0.30),
            (0.46, 0.50),
            (0.26, 0.68),
            (0.70, 0.68),
            (0.48, 0.32),
        ]
        let fx: CGFloat
        let fy: CGFloat
        if normalized < baseAnchors.count {
            (fx, fy) = baseAnchors[normalized]
        } else {
            let idx = normalized - baseAnchors.count // 0..<18 -> 6 columns x 3 rows staggered
            let col = idx % 6
            let row = idx / 6
            let rowShift: CGFloat = (row % 2 == 1) ? 0.045 : -0.025
            fx = min(0.92, max(0.08, 0.12 + CGFloat(col) * 0.15 + rowShift))
            fy = min(0.88, max(0.14, 0.22 + CGFloat(row) * 0.30 + CGFloat(col % 2) * 0.04))
        }
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
        let angle = Double(slot) * 2.399963229728653 // golden angle radians
        let radius: CGFloat = 46 + CGFloat(abs(slot) % 3) * 12
        let dx = CGFloat(cos(angle)) * radius
        let dy = CGFloat(sin(angle)) * radius
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

    static let dimensionFont = NSFont.monospacedDigitSystemFont(ofSize: 9.5, weight: .bold)

    static func selectionCanvasRect(for rect: CGRect, within windowBounds: CGRect, showGuides: Bool = true) -> CGRect {
        guard !rect.isNull, !rect.isEmpty, !windowBounds.isNull, !windowBounds.isEmpty else { return .null }
        if showGuides {
            return windowBounds
        }
        let expanded = rect.insetBy(dx: -16, dy: -24)
        return expanded.intersection(windowBounds)
    }

    static func drawSelectionBox(
        rect: CGRect,
        color: NSColor,
        alpha: CGFloat = 1.0,
        canvasBounds: CGRect = .null,
        showGuides: Bool = true,
        showDimensions: Bool = true
    ) {
        guard !rect.isNull, !rect.isEmpty, alpha > 0.01 else { return }
        let clampedAlpha = max(0, min(1, alpha))

        // 1. @hrstwt-style extended 0.8pt dashed/hairline laser alignment guide lines clamped to canvasBounds.
        if showGuides, !canvasBounds.isNull, !canvasBounds.isEmpty {
            let guidePath = NSBezierPath()
            let gap: CGFloat = 6.5
            for yLine in [rect.minY, rect.maxY] where yLine >= canvasBounds.minY && yLine <= canvasBounds.maxY {
                if rect.minX - gap > canvasBounds.minX {
                    guidePath.move(to: CGPoint(x: canvasBounds.minX, y: yLine))
                    guidePath.line(to: CGPoint(x: rect.minX - gap, y: yLine))
                }
                if rect.maxX + gap < canvasBounds.maxX {
                    guidePath.move(to: CGPoint(x: rect.maxX + gap, y: yLine))
                    guidePath.line(to: CGPoint(x: canvasBounds.maxX, y: yLine))
                }
            }
            for xLine in [rect.minX, rect.maxX] where xLine >= canvasBounds.minX && xLine <= canvasBounds.maxX {
                if rect.minY - gap > canvasBounds.minY {
                    guidePath.move(to: CGPoint(x: xLine, y: canvasBounds.minY))
                    guidePath.line(to: CGPoint(x: xLine, y: rect.minY - gap))
                }
                if rect.maxY + gap < canvasBounds.maxY {
                    guidePath.move(to: CGPoint(x: xLine, y: rect.maxY + gap))
                    guidePath.line(to: CGPoint(x: xLine, y: canvasBounds.maxY))
                }
            }
            guidePath.lineWidth = 0.8
            let pattern: [CGFloat] = [4.0, 4.0]
            guidePath.setLineDash(pattern, count: pattern.count, phase: 0)
            color.withAlphaComponent(0.38 * clampedAlpha).setStroke()
            guidePath.stroke()
        }

        // 2. 8% tint fill inside the targeted element/drag bounds.
        color.withAlphaComponent(0.08 * clampedAlpha).setFill()
        NSBezierPath(rect: rect).fill()

        // 3. Subtle outer white contrast halo so the wireframe pops on dark canvases.
        let halo = NSBezierPath(rect: rect.insetBy(dx: -0.9, dy: -0.9))
        halo.lineWidth = 0.9
        NSColor.white.withAlphaComponent(0.45 * clampedAlpha).setStroke()
        halo.stroke()

        // 4. Crisp 1.8pt agentColor wireframe stroke.
        let wireframe = NSBezierPath(rect: rect)
        wireframe.lineWidth = 1.8
        color.withAlphaComponent(0.95 * clampedAlpha).setStroke()
        wireframe.stroke()

        // 5. Four `+` corner crosshair ticks + 5x5 Figma-style corner handles.
        let handleSize: CGFloat = 5.0
        let tickArm: CGFloat = 7.0
        let corners = [
            CGPoint(x: rect.minX, y: rect.minY),
            CGPoint(x: rect.maxX, y: rect.minY),
            CGPoint(x: rect.minX, y: rect.maxY),
            CGPoint(x: rect.maxX, y: rect.maxY),
        ]
        let ticks = NSBezierPath()
        for corner in corners {
            ticks.move(to: CGPoint(x: corner.x - tickArm, y: corner.y))
            ticks.line(to: CGPoint(x: corner.x + tickArm, y: corner.y))
            ticks.move(to: CGPoint(x: corner.x, y: corner.y - tickArm))
            ticks.line(to: CGPoint(x: corner.x, y: corner.y + tickArm))
        }
        ticks.lineWidth = 1.15
        color.withAlphaComponent(0.88 * clampedAlpha).setStroke()
        ticks.stroke()

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

        // 6. Compact `W × H` pill anchored at top-left outside edge (staying clear of centered cursor tags).
        if showDimensions, rect.width >= 72, rect.height >= 18 {
            let dimLabel = "\(Int(rect.width.rounded())) × \(Int(rect.height.rounded()))"
            let attrs: [NSAttributedString.Key: Any] = [
                .font: dimensionFont,
                .foregroundColor: NSColor.white.withAlphaComponent(0.98 * clampedAlpha),
            ]
            let textSize = (dimLabel as NSString).size(withAttributes: attrs)
            let pillW = ceil(textSize.width) + 10
            let pillH: CGFloat = 15
            var pillX = rect.minX + 6
            var pillY = rect.minY - pillH - 5
            if !canvasBounds.isNull && !canvasBounds.isEmpty {
                pillX = min(canvasBounds.maxX - pillW - 4, max(canvasBounds.minX + 4, pillX))
                if pillY < canvasBounds.minY + 4 {
                    pillY = min(canvasBounds.maxY - pillH - 4, rect.maxY + 5)
                }
            } else if pillY < 2 {
                pillY = rect.maxY + 5
            }
            let pillRect = CGRect(x: pillX, y: pillY, width: pillW, height: pillH)
            let pillPath = NSBezierPath(roundedRect: pillRect, xRadius: 4, yRadius: 4)
            color.withAlphaComponent(0.92 * clampedAlpha).setFill()
            pillPath.fill()
            let rim = NSBezierPath(roundedRect: pillRect.insetBy(dx: -0.35, dy: -0.35), xRadius: 4.35, yRadius: 4.35)
            rim.lineWidth = 0.7
            NSColor.white.withAlphaComponent(0.42 * clampedAlpha).setStroke()
            rim.stroke()
            (dimLabel as NSString).draw(
                at: CGPoint(x: pillRect.midX - textSize.width / 2, y: pillRect.midY - textSize.height / 2),
                withAttributes: attrs
            )
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
        pulsePhase: Double = 0,
        alpha: CGFloat = 1.0,
        tagOffsetY: CGFloat = 0
    ) {
        let masterAlpha = max(0, min(1, alpha))
        guard masterAlpha > 0.01 else { return }

        // 1. 5-dot fading comet trail behind the flying cursor.
        for dot in trail.reversed() where dot.alpha * masterAlpha > 0.01 && dot.radius > 0.2 {
            let dotAlpha = dot.alpha * masterAlpha
            let haloRadius = dot.radius + 1.8
            let haloRect = CGRect(x: dot.point.x - haloRadius, y: dot.point.y - haloRadius,
                                  width: haloRadius * 2, height: haloRadius * 2)
            NSColor.white.withAlphaComponent(dotAlpha * 0.38).setFill()
            NSBezierPath(ovalIn: haloRect).fill()

            let dotRect = CGRect(x: dot.point.x - dot.radius, y: dot.point.y - dot.radius,
                                 width: dot.radius * 2, height: dot.radius * 2)
            color.withAlphaComponent(dotAlpha).setFill()
            NSBezierPath(ovalIn: dotRect).fill()
        }

        // 2. Waiting-turn subtle pulse halo around the cursor tip.
        if waitingTurn {
            let wave = CGFloat(0.5 + 0.5 * sin(pulsePhase * 6.0))
            let pulseRadius = 11 + 5 * wave
            let pulseRect = CGRect(x: point.x - pulseRadius, y: point.y - pulseRadius,
                                   width: pulseRadius * 2, height: pulseRadius * 2)
            color.withAlphaComponent((0.14 + 0.14 * wave) * masterAlpha).setFill()
            NSBezierPath(ovalIn: pulseRect).fill()
            let pulseRing = NSBezierPath(ovalIn: pulseRect)
            pulseRing.lineWidth = 1.4
            color.withAlphaComponent((0.45 + 0.30 * wave) * masterAlpha).setStroke()
            pulseRing.stroke()
        }

        // 3. Click glow and expanding click ripple around the V tip on press.
        if press > 0.01 || ripple != nil {
            if press > 0.01 {
                let glowRadius = 10 + 5 * press
                let glowRect = CGRect(x: point.x - glowRadius, y: point.y - glowRadius,
                                      width: glowRadius * 2, height: glowRadius * 2)
                color.withAlphaComponent(0.24 * press * masterAlpha).setFill()
                NSBezierPath(ovalIn: glowRect).fill()
            }
            let progress = ripple ?? max(0, min(1, 0.55 * press))
            let ringRadius = 6 + 15 * progress
            let ringAlpha = (ripple != nil ? (1 - progress) * 0.72 : 0.60 * press) * masterAlpha
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
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.30 * masterAlpha)
        shadow.shadowBlurRadius = 3.0
        shadow.shadowOffset = NSSize(width: 0, height: -1.5)
        shadow.set()
        NSColor.white.withAlphaComponent(masterAlpha).setStroke()
        path.stroke()
        NSGraphicsContext.restoreGraphicsState()
        NSColor.white.withAlphaComponent(masterAlpha).setStroke()
        path.stroke()
        color.withAlphaComponent(masterAlpha).setFill()
        path.fill()

        // 5. Bold agentName pill tag beside the pointer tail.
        if let label = formattedTag(tag, waitingTurn: waitingTurn) {
            let showDot = !waitingTurn
            let pill = tagPillSize(for: label, showDot: showDot)
            let pillX = flipTagLeft ? (point.x - 8 - pill.width) : (point.x + 20)
            let pillY = point.y + 18 + tagOffsetY
            let pillRect = CGRect(x: pillX, y: pillY, width: pill.width, height: pill.height)
            let radius = pill.height / 2
            let capsule = NSBezierPath(roundedRect: pillRect, xRadius: radius, yRadius: radius)
            NSGraphicsContext.saveGraphicsState()
            let pillShadow = NSShadow()
            pillShadow.shadowColor = NSColor.black.withAlphaComponent(0.28 * masterAlpha)
            pillShadow.shadowBlurRadius = 4
            pillShadow.shadowOffset = NSSize(width: 0, height: -1.5)
            pillShadow.set()
            let pillFill = rgb?.tintedPillFill(alpha: 0.94 * masterAlpha)
                ?? NSColor(srgbRed: 22/255, green: 22/255, blue: 27/255, alpha: 0.94 * masterAlpha)
            pillFill.setFill()
            capsule.fill()
            NSGraphicsContext.restoreGraphicsState()

            let outerRim = NSBezierPath(roundedRect: pillRect.insetBy(dx: -0.4, dy: -0.4),
                                        xRadius: radius + 0.4, yRadius: radius + 0.4)
            outerRim.lineWidth = 0.7
            NSColor.white.withAlphaComponent(0.28 * masterAlpha).setStroke()
            outerRim.stroke()

            let border = NSBezierPath(roundedRect: pillRect.insetBy(dx: 0.75, dy: 0.75),
                                      xRadius: radius - 0.75, yRadius: radius - 0.75)
            border.lineWidth = 1.5
            color.withAlphaComponent(0.95 * masterAlpha).setStroke()
            border.stroke()

            var textX = pillRect.minX + 8
            if showDot {
                let dotRect = CGRect(x: pillRect.minX + 7, y: pillRect.midY - 3, width: 6, height: 6)
                color.withAlphaComponent(masterAlpha).setFill()
                NSBezierPath(ovalIn: dotRect).fill()
                textX = pillRect.minX + 16
            }
            let attrs: [NSAttributedString.Key: Any] = [
                .font: tagFont,
                .foregroundColor: NSColor.white.withAlphaComponent(0.98 * masterAlpha),
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
    var showGuides = true
    var showDimensions = true

    override func draw(_ dirtyRect: NSRect) {
        PresenceArtwork.drawSelectionBox(
            rect: selectionRect,
            color: agentColor,
            alpha: boxAlpha,
            canvasBounds: bounds,
            showGuides: showGuides,
            showDimensions: showDimensions
        )
    }
}

/// Shared 60fps full-window canvas multiplexing 16–24+ Computer Use Cluster cursors,
/// curved comet wakes, click ripples, and @hrstwt precision crosshairs/laser guides.
@MainActor
final class ClusterSwarmOverlayView: NSView {
    struct RenderItem {
        let slot: Int
        let point: CGPoint
        let press: CGFloat
        let ripple: CGFloat?
        let color: NSColor
        let rgb: AgentRGB
        let trail: [CursorMotion.CometDot]
        let tag: String?
        let flipTagLeft: Bool
        let alpha: CGFloat
        let selectionRect: CGRect?
        let selectionAlpha: CGFloat
        let showGuides: Bool
    }

    override var isFlipped: Bool { true }
    var items: [RenderItem] = []
    var pulsePhase: Double = 0
    var hudText: String?
    var hudProgress: Double?

    override func draw(_ dirtyRect: NSRect) {
        let viewBounds = bounds
        guard !viewBounds.isEmpty else { return }

        // Pass 1: Precision wireframes, extended laser alignment guides, `+` crosshairs & `W × H` pills.
        for item in items {
            if let selRect = item.selectionRect, item.selectionAlpha > 0.01 {
                PresenceArtwork.drawSelectionBox(
                    rect: selRect,
                    color: item.color,
                    alpha: item.selectionAlpha * item.alpha,
                    canvasBounds: viewBounds,
                    showGuides: item.showGuides,
                    showDimensions: true
                )
            }
        }

        // Pass 2: 60fps multicolored Figma V-arrows, curved 5-dot comet trails, click ripples & non-overlapping pills.
        var placedPillRects: [CGRect] = []
        for item in items where item.alpha > 0.01 {
            var resolvedFlip = item.flipTagLeft
            var resolvedOffsetY: CGFloat = 0
            if let label = PresenceArtwork.formattedTag(item.tag, waitingTurn: false) {
                let pillSize = PresenceArtwork.tagPillSize(for: label, showDot: true)
                let candidates: [(Bool, CGFloat)] = [
                    (item.flipTagLeft, 0),
                    (!item.flipTagLeft, 0),
                    (item.flipTagLeft, -34),
                    (item.flipTagLeft, 24),
                    (!item.flipTagLeft, -34),
                ]
                for (candFlip, candOffY) in candidates {
                    let px = candFlip ? (item.point.x - 8 - pillSize.width) : (item.point.x + 20)
                    let py = item.point.y + 18 + candOffY
                    let rect = CGRect(x: px, y: py, width: pillSize.width, height: pillSize.height)
                    let inBounds = rect.minX >= viewBounds.minX + 4
                        && rect.maxX <= viewBounds.maxX - 4
                        && rect.minY >= viewBounds.minY + 4
                        && rect.maxY <= viewBounds.maxY - 4
                    let collides = placedPillRects.contains { $0.insetBy(dx: -3, dy: -2).intersects(rect) }
                    if inBounds && !collides {
                        resolvedFlip = candFlip
                        resolvedOffsetY = candOffY
                        placedPillRects.append(rect)
                        break
                    }
                }
            }

            PresenceArtwork.cursor(
                at: item.point,
                press: item.press,
                color: item.color,
                rgb: item.rgb,
                ripple: item.ripple,
                trail: item.trail,
                tag: item.tag,
                flipTagLeft: resolvedFlip,
                waitingTurn: false,
                pulsePhase: pulsePhase,
                alpha: item.alpha,
                tagOffsetY: resolvedOffsetY
            )
        }

        // Pass 3: Optional @hrstwt bottom-center floating cluster HUD pill.
        if let rawHud = hudText?.trimmingCharacters(in: .whitespacesAndNewlines), !rawHud.isEmpty {
            let font = NSFont.monospacedDigitSystemFont(ofSize: 11.5, weight: .semibold)
            let attrs: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: NSColor.white.withAlphaComponent(0.94),
            ]
            let textSize = (rawHud as NSString).size(withAttributes: attrs)
            let dotsWidth: CGFloat = 46
            let barWidth: CGFloat = (hudProgress != nil) ? 68 : 0
            let hudW = min(viewBounds.width - 28, dotsWidth + ceil(textSize.width) + barWidth + 28)
            let hudH: CGFloat = 28
            let hudRect = CGRect(
                x: viewBounds.midX - hudW / 2,
                y: viewBounds.maxY - hudH - 14,
                width: hudW,
                height: hudH
            )
            let hudPath = NSBezierPath(roundedRect: hudRect, xRadius: hudH / 2, yRadius: hudH / 2)
            NSColor(srgbRed: 14/255, green: 16/255, blue: 23/255, alpha: 0.90).setFill()
            hudPath.fill()
            let border = NSBezierPath(roundedRect: hudRect.insetBy(dx: 0.5, dy: 0.5),
                                      xRadius: (hudH - 1) / 2, yRadius: (hudH - 1) / 2)
            border.lineWidth = 1.0
            NSColor.white.withAlphaComponent(0.18).setStroke()
            border.stroke()

            for dotIdx in 0..<5 {
                let entry = AgentSlotPalette.entry(for: dotIdx)
                let dotX = hudRect.minX + 11 + CGFloat(dotIdx) * 7.2
                let dotRect = CGRect(x: dotX, y: hudRect.midY - 4.5, width: 9, height: 9)
                NSColor(srgbRed: 14/255, green: 16/255, blue: 23/255, alpha: 1).setFill()
                NSBezierPath(ovalIn: dotRect.insetBy(dx: -1, dy: -1)).fill()
                entry.rgb.nsColor.setFill()
                NSBezierPath(ovalIn: dotRect).fill()
            }

            let textX = hudRect.minX + 52
            (rawHud as NSString).draw(
                at: CGPoint(x: textX, y: hudRect.midY - textSize.height / 2),
                withAttributes: attrs
            )

            if let prog = hudProgress {
                let clamped = CGFloat(max(0, min(1, prog)))
                let trackRect = CGRect(
                    x: hudRect.maxX - barWidth - 10,
                    y: hudRect.midY - 3,
                    width: barWidth,
                    height: 6
                )
                NSColor.white.withAlphaComponent(0.14).setFill()
                NSBezierPath(roundedRect: trackRect, xRadius: 3, yRadius: 3).fill()
                if clamped > 0.01 {
                    let fillRect = CGRect(
                        x: trackRect.minX,
                        y: trackRect.minY,
                        width: max(6, trackRect.width * clamped),
                        height: trackRect.height
                    )
                    AgentSlotPalette.entry(for: 1).rgb.nsColor.setFill()
                    NSBezierPath(roundedRect: fillRect, xRadius: 3, yRadius: 3).fill()
                }
            }
        }
    }
}
