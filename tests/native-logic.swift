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
        print("\(checked) input parsing, UTF-16, AX type, and rich Markdown checks passed; no input or clipboard writes")
    }
}
