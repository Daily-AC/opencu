import AppKit
import ApplicationServices

@main
// Pure logic and in-memory rich-text checks. No input events are posted, and
// NSPasteboard.general and the production CLI entry point are never accessed.
struct OpenCUInputLogicChecks {
    @MainActor static func main() {
        do { try run() }
        catch {
            FileHandle.standardError.write(Data("FAIL: \(error)\n".utf8))
            exit(1)
        }
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
        // Opaque window detection uses the window's actual decoration elements,
        // not every AXButton, a localized title, or the application's menu bar.
        let decorations = ["close", "minimize", "zoom"]
        expect(windowHasOnlyDecorations(children: decorations, decorations: decorations, equal: ==),
               "Window with only its own title-bar buttons is opaque")
        expect(windowHasOnlyDecorations(children: [String](), decorations: [], equal: ==),
               "An empty accessible window has no accessible content")
        expect(!windowHasOnlyDecorations(children: nil as [String]?, decorations: decorations, equal: ==),
               "An unreadable child list is not evidence of an empty window")
        for content in ["textField", "webArea", "customButton", "canvas", "otherWindowClose"] {
            expect(!windowHasOnlyDecorations(children: decorations + [content], decorations: decorations, equal: ==),
                   "Content or another window's decoration must not match the shell")
        }
        expect(!windowHasOnlyDecorations(children: ["close"], decorations: [String](), equal: ==),
               "A button is not a decoration without window-owned identity")
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
        print("\(checked) attachment identity, input parsing, UTF-16, AX type, and rich Markdown checks passed; no input or clipboard writes")
    }
}
