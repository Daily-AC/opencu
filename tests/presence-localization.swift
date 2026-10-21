import Foundation

@main
struct PresenceLocalizationChecks {
    static func main() throws {
        var checks = 0
        func expect(_ value: Bool, _ reason: String) {
            precondition(value, reason)
            checks += 1
        }
        let resourceURL = URL(fileURLWithPath: CommandLine.arguments[1])
        let resources = Bundle(path: resourceURL.path)!
        func table(_ language: String) throws -> [String: String] {
            let data = try Data(contentsOf: resourceURL.appendingPathComponent("\(language).lproj/Presence.strings"))
            return try PropertyListSerialization.propertyList(from: data, format: nil) as! [String: String]
        }
        let english = try table("en"), chinese = try table("zh-Hans")
        expect(Set(english.keys) == Set(chinese.keys), "Every person-facing key must exist in both languages")
        expect(english.count >= 50, "The complete presence/setup/badge/desktop table is tested")
        let placeholder = try NSRegularExpression(pattern: "%@")
        for key in english.keys.sorted() {
            let en = english[key]!, zh = chinese[key]!
            expect(!en.isEmpty && !zh.isEmpty, "Missing translation: \(key)")
            let count: (String) -> Int = { placeholder.numberOfMatches(in: $0, range: NSRange($0.startIndex..., in: $0)) }
            expect(count(en) == count(zh), "Format arguments differ between languages: \(key)")
            for language in ["en", "zh-Hans"] {
                let strings = PresenceStrings(resources: resources, preferredLanguages: [language])
                expect(strings.text(key) == (language == "en" ? en : zh), "Actual bundle lookup failed for \(language): \(key)")
            }
        }
        let simplified = ["zh-Hans", "zh-Hans-CN", "zh-Hans-SG", "zh-CN", "zh-SG", "zh_CN", "ZH-hAnS", "zh-Hans-TW", "zh-CN-u-nu-hanidec"]
        for tag in simplified {
            let strings = PresenceStrings(resources: resources, preferredLanguages: [tag, "en"])
            expect(strings.language == "zh-Hans", "Expected Simplified Chinese for \(tag)")
            expect(strings.text("Stop") == "停止", "Stop must use chosen language for \(tag)")
            expect(strings.text("OpenCU agent desktop") == "OpenCU agent 桌面", "Host title must be localized for \(tag)")
        }
        for preferences in [[String](), ["en"], ["en-US", "zh-Hans"], ["fr", "zh-CN"], ["ja"], ["zh"], ["zh-TW"], ["zh-HK"], ["zh-Hant"], ["zh-Hant-CN"], ["zh-Latn-CN"], ["zh-u-rg-cnzzzz"]] {
            let strings = PresenceStrings(resources: resources, preferredLanguages: preferences)
            expect(strings.language == "en", "Only an explicitly preferred Simplified Chinese tag selects zh-Hans: \(preferences)")
            expect(strings.text("Stop") == "Stop", "English fallback must not accidentally choose Simplified Chinese")
        }
        let zh = PresenceStrings(resources: resources, preferredLanguages: ["zh-CN"])
        let en = PresenceStrings(resources: resources, preferredLanguages: ["en"])
        for (key, translation) in [("Move once", "挪过来一次"), ("Allow once", "允许一次"), ("Keep here", "留在原处"),
                                   ("agent desktop", "agent 桌面"), ("OpenCU Agent Display", "OpenCU agent 显示器"),
                                   ("Untitled window", "无标题窗口")] {
            expect(zh.text(key) == translation, "Owner-readable label: \(key)")
        }
        for status in AgentDesktopStatusText.allCases {
            expect(english[status.rawValue] != nil && chinese[status.rawValue] != nil, "Every host status/pause has both translations")
            expect(zh.text(status.rawValue) != en.text(status.rawValue), "Host status must not remain English")
        }
        let move = "Move ‘%@’ from %@ to the agent desktop? It will return when this desktop closes. The app stays open. Keep the mouse still for 2 seconds after clicking."
        let allow = "Allow this window for the agent? ‘%@’ from %@ is already on the agent display. OpenCU will not move or restore it."
        expect(zh.format(move, "草稿 100% %@", "测试应用") == "把「草稿 100% %@」（测试应用）挪到 agent 桌面？结束时会挪回原处，应用会继续开着。点击后请保持鼠标不动 2 秒。", "Consent preserves names, percent signs and promised return")
        expect(zh.format(allow, "草稿", "测试应用") == "允许 agent 操作「草稿」（测试应用）吗？它已在 agent 显示器上，OpenCU 不会挪动或还原它。", "Already-present window uses permission wording, not a move promise")
        expect(en.format(move, "Draft", "Fixture").contains("Move ‘Draft’ from Fixture"), "English format arguments stay in order")
        expect(zh.format("OpenCU is using %@", zh.text("agent desktop")) == "OpenCU 正在使用 agent 桌面", "Menu heading localizes the desktop target as well as its sentence")
        expect(zh.text("OpenCU is stopped") == "OpenCU 已停止", "Menu stopped state is localized")
        expect(BadgeAction(method: "get_app_state").localized(zh.text) == "读取界面", "Desktop reading badge uses selected locale")
        expect(BadgeAction(method: "stopped").localized(zh.text) == "已被你停止", "Desktop stopped badge uses selected locale")
        expect(BadgeAction(method: "click", label: "Fixture").localized(zh.text) == "点击「Fixture」", "Badge action localizes without translating user content")
        print("\(checks) presence/desktop localization checks passed (\(english.count) bilingual keys); no GUI, capture or input")
    }
}
