import Foundation

/// The localized CFBundleDisplayName/CFBundleName an app shows, read without CFBundle's
/// localized Info.plist lookup. That lookup opens every .lproj directory of the app;
/// across all installed apps on a cold disk cache, list_apps took over a minute.
enum AppNames {
    static func name(appURL: URL, info: [String: Any], preferences: [String]? = nil) -> String {
        let tables = infoStrings(resources: appURL.appendingPathComponent("Contents/Resources"), preferences: preferences) + [info]
        for key in ["CFBundleDisplayName", "CFBundleName"] {
            if let value = tables.lazy.compactMap({ $0[key] as? String }).first { return value }
        }
        return appURL.deletingPathExtension().lastPathComponent
    }

    /// The best localization's InfoPlist strings or, when the app has none, an
    /// unlocalized InfoPlist.strings at the top of Resources, as CFBundle does.
    static func infoStrings(resources: URL, preferences: [String]?) -> [[String: Any]] {
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: resources.path)) ?? []
        var tables: [[String: Any]] = []
        if entries.contains("InfoPlist.loctable"),
           let all = plist(resources.appendingPathComponent("InfoPlist.loctable")) as? [String: Any],
           let best = Bundle.preferredLocalizations(from: all.keys.filter { $0 != "LocProvenance" }, forPreferences: preferences).first,
           let table = all[best] as? [String: Any] {
            tables.append(table)
        } else if let best = Bundle.preferredLocalizations(from: entries.filter { $0.hasSuffix(".lproj") }.map { String($0.dropLast(6)) },
                                                            forPreferences: preferences).first,
                  let table = plist(resources.appendingPathComponent("\(best).lproj/InfoPlist.strings")) as? [String: Any] {
            tables.append(table)
        }
        if tables.isEmpty, entries.contains("InfoPlist.strings"),
           let table = plist(resources.appendingPathComponent("InfoPlist.strings")) as? [String: Any] {
            tables.append(table)
        }
        return tables
    }

    private static func plist(_ url: URL) -> Any? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? PropertyListSerialization.propertyList(from: data, format: nil)
    }
}
