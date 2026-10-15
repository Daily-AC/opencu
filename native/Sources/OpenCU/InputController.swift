import AppKit
import ApplicationServices
import Darwin

@MainActor
final class InputController {
    // Presence hooks stay independent of the input routing/focus implementation.
    var pointerDelivered: ((CGPoint, WindowSnapshot, Bool) -> Void)?
    var requireInputAllowed: (() throws -> Void)?
    private var backgroundFocus: BackgroundFocus?

    func releaseFocus(unlessTarget pid: pid_t? = nil) {
        if let pid, backgroundFocus?.pid == pid { return }
        backgroundFocus?.finish()
        backgroundFocus = nil
    }
    private var mouseEventNumber = 0
    private typealias SetWindowLocation = @convention(c) (CGEvent, CGPoint) -> Void
    private static let coreGraphicsHandle = dlopen("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", RTLD_LAZY | RTLD_LOCAL)
    private static let setWindowLocation: SetWindowLocation? = {
        guard let handle = coreGraphicsHandle,
              let address = dlsym(handle, "CGEventSetWindowLocation") else { return nil }
        return unsafeBitCast(address, to: SetWindowLocation.self)
    }()

    private struct MouseWindow {
        let id: CGWindowID
        let bounds: CGRect
    }

    private struct HeldKey {
        let release: CGEvent
        let modifier: CGEventFlags?
    }

    private struct HeldChord {
        let keys: [HeldKey]
        let flags: CGEventFlags
        let pid: pid_t

        func release() {
            var remaining = flags
            for key in keys.reversed() {
                if let modifier = key.modifier { remaining.remove(modifier) }
                key.release.flags = remaining
                key.release.timestamp = DispatchTime.now().uptimeNanoseconds
                key.release.postToPid(pid)
            }
        }
    }

    func perform(method: String, args: Arguments, snapshot: WindowSnapshot) async throws -> MenuEffect {
        try requireAccessibility()
        try Task.checkCancellation()
        try validate(snapshot)
        switch method {
        case "click": return try await click(args, snapshot)
        case "drag": try await drag(args, snapshot)
        case "press_key":
            try validateKeyboardDelivery(snapshot)
            try await prepareFocus(snapshot)
            let chord = try OpenCUKeyChord.parse(requiredString(args, "key", allowEmpty: true))
            try await send(chord, duration: duration(args), snapshot: snapshot)
        case "type_text":
            try requireTextWindow(snapshot)
            try validateKeyboardDelivery(snapshot)
            try await prepareFocus(snapshot)
            try await typeText(requiredString(args, "text", allowEmpty: true), snapshot)
        case "paste":
            try requireTextWindow(snapshot)
            try validateKeyboardDelivery(snapshot)
            try await prepareFocus(snapshot)
            try await paste(args, snapshot)
        case "scroll": try await scroll(args, snapshot)
        case "set_value": try setValue(args, snapshot)
        case "select_text": try selectText(args, snapshot)
        case "perform_secondary_action":
            let element = try indexedElement(args, snapshot)
            let requested = try requiredString(args, "action")
            guard let action = axResolveAction(requested, in: try actionNames(element)) else {
                throw OpenCUError("UNSUPPORTED_ACTION", "The element does not expose \(requested); read the current state for its available actions")
            }
            return try await perform(action, on: element)
        default: throw OpenCUError("UNKNOWN_METHOD", "Unknown input method: \(method)")
        }
        return .none
    }

    private func validate(_ snapshot: WindowSnapshot) throws {
        try requireInputAllowed?()
        try Task.checkCancellation()
        guard !snapshot.app.application.isTerminated,
              let running = NSRunningApplication(processIdentifier: snapshot.app.pid), !running.isTerminated,
              running.launchDate == snapshot.app.application.launchDate else {
            throw OpenCUError("STALE_APPLICATION", "The observed application exited or was replaced; get a new app state")
        }
        let application = AXUIElementCreateApplication(snapshot.app.pid)
        if let window = snapshot.window {
            guard let selected = axSelectedWindow(application), CFEqual(selected, window) else {
                throw OpenCUError("WINDOW_FOCUS_CHANGED", "The target application's selected window changed; get a new app state")
            }
            try validateLiveElement(window)
        } else if axSelectedWindow(application) != nil || !axWindows(application).isEmpty {
            throw OpenCUError("WINDOW_FOCUS_CHANGED", "The application now has a window; get a new app state before sending input")
        }
    }

    private func validateLiveElement(_ element: AXUIElement) throws {
        var role: CFTypeRef?
        try check(AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role), operation: "validate accessibility element")
        guard role != nil else { throw OpenCUError("STALE_ELEMENT", "The observed accessibility element is no longer available") }
    }

    private func requireTextWindow(_ snapshot: WindowSnapshot) throws {
        guard snapshot.window != nil else {
            throw OpenCUError("NO_ACCESSIBLE_WINDOW", "Typing and paste require a window; use a menu command or press_key shortcut to open one")
        }
    }

    /// AX attachment authorizes indexed actions, but does not make AppKit's
    /// background keyboard delivery work across a remote-view process boundary.
    /// Use WindowServer foreground state, never synthetic NSRunningApplication.isActive.
    private func validateKeyboardDelivery(_ snapshot: WindowSnapshot) throws {
        try validate(snapshot)
        let application = AXUIElementCreateApplication(snapshot.app.pid)
        let focused = axElement(application, kAXFocusedUIElementAttribute)
        var focusedPID: pid_t?
        if let focused {
            var owner: pid_t = 0
            if AXUIElementGetPid(focused, &owner) == .success, owner > 0 { focusedPID = owner }
        }
        try Self.requireKeyboardDelivery(isFrontmost: snapshot.app.isFrontmost,
                                         isFilePanel: isFilePanelFocus(focused, snapshot),
                                         targetPID: snapshot.app.pid, focusedPID: focusedPID)
    }

    // On macOS 26 a remote file panel's AX proxy can report the host PID. The
    // panel identifiers are present in both the macOS 15 VM and macOS 26 traces.
    // This is a refusal boundary, never a grant of access to another AX tree.
    static func isFilePanel(role: String?, identifier: String?) -> Bool {
        axIsWindowRole(role) && (identifier == "save-panel" || identifier == "open-panel")
    }

    private func isFilePanelFocus(_ focused: AXUIElement?, _ snapshot: WindowSnapshot) -> Bool {
        func panel(_ element: AXUIElement) -> Bool {
            Self.isFilePanel(role: axString(element, kAXRoleAttribute),
                             identifier: axString(element, kAXIdentifierAttribute))
        }
        guard let window = snapshot.window else { return false }
        if panel(window) { return true }
        // Some apps select their document window rather than the attached sheet.
        // Only consider the focused control's recorded, still-live window path;
        // a stale panel elsewhere in the snapshot must not block local typing.
        guard let focused, let path = snapshot.elementPaths.values.first(where: {
            $0.last.map { CFEqual($0, focused) } == true
        }), attachedPath(path, to: [window], equal: { CFEqual($0, $1) }, children: axChildren) else { return false }
        return path.contains(where: panel)
    }

    static func requireKeyboardDelivery(isFrontmost: Bool, isFilePanel: Bool,
                                        targetPID: pid_t, focusedPID: pid_t?) throws {
        // Foreground panels retain the proven PID-targeted path. Unknown focus
        // also keeps it unless the selected window/path identifies a file panel.
        if isFrontmost { return }
        let alternatives = "Use indexed set_value or exposed AX actions on the panel controls, or explicitly use activate_app before keyboard input."
        if isFilePanel || focusedPID.map({ $0 != targetPID }) == true {
            throw OpenCUError("BACKGROUND_REMOTE_FOCUS", "Background keyboard input to system Open/Save panels or remote-process focused controls is not supported. " + alternatives)
        }
    }

    private func prepareFocus(_ snapshot: WindowSnapshot) async throws {
        if backgroundFocus?.pid != snapshot.app.pid || backgroundFocus?.windowID != snapshot.windowID {
            releaseFocus()
            backgroundFocus = try BackgroundFocus(snapshot: snapshot)
        }
        if backgroundFocus?.refresh() == true { try await pause(0.025) }
        try validate(snapshot)
    }

    private func indexedElement(_ args: Arguments, _ snapshot: WindowSnapshot) throws -> AXUIElement {
        let number = try finiteNumber(args, "element_index")
        guard number.rounded(.towardZero) == number, number >= 0, number < Double(Int.max),
              let element = snapshot.elements[Int(number)], let path = snapshot.elementPaths[Int(number)],
              let last = path.last, CFEqual(last, element) else {
            throw OpenCUError("UNKNOWN_ELEMENT", "element_index must identify an element in the latest app state")
        }
        let application = AXUIElementCreateApplication(snapshot.app.pid)
        let roots = [snapshot.window, axElement(application, kAXMenuBarAttribute)].compactMap { $0 }
        guard attachedPath(path, to: roots, equal: { CFEqual($0, $1) }, children: axChildren) else {
            throw OpenCUError("STALE_ELEMENT", "The observed element is no longer attached to the target window or menu bar; get a new app state")
        }
        try validateLiveElement(element)
        return element
    }

    private func duration(_ args: Arguments) throws -> Double {
        guard args["duration"] != nil else { return 0 }
        let value = try finiteNumber(args, "duration")
        guard (0...30).contains(value) else { throw OpenCUError("INVALID_ARGUMENT", "duration must be between 0 and 30 seconds") }
        return value
    }

    private func point(_ args: Arguments, _ snapshot: WindowSnapshot, x: String = "x", y: String = "y") throws -> CGPoint {
        guard let width = snapshot.screenshotWidth, let height = snapshot.screenshotHeight, width > 0, height > 0 else {
            throw OpenCUError("SCREENSHOT_REQUIRED", "Coordinate input requires a screenshot from the latest app state")
        }
        guard let targetWindow = snapshot.window, let current = axRect(targetWindow), sameBounds(current, snapshot.bounds) else {
            throw OpenCUError("STALE_SCREENSHOT", "The observed window moved or resized; get a new screenshot before coordinate input")
        }
        let pixelX = try finiteNumber(args, x), pixelY = try finiteNumber(args, y)
        guard pixelX >= 0, pixelY >= 0, pixelX < Double(width), pixelY < Double(height) else {
            throw OpenCUError("INVALID_COORDINATE", "Coordinates must be inside the \(width)×\(height) screenshot")
        }
        return CursorMotion.screenPoint(pixel: CGPoint(x: pixelX, y: pixelY),
                                        pixels: CGSize(width: width, height: height), bounds: snapshot.bounds)
    }

    private func sameBounds(_ first: CGRect, _ second: CGRect) -> Bool {
        abs(first.minX - second.minX) < 0.01 && abs(first.minY - second.minY) < 0.01 &&
        abs(first.width - second.width) < 0.01 && abs(first.height - second.height) < 0.01
    }

    private func elementPoint(_ element: AXUIElement) throws -> CGPoint {
        guard let bounds = axRect(element), !bounds.isEmpty, !bounds.isNull, !bounds.isInfinite,
              bounds.minX.isFinite, bounds.minY.isFinite, bounds.width.isFinite, bounds.height.isFinite else {
            throw OpenCUError("ELEMENT_NOT_VISIBLE", "The element has no usable on-screen bounds; choose an exposed accessibility action")
        }
        return CGPoint(x: bounds.midX, y: bounds.midY)
    }

    private func target(_ args: Arguments, _ snapshot: WindowSnapshot) throws -> (AXUIElement?, CGPoint?) {
        let indexed = args["element_index"] != nil
        let coordinate = args["x"] != nil || args["y"] != nil
        guard indexed != coordinate else {
            throw OpenCUError("INVALID_ARGUMENT", "Supply either element_index or both x and y")
        }
        if indexed { return (try indexedElement(args, snapshot), nil) }
        return (nil, try point(args, snapshot))
    }

    private func mouseButton(_ args: Arguments) throws -> CGMouseButton {
        guard let value = args["mouse_button"] else { return .left }
        guard let name = value as? String else { throw OpenCUError("INVALID_ARGUMENT", "mouse_button must be left, right, or middle") }
        switch name.lowercased() {
        case "left", "l": return .left
        case "right", "r": return .right
        case "middle", "m": return .center
        default: throw OpenCUError("INVALID_ARGUMENT", "mouse_button must be left, right, or middle")
        }
    }

    private func click(_ args: Arguments, _ snapshot: WindowSnapshot) async throws -> MenuEffect {
        let (element, coordinate) = try target(args, snapshot)
        let button = try mouseButton(args)
        let hold = args["duration"] == nil ? 0.04 : try duration(args)
        let count = args["click_count"] == nil ? 1 : try finiteNumber(args, "click_count")
        guard count.rounded(.towardZero) == count, (1...3).contains(count) else {
            throw OpenCUError("INVALID_ARGUMENT", "click_count must be an integer between 1 and 3")
        }
        let chord = try args["key"].map { _ in try OpenCUKeyChord.parse(requiredString(args, "key")) }
        if let element, button == .left, count == 1, chord == nil, args["duration"] == nil,
           try actionNames(element).contains(kAXPressAction) {
            // AX actions need no WindowServer ID. For a real background window,
            // retain key-window activation so AppKit validates window commands.
            if snapshot.windowID != nil { try await prepareFocus(snapshot) }
            _ = try indexedElement(args, snapshot)
            let location = try? elementPoint(element)
            let effect = try await perform(kAXPressAction, on: element)
            if let location { pointerDelivered?(location, snapshot, true) }
            return effect
        }
        if let element, button == .left,
           [kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole].contains(axString(element, kAXRoleAttribute) ?? "") {
            if snapshot.windowID != nil { try await prepareFocus(snapshot) }
            _ = try indexedElement(args, snapshot)
            var focusSettable = DarwinBoolean(false)
            if AXUIElementIsAttributeSettable(element, kAXFocusedAttribute as CFString, &focusSettable) == .success,
               focusSettable.boolValue {
                try check(AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue), operation: "focus text control")
                var owner: pid_t = 0
                if AXUIElementGetPid(element, &owner) == .success, owner != snapshot.app.pid,
                   count == 1, chord == nil, args["duration"] == nil {
                    // Remote panel text controls accept AX focus. Never send a
                    // pointer event to the host window at a remote control's point.
                    if let location = try? elementPoint(element) { pointerDelivered?(location, snapshot, true) }
                    return .none
                }
            }
        }
        if let element {
            var owner: pid_t = 0
            guard AXUIElementGetPid(element, &owner) == .success, owner == snapshot.app.pid else {
                throw OpenCUError("TARGETED_MOUSE_UNAVAILABLE", "This remote control requires an exposed accessibility action or set_value; no pointer input was sent")
            }
        }
        let location = try coordinate ?? elementPoint(element!)
        let window = try mouseWindow(snapshot)
        try await prepareFocus(snapshot)
        let source = try eventSource()
        let held = try holdChord(chord, source: source, pid: snapshot.app.pid)
        defer { held.release() }
        for number in 1...Int(count) {
            try Task.checkCancellation()
            try validate(snapshot)
            if coordinate != nil { _ = try point(args, snapshot) }
            let down = try mouseEvent(button == .left ? .leftMouseDown : button == .right ? .rightMouseDown : .otherMouseDown,
                                      at: location, button: button, source: source, window: window, flags: held.flags)
            let up = try mouseEvent(button == .left ? .leftMouseUp : button == .right ? .rightMouseUp : .otherMouseUp,
                                    at: location, button: button, source: source, window: window, flags: held.flags)
            down.setIntegerValueField(.mouseEventClickState, value: Int64(number))
            up.setIntegerValueField(.mouseEventClickState, value: Int64(number))
            down.postToPid(snapshot.app.pid)
            pointerDelivered?(location, snapshot, true)
            do {
                defer {
                    up.timestamp = DispatchTime.now().uptimeNanoseconds
                    up.postToPid(snapshot.app.pid)
                }
                try await pause(hold)
            }
            if number < Int(count) { try await pause(0.05) }
        }
        return .none
    }

    /// Clicking a menu bar item or submenu lists its items without opening it:
    /// AppKit populates delegate menus and validates items when Accessibility
    /// reads them, and AXPress on a closed item still runs it after validation.
    /// An open background menu would cover the user's screen and close on their
    /// next click. AppKit sends a command chosen from an already open menu after
    /// its dismissal animation, so wait for that menu to close.
    private func perform(_ action: String, on element: AXUIElement) async throws -> MenuEffect {
        let role = axString(element, kAXRoleAttribute)
        guard [kAXPressAction, kAXPickAction].contains(action), role == kAXMenuBarItemRole || role == kAXMenuItemRole else {
            try check(AXUIElementPerformAction(element, action as CFString), operation: action)
            return .none
        }
        var submenus: CFIndex = 0
        if AXUIElementGetAttributeValueCount(element, kAXChildrenAttribute as CFString, &submenus) == .success, submenus > 0 {
            return .opened(element)
        }
        var menuBarItem: AXUIElement?
        var current = element
        while let parent = axValue(current, kAXParentAttribute), CFGetTypeID(parent) == AXUIElementGetTypeID() {
            current = parent as! AXUIElement
            if axString(current, kAXRoleAttribute) == kAXMenuBarItemRole { menuBarItem = current; break }
        }
        try check(AXUIElementPerformAction(element, action as CFString), operation: action)
        // Up to 1.5 s: the command is sent when the open menu finishes closing.
        for _ in 0..<60 {
            guard let menuBarItem, axValue(menuBarItem, kAXSelectedAttribute) as? Bool == true else { break }
            try await pause(0.025)
        }
        return .chose
    }

    private func drag(_ args: Arguments, _ snapshot: WindowSnapshot) async throws {
        let start = try point(args, snapshot, x: "from_x", y: "from_y")
        let end = try point(args, snapshot, x: "to_x", y: "to_y")
        let window = try mouseWindow(snapshot)
        try await prepareFocus(snapshot)
        let source = try eventSource()
        let down = try mouseEvent(.leftMouseDown, at: start, button: .left, source: source, window: window)
        var up = try mouseEvent(.leftMouseUp, at: start, button: .left, source: source, window: window)
        try Task.checkCancellation()
        down.postToPid(snapshot.app.pid)
        pointerDelivered?(start, snapshot, true)
        defer {
            up.timestamp = DispatchTime.now().uptimeNanoseconds
            up.postToPid(snapshot.app.pid)
        }
        for step in 1...20 {
            try Task.checkCancellation()
            try validate(snapshot)
            _ = try point(args, snapshot, x: "from_x", y: "from_y")
            let fraction = Double(step) / 20
            let location = CGPoint(x: start.x + (end.x - start.x) * fraction, y: start.y + (end.y - start.y) * fraction)
            let move = try mouseEvent(.leftMouseDragged, at: location, button: .left, source: source, window: window)
            up = try mouseEvent(.leftMouseUp, at: location, button: .left, source: source, window: window)
            move.postToPid(snapshot.app.pid)
            pointerDelivered?(location, snapshot, false)
            try await pause(0.015)
        }
    }

    private func scroll(_ args: Arguments, _ snapshot: WindowSnapshot) async throws {
        let (element, coordinate) = try target(args, snapshot)
        if let element {
            var owner: pid_t = 0
            guard AXUIElementGetPid(element, &owner) == .success, owner == snapshot.app.pid else {
                throw OpenCUError("TARGETED_MOUSE_UNAVAILABLE", "This remote control requires an exposed accessibility action or set_value; no pointer input was sent")
            }
        }
        let location = try coordinate ?? elementPoint(element!)
        let direction = try requiredString(args, "direction").lowercased()
        guard ["up", "down", "left", "right", "u", "d", "l", "r"].contains(direction) else {
            throw OpenCUError("INVALID_ARGUMENT", "direction must be up, down, left, or right")
        }
        let pages = args["pages"] == nil ? 1 : try finiteNumber(args, "pages")
        guard pages > 0 else { throw OpenCUError("INVALID_ARGUMENT", "pages must be positive") }
        let horizontal = ["left", "right", "l", "r"].contains(direction)
        let viewport = element.flatMap { axRect($0) } ?? snapshot.bounds
        let distance = (horizontal ? viewport.width : viewport.height) * 0.85 * pages
        guard distance.isFinite, distance > 0, distance <= Double(Int32.max) else {
            throw OpenCUError("INVALID_ARGUMENT", "The requested scroll distance is outside the supported pixel range")
        }
        let positive = ["up", "left", "u", "l"].contains(direction)
        let delta = Int32(max(1, distance.rounded())) * (positive ? 1 : -1)
        let window = try mouseWindow(snapshot)
        try await prepareFocus(snapshot)
        let source = try eventSource()
        guard let wheel = CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 2,
                                  wheel1: horizontal ? 0 : delta, wheel2: horizontal ? delta : 0, wheel3: 0) else {
            throw OpenCUError("EVENT_CREATION_FAILED", "Could not create a scroll event")
        }
        let hover = try mouseEvent(.mouseMoved, at: location, button: .left, source: source, window: window)
        let event = try mouseEvent(.mouseMoved, at: location, button: .left, source: source, window: window)
        event.type = .scrollWheel
        // Keep the AppKit factory's window association and window-local point,
        // while obtaining the scroll encoding from the public CGEvent factory.
        let fields: [CGEventField] = [.scrollWheelEventDeltaAxis1, .scrollWheelEventDeltaAxis2, .scrollWheelEventDeltaAxis3,
                                     .scrollWheelEventFixedPtDeltaAxis1, .scrollWheelEventFixedPtDeltaAxis2, .scrollWheelEventFixedPtDeltaAxis3,
                                     .scrollWheelEventPointDeltaAxis1, .scrollWheelEventPointDeltaAxis2, .scrollWheelEventPointDeltaAxis3,
                                     .scrollWheelEventIsContinuous, .scrollWheelEventScrollPhase, .scrollWheelEventMomentumPhase]
        for field in fields { event.setIntegerValueField(field, value: wheel.getIntegerValueField(field)) }
        try Task.checkCancellation()
        hover.postToPid(snapshot.app.pid)
        event.postToPid(snapshot.app.pid)
        pointerDelivered?(location, snapshot, false)
    }

    private func setValue(_ args: Arguments, _ snapshot: WindowSnapshot) throws {
        let element = try indexedElement(args, snapshot)
        let value = try requiredString(args, "value", allowEmpty: true)
        try requireSettable(element, attribute: kAXValueAttribute)
        guard let current = axValue(element, kAXValueAttribute) else {
            throw OpenCUError("VALUE_TYPE_UNAVAILABLE", "The element does not expose its current value type")
        }
        let replacement = try Self.typedValue(value, current: current, role: axString(element, kAXRoleAttribute))
        try check(AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, replacement), operation: "set element value")
    }

    static func typedValue(_ text: String, current: CFTypeRef, role: String?) throws -> CFTypeRef {
        let type = CFGetTypeID(current)
        if type == CFStringGetTypeID() { return text as CFString }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if type == CFBooleanGetTypeID() {
            switch trimmed.lowercased() {
            case "true", "1": return kCFBooleanTrue
            case "false", "0": return kCFBooleanFalse
            default: throw OpenCUError("INVALID_ARGUMENT", "This element requires true, false, 1, or 0")
            }
        }
        if type == CFNumberGetTypeID() {
            if role == kAXCheckBoxRole || role == kAXRadioButtonRole {
                if trimmed.lowercased() == "true" { return NSNumber(value: 1) }
                if trimmed.lowercased() == "false" { return NSNumber(value: 0) }
            }
            guard let value = Double(trimmed), value.isFinite else {
                throw OpenCUError("INVALID_ARGUMENT", "This element requires a finite numeric value")
            }
            return NSNumber(value: value)
        }
        throw OpenCUError("UNSUPPORTED_VALUE_TYPE", "Only exposed string, numeric, and boolean AX values can be set")
    }

    private func selectText(_ args: Arguments, _ snapshot: WindowSnapshot) throws {
        let element = try indexedElement(args, snapshot)
        try requireSettable(element, attribute: kAXSelectedTextRangeAttribute)
        guard let value = axString(element, kAXValueAttribute) else {
            throw OpenCUError("TEXT_UNAVAILABLE", "The element does not expose a readable text value")
        }
        let text = try requiredString(args, "text", allowEmpty: true)
        let prefix = try optionalString(args, "prefix"), suffix = try optionalString(args, "suffix")
        let kind = try optionalString(args, "selection_type") ?? "text"
        guard ["text", "cursor_before", "cursor_after"].contains(kind) else {
            throw OpenCUError("INVALID_ARGUMENT", "selection_type must be text, cursor_before, or cursor_after")
        }
        let match = try Self.textRange(in: value, text: text, prefix: prefix, suffix: suffix)
        var range = CFRange(location: kind == "cursor_after" ? NSMaxRange(match) : match.location,
                            length: kind == "text" ? match.length : 0)
        guard let encoded = AXValueCreate(.cfRange, &range) else { throw OpenCUError("INVALID_ARGUMENT", "Could not encode the text selection") }
        try check(AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, encoded), operation: "set selected text range")
        if let actual = axValue(element, kAXSelectedTextRangeAttribute), CFGetTypeID(actual) == AXValueGetTypeID() {
            var observed = CFRange()
            if AXValueGetValue(actual as! AXValue, .cfRange, &observed), observed.location != range.location || observed.length != range.length {
                throw OpenCUError("SELECTION_NOT_APPLIED", "The element did not retain the requested text selection")
            }
        }
    }

    // NSString ranges intentionally count UTF-16 code units, matching AX text ranges.
    static func textRange(in value: String, text: String, prefix: String?, suffix: String?) throws -> NSRange {
        let source = value as NSString, needle = text as NSString
        let before = (prefix ?? "") as NSString, after = (suffix ?? "") as NSString
        var matches: [NSRange] = []
        var offset = 0
        while offset <= source.length {
            let match = needle.length == 0 ? NSRange(location: offset, length: 0) :
                source.range(of: text, options: .literal, range: NSRange(location: offset, length: source.length - offset))
            if match.location == NSNotFound { break }
            let end = NSMaxRange(match)
            let startsInsideSurrogate = match.location > 0 && match.location < source.length &&
                (0xDC00...0xDFFF).contains(source.character(at: match.location)) &&
                (0xD800...0xDBFF).contains(source.character(at: match.location - 1))
            if !startsInsideSurrogate, match.location >= before.length, source.length - end >= after.length,
               source.compare(before as String, options: .literal,
                              range: NSRange(location: match.location - before.length, length: before.length)) == .orderedSame,
               source.compare(after as String, options: .literal,
                              range: NSRange(location: end, length: after.length)) == .orderedSame {
                matches.append(match)
                if matches.count > 1 {
                    throw OpenCUError("AMBIGUOUS_TEXT", "The text matches more than once; provide adjacent prefix and/or suffix to identify one occurrence")
                }
            }
            offset = match.location + 1
        }
        guard let result = matches.first else { throw OpenCUError("TEXT_NOT_FOUND", "No text occurrence matches the supplied text, prefix, and suffix") }
        return result
    }

    private func paste(_ args: Arguments, _ snapshot: WindowSnapshot) async throws {
        let text = try requiredString(args, "text", allowEmpty: true)
        let format = try optionalString(args, "format") ?? "text"
        guard ["text", "md", "html"].contains(format) else { throw OpenCUError("INVALID_ARGUMENT", "format must be text, md, or html") }
        let item = NSPasteboardItem()
        if format == "md" {
            let representation = try Self.markdownRepresentation(text)
            guard item.setString(representation.plain, forType: .string),
                  item.setData(representation.rtf, forType: .rtf),
                  item.setData(representation.html, forType: .html),
                  item.setData(Data(text.utf8), forType: .init("net.daringfireball.markdown")) else {
                throw OpenCUError("CLIPBOARD_WRITE_FAILED", "Could not prepare the Markdown representations")
            }
        } else {
            guard item.setString(text, forType: .string),
                  format != "html" || item.setData(Data(text.utf8), forType: .html) else {
                throw OpenCUError("CLIPBOARD_WRITE_FAILED", "Could not prepare the paste text")
            }
        }
        let pasteChord = try OpenCUKeyChord.parse("super+v")
        let clipboard = NSPasteboard.general
        let initialChangeCount = clipboard.changeCount
        var saved: [[NSPasteboard.PasteboardType: Data]] = []
        for item in clipboard.pasteboardItems ?? [] {
            var contents: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                guard let data = item.data(forType: type) else {
                    throw OpenCUError("CLIPBOARD_UNAVAILABLE", "An existing clipboard item could not be preserved; the clipboard was not changed")
                }
                contents[type] = data
            }
            saved.append(contents)
        }
        guard clipboard.changeCount == initialChangeCount else {
            throw OpenCUError("CLIPBOARD_CHANGED", "The clipboard changed while it was being preserved; paste was not sent")
        }
        try Task.checkCancellation()
        try validateKeyboardDelivery(snapshot)
        clipboard.clearContents()
        var ownedChangeCount = clipboard.changeCount
        defer {
            // Other applications own any later clipboard change. Never replace it.
            if clipboard.changeCount == ownedChangeCount {
                clipboard.clearContents()
                if !saved.isEmpty {
                    let restored = saved.map { values -> NSPasteboardItem in
                        let restored = NSPasteboardItem()
                        for (type, data) in values { restored.setData(data, forType: type) }
                        return restored
                    }
                    clipboard.writeObjects(restored)
                }
            }
        }
        let written = clipboard.writeObjects([item])
        ownedChangeCount = clipboard.changeCount
        guard written else { throw OpenCUError("CLIPBOARD_WRITE_FAILED", "Could not write the paste text") }
        try validate(snapshot)
        try await send(pasteChord, duration: 0, snapshot: snapshot)
        // Posting is asynchronous. Allow the application's paste command to consume
        // its data before restoring; the dispatcher observes the actual result.
        try await pause(0.25)
    }

    static func markdownRepresentation(_ markdown: String) throws -> (plain: String, rtf: Data, html: Data) {
        let parsed: AttributedString
        do { parsed = try AttributedString(markdown: markdown) }
        catch { throw OpenCUError("INVALID_MARKDOWN", "Could not parse Markdown: \(error.localizedDescription)") }
        let rich = NSMutableAttributedString(string: "")
        var previousBlock: Int?
        var previousRow: Int?
        for run in parsed.runs {
            let intents = run.presentationIntent?.components ?? []
            let block = intents.first?.identity
            var row: Int?
            var headerLevel: Int?
            var listOrdinal: Int?
            var orderedList = false
            var listDepth = 0
            var codeBlock = false
            var quote = false
            for intent in intents {
                switch intent.kind {
                case .header(let level): headerLevel = level
                case .listItem(let ordinal): listOrdinal = ordinal
                case .orderedList: orderedList = true; listDepth += 1
                case .unorderedList: listDepth += 1
                case .codeBlock: codeBlock = true
                case .blockQuote: quote = true
                case .tableRow, .tableHeaderRow: row = intent.identity
                default: break
                }
            }
            let inline = run.inlinePresentationIntent ?? []
            let size: CGFloat = headerLevel.map { max(14, 26 - CGFloat($0) * 2) } ?? 13
            var font = inline.contains(.code) || codeBlock ? NSFont.monospacedSystemFont(ofSize: size, weight: .regular) : NSFont.systemFont(ofSize: size)
            if inline.contains(.stronglyEmphasized) || headerLevel != nil { font = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask) }
            if inline.contains(.emphasized) { font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) }
            let paragraph = NSMutableParagraphStyle()
            paragraph.paragraphSpacing = 6
            if listDepth > 0 {
                paragraph.firstLineHeadIndent = CGFloat(listDepth - 1) * 18
                paragraph.headIndent = CGFloat(listDepth) * 18
                paragraph.tabStops = [NSTextTab(textAlignment: .left, location: paragraph.headIndent)]
            } else if quote {
                paragraph.firstLineHeadIndent = 18
                paragraph.headIndent = 18
            }
            var attributes: [NSAttributedString.Key: Any] = [.font: font, .paragraphStyle: paragraph]
            if inline.contains(.strikethrough) { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            if let link = run.link { attributes[.link] = link }
            if block != previousBlock {
                if rich.length > 0 { rich.append(NSAttributedString(string: row != nil && row == previousRow ? "\t" : "\n", attributes: attributes)) }
                if let ordinal = listOrdinal {
                    rich.append(NSAttributedString(string: orderedList ? "\(ordinal).\t" : "•\t", attributes: attributes))
                }
                previousBlock = block
                previousRow = row
            }
            rich.append(NSAttributedString(string: String(parsed[run.range].characters), attributes: attributes))
        }
        let range = NSRange(location: 0, length: rich.length)
        let rtf = try rich.data(from: range, documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
        let html = try rich.data(from: range, documentAttributes: [.documentType: NSAttributedString.DocumentType.html,
                                                                 .characterEncoding: String.Encoding.utf8.rawValue])
        return (rich.string, rtf, html)
    }

    private func typeText(_ text: String, _ snapshot: WindowSnapshot) async throws {
        let source = try eventSource()
        for character in text {
            try Task.checkCancellation()
            try validateKeyboardDelivery(snapshot)
            if character == "\n" || character == "\r" || character == "\r\n" {
                try await send(OpenCUKeyChord.parse("Return"), duration: 0, snapshot: snapshot)
            } else if character == "\t" {
                try await send(OpenCUKeyChord.parse("Tab"), duration: 0, snapshot: snapshot)
            } else {
                let chord = OpenCUKeyChord(modifiers: [], code: nil, unicode: String(character))
                let held = try holdChord(chord, source: source, pid: snapshot.app.pid)
                held.release()
            }
            try await pause(0.002)
        }
    }

    private func send(_ chord: OpenCUKeyChord, duration: Double, snapshot: WindowSnapshot) async throws {
        try validateKeyboardDelivery(snapshot)
        let source = try eventSource()
        let held = try holdChord(chord, source: source, pid: snapshot.app.pid)
        defer { held.release() }
        try await pause(duration)
    }

    private func holdChord(_ chord: OpenCUKeyChord?, source: CGEventSource, pid: pid_t) throws -> HeldChord {
        guard let chord else { return HeldChord(keys: [], flags: [], pid: pid) }
        var flags: CGEventFlags = []
        var events: [(CGEvent, HeldKey)] = []
        for modifier in chord.modifiers {
            let down = try keyboardEvent(modifier.code, down: true, source: source)
            let up = try keyboardEvent(modifier.code, down: false, source: source)
            flags.insert(modifier.flag)
            down.type = .flagsChanged
            up.type = .flagsChanged
            down.flags = flags
            events.append((down, HeldKey(release: up, modifier: modifier.flag)))
        }
        if chord.code != nil || chord.unicode != nil {
            let down = try keyboardEvent(chord.code ?? 0, down: true, source: source)
            let up = try keyboardEvent(chord.code ?? 0, down: false, source: source)
            down.flags = flags
            if let text = chord.unicode {
                let units = Array(text.utf16)
                units.withUnsafeBufferPointer { buffer in
                    down.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: buffer.baseAddress!)
                    up.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: buffer.baseAddress!)
                }
            }
            events.append((down, HeldKey(release: up, modifier: nil)))
        }
        // Create every release before posting any key down, so an allocation
        // failure cannot leave a partly held chord behind.
        try Task.checkCancellation()
        for (down, _) in events { down.postToPid(pid) }
        return HeldChord(keys: events.map(\.1), flags: flags, pid: pid)
    }

    private func eventSource() throws -> CGEventSource {
        guard let source = CGEventSource(stateID: .privateState) else { throw OpenCUError("EVENT_CREATION_FAILED", "Could not create an input event source") }
        return source
    }

    private func keyboardEvent(_ code: CGKeyCode, down: Bool, source: CGEventSource) throws -> CGEvent {
        guard let event = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down) else {
            throw OpenCUError("EVENT_CREATION_FAILED", "Could not create a keyboard event")
        }
        event.setIntegerValueField(.keyboardEventAutorepeat, value: 0)
        return event
    }

    private func mouseWindow(_ snapshot: WindowSnapshot) throws -> MouseWindow {
        guard Self.setWindowLocation != nil else {
            throw OpenCUError("TARGETED_MOUSE_UNAVAILABLE", "Targeted mouse input is unavailable on this macOS version. No input was sent.")
        }
        guard let id = snapshot.windowID, id != kCGNullWindowID else {
            throw OpenCUError("WINDOW_ID_UNAVAILABLE", "Mouse input requires a uniquely identified target window. Read the app state again or use an exposed accessibility action. No input was sent.")
        }
        guard let targetWindow = snapshot.window, let current = axRect(targetWindow),
              current.width > 0, current.height > 0,
              let windows = CGWindowListCopyWindowInfo(.optionIncludingWindow, id) as? [[String: Any]],
              let record = windows.first(where: { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value == id }),
              (record[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == snapshot.app.pid else {
            throw OpenCUError("STALE_WINDOW", "The target window identity changed. Read the app state again before mouse input. No input was sent.")
        }
        // Stage Manager translates/scales the composited CG window independently
        // of its AX content geometry. Routing uses the exact AX window ID and
        // an explicit window-local point, so composited bounds are not a match key.
        return MouseWindow(id: id, bounds: current)
    }

    private func mouseEvent(_ type: CGEventType, at point: CGPoint, button: CGMouseButton,
                            source: CGEventSource, window: MouseWindow, flags: CGEventFlags = []) throws -> CGEvent {
        guard let eventType = NSEvent.EventType(rawValue: UInt(type.rawValue)) else {
            throw OpenCUError("EVENT_CREATION_FAILED", "Unsupported mouse event type")
        }
        mouseEventNumber &+= 1
        let local = NSPoint(x: point.x - window.bounds.minX, y: window.bounds.maxY - point.y)
        let released = [.leftMouseUp, .rightMouseUp, .otherMouseUp, .mouseMoved].contains(type)
        guard let native = NSEvent.mouseEvent(with: eventType, location: local,
                                             modifierFlags: NSEvent.ModifierFlags(rawValue: UInt(flags.rawValue)),
                                             timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: Int(window.id),
                                             context: nil, eventNumber: mouseEventNumber, clickCount: type == .mouseMoved ? 0 : 1,
                                             pressure: released ? 0 : 1),
              let event = native.cgEvent else {
            throw OpenCUError("EVENT_CREATION_FAILED", "Could not create a mouse event")
        }
        event.setSource(source)
        event.flags = flags
        event.setIntegerValueField(.mouseEventSubtype, value: 3)
        event.setIntegerValueField(.mouseEventButtonNumber, value: Int64(button.rawValue))
        event.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: Int64(window.id))
        event.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: Int64(window.id))
        // The global point and the receiver's window-relative point are separate
        // fields. AppKit leaves the latter unset for another process's window.
        event.location = point
        guard let setWindowLocation = Self.setWindowLocation else {
            throw OpenCUError("TARGETED_MOUSE_UNAVAILABLE", "Targeted mouse input is unavailable on this macOS version. No input was sent.")
        }
        // OS SPI: the relative point uses the top-left origin, without AppKit's
        // Y flip. The ABI and coordinate convention are independently described
        // by https://github.com/andelf/axcli/blob/main/src/input.rs and main.rs.
        setWindowLocation(event, CGPoint(x: point.x - window.bounds.minX, y: point.y - window.bounds.minY))
        return event
    }

    private func pause(_ seconds: Double) async throws {
        try requireInputAllowed?()
        try Task.checkCancellation()
        if seconds > 0 { try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }
    }

    private func optionalString(_ args: Arguments, _ name: String) throws -> String? {
        guard let value = args[name] else { return nil }
        guard let string = value as? String else { throw OpenCUError("INVALID_ARGUMENT", "\(name) must be a string") }
        return string
    }

    private func actionNames(_ element: AXUIElement) throws -> [String] {
        var value: CFArray?
        try check(AXUIElementCopyActionNames(element, &value), operation: "read accessibility actions")
        return value as? [String] ?? []
    }

    private func requireSettable(_ element: AXUIElement, attribute: String) throws {
        var settable = DarwinBoolean(false)
        try check(AXUIElementIsAttributeSettable(element, attribute as CFString, &settable), operation: "check \(attribute)")
        guard settable.boolValue else { throw OpenCUError("ATTRIBUTE_NOT_SETTABLE", "The element does not allow setting \(attribute)") }
    }

    private func check(_ result: AXError, operation: String) throws {
        guard result == .success else {
            let code = result == .invalidUIElement ? "STALE_ELEMENT" : result == .apiDisabled ? "ACCESSIBILITY_PERMISSION_REQUIRED" : "ACCESSIBILITY_ERROR"
            throw OpenCUError(code, "Could not \(operation) (AX error \(result.rawValue)); actions are not retried")
        }
    }
}
