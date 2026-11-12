import AppKit
import ApplicationServices

@main
// Pure logic and in-memory rich-text checks. No input events are posted, and
// NSPasteboard.general and the production CLI entry point are never accessed.
struct OpenCUInputLogicChecks {
    @MainActor static func main() {
        // Fake metadata child for offline posix_spawn transport checks. Never
        // execute OnlineDisplays.current(), which would query the real desktop.
        if CommandLine.arguments.dropFirst().first == "--fake-online-displays" {
            switch CommandLine.arguments.last {
            case "valid": print("{\"schemaVersion\":1,\"displays\":[]}")
            case "failure": exit(23)
            case "hang": Thread.sleep(forTimeInterval: 5)
            case "oversized": print(String(repeating: "x", count: 70_000))
            default: print("not JSON")
            }
            return
        }
        Task { @MainActor in
            do {
                try run()
                try await checkDisplayRemoval()
                try checkAppNames()
                try await checkMultiAgentCollaboration()
                exit(0)
            } catch {
                FileHandle.standardError.write(Data("FAIL: \(error)\n".utf8))
                exit(1)
            }
        }
        RunLoop.main.run()
    }

    // Synthetic bundles in a temporary directory; no installed app is read.
    static func checkAppNames() throws {
        var checked = 0
        func expect(_ value: Bool, _ message: String) throws {
            guard value else { throw OpenCUError("TEST_FAILED", message) }
            checked += 1
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("opencu-appnames-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        func app(_ name: String, files: [String: Any]) throws -> URL {
            let url = root.appendingPathComponent("\(name).app")
            for (path, value) in files {
                let file = url.appendingPathComponent("Contents/Resources/\(path)")
                try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                if let table = value as? [String: Any] {
                    try PropertyListSerialization.data(fromPropertyList: table, format: .binary, options: 0).write(to: file)
                }
            }
            try FileManager.default.createDirectory(at: url.appendingPathComponent("Contents/Resources"), withIntermediateDirectories: true)
            return url
        }
        let zh = ["zh-Hans"], en = ["en"]
        let table = try app("Table", files: ["InfoPlist.loctable": ["en": ["CFBundleName": "Table"], "zh_CN": ["CFBundleName": "表格"],
                                                                     "LocProvenance": ["en": 1]],
                                             "InfoPlist.strings": ["CFBundleDisplayName": "Unlocalized"]])
        try expect(AppNames.name(appURL: table, info: [:], preferences: zh) == "表格", "Loctable picks the preferred localization")
        try expect(AppNames.name(appURL: table, info: [:], preferences: en) == "Table", "Loctable falls back by preference")
        let lproj = try app("Lproj", files: ["zh-Hans.lproj/InfoPlist.strings": ["CFBundleDisplayName": "本地化"],
                                             "en.lproj/InfoPlist.strings": ["CFBundleDisplayName": "Localized"]])
        try expect(AppNames.name(appURL: lproj, info: ["CFBundleName": "Plain"], preferences: zh) == "本地化", "Best .lproj strings win")
        try expect(AppNames.name(appURL: lproj, info: ["CFBundleName": "Plain"], preferences: en) == "Localized", "English .lproj strings")
        let fallback = try app("Fallback", files: ["InfoPlist.strings": ["CFBundleDisplayName": "Wi-Fi"]])
        try FileManager.default.createDirectory(at: fallback.appendingPathComponent("Contents/Resources/zh_CN.lproj"), withIntermediateDirectories: true)
        try expect(AppNames.name(appURL: fallback, info: ["CFBundleName": "WiFiAgent"], preferences: zh) == "Wi-Fi",
                   "Unlocalized InfoPlist.strings applies when no localization has strings")
        let plain = try app("Plain", files: [:])
        try expect(AppNames.name(appURL: plain, info: ["CFBundleDisplayName": "Display", "CFBundleName": "Name"], preferences: zh) == "Display",
                   "Info.plist display name without localizations")
        try expect(AppNames.name(appURL: plain, info: [:], preferences: zh) == "Plain", "File name is the last resort")
        print("\(checked) application name checks passed on synthetic bundles; no installed app was read")
    }

    @MainActor static func checkDisplayRemoval() async throws {
        var checked = 0
        func expect(_ value: Bool, _ message: String) throws {
            guard value else { throw OpenCUError("TEST_FAILED", message) }
            checked += 1
        }
        let main = OnlineDisplay(id: 1, frame: CGRect(x: 0, y: 0, width: 1728, height: 1117),
                                 main: true, mirrored: false, pixelWidth: 3456, pixelHeight: 2234)
        let agent = OnlineDisplay(id: 8, frame: CGRect(x: 1728, y: 1117, width: 1728, height: 1117),
                                  main: false, mirrored: false, pixelWidth: 3456, pixelHeight: 2234)
        let decoded = try OnlineDisplays.parse(OnlineDisplays.encode([agent, main]))
        try expect(decoded == [main, agent], "Fresh display JSON preserves IDs, frames, flags and pixels and sorts by ID")
        try expect(try OnlineDisplays.parse(Data("{\"schemaVersion\":1,\"displays\":[]}".utf8)).isEmpty, "Valid empty list is accepted")
        let validJSON = String(decoding: try OnlineDisplays.encode([main]), as: UTF8.self)
        let invalid = ["", "not JSON", "{\"error\":\"query failed\"}",
                       validJSON.replacingOccurrences(of: "\"schemaVersion\":1", with: "\"schemaVersion\":2"),
                       validJSON.replacingOccurrences(of: "\"id\":1", with: "\"id\":true"),
                       validJSON.replacingOccurrences(of: "\"id\":1", with: "\"id\":4294967296"),
                       validJSON.replacingOccurrences(of: "\"width\":1728", with: "\"width\":-1"),
                       validJSON.replacingOccurrences(of: "\"main\":true", with: "\"main\":1"),
                       validJSON + "garbage", String(repeating: " ", count: 65_537)]
        for value in invalid {
            do { _ = try OnlineDisplays.parse(Data(value.utf8)); throw OpenCUError("TEST_FAILED", "Invalid fresh list was accepted") }
            catch let error as OpenCUError { try expect(error.code == "AGENT_DISPLAY_LIST_INVALID", "Reject malformed fresh lists") }
        }
        do { _ = try OnlineDisplays.parse(OnlineDisplays.encode([main, main])); throw OpenCUError("TEST_FAILED", "Duplicate IDs accepted") }
        catch let error as OpenCUError { try expect(error.code == "AGENT_DISPLAY_LIST_INVALID", "Duplicate IDs refused") }

        var time = 10.0, calls = 0, budgets: [Double] = []
        let delayed = await DisplayRemovalPoll.wait(for: 8, started: time, now: { time }, sleep: { time += $0 }) { budget in
            calls += 1; budgets.append(budget); time += 0.02
            return calls < 3 ? [main, agent] : [main]
        }
        try expect(delayed.removed && delayed.checks == 3 && delayed.displays == [main], "Poll uses each injected fresh result, not the owner's stale list")
        try expect(abs(delayed.elapsedMs - 560) < 0.01 && delayed.error == nil, "Measured time includes child-query latency and polling intervals")
        try expect(budgets.allSatisfy { $0 > 0 && $0 <= 2 }, "Each child gets a bounded deadline")

        time = 0; calls = 0
        let gone = await DisplayRemovalPoll.wait(for: 8, started: 0, now: { time }, sleep: { _ in
            throw OpenCUError("TEST_FAILED", "Should not sleep after confirmation")
        }) { _ in calls += 1; return [main] }
        try expect(gone.removed && gone.checks == 1 && calls == 1, "Immediate/duplicate removal completes in one check")

        time = 0; budgets = []
        let timeout = await DisplayRemovalPoll.wait(for: 8, started: 0, now: { time }, sleep: { time += $0 }) { budget in
            budgets.append(budget); return [main, agent]
        }
        try expect(!timeout.removed && timeout.checks == 40 && abs(timeout.elapsedMs - 10_000) < 0.01,
                   "Display still listed by fresh processes is a real ten-second failure")
        try expect(timeout.displays == [main, agent] && timeout.error?.contains("still list display 8") == true, "Timeout keeps last fresh evidence")
        try expect(budgets.last == 0.25, "Final process cannot exceed the overall deadline")

        time = 0
        let failed = await DisplayRemovalPoll.wait(for: 8, started: 0, now: { time }, sleep: { time += $0 }) { _ in
            throw OpenCUError("AGENT_DISPLAY_LIST_INVALID", "malformed child JSON")
        }
        try expect(!failed.removed && failed.checks == 1 && failed.displays == nil && failed.error != nil,
                   "Query/parsing failure cannot falsely confirm removal")
        let expired = await DisplayRemovalPoll.wait(for: 8, started: 0, now: { 10 }, sleep: { _ in }) { _ in
            throw OpenCUError("TEST_FAILED", "Must not launch a child after deadline")
        }
        try expect(!expired.removed && expired.checks == 0, "Expired budget launches no children")
        time = 0
        let late = await DisplayRemovalPoll.wait(for: 8, started: 0, now: { time }, sleep: { time += $0 }) { _ in
            time = 11; return [main]
        }
        try expect(!late.removed && late.error?.contains("deadline") == true, "An over-budget lister cannot report timely removal")

        let executable = CommandLine.arguments[0]
        let bytes = try FreshOnlineDisplays.run(executable: executable, arguments: ["--fake-online-displays", "valid"], timeout: 2)
        try expect(try OnlineDisplays.parse(bytes).isEmpty, "Actual posix_spawn pipe transports fake metadata without GUI access")
        for mode in ["failure", "hang", "oversized"] {
            do {
                _ = try FreshOnlineDisplays.run(executable: executable, arguments: ["--fake-online-displays", mode], timeout: mode == "hang" ? 0.1 : 2)
                throw OpenCUError("TEST_FAILED", "Child failure was ignored")
            } catch let error as OpenCUError {
                try expect(error.code == "AGENT_DISPLAY_LIST_FAILED", "Child exit, timeout and output limit fail closed and reap the child")
            }
        }
        print("\(checked) fresh-display parsing, injected removal polling and fake-child transport checks passed; no display enumeration or GUI access")
    }

    @MainActor static func run() throws {
        var checked = 0
        func expect(_ condition: @autoclosure () -> Bool, _ note: String) {
            guard condition() else {
                FileHandle.standardError.write(Data("FAIL: \(note)\n".utf8))
                exit(1)
            }
            checked += 1
        }
        func fails(_ code: String, _ body: () throws -> Void) {
            do { try body(); expect(false, "Expected \(code)") }
            catch let error as OpenCUError { expect(error.code == code, "\(error.code) != \(code)") }
            catch { expect(false, "Unexpected error: \(error)") }
        }
        // The exact indexed tree reported by the reviewer; no AX reads or window
        // decoration attribute identities are involved in these regressions.
        typealias ObservedRow = (index: Int, trait: ObservedElementTraits, path: [Int])
        func opaque(_ rows: [ObservedRow], window: Int? = 1) -> Bool {
            observedWindowIsOpaque(window: window,
                elements: Dictionary(uniqueKeysWithValues: rows.map { ($0.index, $0.index) }),
                paths: Dictionary(uniqueKeysWithValues: rows.map { ($0.index, $0.path) }),
                traits: Dictionary(uniqueKeysWithValues: rows.map { ($0.index, $0.trait) }))
        }
        let reviewerWindow: [ObservedRow] = [
            (1, .init(role: kAXWindowRole, hasLabel: true, actions: [kAXRaiseAction]), [1]),
            (2, .init(role: kAXButtonRole, actions: [kAXPressAction]), [1, 2]),
            (3, .init(role: kAXButtonRole, actions: [kAXPressAction, "AXZoomWindow"]), [1, 3]),
            (4, .init(role: kAXGroupRole, hasLabel: true), [1, 3, 4]), // kind="group"
            (5, .init(role: kAXGroupRole, hasLabel: true), [1, 3, 4, 5]), // kind="group"
            (6, .init(role: kAXButtonRole, actions: [kAXPressAction]), [1, 6]),
        ]
        expect(opaque(reviewerWindow), "blender_observed_chrome_tree_is_opaque")
        fails("BACKGROUND_INPUT_UNSUPPORTED") {
            try InputController.requireBackgroundDelivery(isFrontmost: false, unsupportedWindow: opaque(reviewerWindow))
        }
        let observedMenu: [ObservedRow] = [
            (7, .init(role: kAXMenuBarRole), [7]),
            (8, .init(role: kAXMenuBarItemRole, hasLabel: true, actions: [kAXPressAction]), [7, 8]),
        ]
        expect(opaque(reviewerWindow + observedMenu), "separate_menu_bar_does_not_make_window_content")
        expect(!opaque(reviewerWindow + [(9, .init(role: kAXButtonRole, hasLabel: true, actions: [kAXPressAction]), [1, 9])]),
               "ordinary_labelled_button_window_is_not_opaque")
        expect(!opaque(reviewerWindow + [(9, .init(role: kAXStaticTextRole, hasLabel: true), [1, 9])]),
               "ordinary_static_text_window_is_not_opaque")
        let root = [reviewerWindow[0]]
        expect(!opaque(root + [(9, .init(role: kAXGroupRole, hasLabel: true), [1, 9])]),
               "empty_but_labelled_content_window_is_not_opaque")
        expect(!opaque(root + [(9, .init(role: kAXTextFieldRole), [1, 9])]),
               "single_unlabelled_text_field_window_is_not_opaque")
        expect(!opaque(root + [(9, .init(role: "AXWebArea"), [1, 9])]),
               "ordinary_web_content_window_is_not_opaque")
        expect(!opaque(root + [(9, .init(role: kAXButtonRole, actions: [kAXPressAction, kAXIncrementAction]), [1, 9])]),
               "button_with_content_action_is_not_title_bar_chrome")
        expect(!opaque(root + [(9, .init(role: kAXGroupRole, hasLabel: true), [1, 9]),
                               (10, .init(role: kAXButtonRole, actions: [kAXPressAction]), [1, 9, 10])]),
               "button_inside_content_group_is_not_title_bar_chrome")
        expect(opaque(root), "window_title_and_raise_action_alone_are_not_content")
        expect(!opaque(observedMenu, window: nil), "windowless_menu_shortcuts_remain_supported")
        expect(!opaque(observedMenu), "missing_observed_window_is_not_classified_as_opaque")
        // Unindexed layout wrappers were removed by the normal observation filter.
        let wrapped = reviewerWindow.map { row -> ObservedRow in
            (row.index, row.trait, row.path.count > 1 ? [1, 99] + row.path.dropFirst() : row.path)
        }
        expect(opaque(wrapped), "filtered_wrappers_do_not_change_visible_chrome_classification")
        expect(!opaque(root + [(9, .init(role: kAXTextFieldRole), [1, 99, 9])]),
               "content_below_filtered_wrapper_is_not_opaque")
        for frontmost in [false, true] {
            for unsupportedWindow in [false, true] {
                let delivery = {
                    try InputController.requireBackgroundDelivery(isFrontmost: frontmost, unsupportedWindow: unsupportedWindow)
                }
                if !frontmost && unsupportedWindow { fails("BACKGROUND_INPUT_UNSUPPORTED", delivery) }
                else { try delivery(); expect(true, "Foreground and content-bearing windows retain their input path") }
            }
        }
        for frontmost in [false, true] {
            for isPanel in [false, true] {
                let delivery = { try InputController.requirePointerDelivery(isFrontmost: frontmost, isFilePanel: isPanel) }
                if !frontmost && isPanel { fails("BACKGROUND_REMOTE_FOCUS", delivery) }
                else { try delivery(); expect(true, "Foreground panels and ordinary background windows retain pointer delivery") }
            }
        }
        let panelBounds = CGRect(x: 10, y: 10, width: 20, height: 20)
        for (start, end, intersects) in [
            (CGPoint(x: 15, y: 15), CGPoint(x: 15, y: 15), true),
            (CGPoint(x: 5, y: 15), CGPoint(x: 5, y: 15), false),
            (CGPoint(x: 0, y: 20), CGPoint(x: 40, y: 20), true),
            (CGPoint(x: 40, y: 20), CGPoint(x: 0, y: 20), true),
            (CGPoint(x: 20, y: 0), CGPoint(x: 20, y: 40), true),
            (CGPoint(x: 0, y: 40), CGPoint(x: 40, y: 0), true),
            (CGPoint(x: 0, y: 20), CGPoint(x: 20, y: 0), true), // Touching edge.
            (CGPoint(x: 0, y: 15), CGPoint(x: 15, y: 0), false), // Bounding boxes overlap, segment misses.
        ] {
            expect(InputController.pointerIntersectsPanel(from: start, to: end, bounds: panelBounds) == intersects,
                   "Pointer path correctly targets the panel")
        }
        expect(!InputController.pointerIntersectsPanel(from: .zero, to: .zero, bounds: .zero), "Empty panel bounds do not qualify")

        expect(AXError.cannotComplete.rawValue == -25204, "Reported AX error matches cannotComplete")
        for action in [kAXPressAction, kAXConfirmAction, kAXIncrementAction, "customAction"] {
            let outcome = try InputController.actionEffect(.cannotComplete, action: action, confirmed: .chose)
            expect(outcome.requiresObservation, "An unconfirmed AX action requires a fresh read")
            expect(outcome.actionResult["ok"] as? Bool == true && outcome.actionResult["outcome"] as? String == "unknown",
                   "Unknown outcome is not an action failure or a completion claim")
            expect(outcome.actionResult["message"] as? String == "The app did not confirm the action. Read state before continuing; do not repeat the action automatically.",
                   "Unknown outcome wording is stable")
        }
        let confirmed = try InputController.actionEffect(.success, action: kAXPressAction, confirmed: .chose)
        if case .chose = confirmed { expect(true, "Confirmed menu choice retained") }
        else { expect(false, "Successful action lost menu effect") }
        expect(!confirmed.requiresObservation && confirmed.actionResult["outcome"] == nil, "Ordinary success retains its result")
        for (error, code) in [(AXError.invalidUIElement, "STALE_ELEMENT"), (.apiDisabled, "ACCESSIBILITY_PERMISSION_REQUIRED"),
                              (.actionUnsupported, "ACCESSIBILITY_ERROR"), (.failure, "ACCESSIBILITY_ERROR")] {
            fails(code) { _ = try InputController.actionEffect(error, action: kAXPressAction, confirmed: .none) }
        }
        fails("ACCESSIBILITY_ERROR") { try InputController.checkAXResult(.cannotComplete, operation: "set element value") }
        for result in [AXError.success, .attributeUnsupported] {
            fails("TEXT_SELECTION_UNSUPPORTED") {
                try InputController.checkSettable(result, settable: false, attribute: kAXSelectedTextRangeAttribute)
            }
        }
        try InputController.checkSettable(.success, settable: true, attribute: kAXSelectedTextRangeAttribute)
        expect(true, "Settable text selection remains supported")
        fails("ATTRIBUTE_NOT_SETTABLE") { try InputController.checkSettable(.success, settable: false, attribute: kAXValueAttribute) }
        fails("ACCESSIBILITY_ERROR") { try InputController.checkSettable(.cannotComplete, settable: false, attribute: kAXSelectedTextRangeAttribute) }
        fails("ACCESSIBILITY_PERMISSION_REQUIRED") { try InputController.checkSettable(.apiDisabled, settable: false, attribute: kAXSelectedTextRangeAttribute) }
        let resources = Bundle(path: CommandLine.arguments[1])!
        func badgeText(_ action: BadgeAction, _ language: String) -> String {
            let localized = Bundle(path: resources.path(forResource: language, ofType: "lproj")!)!
            return action.localized { localized.localizedString(forKey: $0, value: $0, table: "Presence") }
        }
        let wording: [(BadgeAction, String, String)] = [
            (BadgeAction(method: "get_app_state"), "Reading", "读取界面"),
            (BadgeAction(method: "click"), "Click", "点击"),
            (BadgeAction(method: "click", label: "Save"), "Click \"Save\"", "点击「Save」"),
            (BadgeAction(method: "click", doubleClick: true), "Double-click", "双击"),
            (BadgeAction(method: "click", label: "Save", doubleClick: true), "Double-click \"Save\"", "双击「Save」"),
            (BadgeAction(method: "click", rightClick: true), "Right-click", "右键点击"),
            (BadgeAction(method: "click", label: "Save", rightClick: true), "Right-click \"Save\"", "右键点击「Save」"),
            (BadgeAction(method: "click", menuPath: ["File", "Save"]), "Choose \"File › Save\"", "选择菜单「File › Save」"),
            (BadgeAction(method: "type_text", text: "hello", secure: false), "Type \"hello\"", "输入「hello」"),
            (BadgeAction(method: "paste", text: "hello", secure: false), "Type \"hello\"", "输入「hello」"),
            (BadgeAction(method: "press_key", key: "super+a"), "Press ⌘A", "按下 ⌘A"),
            (BadgeAction(method: "scroll"), "Scroll", "滚动"),
            (BadgeAction(method: "drag"), "Drag", "拖动"),
            (BadgeAction(method: "set_value", label: "Filename"), "Set \"Filename\"", "设置「Filename」"),
            (BadgeAction(method: "select_text", text: "never display selection"), "Select text", "选中文字"),
            (BadgeAction(method: "perform_secondary_action", label: "Show Menu"), "Perform \"Show Menu\"", "执行「Show Menu」"),
            (BadgeAction(method: "activate_app"), "Bring to front", "切到前台"),
            (BadgeAction(method: "stopped"), "Stopped by you", "已被你停止")]
        for (action, english, chinese) in wording {
            expect(badgeText(action, "en") == english, "English badge wording: \(english)")
            expect(badgeText(action, "zh-Hans") == chinese, "Chinese badge wording: \(chinese)")
        }
        for method in ["type_text", "paste"] {
            for secure: Bool? in [true, nil] {
                let action = BadgeAction(method: method, text: "secret👨‍👩‍👧‍👦", secure: secure)
                expect(action.argument == "7", "Secure or unknown focus stores count only, counted as composed characters")
                expect(badgeText(action, "en") == "Type 7 characters", "Secure text never reaches English display")
                expect(badgeText(action, "zh-Hans") == "输入 7 个字符", "Secure text never reaches Chinese display")
            }
            let sixteen = String(repeating: "👨‍👩‍👧‍👦", count: 16)
            expect(BadgeAction(method: method, text: sixteen, secure: false).argument == sixteen, "16 characters have no ellipsis")
            expect(BadgeAction(method: method, text: sixteen + "secret", secure: false).argument == sixteen + "…", "Long input retains only first 16 composed characters")
        }
        expect(BadgeAction.isSecure(role: "AXSecureTextField", subrole: nil), "Secure role recognized")
        expect(BadgeAction.isSecure(role: "AXTextField", subrole: "AXSecureTextField"), "Secure subrole recognized")
        expect(!BadgeAction.isSecure(role: "AXTextField", subrole: "AXSearchField"), "Search field is not secure")
        expect(BadgeAction(method: "set_value", text: "secret", secure: true).argument == nil, "Set value never previews its value")
        expect(BadgeAction.singleLine("line1\nline2\tend") == "line1 line2 end", "Badge is always single line")
        for (key, symbol) in [("shift+super+s", "⇧⌘S"), ("Cmd+Shift+s", "⇧⌘S"), ("Return", "↩︎"),
                              ("Tab", "⇥"), ("Escape", "⎋"), ("ctrl+alt+delete", "⌃⌥⌦"),
                              ("super++", "⌘+"), ("ISO_Left_Tab", "⇧⇥"), ("super+super+a", "⌘A")] {
            expect(BadgeAction.keySymbols(key) == symbol, "Mac key notation: \(key)")
        }
        let badgeWindow = CGRect(x: -500, y: -300, width: 720, height: 500)
        let badge = BadgeLayout(window: badgeWindow, titleBarHeight: nil, textWidth: 60)
        expect(badge.frame.height == 22 && badge.frame.width == 95, "Badge height and exact padding/gap/glyph budget")
        expect(badge.frame.maxX == badgeWindow.maxX - 10 && badge.frame.minY == badgeWindow.minY + 3, "Fallback 28pt title bar; 10pt right inset")
        expect(BadgeLayout(window: badgeWindow, titleBarHeight: 52, textWidth: 60).frame.minY == badgeWindow.minY + 15, "AX toolbar vertical centering")
        expect(BadgeLayout(window: badgeWindow, titleBarHeight: nil, textWidth: 1000).frame.width == 324, "Long label capped to 45 percent")
        for width: CGFloat in [259, 260] {
            let layout = BadgeLayout(window: CGRect(x: 0, y: 0, width: width, height: 200), titleBarHeight: nil, textWidth: 100)
            expect(layout.glyphOnly == (width < 260), "Glyph-only threshold is strictly below 260pt")
            if width < 260 { expect(layout.frame.width == 29, "Glyph only keeps 8pt left and 10pt right padding") }
        }
        expect(BadgeLayout.titleHeight(window: badgeWindow, toolbar: CGRect(x: -500, y: -300, width: 720, height: 52), title: nil) == 52,
               "AX toolbar measures title region")
        expect(BadgeLayout.titleHeight(window: badgeWindow, toolbar: nil, title: CGRect(x: -300, y: -292, width: 100, height: 12)) == 28,
               "AX title centre measures title region")
        expect(BadgeLayout.titleHeight(window: badgeWindow, toolbar: CGRect(x: 0, y: 100, width: 100, height: 200), title: nil) == nil,
               "Content toolbar cannot masquerade as window title bar")
        var lifetime = BadgeLifetime()
        expect(lifetime.opacity(at: 0) == 0, "No badge before a window call")
        lifetime.call(target: "1:2", now: 10)
        expect(lifetime.opacity(at: 13) == 1, "Badge holds for exactly 3 seconds")
        expect(abs(lifetime.opacity(at: 13.1) - 0.5) < 0.0001, "Fade halfway at 100ms")
        expect(lifetime.opacity(at: 13.201) == 0, "Fade completes after 200ms")
        lifetime.call(target: "1:2", now: 20)
        expect(lifetime.opacity(at: 22.99) == 1, "Next call renews lifetime")
        lifetime.hide()
        expect(lifetime.opacity(at: 21) == 0, "Target change hides without fading")
        lifetime.call(target: "2:3", now: 30); lifetime.stop(now: 40)
        expect(lifetime.opacity(at: 42.999) == 1 && lifetime.opacity(at: 43) == 0, "Stop shows for 3 seconds then hides")
        lifetime.call(target: "2:3", now: 42)
        expect(lifetime.stopped && lifetime.opacity(at: 43) == 0, "Reads after Stop cannot overwrite or prolong it")
        lifetime.disconnect()
        expect(lifetime.opacity(at: 41) == 0, "Disconnect immediately removes stopped badge")
        lifetime.call(target: "3:4", now: 44)
        expect(lifetime.opacity(at: 44) == 0, "Disconnected callbacks cannot reshow badge")
        expect(FocusGuard.isPresenceProcess(pid: getpid(), bundleID: nil), "Own process is never a foreground restoration target")
        expect(FocusGuard.isPresenceProcess(pid: -1, bundleID: "dev.opencu.engine"), "Separate setup process is a person's focus choice")
        expect(!FocusGuard.isPresenceProcess(pid: -1, bundleID: "dev.opencu.fixture"), "Ordinary target remains guarded")
        for ms in [1, 15000] {
            let parsed = try waitMilliseconds(["ms": ms])
            expect(parsed == UInt64(ms), "Wait includes boundary")
        }
        for ms: Any in [0, -1, 15001, 1.5, "1", true, NSNull()] {
            fails("INVALID_ARGUMENT") { _ = try waitMilliseconds(["ms": ms]) }
        }
        fails("INVALID_ARGUMENT") { _ = try waitMilliseconds([:]) }
        expect(PresenceState.requiresPermissionToContinue("wait", screenshot: false), "Wait participates in stop cancellation")
        var presence = PresenceState()
        expect(!presence.menuVisible(at: 0) && !presence.cursorVisible(at: 0), "No presence before app calls")
        presence.call(target: "fixture", now: 10)
        presence.finished(now: 10)
        presence.pointer(now: 11)
        expect(presence.menuVisible(at: 24.999), "Menu remains before 15-second deadline")
        expect(!presence.menuVisible(at: 25), "Menu expires exactly at 15 seconds")
        expect(presence.cursorVisible(at: 13.999), "Cursor remains before 3-second deadline")
        expect(!presence.cursorVisible(at: 14), "Cursor expires exactly at 3 seconds")
        presence.call(target: "fixture", now: 20)
        presence.finished(now: 20)
        expect(presence.menuVisible(at: 34.999), "Subsequent calls extend menu visibility")
        var longCall = PresenceState()
        longCall.call(target: "fixture", now: 0)
        expect(longCall.menuVisible(at: 30), "Stop remains accessible throughout a long in-flight operation")
        longCall.finished(now: 30)
        expect(longCall.menuVisible(at: 44.999) && !longCall.menuVisible(at: 45), "Idle timeout starts after the operation finishes")
        presence.pointer(now: 21)
        presence.call(target: "other", now: 22)
        expect(!presence.cursorVisible(at: 22), "Changing target hides cursor")
        presence.pointer(now: 23)
        presence.stop()
        expect(!presence.cursorVisible(at: 23), "Stop hides cursor immediately")
        for method in ["wait", "click", "drag", "press_key", "type_text", "paste", "scroll", "set_value", "select_text",
                       "perform_secondary_action", "activate_app"] {
            fails("STOPPED_BY_PERSON") { try presence.requireAllowed(method) }
        }
        fails("STOPPED_BY_PERSON") { try presence.requireAllowed("get_app_state", screenshot: true) }
        for method in ["agent_desktop_start"] {
            fails("STOPPED_BY_PERSON") { try presence.requireAllowed(method) }
        }
        for method in ["get_app_state", "doctor", "list_apps", "agent_desktop_status", "agent_desktop_stop"] { try presence.requireAllowed(method) }
        presence.call(target: "other", now: 30); presence.pointer(now: 30)
        expect(presence.stopped && !presence.cursorVisible(at: 30), "Calls cannot clear the stop latch")
        presence.disconnect()
        expect(!presence.menuVisible(at: 30) && !presence.cursorVisible(at: 30), "Disconnect removes both indicators")
        var disconnected = PresenceState()
        disconnected.call(target: "fixture", now: 0); disconnected.pointer(now: 0); disconnected.disconnect()
        disconnected.call(target: "fixture", now: 1); disconnected.pointer(now: 1)
        expect(!disconnected.menuVisible(at: 1) && !disconnected.cursorVisible(at: 1), "Queued callbacks cannot reshow after EOF")
        try PresenceState().requireAllowed("click")
        expect(!PresenceState().stopped, "New connection starts fresh")
        let motion = CursorMotion(start: CGPoint(x: -200, y: 50), end: CGPoint(x: 100, y: 200), began: 10)
        expect(motion.point(at: 9) == motion.start && motion.point(at: 10) == motion.start, "Animation starts at previous point")
        expect(motion.point(at: 10.25) == motion.end && motion.point(at: 11) == motion.end, "Animation clamps to exact endpoint")
        expect(motion.point(at: 10.125).x == 62.5, "Cubic ease-out midpoint")
        expect(CursorMotion.press(at: 1, began: 1) == 0 && CursorMotion.press(at: 2, began: 1) == 0, "Press pulse returns to rest")
        expect(abs(CursorMotion.press(at: 1.15, began: 1) - 1) < 0.0001, "Press pulse peaks halfway")
        for scale: CGFloat in [1, 2] {
            let bounds = CGRect(x: -800, y: -300, width: 600, height: 400)
            let point = CursorMotion.screenPoint(pixel: CGPoint(x: 150 * scale, y: 100 * scale),
                                                  pixels: CGSize(width: 600 * scale, height: 400 * scale), bounds: bounds)
            expect(point == CGPoint(x: -650, y: -200), "Screenshot pixels map to screen points at 1x and 2x on secondary display")
        }
        expect(CursorMotion.appKitRect(CGRect(x: -650, y: -200, width: 60, height: 60), primaryHeight: 900)
               == CGRect(x: -650, y: 1040, width: 60, height: 60), "AppKit conversion uses primary-display origin")
        for ax in [false, true] { for screen in [false, true] { for reconnect in [false, true] {
            expect(PermissionStatus(accessibility: ax, screenRecording: screen, reconnect: reconnect).ready == (ax && screen && !reconnect),
                   "Ready requires both grants and no restart")
        } } }
        for responsible: Int32? in [nil, -1, 0, 20] {
            fails("CAPTURE_RESPONSIBILITY_UNVERIFIED") {
                try CaptureSafety.requireVerifiedEngine(worker: true, pid: 10, responsiblePID: responsible)
            }
        }
        fails("CAPTURE_RESPONSIBILITY_UNVERIFIED") {
            try CaptureSafety.requireVerifiedEngine(worker: false, pid: 10, responsiblePID: 10)
        }
        try CaptureSafety.requireVerifiedEngine(worker: true, pid: 10, responsiblePID: 10)
        expect(true, "Only a independent worker and OS-verified self-responsible engine qualifies")
        fails("SCREEN_RECORDING_PERMISSION_REQUIRED") { try CaptureSafety.requireScreenRecordingGrant(false) }
        try CaptureSafety.requireScreenRecordingGrant(true)
        expect(true, "An existing grant allows capture by a verified engine")
        let mainDisplay = CGRect(x: 0, y: 0, width: 1728, height: 1117)
        let offstageFrame = CGRect(x: 160, y: 255, width: 700, height: 782)
        typealias Candidate = AgentDisplayWindowIdentity.Candidate
        let hidden = Candidate(id: 71, pid: 10, title: "Fixture", frame: offstageFrame, onScreen: false)
        let hiddenMatch = try AgentDisplayWindowIdentity.resolve(pid: 10, title: "Fixture", frame: offstageFrame,
            exactID: nil, candidates: [hidden])
        expect(hiddenMatch.id == 71, "Offscreen windows remain eligible for identity matching")
        let thumbnail = Candidate(id: 71, pid: 10, title: "Fixture", frame: CGRect(x: 16, y: 300, width: 80, height: 90), onScreen: true)
        let transformed = try AgentDisplayWindowIdentity.resolve(pid: 10, title: "Fixture", frame: offstageFrame,
            exactID: nil, candidates: [thumbnail])
        expect(transformed.id == 71 && transformed.source.contains("unique-title"), "Unique PID/title bridges Stage Manager transformed geometry")
        let unnamed = Candidate(id: 72, pid: 10, title: nil, frame: offstageFrame, onScreen: false)
        let unnamedMatch = try AgentDisplayWindowIdentity.resolve(pid: 10, title: "Fixture", frame: offstageFrame,
            exactID: nil, candidates: [unnamed])
        expect(unnamedMatch.id == 72, "Unique bounds match when CG hides window title")
        fails("AGENT_DISPLAY_WINDOW_ID_UNAVAILABLE") {
            _ = try AgentDisplayWindowIdentity.resolve(pid: 11, title: "Fixture", frame: offstageFrame, exactID: 71, candidates: [hidden])
        }
        fails("AGENT_DISPLAY_AMBIGUOUS_WINDOW") {
            _ = try AgentDisplayWindowIdentity.resolve(pid: 10, title: "Fixture", frame: offstageFrame, exactID: nil,
                candidates: [hidden, Candidate(id: 72, pid: 10, title: "Fixture", frame: offstageFrame, onScreen: true)])
        }
        fails("AGENT_DISPLAY_WINDOW_ID_UNAVAILABLE") {
            _ = try AgentDisplayWindowIdentity.resolve(pid: 10, title: "Other", frame: offstageFrame, exactID: nil, candidates: [hidden])
        }
        let exactMatch = try AgentDisplayWindowIdentity.resolve(pid: 10, title: "Other", frame: offstageFrame,
            exactID: 71, candidates: [hidden])
        expect(exactMatch.id == 71, "Exact AX identity wins over stale title")
        let agentSize = CGSize(width: 1728, height: 1117)
        let bottomRight = try AgentDisplayGeometry.placement(main: mainDisplay, others: [], size: agentSize)
        expect(bottomRight.origin == CGPoint(x: 1728, y: 1117), "Agent display touches the main display at one corner")
        let alternate = try AgentDisplayGeometry.placement(main: mainDisplay, others: [bottomRight], size: agentSize)
        expect(alternate.origin == CGPoint(x: -1728, y: 1117), "Occupied corner uses a free corner without translating existing displays")
        let edgeBlocked = try AgentDisplayGeometry.placement(main: mainDisplay,
            others: [CGRect(x: 1728, y: 0, width: 1728, height: 1117)], size: agentSize)
        expect(edgeBlocked.origin == CGPoint(x: -1728, y: 1117), "Do not expose a wide pointer crossing from another display")
        let offset = try AgentDisplayGeometry.placement(main: CGRect(x: -100, y: -200, width: 1000, height: 700), others: [], size: agentSize)
        expect(offset.origin == CGPoint(x: 900, y: 500), "Placement handles negative Quartz coordinates")
        fails("AGENT_DISPLAY_GEOMETRY") {
            _ = try AgentDisplayGeometry.placement(main: mainDisplay,
                others: [CGRect(x: -2000, y: -2000, width: 6000, height: 6000)], size: agentSize)
        }
        fails("AGENT_DISPLAY_GEOMETRY") {
            _ = try AgentDisplayGeometry.placement(main: mainDisplay, others: [], size: CGSize(width: 0, height: 20))
        }
        fails("AGENT_DISPLAY_GEOMETRY") {
            _ = try AgentDisplayGeometry.placement(main: CGRect(x: Double.infinity, y: 0, width: 10, height: 10), others: [], size: agentSize)
        }
        let originalFrame = CGRect(x: 120, y: 80, width: 700, height: 782)
        let movedFrame = try AgentDisplayGeometry.destination(original: originalFrame, display: bottomRight)
        expect(movedFrame.size == originalFrame.size && bottomRight.contains(movedFrame), "Move preserves a fitting window's size")
        let clamped = try AgentDisplayGeometry.destination(original: CGRect(x: 0, y: 0, width: 4000, height: 2000), display: bottomRight)
        expect(bottomRight.contains(clamped) && clamped.width == 1600, "Oversized target is fitted within display margins")
        var ledger = AgentDisplayLedger()
        expect(ledger.cleanupSteps.isEmpty, "Cleanup before creation is idempotent")
        try ledger.created(42)
        expect(ledger.cleanupSteps == [.releaseDisplay], "Created display alone needs release")
        fails("AGENT_DISPLAY_BUSY") { try ledger.created(43) }
        let savedFrame = AgentDisplayLedger.SavedFrame(windowID: 21, displayID: 1, frame: originalFrame)
        try ledger.remember(savedFrame)
        expect(ledger.pending == [savedFrame] && ledger.restorePending, "Frame committed before any AX mutation")
        fails("AGENT_DISPLAY_BUSY") {
            try ledger.remember(savedFrame)
        }
        expect(ledger.pending == [savedFrame], "Repeated/other-window move cannot overwrite original frame")
        expect(ledger.cleanupSteps == [.restore, .releaseDisplay], "Disconnect and failure restore before release")
        ledger.released() // Simulated failed restore: still release the display.
        expect(ledger.restorePending && ledger.pending == [savedFrame] && ledger.cleanupSteps == [.restore], "Failed restoration retains recovery state after release")
        fails("AGENT_DISPLAY_BUSY") { try ledger.created(43) }
        ledger.restored()
        ledger.released()
        expect(ledger.cleanupSteps.isEmpty, "Successful restoration plus repeated destroy is idempotent")
        try ledger.created(43)
        expect(ledger.pending.isEmpty, "Fresh display clears completed bookkeeping")
        try ledger.remember(savedFrame)
        ledger.restored()
        expect(ledger.cleanupSteps == [.releaseDisplay], "Explicit restore prevents duplicate window writes at shutdown")
        var desktop = AgentDesktopState()
        desktop.change(.starting)
        desktop.change(.running)
        expect(desktop.ready, "Desktop is ready only after startup")
        let generation = desktop.generation
        expect(desktop.lock(true) && !desktop.ready, "Lock suspends desktop without losing ownership")
        fails("SCREEN_LOCKED") { try desktop.requireRunning() }
        expect(desktop.ownsDesktop && desktop.generation > generation, "Lock invalidates observations, retaining cleanup")
        _ = desktop.lock(false)
        desktop.stopByPerson()
        desktop.change(.inactive)
        desktop.change(.running)
        fails("STOPPED_BY_PERSON") { try desktop.requireRunning() }
        expect(desktop.phase == .stopped, "A late start or cleanup cannot clear the person latch")
        var consent = AgentDesktopConsent()
        let firstConsent = try consent.begin(window: "pid:birth:window1", now: 100)!
        fails("AGENT_DISPLAY_BUSY") { _ = try consent.begin(window: "window2", now: 101) }
        expect(!consent.decide(token: UUID(), approve: true, now: 102), "Wrong consent token cannot approve")
        expect(!consent.decide(token: firstConsent.token, approve: false, now: 103), "Decline does not approve")
        let declinedAgain = try consent.begin(window: "pid:birth:window1", now: 110)
        expect(declinedAgain == nil, "Declined windows cannot be prompted again")
        let secondConsent = try consent.begin(window: "window2", now: 200)!
        expect(!consent.decide(token: secondConsent.token, approve: true, now: 260), "Deadline wins over late approval")
        expect(consent.reduced["window2"] == "expired", "Expiry remains reduced for this lifetime")
        let thirdConsent = try consent.begin(window: "window3", now: 300)!
        consent.cancel()
        expect(!consent.decide(token: thirdConsent.token, approve: true, now: 301), "EOF/cancel prevents latent approval")
        let fourthConsent = try consent.begin(window: "window4", now: 400)!
        expect(consent.decide(token: fourthConsent.token, approve: true, now: 401), "Timely exact approval succeeds once")
        expect(!consent.decide(token: fourthConsent.token, approve: true, now: 402), "Approval is consumed once")
        consent.returned("window4")
        let returnedAgain = try consent.begin(window: "window4", now: 410)
        expect(returnedAgain == nil, "Manual return cannot be automatically undone")
        var multi = AgentDisplayLedger()
        try multi.created(44)
        try multi.remember(savedFrame)
        let anotherFrame = AgentDisplayLedger.SavedFrame(windowID: 22, displayID: 2, frame: movedFrame)
        try multi.remember(anotherFrame)
        fails("AGENT_DISPLAY_BUSY") { try multi.remember(savedFrame) }
        expect(multi.pending == [savedFrame, anotherFrame], "Multiple originals survive without substitution")
        multi.restored(22)
        multi.released()
        expect(multi.pending == [savedFrame], "Partial cleanup retains the failed original after display release")
        multi.restored(21)
        expect(multi.cleanupSteps.isEmpty, "Per-window completion is idempotent")
        // A move refusal is local: rollback selects that exact ledger entry only.
        var rollback = AgentDisplayLedger(); try rollback.created(50)
        try rollback.remember(savedFrame); try rollback.remember(anotherFrame)
        expect(rollback.restorations(windowID: 22) == [anotherFrame], "Interrupted second move never restores the first window")
        rollback.restored(22)
        expect(rollback.pending == [savedFrame], "First window stays admitted with its original recovery frame")
        expect(rollback.restorations(windowID: 99).isEmpty, "An interruption before any write restores nothing")
        for interruption in ["AGENT_DISPLAY_PERSON_ACTIVE", "SCREEN_LOCKED"] {
            expect(!AgentDesktopAdmissionPolicy.tearsDownDesktop(interruption), "Input interruptions preserve desktop ownership")
        }
        expect(AgentDesktopAdmissionPolicy.tearsDownDesktop("AGENT_DISPLAY_LAYOUT_CHANGED"), "A real layout failure still cleans up")
        expect(AgentDisplayGeometry.size(screen: CGSize(width: 1728, height: 1117), topInset: 32) == CGSize(width: 1728, height: 1085), "Agent display matches a notched screen's full-screen area")
        expect(AgentDisplayGeometry.size(screen: CGSize(width: 1440, height: 900), topInset: 0) == CGSize(width: 1728, height: 1080), "Agent display keeps a notch-free screen's shape")
        expect(!AgentDesktopAdmissionPolicy.usableWindow(role: "AXWindow", minimized: true, fullScreen: false, onDisplay: false), "Minimized windows reduce without moving")
        expect(!AgentDesktopAdmissionPolicy.usableWindow(role: "AXWindow", minimized: false, fullScreen: true, onDisplay: true), "Full-screen windows reduce without moving")
        expect(!AgentDesktopAdmissionPolicy.usableWindow(role: "AXSheet", minimized: false, fullScreen: false, onDisplay: false), "Focused off-display sheets reduce without moving")
        expect(AgentDesktopAdmissionPolicy.usableWindow(role: "AXSheet", minimized: false, fullScreen: false, onDisplay: true), "Sheets already on display can use process admission without geometry writes")
        let missingReadBounds = try AgentDesktopAdmissionPolicy.readBounds(nil, reduced: true)
        expect(missingReadBounds == .zero, "Unavailable bounds still permit reduced text traversal")
        fails("WINDOW_BOUNDS_UNAVAILABLE") { _ = try AgentDesktopAdmissionPolicy.readBounds(nil, reduced: false) }
        for reason in ["AGENT_DISPLAY_UNSUPPORTED_WINDOW", "AGENT_DISPLAY_AX_BOUNDS_UNAVAILABLE", "AGENT_DISPLAY_WINDOW_ID_UNAVAILABLE", "AGENT_DISPLAY_AMBIGUOUS_WINDOW", "AGENT_DISPLAY_ORIGINAL_DISPLAY_MISSING"] {
            expect(AgentDesktopAdmissionPolicy.reducedReason(OpenCUError(reason, "fixture")) == reason, "Move-only failure becomes a reduced read with its reason")
        }
        expect(AgentDesktopAdmissionPolicy.reducedReason(OpenCUError("ACCESSIBILITY_PERMISSION_REQUIRED", "fixture")) == nil, "Permission failures are not masked as move refusals")
        for explicit in [false, true] {
            expect(AgentDesktopAdmissionPolicy.choice(admitted: false, onDisplay: true, sameProcess: true, sticky: false, explicit: explicit) == .inheritProcess, "Same-process windows already on display need no movement consent, including final reads")
            expect(AgentDesktopAdmissionPolicy.choice(admitted: false, onDisplay: true, sameProcess: false, sticky: false, explicit: explicit) == (explicit ? .askUse : .reduced), "Other-process window uses a card only on an explicit read")
            expect(AgentDesktopAdmissionPolicy.choice(admitted: false, onDisplay: false, sameProcess: true, sticky: false, explicit: explicit) == (explicit ? .askMove : .reduced), "Same process never authorizes a new move implicitly")
            expect(AgentDesktopAdmissionPolicy.choice(admitted: false, onDisplay: true, sameProcess: true, sticky: true, explicit: explicit) == .reduced, "A declined/returned window cannot inherit admission")
        }
        for reason in ["lock", "MCP cancel", "tool stop"] {
            var cancelled = AgentDesktopConsent()
            let request = try cancelled.begin(window: reason, now: 0)!
            cancelled.cancel()
            expect(!cancelled.decide(token: request.token, approve: true, now: 1), "Cancelled approval cannot commit later")
            let next = try cancelled.begin(window: reason, now: 2)
            expect(next != nil && cancelled.reduced.isEmpty, "Lock/cancel/stop are not declines; another explicit read may ask")
        }
        fails("OBSERVATION_REQUIRED") { try AgentDesktopAdmissionPolicy.requireSnapshot(admitted: true, fresh: false) }
        fails("AGENT_DESKTOP_CONSENT_REQUIRED") { try AgentDesktopAdmissionPolicy.requireSnapshot(admitted: false, fresh: true) }
        try AgentDesktopAdmissionPolicy.requireSnapshot(admitted: true, fresh: true)
        expect(!AgentDesktopState.stopError.message.contains("Text-only"), "Desktop stop never promises text reads")
        var observedDesktop = AgentDesktopState(); observedDesktop.change(.running)
        let beforeRead = observedDesktop.generation
        try observedDesktop.requireGeneration(beforeRead)
        observedDesktop.invalidate()
        fails("OBSERVATION_REQUIRED") { try observedDesktop.requireGeneration(beforeRead) }
        var queued = AgentDesktopRequestQueue()
        try queued.enqueue("1"); queued.cancel("1")
        do { try queued.begin("1"); expect(false, "Queued cancellation must precede dispatch") } catch is CancellationError { expect(true, "Early cancellation is retained") }
        queued.cancel("1"); try queued.enqueue("2"); try queued.begin("2")
        for index in 0..<128 { try queued.enqueue("limit-\(index)") }
        fails("INVALID_REQUEST") { try queued.enqueue("overflow") }
        var monitorCursor = 0
        let manyWindows = Array(UInt32(1)...UInt32(100))
        var visited = Set<UInt32>()
        for _ in 0..<100 {
            let batch = AgentDesktopMonitoring.batch(ids: manyWindows, cursor: &monitorCursor, observed: 90)
            expect(batch.count <= 2 && Set(batch).count == batch.count, "Every monitor tick has at most two bounded AX targets")
            visited.formUnion(batch)
        }
        expect(visited.count == 100, "Bounded monitor rotates through every admitted window")
        // The same remote focus works in the foreground and must be refused in
        // the background. A host-PID panel proxy must also be refused; unknown
        // focus in ordinary apps keeps the existing PID-targeted path.
        for frontmost in [false, true] {
            for isFilePanel in [false, true] {
                for owner: pid_t? in [nil, 10, 20] {
                    let code = !frontmost && (isFilePanel || owner == 20) ? "BACKGROUND_REMOTE_FOCUS" : nil
                    let checkDelivery = {
                        try InputController.requireKeyboardDelivery(isFrontmost: frontmost, isFilePanel: isFilePanel,
                                                                    targetPID: 10, focusedPID: owner)
                    }
                    if let code { fails(code, checkDelivery) }
                    else { try checkDelivery(); expect(true, "Keyboard delivery policy") }
                }
            }
        }
        // Observed identifiers, not localized titles or process names. A sheet
        // without a file-panel identifier is still an ordinary local input target.
        for role in [kAXWindowRole, kAXSheetRole] {
            for identifier in ["save-panel", "open-panel"] {
                expect(InputController.isFilePanel(role: role, identifier: identifier), "File-panel proxy recognized without its PID")
            }
            expect(!InputController.isFilePanel(role: role, identifier: "acceptanceWindow"), "Ordinary window/sheet still allows background typing")
            expect(!InputController.isFilePanel(role: role, identifier: nil), "Unknown identifier is not proof of a file panel")
        }
        expect(!InputController.isFilePanel(role: kAXTextFieldRole, identifier: "save-panel"), "Only a window/sheet root identifies a panel")
        expect(!InputController.isFilePanel(role: nil, identifier: "open-panel"), "Missing role is not proof of a file panel")
        // Roles seen in the paired benchmark: Safari selected its save sheet,
        // while Finder selected a desktop scroll area rather than a window.
        expect(axIsWindowRole(kAXSheetRole), "Selected save sheet remains a window root")
        expect(axIsWindowRole(kAXWindowRole), "Document window remains a window root")
        expect(!axIsWindowRole(kAXScrollAreaRole), "Finder desktop is windowless")
        expect(!axIsWindowRole(nil), "Missing role cannot grant window input")
        // Model the live AX attachment graph. Remote service nodes deliberately
        // share neither PID nor window identity with their presenting app.
        struct Node: Equatable { let pid: Int; let id: String }
        let window = Node(pid: 10, id: "document")
        let sibling = Node(pid: 10, id: "other-document")
        let menu = Node(pid: 10, id: "menu")
        let item = Node(pid: 10, id: "new")
        let sheet = Node(pid: 20, id: "remote-sheet")
        let field = Node(pid: 20, id: "filename")
        let unrelated = Node(pid: 30, id: "unrelated-window")
        let otherPanel = Node(pid: 20, id: "same-service-other-panel")
        var edges = ["document": [sheet], "remote-sheet": [field], "menu": [item],
                     "other-document": [otherPanel], "same-service-other-panel": [field]]
        func attached(_ path: [Node], roots: [Node] = []) -> Bool {
            attachedPath(path, to: roots.isEmpty ? [window, menu] : roots, equal: ==,
                         children: { edges[$0.id] ?? [] })
        }
        expect(attached([window, sheet, field]), "Attached remote field accepted")
        expect(attached([menu, item], roots: [menu]), "Windowless menu accepted")
        expect(!attached([sibling, otherPanel, field]), "Same-PID sibling window refused")
        expect(!attached([unrelated, field]), "Unrelated app refused")
        expect(!attached([window, otherPanel, field]), "Same remote service is not proof of attachment")
        expect(!attached([window, field]), "Missing attachment edge refused")
        expect(!attached([]), "Empty path refused")
        edges["document"] = []
        expect(!attached([window, sheet, field]), "Dismissed sheet refused even with live remote descendants")
        edges["document"] = [sheet]
        edges["remote-sheet"] = []
        expect(!attached([window, sheet, field]), "Detached control refused")
        expect(!attached([window, sheet], roots: [menu]), "Old window path refused in windowless state")
        let emoji = try InputController.textRange(in: "a🧑🏽‍💻b", text: "🧑🏽‍💻", prefix: nil, suffix: nil)
        expect(emoji.location == 1 && emoji.length == 7, "UTF-16 emoji range")
        let context = try InputController.textRange(in: "one target; two target", text: "target", prefix: "two ", suffix: nil)
        expect(context.location == 16 && context.length == 6, "Adjacent prefix")
        let suffix = try InputController.textRange(in: "one target; two target", text: "target", prefix: nil, suffix: ";")
        expect(suffix.location == 4 && suffix.length == 6, "Adjacent suffix")
        let cursor = try InputController.textRange(in: "ab", text: "", prefix: "a", suffix: "b")
        expect(cursor.location == 1 && cursor.length == 0, "Context-only cursor")
        let composed = try InputController.textRange(in: "é e\u{301}", text: "e\u{301}", prefix: nil, suffix: nil)
        expect(composed.location == 2 && composed.length == 2, "Literal Unicode match")
        fails("AMBIGUOUS_TEXT") { _ = try InputController.textRange(in: "banana", text: "ana", prefix: nil, suffix: nil) }
        fails("AMBIGUOUS_TEXT") { _ = try InputController.textRange(in: "😀", text: "", prefix: nil, suffix: nil) }
        fails("TEXT_NOT_FOUND") { _ = try InputController.textRange(in: "target", text: "target", prefix: "no", suffix: nil) }
        let shifted = try OpenCUKeyChord.parse("Shift_L+Return")
        expect(shifted.code == 36 && shifted.modifiers.contains { $0.flag == .maskShift }, "Shift+Return")
        let shortcut = try OpenCUKeyChord.parse("Control_L+Alt_R+Delete")
        expect(shortcut.code == 117 && shortcut.modifiers.count == 2, "Control+Alt+Delete")
        let tab = try OpenCUKeyChord.parse("ISO_Left_Tab")
        expect(tab.code == 48 && tab.modifiers.contains { $0.flag == .maskShift }, "Reverse Tab")
        let mods = try OpenCUKeyChord.parse("Control_L+Shift_R")
        expect(mods.code == nil && mods.unicode == nil && mods.modifiers.count == 2, "Modifier-only chord")
        let unicode = try OpenCUKeyChord.parse("U1F600")
        expect(unicode.unicode == "😀", "Unicode keysym")
        let plus = try OpenCUKeyChord.parse("super++")
        expect(plus.code != nil && plus.modifiers.contains { $0.flag == .maskCommand }, "Literal plus chord")
        fails("INVALID_ARGUMENT") { _ = try OpenCUKeyChord.parse("a+b") }
        fails("UNSUPPORTED_KEY") { _ = try OpenCUKeyChord.parse("invented_key") }
        fails("UNSUPPORTED_KEY_CHORD") { _ = try OpenCUKeyChord.parse("super+U1F600") }
        let textValue = try InputController.typedValue("001", current: "old" as CFString, role: kAXTextFieldRole)
        expect((textValue as? String) == "001", "AX strings stay strings")
        let number = try InputController.typedValue("2.5", current: NSNumber(value: 0), role: kAXSliderRole)
        expect((number as? NSNumber)?.doubleValue == 2.5, "AX numeric value")
        let boolean = try InputController.typedValue("false", current: kCFBooleanTrue, role: kAXCheckBoxRole)
        expect(CFGetTypeID(boolean) == CFBooleanGetTypeID() && !(boolean as! NSNumber).boolValue, "AX boolean value")
        let checkbox = try InputController.typedValue("true", current: NSNumber(value: 0), role: kAXCheckBoxRole)
        expect((checkbox as? NSNumber)?.intValue == 1, "AX numeric checkbox")
        for invalid in ["nan", "inf", "-inf", "1e1000"] {
            fails("INVALID_ARGUMENT") { _ = try InputController.typedValue(invalid, current: NSNumber(value: 0), role: kAXSliderRole) }
        }
        fails("INVALID_ARGUMENT") { _ = try InputController.typedValue("true", current: NSNumber(value: 0), role: kAXSliderRole) }
        fails("INVALID_ARGUMENT") { _ = try InputController.typedValue("2", current: kCFBooleanTrue, role: kAXCheckBoxRole) }
        fails("UNSUPPORTED_VALUE_TYPE") { _ = try InputController.typedValue("x", current: [] as CFArray, role: nil) }
        let copy = "Name:拷贝\nTarget:0x0\nSelector:(null)"
        expect(axActionLabel(copy) == "拷贝", "Custom action shows its label")
        expect(axActionLabel("AXPress") == "AXPress", "Standard action name unchanged")
        expect(axResolveAction("拷贝", in: ["AXPress", copy]) == copy, "Label resolves to the custom action")
        expect(axResolveAction(copy, in: ["AXPress", copy]) == copy, "Exact custom action name still accepted")
        expect(axResolveAction("拷贝", in: [copy, "Name:拷贝\nTarget:0x1\nSelector:copy:"]) == nil, "Ambiguous label refused")
        expect(axResolveAction("粘贴", in: [copy]) == nil, "Unknown label refused")
        let markdown = try InputController.markdownRepresentation("# Heading\n\n**Bold** and *italic* and `code`\n\n- one\n- two\n\n[x](https://example.com)")
        expect(markdown.plain == "Heading\nBold and italic and code\n•\tone\n•\ttwo\nx", "Markdown plain text preserves blocks")
        let decoded = try NSAttributedString(data: markdown.rtf, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil)
        expect(decoded.string == markdown.plain, "Markdown RTF text survives decode")
        let boldRange = (decoded.string as NSString).range(of: "Bold")
        let italicRange = (decoded.string as NSString).range(of: "italic")
        expect(boldRange.location != NSNotFound && italicRange.location != NSNotFound, "RTF emphasis text present")
        let boldFont = decoded.attribute(.font, at: boldRange.location, effectiveRange: nil) as! NSFont
        let italicFont = decoded.attribute(.font, at: italicRange.location, effectiveRange: nil) as! NSFont
        expect(NSFontManager.shared.traits(of: boldFont).contains(.boldFontMask), "Markdown RTF bold survives decode")
        expect(NSFontManager.shared.traits(of: italicFont).contains(.italicFontMask), "Markdown RTF italic survives decode")
        expect(String(data: markdown.html, encoding: .utf8)?.contains("https://example.com") == true, "Markdown HTML link")
        print("\(checked) presence, stop policy, agent-display geometry/cleanup, attachment identity, input parsing, UTF-16, AX type, and rich Markdown checks passed; no input, GUI actions or clipboard writes")
    }

    @MainActor static func checkMultiAgentCollaboration() async throws {
        var checked = 0
        func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
            guard condition() else { throw OpenCUError("TEST_FAILED", message) }
            checked += 1
        }

        // 1. Palette & config path expansion / sanitization checks.
        let expectedPalette: [(Int, String, String)] = [
            (0, "#FF6B9D", "Agent 1"),
            (1, "#38BDF8", "Agent 2"),
            (2, "#F59E0B", "Agent 3"),
            (3, "#34D399", "Agent 4"),
            (4, "#A78BFA", "Agent 5"),
            (5, "#FB7185", "Agent 6"),
        ]
        for (slot, hex, name) in expectedPalette {
            let entry = AgentSlotPalette.entry(for: slot)
            try expect(entry.slot == slot && entry.hex == hex && entry.defaultName == name, "Palette slot \(slot)")
        }
        let envDefaults = ["HOME": "/tmp/fake-home"]
        try expect(AgentConfig.hubDirectory(environment: envDefaults) == "/tmp/fake-home/.opencu/hub", "Default hub dir")
        try expect(AgentConfig.eventSocketPath(environment: envDefaults) == "/tmp/fake-home/.ibuki-pet/opencu.sock", "Default event sock")
        try expect(AgentConfig.hubDirectory(environment: ["HOME": "/tmp/fake-home", "OPENCU_HUB_DIR": "~/custom/hub"]) == "/tmp/fake-home/custom/hub", "Tilde hub dir")
        try expect(AgentConfig.eventSocketPath(environment: ["HOME": "/tmp/fake-home", "OPENCU_EVENT_SOCK": "~/custom/ev.sock"]) == "/tmp/fake-home/custom/ev.sock", "Tilde event sock")

        // Short /tmp root so AF_UNIX sun_path (< 104 bytes) always fits comfortably.
        let shortRoot = URL(fileURLWithPath: "/tmp/ocu-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: shortRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: shortRoot) }

        let hubDir = shortRoot.appendingPathComponent("hub").path
        var livePIDs: Set<pid_t> = [2001, 2002, 2003, 2004, 2005, 2006, 2007]

        // Seed a stale dead PID record claiming slot 0; registration must clean it and reclaim slot 0.
        let agentsDir = (hubDir as NSString).appendingPathComponent("agents")
        try FileManager.default.createDirectory(atPath: agentsDir, withIntermediateDirectories: true)
        let staleRecord = AgentRecord(pid: 999991, agentId: "stale-0", agentName: "Agent 1", agentColor: "#FF6B9D",
                                      slot: 0, explicitName: false, windowID: 88, targetPID: 4321, updatedAtMs: 1)
        try JSONEncoder().encode(staleRecord).write(to: URL(fileURLWithPath: (agentsDir as NSString).appendingPathComponent("999991.json")))

        var hubs: [AgentHub] = []
        for index in 0..<6 {
            let pid = pid_t(2001 + index)
            let hub = AgentHub(hubDirectory: hubDir, selfPID: pid, environment: ["HOME": shortRoot.path], isAlive: { livePIDs.contains($0) })
            let id = hub.register()
            try expect(id.slot == index, "Deterministic slot \(index) assigned to PID \(pid)")
            try expect(id.agentColor == expectedPalette[index].1, "Slot \(index) color matches palette")
            try expect(id.agentName == expectedPalette[index].2, "Slot \(index) name matches palette")
            try expect(id.agentId == "opencu-\(pid)", "Default agentId uses worker PID")
            if index == 0 {
                try expect(!FileManager.default.fileExists(atPath: (agentsDir as NSString).appendingPathComponent("999991.json")),
                           "Stale dead PID record cleaned on registration")
                try expect(!hub.shouldShowCursorTag(forceRefresh: true), "Solo unnamed agent hides redundant cursor tag")
            } else if index == 1 {
                try expect(hubs[0].shouldShowCursorTag(forceRefresh: true), "First agent shows cursor tag once sibling joins")
                try expect(hub.shouldShowCursorTag(forceRefresh: true), "Second agent shows cursor tag when multiple agents active")
            }
            hubs.append(hub)
        }

        // Simulate PID 2003 (slot 2) crashing without unregistering; PID 2007 must clean it and reclaim slot 2!
        livePIDs.remove(2003)
        let customEnv = [
            "HOME": shortRoot.path,
            "OPENCU_AGENT_ID": "reviewer-bot",
            "OPENCU_AGENT_NAME": "Reviewer\nBot",
            "OPENCU_AGENT_COLOR": "#38bdf8",
        ]
        let replacement = AgentHub(hubDirectory: hubDir, selfPID: 2007, environment: customEnv, isAlive: { livePIDs.contains($0) })
        let repID = replacement.register()
        try expect(repID.slot == 2, "Crashed agent's slot 2 deterministically reclaimed")
        try expect(repID.agentId == "reviewer-bot", "Custom OPENCU_AGENT_ID preserved")
        try expect(repID.agentName == "Reviewer Bot" && repID.explicitName, "Custom OPENCU_AGENT_NAME sanitized and marked explicit")
        try expect(repID.agentColor == "#38BDF8", "Custom OPENCU_AGENT_COLOR normalized to uppercase #RRGGBB")

        // 2. Shared-window peer placement & non-overlapping BadgeLayout checks.
        hubs[0].updateTarget(windowID: 88, targetPID: 4321)
        hubs[1].updateTarget(windowID: 88, targetPID: 4321)
        replacement.updateTarget(windowID: 88, targetPID: 4321)
        hubs[3].updateTarget(windowID: 99, targetPID: 5555)

        let p0 = hubs[0].peerPlacement(for: 88, forceRefresh: true)
        let p1 = hubs[1].peerPlacement(for: 88, forceRefresh: true)
        let p2 = replacement.peerPlacement(for: 88, forceRefresh: true)
        let pOther = hubs[3].peerPlacement(for: 99, forceRefresh: true)
        try expect(p0.peerCount == 3 && p0.peerIndex == 0, "Slot 0 is peerIndex 0 on shared window 88")
        try expect(p1.peerCount == 3 && p1.peerIndex == 1, "Slot 1 is peerIndex 1 on shared window 88")
        try expect(p2.peerCount == 3 && p2.peerIndex == 2, "Slot 2 is peerIndex 2 on shared window 88")
        try expect(pOther.peerCount == 1 && pOther.peerIndex == 0, "Agent on window 99 stays solo on its own window")

        for width in [CGFloat(960), 720, 420, 240] {
            let win = CGRect(x: 100, y: 80, width: width, height: 600)
            for peerCount in 2...6 {
                let widths: [CGFloat] = [24, 150, 60, 190, 40, 110]
                var frames: [CGRect] = []
                for rank in 0..<peerCount {
                    let layout = BadgeLayout(window: win, titleBarHeight: 28, textWidth: widths[rank],
                                             peerIndex: rank, peerCount: peerCount)
                    try expect(layout.frame.width >= 29 && layout.frame.height == 22, "Badge dimensions valid")
                    for previous in frames {
                        try expect(!previous.intersects(layout.frame),
                                   "Badges never overlap (window width \(width), peers \(peerCount), rank \(rank))")
                    }
                    frames.append(layout.frame)
                }
            }
        }

        // Waiting-turn pointer & badge persistence checks.
        var pState = PresenceState()
        pState.call(target: "4321", now: 10)
        pState.pointer(now: 10)
        try expect(!pState.cursorVisible(at: 14), "Normal cursor hides after 3 seconds")
        pState.pointer(now: 20)
        pState.setWaitingTurn(true, now: 20.5)
        try expect(pState.cursorVisible(at: 29.0), "Waiting-turn cursor remains visible while waiting for peer turn")
        pState.setWaitingTurn(false, now: 29.0)
        try expect(pState.cursorVisible(at: 31.0) && !pState.cursorVisible(at: 32.5), "Cursor resumes normal 3s fade after turn acquired")

        var bLife = BadgeLifetime()
        bLife.call(target: "4321:88", now: 10)
        bLife.setWaitingTurn(true, now: 10.5)
        try expect(bLife.opacity(at: 19.0) == 1, "Badge stays visible during waitingTurn")
        bLife.setWaitingTurn(false, now: 19.0)
        try expect(bLife.opacity(at: 22.5) == 0, "Badge fades normally after waitingTurn clears")

        for hub in hubs { hub.unregister() }
        replacement.unregister()

        // 3. Real AF_UNIX SOCK_DGRAM NDJSON companion broadcast & strict privacy checks.
        let sockPath = shortRoot.appendingPathComponent("opencu.sock").path
        let serverFD = Darwin.socket(AF_UNIX, SOCK_DGRAM, 0)
        try expect(serverFD >= 0, "Create test SOCK_DGRAM listener")
        defer { _ = Darwin.close(serverFD); _ = Darwin.unlink(sockPath) }
        _ = Darwin.fcntl(serverFD, F_SETFL, Darwin.fcntl(serverFD, F_GETFL) | O_NONBLOCK)
        var bindAddr = sockaddr_un()
        bindAddr.sun_family = sa_family_t(AF_UNIX)
        let sockBytes = Array(sockPath.utf8)
        withUnsafeMutableBytes(of: &bindAddr.sun_path) { raw in
            raw.initializeMemory(as: UInt8.self, repeating: 0)
            for (idx, b) in sockBytes.enumerated() { raw[idx] = b }
        }
        let bindLen = socklen_t(MemoryLayout.offset(of: \sockaddr_un.sun_path)! + sockBytes.count + 1)
        bindAddr.sun_len = UInt8(bindLen)
        let bound = withUnsafePointer(to: &bindAddr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(serverFD, $0, bindLen) }
        }
        try expect(bound == 0, "Bind test SOCK_DGRAM socket at \(sockPath)")

        let broadcaster = CompanionBroadcaster(socketPath: sockPath)
        let testIdentity = AgentIdentity(
            pid: 4242,
            agentId: "opencu-4242",
            agentName: "Coder",
            agentColor: "#FF6B9D",
            rgb: AgentSlotPalette.entry(for: 0).rgb,
            slot: 0,
            explicitName: true
        )
        broadcaster.activate(identity: testIdentity)
        let testApp = CompanionApp(pid: 4321, bundleId: "com.apple.Notes", name: "Notes")
        let testWin = CompanionWindow(id: 88, bounds: CGRect(x: 120, y: 80, width: 900, height: 640))!
        _ = broadcaster.send(CompanionEventPayload(identity: testIdentity, event: .observed, app: testApp, window: testWin))
        broadcaster.waitingTurn(identity: testIdentity, app: testApp, window: testWin, kind: .click)
        let dragFrom = CompanionPoint(x: 300, y: 320)!
        let dragTo = CompanionPoint(x: 620, y: 320)!
        broadcaster.actionStart(
            identity: testIdentity,
            app: testApp,
            window: testWin,
            action: CompanionAction(kind: .drag, point: dragFrom, from: dragFrom, to: dragTo, progress: 0.0)
        )
        for step in [1, 10, 20] {
            let p = Double(step) / 20.0
            let cur = CompanionPoint(x: 300 + 320 * p, y: 320)!
            _ = broadcaster.send(CompanionEventPayload(
                identity: testIdentity,
                event: .pointerMove,
                app: testApp,
                window: testWin,
                action: CompanionAction(kind: .drag, point: cur, from: dragFrom, to: dragTo, progress: p)
            ))
        }
        broadcaster.actionDone(
            identity: testIdentity,
            app: testApp,
            window: testWin,
            action: CompanionAction(kind: .drag, point: dragTo, from: dragFrom, to: dragTo, progress: 1.0)
        )
        broadcaster.actionStart(identity: testIdentity, app: testApp, window: testWin, action: CompanionAction(kind: .paste))
        broadcaster.actionDone(identity: testIdentity, app: testApp, window: testWin, action: CompanionAction(kind: .paste))
        broadcaster.stopped(identity: testIdentity)
        broadcaster.disconnect(identity: testIdentity)

        var receivedLines: [String] = []
        var recvBuf = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = Darwin.recv(serverFD, &recvBuf, recvBuf.count, 0)
            if n <= 0 { break }
            try expect(n <= CompanionBroadcaster.maxDatagramBytes, "Datagram <= 2048 bytes")
            try expect(recvBuf[n - 1] == 0x0A, "Datagram is newline-delimited NDJSON")
            receivedLines.append(String(decoding: recvBuf.prefix(n), as: UTF8.self))
        }
        try expect(receivedLines.count == 12, "All 12 lifecycle datagrams received losslessly")

        let allowedTopKeys: Set<String> = ["v", "ts", "coordSpace", "agentId", "agentName", "agentColor", "slot", "event", "app", "window", "action"]
        let forbiddenKeys: Set<String> = ["text", "value", "key", "title", "url", "label", "screenshot", "clipboard", "password", "path"]
        var seenEvents: [String] = []
        var dragProgresses: [Double] = []
        for rawLine in receivedLines {
            let trimmed = rawLine.trimmingCharacters(in: .newlines)
            let obj = try JSONSerialization.jsonObject(with: Data(trimmed.utf8)) as? [String: Any]
            try expect(obj != nil, "Valid JSON object datagram")
            let dict = obj!
            try expect(Set(dict.keys).isSubset(of: allowedTopKeys), "No unknown top-level keys for serde(deny_unknown_fields)")
            try expect(Set(dict.keys).isDisjoint(with: forbiddenKeys), "Zero forbidden secret keys at top level")
            try expect(dict["v"] as? Int == 1, "Schema v == 1")
            try expect(dict["coordSpace"] as? String == "cg_points_top_left", "coordSpace == cg_points_top_left")
            try expect(dict["agentId"] as? String == "opencu-4242" && dict["agentName"] as? String == "Coder", "Agent identity fields")
            try expect(dict["agentColor"] as? String == "#FF6B9D" && dict["slot"] as? Int == 0, "Agent color and slot")
            seenEvents.append(dict["event"] as? String ?? "")
            if let appDict = dict["app"] as? [String: Any] {
                try expect(Set(appDict.keys).isSubset(of: ["pid", "bundleId", "name"]), "Strict app keys")
                try expect(Set(appDict.keys).isDisjoint(with: forbiddenKeys), "No secret keys in app")
            }
            if let winDict = dict["window"] as? [String: Any] {
                try expect(Set(winDict.keys) == ["id", "x", "y", "width", "height"], "Strict window keys")
            }
            if let actDict = dict["action"] as? [String: Any] {
                try expect(Set(actDict.keys).isSubset(of: ["kind", "point", "from", "to", "progress"]), "Strict action keys")
                try expect(Set(actDict.keys).isDisjoint(with: forbiddenKeys), "No text/value/key in action")
                if dict["event"] as? String == "pointer_move", let prog = actDict["progress"] as? Double {
                    dragProgresses.append(prog)
                }
            }
        }
        try expect(seenEvents.first == "connected" && seenEvents.last == "disconnected", "Connected first and disconnected last")
        try expect(seenEvents.contains("observed") && seenEvents.contains("waiting_turn") && seenEvents.contains("stopped"), "All event kinds emitted")
        try expect(dragProgresses == [0.05, 0.5, 1.0], "Drag pointer_move emits exact progress steps")

        // Missing socket (ibuki not running) must never block or throw.
        let missingBroadcaster = CompanionBroadcaster(socketPath: shortRoot.appendingPathComponent("nonexistent/opencu.sock").path)
        let beforeMissing = AdvisoryFileLock.monotonicNow
        missingBroadcaster.activate(identity: testIdentity)
        try expect(AdvisoryFileLock.monotonicNow - beforeMissing < 0.05, "Missing socket returns immediately without blocking")

        // 4. AdvisoryFileLock coordination: clipboard lock serialization, cross-app parallelism & same-app queuing.
        let locksDir = (hubDir as NSString).appendingPathComponent("locks")
        let clipLock = (locksDir as NSString).appendingPathComponent("clipboard.lock")
        let pidLockA = (locksDir as NSString).appendingPathComponent("pid-4321.lock")
        let pidLockB = (locksDir as NSString).appendingPathComponent("pid-8765.lock")

        var eventsOrder: [String] = []
        var clipContended = false
        let clipLease1 = try await AdvisoryFileLock.acquire(
            path: clipLock, timeout: 5.0, pollInterval: 0.015,
            errorCode: "CLIPBOARD_BUSY", errorMessage: "busy"
        )
        try expect(AdvisoryFileLock.isContended(path: clipLock), "Held flock is detected as contended")
        eventsOrder.append("clip1-acquired")
        let waiterTask = Task { @MainActor in
            let lease2 = try await AdvisoryFileLock.acquire(
                path: clipLock, timeout: 5.0, pollInterval: 0.015,
                errorCode: "CLIPBOARD_BUSY", errorMessage: "busy",
                onContended: { clipContended = true }
            )
            eventsOrder.append("clip2-acquired")
            lease2.release()
        }
        try await Task.sleep(nanoseconds: 60_000_000)
        try expect(clipContended && eventsOrder == ["clip1-acquired"], "Second paste waits cleanly while first holds clipboard.lock")
        eventsOrder.append("clip1-releasing")
        clipLease1.release()
        try await waiterTask.value
        try expect(eventsOrder == ["clip1-acquired", "clip1-releasing", "clip2-acquired"], "Clipboard critical sections strictly serialized")
        try expect(!AdvisoryFileLock.isContended(path: clipLock), "Released flock is no longer contended")

        // Cross-app (pid-8765) runs immediately in parallel while same-app (pid-4321) waits its turn!
        let appALease1 = try await AdvisoryFileLock.acquire(
            path: pidLockA, timeout: 10.0, pollInterval: 0.015,
            errorCode: "TARGET_BUSY", errorMessage: "busy"
        )
        var sameAppWaitingFired = false
        var contendedOnMainThread = false
        var checkAllowedOnMainThread = false
        let sameAppTask = Task { @MainActor in
            let lease = try await AdvisoryFileLock.acquire(
                path: pidLockA, timeout: 10.0, pollInterval: 0.015,
                errorCode: "TARGET_BUSY", errorMessage: "busy",
                checkAllowed: { checkAllowedOnMainThread = Thread.isMainThread },
                onContended: {
                    sameAppWaitingFired = true
                    contendedOnMainThread = Thread.isMainThread
                }
            )
            defer { lease.release() }
            return "same-app-done"
        }
        let crossStart = AdvisoryFileLock.monotonicNow
        let appBLease = try await AdvisoryFileLock.acquire(
            path: pidLockB, timeout: 10.0, pollInterval: 0.015,
            errorCode: "TARGET_BUSY", errorMessage: "busy"
        )
        let crossElapsed = AdvisoryFileLock.monotonicNow - crossStart
        appBLease.release()
        try expect(crossElapsed < 0.03, "Different target PID lock acquires immediately in parallel")
        try await Task.sleep(nanoseconds: 50_000_000)
        try expect(sameAppWaitingFired, "Contended same-PID turn emits waiting_turn hook")
        try expect(contendedOnMainThread, "onContended runs strictly on MainActor / main thread")
        try expect(checkAllowedOnMainThread, "checkAllowed runs strictly on MainActor / main thread")
        appALease1.release()
        let sameResult = try await sameAppTask.value
        try expect(sameResult == "same-app-done", "Contended same-PID turn completes once holder releases")

        try expect(WorkerJob.decodeWaitStatus(0) == (0, nil), "Clean exit(0) decodes to 0")
        try expect(WorkerJob.decodeWaitStatus(42 << 8) == (42, nil), "exit(42) decodes to 42")
        try expect(WorkerJob.decodeWaitStatus(SIGTRAP) == (128 + SIGTRAP, SIGTRAP), "SIGTRAP crash decodes to 133 with signal 5")
        try expect(WorkerJob.decodeWaitStatus(SIGSEGV) == (128 + SIGSEGV, SIGSEGV), "SIGSEGV crash decodes to 139 with signal 11")

        // Timeout refusal check.
        let heldForever = try await AdvisoryFileLock.acquire(
            path: pidLockA, timeout: 1.0, pollInterval: 0.01,
            errorCode: "TARGET_BUSY", errorMessage: "busy"
        )
        defer { heldForever.release() }
        do {
            _ = try await AdvisoryFileLock.acquire(
                path: pidLockA, timeout: 0.06, pollInterval: 0.015,
                errorCode: "TARGET_BUSY", errorMessage: "Target still busy"
            )
            throw OpenCUError("TEST_FAILED", "Expected TARGET_BUSY timeout")
        } catch let error as OpenCUError {
            try expect(error.code == "TARGET_BUSY", "Lock timeout surfaces exact OpenCUError code")
        }

        // 5. Figma-multiplayer presence: 12s persistent hold, 280ms cubic-out glide, 5-dot comet trail,
        //    1.15s wireframe selection box, staggered per-slot anchors, and OPENCU_CAPTURE_OVERLAY=1.
        try expect(!AgentConfig.captureOverlayEnabled(environment: [:]), "Capture overlay defaults to false (.none)")
        try expect(AgentConfig.captureOverlayEnabled(environment: ["OPENCU_CAPTURE_OVERLAY": "1"]), "Capture overlay honors 1")
        try expect(AgentConfig.captureOverlayEnabled(environment: ["OPENCU_CAPTURE_OVERLAY": "true"]), "Capture overlay honors true")
        try expect(!AgentConfig.captureOverlayEnabled(environment: ["OPENCU_CAPTURE_OVERLAY": "0"]), "Capture overlay ignores 0")

        var persistent = PresenceState(cursorHoldDuration: 12)
        persistent.call(target: "4321", now: 10)
        persistent.pointer(now: 10)
        persistent.finished(now: 10)
        try expect(persistent.cursorVisible(at: 21.99), "Persistent cursor remains visible across 12-second hold")
        try expect(!persistent.cursorVisible(at: 22.01), "Persistent cursor expires cleanly after 12 seconds")
        persistent.pointer(now: 25)
        persistent.call(target: "4321", now: 28)
        try expect(persistent.cursorVisible(at: 28), "Consecutive call to same target never hides cursor")

        let glide = CursorMotion(
            start: CGPoint(x: 100, y: 120),
            end: CGPoint(x: 360, y: 240),
            began: 10,
            duration: CursorMotion.defaultGlideDuration
        )
        try expect(CursorMotion.defaultGlideDuration == 0.28, "Default multiplayer glide is 280ms")
        try expect(glide.point(at: 10) == CGPoint(x: 100, y: 120), "Glide starts at previous screen point")
        try expect(glide.point(at: 10.28) == CGPoint(x: 360, y: 240), "Glide settles at target after 280ms")
        let midTrail = glide.cometTrail(at: 10.16)
        try expect(midTrail.count == 5, "Flying cursor renders 5-dot comet trail")
        try expect(midTrail.first!.alpha > midTrail.last!.alpha && midTrail.first!.radius > midTrail.last!.radius,
                   "Comet trail fades and tapers from head to tail")
        try expect(glide.cometTrail(at: 10.50).isEmpty, "Comet trail clears once cursor settles")

        let canvasBounds = CGRect(x: 80, y: 60, width: 900, height: 640)
        let anchors = (0..<6).map { PresenceArtwork.anchorPoint(forSlot: $0, within: canvasBounds) }
        for (idx, anchor) in anchors.enumerated() {
            try expect(canvasBounds.insetBy(dx: 16, dy: 16).contains(anchor), "Slot \(idx) anchor inside window")
            for otherIdx in (idx + 1)..<anchors.count {
                try expect(hypot(anchor.x - anchors[otherIdx].x, anchor.y - anchors[otherIdx].y) > 24,
                           "Slot \(idx) and \(otherIdx) anchors are staggered apart")
            }
        }
        let (trailCanvas, _) = PresenceArtwork.cursorCanvasRect(
            at: glide.point(at: 10.16),
            trail: midTrail,
            tag: "Coder",
            waitingTurn: true,
            within: canvasBounds
        )
        try expect(!trailCanvas.isEmpty && canvasBounds.contains(trailCanvas), "Cursor canvas encloses arrow, tag, and comet trail")
        try expect(PresenceArtwork.formattedTag("QA", waitingTurn: true) == "⏳ QA", "Waiting turn prefixes hourglass on tag")

        let highlight = CursorMotion.SelectionHighlight(rect: CGRect(x: 200, y: 160, width: 140, height: 36), began: 50)
        try expect(highlight.opacity(at: 50.5) == 1.0, "Selection box holds full opacity during first ~1s")
        try expect(highlight.opacity(at: 51.05) > 0 && highlight.opacity(at: 51.05) < 1, "Selection box fades smoothly near 1.15s")
        try expect(highlight.opacity(at: 51.20) == 0, "Selection box hides after ~1.15s")
        try expect(highlight.opacity(at: 60.0, waitingTurn: true) == 1.0, "Selection box remains visible while waiting turn")

        // 5b. 16-Color Figma Cluster Palette, 24-Slot Hub, Curved Bézier Flight, Smooth Drag Curve & Swarm Fleet State.
        let expected16Hex = [
            "#FF6B9D", "#38BDF8", "#F59E0B", "#34D399", "#A78BFA", "#FB7185", "#2DD4BF", "#FBBF24",
            "#60A5FA", "#F472B6", "#4ADE80", "#C084FC", "#FB923C", "#22D3EE", "#A3E635", "#E879F9",
        ]
        try expect(AgentSlotPalette.count == 16 && AgentSlotPalette.maxSlots == 24, "16-color palette and 24-slot hub capacity")
        for idx in 0..<24 {
            let entry = AgentSlotPalette.entry(for: idx)
            try expect(entry.slot == idx, "Slot \(idx) preserved across 0..<24")
            try expect(entry.hex == expected16Hex[idx % 16], "Slot \(idx) maps to expected 16-color Figma hex")
            try expect(entry.defaultName == "Agent \(idx + 1)", "Slot \(idx) default name")
            let anchor = PresenceArtwork.anchorPoint(forSlot: idx, within: canvasBounds)
            try expect(canvasBounds.insetBy(dx: 16, dy: 16).contains(anchor), "24-slot anchor \(idx) inside window")
        }

        let arcStart = CGPoint(x: 100, y: 200)
        let arcEnd = CGPoint(x: 400, y: 200)
        let curvedOffset = CursorMotion.deterministicArcOffset(slot: 1, start: arcStart, end: arcEnd, isDrag: false)
        let dragOffset = CursorMotion.deterministicArcOffset(slot: 1, start: arcStart, end: arcEnd, isDrag: true)
        try expect(abs(curvedOffset) >= 14 && abs(curvedOffset) <= 68, "Glide/click computes subtle quadratic Bézier lateral arc")
        try expect(dragOffset == 0, "Drag strictly disables lateral arc so slider drags stay dead-straight")
        let curvedMotion = CursorMotion(start: arcStart, end: arcEnd, began: 20, duration: 0.28, arcOffset: curvedOffset)
        try expect(curvedMotion.point(at: 20.0) == arcStart, "Bézier glide starts strictly at start point")
        try expect(curvedMotion.point(at: 20.28) == arcEnd, "Bézier glide ends strictly at end point")
        try expect(abs(curvedMotion.point(at: 20.14).y - 200) > 6, "Bézier glide curves laterally off chord mid-flight")

        try expect(abs(InputController.smoothDragProgress(0.0) - 0.0) < 1e-9, "Smooth drag starts at 0")
        try expect(abs(InputController.smoothDragProgress(0.5) - 0.5) < 1e-9, "Smooth drag hits 0.5 at midpoint")
        try expect(abs(InputController.smoothDragProgress(1.0) - 1.0) < 1e-9, "Smooth drag ends at 1.0")
        var prevDragP = 0.0
        for step in 1...60 {
            let curDragP = InputController.smoothDragProgress(Double(step) / 60.0)
            try expect(curDragP > prevDragP, "Smooth drag curve is strictly monotonic at step \(step)")
            prevDragP = curDragP
        }

        try expect(SwarmAgentMode.parse("Ripple") == .ripple && SwarmAgentMode.parse("ORBIT") == .orbit,
                   "SwarmAgentMode parses case-insensitively")
        var orbitAgent = SwarmAgentState(
            agentId: "fleet-1",
            agentName: "Agent 1",
            colorHex: "#FF6B9D",
            rgb: AgentSlotPalette.entry(for: 0).rgb,
            slot: 0,
            mode: .orbit,
            motion: CursorMotion(start: CGPoint(x: 300, y: 240), end: CGPoint(x: 300, y: 240), began: 100),
            orbitCenter: CGPoint(x: 420, y: 300),
            orbitRadius: 90,
            orbitAngularSpeed: 2.5,
            orbitPhase: 0,
            orbitBegan: 100,
            lastUpdatedAt: 100
        )
        let orbitP1 = orbitAgent.point(at: 100.4)
        let orbitP2 = orbitAgent.point(at: 100.9)
        try expect(hypot(orbitP1.x - orbitP2.x, orbitP1.y - orbitP2.y) > 30, "Orbit mode animates smoothly around ring")
        try expect(orbitAgent.trail(at: 100.9).count >= 3, "Orbit mode produces smooth multi-dot comet wake")
        orbitAgent.mode = .click
        orbitAgent.pendingClickAt = 101.2
        orbitAgent.advanceEffects(at: 101.25)
        try expect(orbitAgent.pressBegan == 101.2 && orbitAgent.pendingClickAt == nil, "Arrival triggers click ripple")
        orbitAgent.dismissBegan = 102.0
        try expect(orbitAgent.opacity(at: 102.1) > 0 && orbitAgent.opacity(at: 102.3) == 0, "Dismiss mode fades cleanly")
        try expect(PresenceState.inputMethods.contains("swarm_dispatch") && PresenceState.inputMethods.contains("cluster_cursors"),
                   "swarm_dispatch and cluster_cursors gated by Stop policy")

        // 6. Real 4-concurrent-worker `launchd` startup test:
        //    Spawn 4 `opencu-engine serve` processes simultaneously and verify zero ENGINE_EXITED / launchd race!
        let repoRoot = URL(fileURLWithPath: CommandLine.arguments[1]).deletingLastPathComponent().deletingLastPathComponent()
        let builtEngine = repoRoot.appendingPathComponent(".build/OpenCU.app/Contents/MacOS/opencu-engine")
        if FileManager.default.isExecutableFile(atPath: builtEngine.path) {
            let launchHub = shortRoot.appendingPathComponent("parallel-hub").path
            let launchSock = shortRoot.appendingPathComponent("parallel.sock").path
            let names = ["Coder", "Designer", "Reviewer", "QA"]
            let colors = ["#FF6B9D", "#38BDF8", "#F59E0B", "#34D399"]
            struct WorkerResult: Sendable {
                let index: Int
                let status: Int32
                let stdout: String
                let stderr: String
            }
            let results = await withTaskGroup(of: WorkerResult.self) { group -> [WorkerResult] in
                for index in 0..<4 {
                    let agentName = names[index]
                    let agentColor = colors[index]
                    group.addTask {
                        let proc = Process()
                        proc.executableURL = builtEngine
                        proc.arguments = ["serve"]
                        var env = ProcessInfo.processInfo.environment
                        env["OPENCU_HUB_DIR"] = launchHub
                        env["OPENCU_EVENT_SOCK"] = launchSock
                        env["OPENCU_AGENT_NAME"] = agentName
                        env["OPENCU_AGENT_COLOR"] = agentColor
                        env["OPENCU_CAPTURE_OVERLAY"] = "1"
                        proc.environment = env
                        let stdinPipe = Pipe(), stdoutPipe = Pipe(), stderrPipe = Pipe()
                        proc.standardInput = stdinPipe
                        proc.standardOutput = stdoutPipe
                        proc.standardError = stderrPipe
                        do {
                            try proc.run()
                            let req = "{\"id\":1,\"method\":\"doctor\",\"params\":{}}\n"
                            stdinPipe.fileHandleForWriting.write(Data(req.utf8))
                            try? stdinPipe.fileHandleForWriting.close()
                            let outData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                            let errData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                            proc.waitUntilExit()
                            return WorkerResult(
                                index: index,
                                status: proc.terminationStatus,
                                stdout: String(decoding: outData, as: UTF8.self),
                                stderr: String(decoding: errData, as: UTF8.self)
                            )
                        } catch {
                            return WorkerResult(index: index, status: -1, stdout: "", stderr: "\(error)")
                        }
                    }
                }
                var collected: [WorkerResult] = []
                for await item in group { collected.append(item) }
                return collected.sorted { $0.index < $1.index }
            }
            var workerPIDs = Set<Int>()
            for res in results {
                let index = res.index
                try expect(res.status == 0, "Parallel worker \(index) exited cleanly (status=\(res.status), stderr=\(res.stderr))")
                let firstLine = res.stdout.split(separator: "\n").first.map(String.init) ?? ""
                let parsed = try JSONSerialization.jsonObject(with: Data(firstLine.utf8)) as? [String: Any]
                let doctor = parsed?["result"] as? [String: Any]
                try expect(doctor?["launchedBy"] as? String == "launchd", "Parallel worker \(index) launched via launchd")
                if let wpid = doctor?["workerPID"] as? Int, wpid > 0 {
                    workerPIDs.insert(wpid)
                }
            }
            try expect(workerPIDs.count == 4, "4 concurrent workers received 4 distinct launchd worker PIDs without race")
        }

        print("\(checked) multi-agent slot/color registry, non-overlapping badge, SOCK_DGRAM privacy-safe event stream, and flock concurrency checks passed")
    }
}
