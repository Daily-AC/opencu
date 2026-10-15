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
        EngineRunLoop.run {
            do {
                try run()
                try await checkRunLoop()
                try await checkDisplayRemoval()
            } catch {
                FileHandle.standardError.write(Data("FAIL: \(error)\n".utf8))
                exit(1)
            }
        }
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

    @MainActor static func checkRunLoop() async throws {
        // No AppKit window/server access: a real main-run-loop timer models the
        // source that must fire while display settling suspends on Task.sleep.
        final class Flag: @unchecked Sendable { var fired = false }
        let flag = Flag()
        let timer = Timer(timeInterval: 0.02, repeats: false) { _ in flag.fired = Thread.isMainThread }
        RunLoop.main.add(timer, forMode: .default)
        defer { timer.invalidate() }
        for _ in 0..<50 {
            if flag.fired { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        guard flag.fired else { throw OpenCUError("TEST_FAILED", "Main CFRunLoop source did not run during async settling") }
        print("Main CFRunLoop timer delivered on the main thread during Task.sleep; no GUI access")
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
        print("\(checked) agent-display geometry/cleanup, attachment identity, input parsing, UTF-16, AX type, and rich Markdown checks passed; no GUI actions or clipboard writes")
    }
}
