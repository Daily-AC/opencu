import Foundation
import CoreGraphics

/// Only a bounded preview enters the presentation layer; AX values and the
/// clipboard are never inputs to this model. Unknown secure status is masked.
struct BadgeAction {
    let key: String
    var argument: String?

    init(method: String, label: String? = nil, menuPath: [String] = [], text: String = "",
         secure: Bool? = nil, key: String = "", rightClick: Bool = false, doubleClick: Bool = false) {
        let label = label.map(Self.singleLine).flatMap { $0.isEmpty ? nil : $0 }
        switch method {
        case "get_app_state": self.key = "Reading"
        case "click":
            if !menuPath.isEmpty, !rightClick, !doubleClick {
                self.key = "Choose \"%@\""
                argument = menuPath.map(Self.singleLine).joined(separator: " › ")
            } else {
                let verb = rightClick ? "Right-click" : doubleClick ? "Double-click" : "Click"
                self.key = label == nil ? verb : verb + " \"%@\""
                argument = label
            }
        case "type_text", "paste":
            if secure == false {
                self.key = "Type \"%@\""
                argument = Self.singleLine(String(text.prefix(16))) + (text.count > 16 ? "…" : "")
            } else { self.key = "Type %@ characters"; argument = String(text.count) }
        case "press_key": self.key = "Press %@"; argument = Self.keySymbols(key)
        case "scroll": self.key = "Scroll"
        case "drag": self.key = "Drag"
        case "set_value": self.key = label == nil ? "Set" : "Set \"%@\""; argument = label
        case "select_text": self.key = "Select text"
        case "perform_secondary_action": self.key = label == nil ? "Perform" : "Perform \"%@\""; argument = label
        case "activate_app": self.key = "Bring to front"
        case "stopped": self.key = "Stopped by you"
        default: self.key = "Reading"
        }
    }
    func localized(_ lookup: (String) -> String) -> String {
        argument.map { String(format: lookup(key), $0) } ?? lookup(key)
    }
    static func singleLine(_ text: String) -> String {
        // Strip control/bidi characters, keep composed Unicode characters intact.
        String(text.unicodeScalars.map { scalar -> Character in
            if scalar.properties.generalCategory == .control || CharacterSet.newlines.contains(scalar)
                || (0x202A...0x202E).contains(scalar.value) || (0x2066...0x2069).contains(scalar.value)
                || [0x061C, 0x200E, 0x200F].contains(scalar.value) { return " " }
            return Character(String(scalar))
        }).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    static func isSecure(role: String?, subrole: String?) -> Bool {
        role == "AXSecureTextField" || subrole == "AXSecureTextField"
    }
    static func keySymbols(_ value: String) -> String {
        var raw = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if value == " " { raw = "space" }
        if raw == "+" { raw = "plus" }
        else if raw.hasSuffix("++") { raw = String(raw.dropLast(2)) + "+plus" }
        let modifiers: [(String, Set<String>)] = [
            ("⌃", ["ctrl", "control", "ctrl_l", "control_l", "ctrl_r", "control_r"]),
            ("⌥", ["alt", "option", "alt_l", "option_l", "alt_r", "option_r", "iso_level3_shift"]),
            ("⇧", ["shift", "shift_l", "shift_r"]),
            ("⌘", ["super", "super_l", "super_r", "meta", "meta_l", "meta_r", "cmd", "command", "command_r"]),
            ("fn", ["fn", "function"])]
        let names: [String: String] = ["return": "↩︎", "enter": "↩︎", "kp_enter": "⌤", "tab": "⇥", "iso_left_tab": "⇥",
            "escape": "⎋", "esc": "⎋", "space": "␣", "backspace": "⌫", "back_space": "⌫", "delete": "⌦",
            "forwarddelete": "⌦", "left": "←", "right": "→", "up": "↑", "down": "↓", "home": "↖", "end": "↘",
            "prior": "⇞", "page_up": "⇞", "pageup": "⇞", "next": "⇟", "page_down": "⇟", "pagedown": "⇟",
            "caps_lock": "⇪", "plus": "+", "minus": "−", "comma": ",", "period": ".", "slash": "/"]
        let tokens = raw.split(separator: "+").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        let flags = modifiers.filter { _, aliases in tokens.contains(where: aliases.contains) || (aliases.contains("shift") && tokens.contains("iso_left_tab")) }.map(\.0).joined()
        let keys = tokens.filter { token in !modifiers.contains { $0.1.contains(token) } }
            .map { names[$0] ?? singleLine($0.uppercased()) }.joined()
        return flags + keys
    }
}

struct BadgeLifetime {
    private(set) var target: String?
    private(set) var lastCall: TimeInterval?
    private(set) var stopped = false
    private(set) var connected = true
    mutating func call(target: String, now: TimeInterval) {
        guard connected, !stopped else { return }
        self.target = target; lastCall = now
    }
    mutating func stop(now: TimeInterval) {
        stopped = true
        if target != nil { lastCall = now }
    }
    mutating func hide() { target = nil; lastCall = nil }
    mutating func disconnect() { connected = false; hide() }
    func opacity(at now: TimeInterval) -> CGFloat {
        guard connected, target != nil, let lastCall else { return 0 }
        let elapsed = max(0, now - lastCall)
        if stopped { return elapsed < 3 ? 1 : 0 }
        return min(1, max(0, 1 - (elapsed - 3) / 0.2))
    }
}

struct BadgeLayout {
    static let height: CGFloat = 22
    static let shadowInset: CGFloat = 10
    let frame: CGRect
    let glyphOnly: Bool
    init(window: CGRect, titleBarHeight: CGFloat?, textWidth: CGFloat) {
        glyphOnly = window.width < 260
        let width = min(window.width * 0.45, glyphOnly ? 29 : 35 + max(0, textWidth))
        let bar = titleBarHeight.flatMap { $0.isFinite && $0 >= 22 && $0 <= window.height ? $0 : nil } ?? 28
        frame = CGRect(x: window.maxX - 10 - width, y: window.minY + (bar - Self.height) / 2,
                       width: width, height: Self.height)
    }
    /// AX toolbar extent or the title/traffic-light vertical centre establishes
    /// the title region; reject content controls outside the top of the window.
    static func titleHeight(window: CGRect, toolbar: CGRect?, title: CGRect?) -> CGFloat? {
        if let toolbar, toolbar.width > 0, toolbar.height >= 22, toolbar.minY >= window.minY,
           toolbar.minY - window.minY <= 40, toolbar.maxY - window.minY <= min(160, window.height) {
            return toolbar.maxY - window.minY
        }
        if let title, title.height > 0, title.minY >= window.minY {
            let height = 2 * (title.midY - window.minY)
            if height >= 22 && height <= min(100, window.height) { return height }
        }
        return nil
    }
}
