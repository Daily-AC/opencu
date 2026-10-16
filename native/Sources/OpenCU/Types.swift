import AppKit
import ApplicationServices

typealias Arguments = [String: Any]

struct OpenCUError: Error, LocalizedError {
    let code: String
    let message: String
    let details: Arguments?
    init(_ code: String, _ message: String, details: Arguments? = nil) {
        self.code = code; self.message = message; self.details = details
    }
    var errorDescription: String? { message }
}

struct TargetApp {
    let application: NSRunningApplication
    var pid: pid_t { application.processIdentifier }
    var id: String { application.bundleIdentifier ?? application.bundleURL?.path ?? String(pid) }
    var name: String { application.localizedName ?? id }
    /// AppKit's isActive also turns true under OpenCU's synthetic application-local
    /// activation; only the system's frontmost application is in the foreground.
    var isFrontmost: Bool { NSWorkspace.shared.frontmostApplication?.processIdentifier == pid }
    var json: [String: Any] { ["id": id, "displayName": name, "pid": Int(pid), "isActive": isFrontmost] }
}

struct WindowSnapshot {
    let app: TargetApp
    let window: AXUIElement?
    let bounds: CGRect
    let windowID: CGWindowID?
    let elements: [Int: AXUIElement]
    let elementPaths: [Int: [AXUIElement]]
    let elementTraits: [Int: ObservedElementTraits]
    let screenshotWidth: Int?
    let screenshotHeight: Int?

    var isOpaque: Bool {
        observedWindowIsOpaque(window: window.map(AXIdentity.init),
                               elements: elements.mapValues(AXIdentity.init),
                               paths: elementPaths.mapValues { $0.map(AXIdentity.init) },
                               traits: elementTraits)
    }
}

struct Observation {
    let text: String
    let screenshot: [String: Any]?
    let snapshot: WindowSnapshot
    var json: [String: Any] {
        var value: [String: Any] = ["text": text, "app": snapshot.app.json]
        if let screenshot { value["screenshot"] = screenshot }
        return value
    }
}

/// Menu state or an unconfirmed AX action. An unknown outcome requires a new read.
enum MenuEffect {
    case none
    case opened(AXUIElement)
    case chose
    case unconfirmed

    static let unconfirmedMessage = "The app did not confirm the action. Read state before continuing; do not repeat the action automatically."

    var requiresObservation: Bool {
        if case .unconfirmed = self { return true }
        return false
    }

    var actionResult: [String: Any] {
        if requiresObservation {
            return ["ok": true, "outcome": "unknown", "message": Self.unconfirmedMessage]
        }
        return ["ok": true]
    }
}

func axValue(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
    return value
}

func axString(_ element: AXUIElement, _ name: String) -> String? {
    axValue(element, name) as? String
}

func axRect(_ element: AXUIElement) -> CGRect? {
    guard let p = axValue(element, kAXPositionAttribute), let s = axValue(element, kAXSizeAttribute),
          CFGetTypeID(p) == AXValueGetTypeID(), CFGetTypeID(s) == AXValueGetTypeID() else { return nil }
    var point = CGPoint.zero, size = CGSize.zero
    guard AXValueGetValue(p as! AXValue, .cgPoint, &point), AXValueGetValue(s as! AXValue, .cgSize, &size) else { return nil }
    return CGRect(origin: point, size: size)
}

func requiredString(_ args: Arguments, _ name: String, allowEmpty: Bool = false) throws -> String {
    guard let value = args[name] as? String, allowEmpty || !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        throw OpenCUError("INVALID_ARGUMENT", "\(name) must be a \(allowEmpty ? "string" : "nonempty string")")
    }
    return value
}

func finiteNumber(_ args: Arguments, _ name: String) throws -> Double {
    guard let number = args[name] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite else {
        throw OpenCUError("INVALID_ARGUMENT", "\(name) must be a finite number")
    }
    return number.doubleValue
}

func requireAccessibility() throws {
    guard !desktopLocked() else {
        throw OpenCUError("SCREEN_LOCKED", "macOS is locked. Unlock this Mac before observing or controlling application windows.")
    }
    guard AXIsProcessTrusted() else {
        throw OpenCUError("ACCESSIBILITY_PERMISSION_REQUIRED", "OpenCU needs macOS Accessibility permission. Run opencu setup, grant access to OpenCU in System Settings, then reconnect.")
    }
}

func desktopLocked() -> Bool {
    let session = CGSessionCopyCurrentDictionary() as? [String: Any]
    return session?["CGSSessionScreenIsLocked"] as? Bool ?? false
}

func axElement(_ element: AXUIElement, _ name: String) -> AXUIElement? {
    guard let value = axValue(element, name), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
    return (value as! AXUIElement)
}

/// Safari exposes its Save panel itself as AXFocusedWindow with role AXSheet.
/// Finder exposes a desktop AXScrollArea there, which is not an input window.
func axIsWindowRole(_ role: String?) -> Bool {
    role == kAXWindowRole || role == kAXSheetRole
}

func axWindows(_ application: AXUIElement) -> [AXUIElement] {
    (axValue(application, kAXWindowsAttribute) as? [AXUIElement] ?? []).filter {
        axIsWindowRole(axString($0, kAXRoleAttribute))
    }
}

func axSelectedWindow(_ application: AXUIElement) -> AXUIElement? {
    for attribute in [kAXFocusedWindowAttribute, kAXMainWindowAttribute] {
        if let window = axElement(application, attribute), axIsWindowRole(axString(window, kAXRoleAttribute)) { return window }
    }
    let windows = axWindows(application)
    return windows.count == 1 ? windows[0] : nil
}

/// Recheck the exact observed edges, not a PID, title, geometry or cached
/// membership. Remote AX children are allowed only while still attached.
func attachedPath<Node>(_ path: [Node], to roots: [Node], equal: (Node, Node) -> Bool,
                        children: (Node) -> [Node]) -> Bool {
    guard let root = path.first, roots.contains(where: { equal($0, root) }) else { return false }
    return zip(path, path.dropFirst()).allSatisfy { parent, child in
        children(parent).contains { equal($0, child) }
    }
}

func axChildren(_ element: AXUIElement) -> [AXUIElement] {
    var values: CFArray?
    // Same bound as observation. An oversized or unavailable branch fails closed.
    guard AXUIElementCopyAttributeValues(element, kAXChildrenAttribute as CFString, 0, 8_000, &values) == .success else { return [] }
    return values as? [AXUIElement] ?? []
}

/// Captured only for indexed nodes, using the same labels/actions as the listing.
/// No live AX reads or title-bar attribute identity matching in this policy.
struct ObservedElementTraits {
    let role: String
    var hasLabel = false
    var actions: [String] = []

    var isTitleBarButton: Bool {
        role == kAXButtonRole && !hasLabel && actions.contains(kAXPressAction)
            && actions.allSatisfy { $0 == kAXPressAction || $0 == "AXZoomWindow" }
    }
}

/// Apply the policy to the filtered observation, not to unprinted AX children.
/// A button must be a direct child in the *printed* tree to count as chrome;
/// all of its descendants, including the zoom button's groups, remain chrome.
func observedWindowIsOpaque<Node: Hashable>(window: Node?, elements: [Int: Node],
                                            paths: [Int: [Node]], traits: [Int: ObservedElementTraits]) -> Bool {
    guard let window, elements.values.contains(window) else { return false }
    var byNode: [Node: ObservedElementTraits] = [:]
    for (index, element) in elements {
        guard let trait = traits[index] else { return false }
        byNode[element] = trait
    }
    for (index, element) in elements {
        guard let path = paths[index], path.last == element else { return false }
        guard path.first == window, element != window else { continue }
        // Filtered layout wrappers are absent from byNode, just as in the listing.
        guard let firstChild = path.dropFirst().first(where: { byNode[$0] != nil }),
              byNode[firstChild]?.isTitleBarButton == true else { return false }
    }
    // Root title / AXRaise and the separate menu bar are not window content.
    return true
}

/// AppKit custom actions report their AX action name as
/// "Name:<label>\nTarget:…\nSelector:…". Listings show the label alone.
func axActionLabel(_ name: String) -> String {
    guard name.hasPrefix("Name:") else { return name }
    let label = name.dropFirst(5).prefix { $0 != "\n" && $0 != "\r" }
    return label.isEmpty ? name : String(label)
}

/// Accept the exact action name, or a label that names exactly one action.
func axResolveAction(_ requested: String, in names: [String]) -> String? {
    if names.contains(requested) { return requested }
    let matches = names.filter { axActionLabel($0) == requested }
    return matches.count == 1 ? matches[0] : nil
}

struct AXIdentity: Hashable {
    let element: AXUIElement
    init(_ element: AXUIElement) { self.element = element }
    static func == (lhs: Self, rhs: Self) -> Bool { CFEqual(lhs.element, rhs.element) }
    func hash(into hasher: inout Hasher) { hasher.combine(CFHash(element)) }
}
