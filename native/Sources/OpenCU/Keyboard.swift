import AppKit
import ApplicationServices
import Carbon

struct OpenCUKeyModifier {
    let code: CGKeyCode
    let flag: CGEventFlags
}

struct OpenCUKeyChord {
    var modifiers: [OpenCUKeyModifier]
    let code: CGKeyCode?
    let unicode: String?

    static func parse(_ input: String) throws -> OpenCUKeyChord {
        var raw = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if input == " " { raw = "space" }
        if raw == "+" { raw = "plus" }
        else if raw.hasSuffix("++") { raw = String(raw.dropLast(2)) + "+plus" }
        guard !raw.isEmpty else { throw OpenCUError("INVALID_ARGUMENT", "key must be a nonempty key or chord") }
        let tokens = raw.split(separator: "+", omittingEmptySubsequences: false).map(String.init)
        var modifiers: [OpenCUKeyModifier] = []
        var key: String?
        for token in tokens {
            let name = token.trimmingCharacters(in: .whitespaces)
            if let modifier = modifier(named: name) {
                if !modifiers.contains(where: { $0.flag == modifier.flag }) { modifiers.append(modifier) }
            } else {
                guard !name.isEmpty, key == nil else {
                    throw OpenCUError("INVALID_ARGUMENT", "A chord must contain modifiers and at most one key; use plus for the + key")
                }
                key = name
            }
        }
        guard let key else { return OpenCUKeyChord(modifiers: modifiers, code: nil, unicode: nil) }
        let name = key.lowercased()
        if let code = namedKeys[name] {
            if name == "iso_left_tab", !modifiers.contains(where: { $0.flag == .maskShift }) {
                modifiers.append(.init(code: 56, flag: .maskShift))
            }
            return OpenCUKeyChord(modifiers: modifiers, code: code, unicode: nil)
        }
        var character = punctuation[name] ?? key
        if key.count > 1, key.first == "U", let number = UInt32(key.dropFirst(), radix: 16),
           let scalar = Unicode.Scalar(number) { character = String(scalar) }
        guard character.count == 1 else {
            throw OpenCUError("UNSUPPORTED_KEY", "Unknown key name: \(key)")
        }
        if let physical = physicalKey(for: character) {
            for modifier in physical.modifiers where !modifiers.contains(where: { $0.flag == modifier.flag }) {
                modifiers.append(modifier)
            }
            return OpenCUKeyChord(modifiers: modifiers, code: physical.code, unicode: nil)
        }
        guard modifiers.isEmpty else {
            throw OpenCUError("UNSUPPORTED_KEY_CHORD", "\(key) has no physical key in the current keyboard layout; send it with type_text")
        }
        return OpenCUKeyChord(modifiers: [], code: nil, unicode: character)
    }

    private static func modifier(named name: String) -> OpenCUKeyModifier? {
        switch name.lowercased() {
        case "super", "super_l", "meta", "meta_l", "cmd", "command": return .init(code: 55, flag: .maskCommand)
        case "super_r", "meta_r", "command_r": return .init(code: 54, flag: .maskCommand)
        case "ctrl", "control", "ctrl_l", "control_l": return .init(code: 59, flag: .maskControl)
        case "ctrl_r", "control_r": return .init(code: 62, flag: .maskControl)
        case "alt", "option", "alt_l", "option_l": return .init(code: 58, flag: .maskAlternate)
        case "alt_r", "option_r", "iso_level3_shift": return .init(code: 61, flag: .maskAlternate)
        case "shift", "shift_l": return .init(code: 56, flag: .maskShift)
        case "shift_r": return .init(code: 60, flag: .maskShift)
        case "fn", "function": return .init(code: 63, flag: .maskSecondaryFn)
        default: return nil
        }
    }

    // Public Carbon keyboard-layout translation keeps shortcuts consistent with
    // the user's layout instead of assuming that printable keys use US positions.
    private static func physicalKey(for character: String) -> (code: CGKeyCode, modifiers: [OpenCUKeyModifier])? {
        let sources = [TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
                       TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue()]
        for candidate in sources {
            guard let source = candidate,
                  let opaqueData = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { continue }
            let data = Unmanaged<CFData>.fromOpaque(opaqueData).takeUnretainedValue()
            guard let bytes = CFDataGetBytePtr(data) else { continue }
            let layout = UnsafeRawPointer(bytes).assumingMemoryBound(to: UCKeyboardLayout.self)
            let variants: [(UInt32, [OpenCUKeyModifier])] = [
                (0, []),
                (UInt32(shiftKey >> 8), [.init(code: 56, flag: .maskShift)]),
                (UInt32(optionKey >> 8), [.init(code: 58, flag: .maskAlternate)]),
                (UInt32((shiftKey | optionKey) >> 8), [.init(code: 56, flag: .maskShift), .init(code: 58, flag: .maskAlternate)]),
            ]
            for (flags, modifiers) in variants {
                for code: UInt16 in 0..<128 {
                    var deadKeyState: UInt32 = 0
                    var length: Int = 0
                    var output = [UniChar](repeating: 0, count: 16)
                    let status = UCKeyTranslate(layout, code, UInt16(kUCKeyActionDown), flags, UInt32(LMGetKbdType()),
                                                OptionBits(kUCKeyTranslateNoDeadKeysMask), &deadKeyState,
                                                output.count, &length, &output)
                    if status == noErr, length > 0,
                       String(utf16CodeUnits: output, count: length) == character {
                        return (CGKeyCode(code), modifiers)
                    }
                }
            }
        }
        return nil
    }

    private static let namedKeys: [String: CGKeyCode] = [
        "return": 36, "enter": 36, "tab": 48, "iso_left_tab": 48, "space": 49,
        "backspace": 51, "back_space": 51, "escape": 53, "esc": 53, "caps_lock": 57,
        "delete": 117, "forwarddelete": 117, "home": 115, "end": 119,
        "prior": 116, "page_up": 116, "pageup": 116, "next": 121, "page_down": 121, "pagedown": 121,
        "left": 123, "right": 124, "down": 125, "up": 126, "help": 114, "insert": 114,
        "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96, "f6": 97, "f7": 98,
        "f8": 100, "f9": 101, "f10": 109, "f11": 103, "f12": 111, "f13": 105,
        "f14": 107, "f15": 113, "f16": 106, "f17": 64, "f18": 79, "f19": 80, "f20": 90,
        "kp_enter": 76, "kp_decimal": 65, "kp_multiply": 67, "kp_add": 69, "clear": 71,
        "kp_divide": 75, "kp_subtract": 78, "kp_equal": 81, "kp_0": 82, "kp_1": 83,
        "kp_2": 84, "kp_3": 85, "kp_4": 86, "kp_5": 87, "kp_6": 88, "kp_7": 89,
        "kp_8": 91, "kp_9": 92,
    ]

    private static let punctuation: [String: String] = [
        "exclam": "!", "quotedbl": "\"", "numbersign": "#", "dollar": "$", "percent": "%",
        "ampersand": "&", "apostrophe": "'", "quoteright": "'", "parenleft": "(", "parenright": ")",
        "asterisk": "*", "plus": "+", "comma": ",", "minus": "-", "period": ".", "slash": "/",
        "colon": ":", "semicolon": ";", "less": "<", "equal": "=", "greater": ">", "question": "?",
        "at": "@", "bracketleft": "[", "backslash": "\\", "bracketright": "]", "asciicircum": "^",
        "underscore": "_", "grave": "`", "quoteleft": "`", "braceleft": "{", "bar": "|",
        "braceright": "}", "asciitilde": "~",
    ]
}
