import Foundation

/// Person-facing bundle strings only. Protocol text, codes and logs stay English.
struct PresenceStrings {
    let bundle: Bundle
    let language: String

    /// Follow the person's first preferred language. Unsupported languages use
    /// English, not a later Chinese preference or an implicit zh-Hant fallback.
    static func language(for preferences: [String]) -> String {
        let tag = (preferences.first ?? "en").replacingOccurrences(of: "_", with: "-").lowercased()
        let parts = tag.split(separator: "-").map(String.init)
        guard parts.first == "zh" else { return "en" }
        let subtags = parts.dropFirst().prefix { $0.count > 1 }
        if let script = subtags.first(where: { $0.count == 4 }) {
            return script == "hans" ? "zh-Hans" : "en"
        }
        return subtags.contains("cn") || subtags.contains("sg") ? "zh-Hans" : "en"
    }

    init(language: String? = nil, resources: Bundle = .main,
         preferredLanguages: [String] = Locale.preferredLanguages) {
        self.language = Self.language(for: language.map { [$0] } ?? preferredLanguages)
        if let path = resources.path(forResource: self.language, ofType: "lproj"), let localized = Bundle(path: path) {
            bundle = localized
        } else { bundle = resources }
    }
    func text(_ key: String) -> String { bundle.localizedString(forKey: key, value: key, table: "Presence") }
    func format(_ key: String, _ arguments: CVarArg...) -> String {
        String(format: text(key), arguments: arguments)
    }
}

/// A finite set of host status keys prevents raw engine error messages from being
/// displayed to the person without localization.
enum AgentDesktopStatusText: String, CaseIterable {
    case starting = "Starting…"
    case waiting = "Waiting for the agent"
    case watchOnly = "Watch only · Waiting for an app"
    case locked = "Paused while this Mac is locked"
    case confirmation = "Input paused for a macOS confirmation"
}
