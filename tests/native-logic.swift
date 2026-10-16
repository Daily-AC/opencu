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
                exit(0)
            } catch {
                FileHandle.standardError.write(Data("FAIL: \(error)\n".utf8))
                exit(1)
            }
        }
        RunLoop.main.run()
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
        for method in ["click", "drag", "press_key", "type_text", "paste", "scroll", "set_value", "select_text",
                       "perform_secondary_action", "activate_app"] {
            fails("STOPPED_BY_PERSON") { try presence.requireAllowed(method) }
        }
        fails("STOPPED_BY_PERSON") { try presence.requireAllowed("get_app_state", screenshot: true) }
        for method in ["experimental_agent_display_create", "experimental_agent_display_move_window"] {
            fails("STOPPED_BY_PERSON") { try presence.requireAllowed(method) }
        }
        for method in ["get_app_state", "doctor", "list_apps", "experimental_agent_display_status",
                       "experimental_agent_display_restore", "experimental_agent_display_destroy"] { try presence.requireAllowed(method) }
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
                try CaptureSafety.requireVerifiedEngine(respawned: true, pid: 10, responsiblePID: responsible)
            }
        }
        fails("CAPTURE_RESPONSIBILITY_UNVERIFIED") {
            try CaptureSafety.requireVerifiedEngine(respawned: false, pid: 10, responsiblePID: 10)
        }
        try CaptureSafety.requireVerifiedEngine(respawned: true, pid: 10, responsiblePID: 10)
        expect(true, "Only a respawned and OS-verified self-responsible engine qualifies")
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
        expect(ledger.saved == savedFrame && ledger.restorePending, "Frame committed before any AX mutation")
        fails("AGENT_DISPLAY_BUSY") {
            try ledger.remember(.init(windowID: 22, displayID: 42, frame: movedFrame))
        }
        expect(ledger.saved == savedFrame, "Repeated/other-window move cannot overwrite original frame")
        expect(ledger.cleanupSteps == [.restore, .releaseDisplay], "Disconnect and failure restore before release")
        ledger.released() // Simulated failed restore: still release the display.
        expect(ledger.restorePending && ledger.saved == savedFrame && ledger.cleanupSteps == [.restore], "Failed restoration retains recovery state after release")
        fails("AGENT_DISPLAY_BUSY") { try ledger.created(43) }
        ledger.restored()
        ledger.released()
        expect(ledger.cleanupSteps.isEmpty, "Successful restoration plus repeated destroy is idempotent")
        try ledger.created(43)
        expect(ledger.saved == nil, "Fresh display clears completed bookkeeping")
        try ledger.remember(savedFrame)
        ledger.restored()
        expect(ledger.cleanupSteps == [.releaseDisplay], "Explicit restore prevents duplicate window writes at shutdown")
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
}
