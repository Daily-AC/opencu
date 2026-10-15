import AppKit
import ApplicationServices

@MainActor
final class BadgeView: NSView {
    override var isFlipped: Bool { true }
    var text = ""
    var glyphOnly = false
    var stopped = false
    static let font = NSFont.systemFont(ofSize: 12)
    static func textWidth(_ text: String) -> CGFloat { ceil((text as NSString).size(withAttributes: [.font: font]).width) }
    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: BadgeLayout.shadowInset, dy: BadgeLayout.shadowInset)
        let capsule = NSBezierPath(roundedRect: rect, xRadius: 11, yRadius: 11)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowOffset = NSSize(width: 0, height: -2)
        shadow.shadowBlurRadius = 8
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.18)
        shadow.set()
        let fill = stopped ? NSColor(srgbRed: 120/255, green: 120/255, blue: 127/255, alpha: 0.90)
            : NSColor(srgbRed: 28/255, green: 28/255, blue: 30/255, alpha: 0.86)
        fill.setFill(); capsule.fill()
        NSGraphicsContext.restoreGraphicsState()
        let hairline = NSBezierPath(roundedRect: rect.insetBy(dx: 0.25, dy: 0.25), xRadius: 10.75, yRadius: 10.75)
        hairline.lineWidth = 0.5
        NSColor.white.withAlphaComponent(0.18).setStroke(); hairline.stroke()
        NSColor.white.setFill()
        PresenceArtwork.vPath(origin: CGPoint(x: rect.minX + 8, y: rect.midY - 5.5), size: 11).fill()
        if !glyphOnly {
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineBreakMode = .byTruncatingTail
            let attributes: [NSAttributedString.Key: Any] = [.font: Self.font,
                .foregroundColor: NSColor.white.withAlphaComponent(0.62), .paragraphStyle: paragraph]
            let lineHeight = (text as NSString).size(withAttributes: attributes).height
            (text as NSString).draw(in: CGRect(x: rect.minX + 25, y: rect.midY - lineHeight/2,
                                               width: max(0, rect.width - 35), height: lineHeight), withAttributes: attributes)
        }
    }
}

/// Reads only AX metadata needed for the badge, never AXValue or NSPasteboard.
@MainActor
enum BadgeAccessibility {
    static func titleBarHeight(window: AXUIElement, bounds: CGRect) -> CGFloat? {
        let toolbar = axChildren(window).first { axString($0, kAXRoleAttribute) == kAXToolbarRole }.flatMap(axRect)
        let title = axElement(window, kAXTitleUIElementAttribute) ?? axElement(window, kAXCloseButtonAttribute)
        return BadgeLayout.titleHeight(window: bounds, toolbar: toolbar, title: title.flatMap(axRect))
    }
    static func action(method: String, args: Arguments, snapshot: WindowSnapshot) -> BadgeAction {
        let application = AXUIElementCreateApplication(snapshot.app.pid)
        let liveWindow = axSelectedWindow(application)
        let sameWindow = snapshot.window.map { old in liveWindow.map { CFEqual(old, $0) } == true } == true
        var element: AXUIElement?
        var path: [AXUIElement] = []
        if sameWindow, let index = args["element_index"] as? NSNumber,
           index.doubleValue.isFinite, index.doubleValue.rounded() == index.doubleValue,
           index.doubleValue >= 0, index.doubleValue < Double(Int.max),
           let candidate = snapshot.elements[index.intValue], let candidatePath = snapshot.elementPaths[index.intValue],
           attachedPath(candidatePath, to: [liveWindow, axElement(application, kAXMenuBarAttribute)].compactMap { $0 },
                        equal: { CFEqual($0, $1) }, children: axChildren) {
            element = candidate; path = candidatePath
        }
        func label(_ element: AXUIElement) -> String? {
            if BadgeAction.isSecure(role: axString(element, kAXRoleAttribute), subrole: axString(element, kAXSubroleAttribute)) { return nil }
            return axString(element, kAXTitleAttribute) ?? axString(element, kAXDescriptionAttribute)
        }
        let role = element.flatMap { axString($0, kAXRoleAttribute) }
        let menuPath = [kAXMenuBarItemRole, kAXMenuItemRole].contains(role ?? "") ? path.filter {
            [kAXMenuBarItemRole, kAXMenuItemRole].contains(axString($0, kAXRoleAttribute) ?? "")
        }.compactMap(label) : []
        var secure: Bool? = nil
        if ["type_text", "paste"].contains(method), sameWindow,
           let focused = axElement(application, kAXFocusedUIElementAttribute) {
            // Inspect current focus and its parents; stale snapshot focus must
            // never authorize exposing a preview. Missing ancestry stays masked.
            var current: AXUIElement? = focused
            var seen: [AXUIElement] = []
            let textRole = axString(focused, kAXRoleAttribute)
            let readable = [kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole].contains(textRole ?? "")
            for _ in 0..<32 {
                guard let node = current, !seen.contains(where: { CFEqual($0, node) }) else { break }
                seen.append(node)
                guard let nodeRole = axString(node, kAXRoleAttribute) else { break }
                // A failed subrole read is unknown, not proof of an ordinary field.
                var subrole: CFTypeRef?
                let result = AXUIElementCopyAttributeValue(node, kAXSubroleAttribute as CFString, &subrole)
                if BadgeAction.isSecure(role: nodeRole, subrole: subrole as? String) { secure = true; break }
                if result != .success && result != .noValue && result != .attributeUnsupported { break }
                if let liveWindow, CFEqual(node, liveWindow) { if readable { secure = false }; break }
                current = axElement(node, kAXParentAttribute)
            }
        }
        return BadgeAction(method: method,
                           label: method == "perform_secondary_action" ? (args["action"] as? String).map(axActionLabel) : element.flatMap(label),
                           menuPath: menuPath, text: args["text"] as? String ?? "", secure: secure,
                           key: args["key"] as? String ?? "",
                           rightClick: ["right", "r"].contains((args["mouse_button"] as? String ?? "").lowercased()),
                           doubleClick: (args["click_count"] as? NSNumber)?.intValue == 2)
    }
}
