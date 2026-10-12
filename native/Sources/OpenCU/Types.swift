import AppKit
import ApplicationServices

typealias Arguments = [String: Any]

struct OpenCUError: Error, LocalizedError {
    let code: String
    let message: String
    init(_ code: String, _ message: String) { self.code = code; self.message = message }
    var errorDescription: String? { message }
}

struct TargetApp {
    let application: NSRunningApplication
    var pid: pid_t { application.processIdentifier }
    var id: String { application.bundleIdentifier ?? application.bundleURL?.path ?? String(pid) }
    var name: String { application.localizedName ?? id }
    var json: [String: Any] { ["id": id, "displayName": name, "pid": Int(pid), "isActive": application.isActive] }
}

struct WindowSnapshot {
    let app: TargetApp
    let window: AXUIElement
    let bounds: CGRect
    let windowID: CGWindowID?
    let elements: [Int: AXUIElement]
    let screenshotWidth: Int?
    let screenshotHeight: Int?
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

/// How an input changed menu state. Opened menus are closed again but stay listed.
enum MenuEffect {
    case none
    case opened(AXUIElement)
    case chose
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
