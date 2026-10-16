import AppKit
import ApplicationServices
import Darwin
import ImageIO
import ScreenCaptureKit

@MainActor
final class MacObserver {
    var willObserveWindow: ((WindowSnapshot) -> Void)?
    var requireCaptureAllowed: (() throws -> Void)?
    private let workspace = NSWorkspace.shared
    private let maximumElements = 800
    private let maximumInspected = 8_000
    private let maximumNesting = 120
    private let maximumTextCharacters = 180_000
    /// Capture failures that a retry cannot fix; the text state is returned instead.
    private static let lastingCaptureFailures: Set<String> = ["WINDOW_ID_UNAVAILABLE",
                                                              "SCREENSHOT_WINDOW_UNAVAILABLE", "SCREENSHOT_THUMBNAIL", "SCREENSHOT_TOO_LARGE"]
    private var webAccessibilityRequested: Set<pid_t> = []
    private var enhancedInterface: [pid_t: NSRunningApplication] = [:]
    private var chromiumBundles: [URL: Bool] = [:]

    /// Chromium and Electron expose web content only to assistive clients.
    /// Electron accepts AXManualAccessibility, which has no side effects.
    /// Chromium browsers need AXEnhancedUserInterface, which also slows window
    /// moves made by window managers, so OpenCU restores it when it disconnects.
    private func requestWebAccessibility(_ application: AXUIElement, _ app: TargetApp) async throws {
        guard let url = app.application.bundleURL, isChromium(url) else { return }
        var building = webAccessibilityRequested.insert(app.pid).inserted
        if AXUIElementSetAttributeValue(application, "AXManualAccessibility" as CFString, kCFBooleanTrue) != .success {
            var current: CFTypeRef?
            if AXUIElementCopyAttributeValue(application, "AXEnhancedUserInterface" as CFString, &current) != .success
                || current as? Bool != true {
                // Chromium enables its tree but reports this setter as not implemented.
                _ = AXUIElementSetAttributeValue(application, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
                enhancedInterface[app.pid] = app.application
                building = true
            }
        }
        if building { try await Task.sleep(nanoseconds: 700_000_000) } // The tree is built asynchronously.
    }

    func restoreAccessibilityModes() {
        for (pid, application) in enhancedInterface where !application.isTerminated {
            _ = AXUIElementSetAttributeValue(AXUIElementCreateApplication(pid), "AXEnhancedUserInterface" as CFString, kCFBooleanFalse)
        }
        enhancedInterface = [:]
    }

    /// Chromium browsers and Electron apps ship a renderer helper app.
    private func isChromium(_ url: URL) -> Bool {
        if let known = chromiumBundles[url] { return known }
        let files = FileManager.default
        let frameworks = url.appendingPathComponent("Contents/Frameworks")
        let names = (try? files.contentsOfDirectory(atPath: frameworks.path)) ?? []
        let renderer = { (name: String) in name.hasSuffix(" Helper (Renderer).app") }
        let found = names.contains(where: renderer) || names.filter { $0.hasSuffix(".framework") }.contains { framework in
            let helpers = frameworks.appendingPathComponent(framework).appendingPathComponent("Versions/Current/Helpers")
            return ((try? files.contentsOfDirectory(atPath: helpers.path)) ?? []).contains(where: renderer)
        }
        chromiumBundles[url] = found
        return found
    }

    func listApps() -> [[String: Any]] {
        let running = workspace.runningApplications.filter { !$0.isTerminated }
        var records: [String: [String: Any]] = [:]
        for url in installedApplications() {
            let metadata = applicationMetadata(url)
            if metadata.id == "dev.opencu.engine" { continue }
            records[url.path] = ["id": metadata.id, "displayName": metadata.name,
                                 "path": url.path, "isRunning": false]
        }
        for application in running {
            if application.processIdentifier == getpid() || application.bundleIdentifier == "dev.opencu.engine" { continue }
            let target = TargetApp(application: application)
            let key = application.bundleURL.map(canonicalURL)?.path ?? "pid:\(target.pid)"
            // Background agents and web content helpers are not apps to operate;
            // installed menu bar apps are kept.
            guard application.activationPolicy == .regular || records[key] != nil else { continue }
            var record = records[key] ?? ["id": target.id, "displayName": target.name]
            if let url = application.bundleURL { record["path"] = canonicalURL(url).path }
            record["isRunning"] = true
            var pids = record["pids"] as? [Int] ?? []
            pids.append(Int(target.pid))
            record["pids"] = pids.sorted()
            if pids.count == 1 { record["pid"] = Int(target.pid) }
            else { record.removeValue(forKey: "pid") }
            records[key] = record
        }
        return records.values.sorted {
            let first = $0["displayName"] as? String ?? ""
            let second = $1["displayName"] as? String ?? ""
            if first == second { return String(describing: $0["path"]) < String(describing: $1["path"]) }
            return first.localizedCaseInsensitiveCompare(second) == .orderedAscending
        }
    }

    func resolveApp(_ identifier: String, launch: Bool = true) async throws -> TargetApp {
        let query = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { throw OpenCUError("INVALID_ARGUMENT", "app must be a nonempty name, bundle identifier, or application path.") }
        let running = workspace.runningApplications.filter { !$0.isTerminated }
        if query.contains("/") {
            let url = canonicalURL(URL(fileURLWithPath: (query as NSString).expandingTildeInPath))
            guard url.pathExtension.lowercased() == "app", Bundle(url: url)?.executableURL != nil else {
                throw OpenCUError("APP_NOT_FOUND", "No application bundle exists at \(url.path).")
            }
            return try await resolveURL(url, running: running, launch: launch)
        }

        let bundleMatches = running.filter { matches($0.bundleIdentifier, query) }
        if !bundleMatches.isEmpty { return try uniqueRunningApp(bundleMatches, query: query) }
        let registered = uniqueURLs(workspace.urlsForApplications(withBundleIdentifier: query))
        if !registered.isEmpty {
            guard registered.count == 1 else { throw ambiguousApplication(query, urls: registered) }
            return try await resolveURL(registered[0], running: running, launch: launch)
        }

        let namedRunning = running.filter {
            matches($0.localizedName, query) || matches($0.bundleURL?.deletingPathExtension().lastPathComponent, query)
        }
        var candidates = installedApplications().filter {
            let metadata = applicationMetadata($0)
            return matches(metadata.name, query) || matches($0.deletingPathExtension().lastPathComponent, query)
                || matches(metadata.id, query)
        }
        candidates.append(contentsOf: namedRunning.compactMap(\.bundleURL))
        candidates = uniqueURLs(candidates)
        guard candidates.count <= 1 else { throw ambiguousApplication(query, urls: candidates) }
        if let url = candidates.first { return try await resolveURL(url, running: running, launch: launch) }
        if !namedRunning.isEmpty { return try uniqueRunningApp(namedRunning, query: query) }
        throw OpenCUError("APP_NOT_FOUND", "No application matches \(quoted(query)). Use list_apps or provide its full .app path.")
    }

    /// Menus the caller opened. Their items were populated and validated while
    /// open; AXPress still chooses them after the menu closes.
    private var expandedMenus: Set<AXIdentity> = []
    private var expandedMenusPID: pid_t = 0

    func record(_ effect: MenuEffect, pid: pid_t) {
        switch effect {
        case .none: return
        case .chose, .unconfirmed: expandedMenus = []
        case .opened(let menu):
            // Choosing another menu bar item replaces the previous menu path.
            if expandedMenusPID != pid || axString(menu, kAXRoleAttribute) == kAXMenuBarItemRole { expandedMenus = [] }
            expandedMenusPID = pid
            expandedMenus.insert(AXIdentity(menu))
        }
    }

    func observe(_ app: TargetApp, includeScreenshot: Bool) async throws -> Observation {
        try requireAccessibility()
        guard !app.application.isTerminated else { throw OpenCUError("APP_NOT_RUNNING", "\(app.name) is no longer running. Resolve the application again.") }
        let application = AXUIElementCreateApplication(app.pid)
        AXUIElementSetMessagingTimeout(application, 1)
        try await requestWebAccessibility(application, app)
        guard let window = try await observedWindow(application) else {
            let tree = accessibilityTree(window: nil, bounds: .zero, application: application, focused: nil,
                                         expanded: expandedMenusPID == app.pid ? expandedMenus : [])
            guard axSelectedWindow(application) == nil, axWindows(application).isEmpty else {
                throw OpenCUError("WINDOW_CHANGED", "A window appeared while observing the application; read its state again")
            }
            let note = "No accessible window is open. Use the menu bar or press_key shortcuts (for example Cmd+N or Cmd+O) to open one. Screenshots, coordinate input, typing and paste require a window."
            return Observation(text: (["App: \(quoted(app.name)) (\(app.id), pid \(app.pid), \(app.isFrontmost ? "foreground" : "background"))", note] + tree.lines).joined(separator: "\n"),
                               screenshot: nil,
                               snapshot: WindowSnapshot(app: app, window: nil, bounds: .zero, windowID: nil,
                                                        elements: tree.elements, elementPaths: tree.paths,
                                                        elementTraits: tree.traits,
                                                        screenshotWidth: nil, screenshotHeight: nil))
        }
        guard let bounds = axRect(window), usableBounds(bounds) else {
            throw OpenCUError("WINDOW_BOUNDS_UNAVAILABLE", "The selected window does not expose usable Accessibility bounds. Select a visible window and try again.")
        }
        var windowID = inputWindowID(app: app, window: window)
        willObserveWindow?(WindowSnapshot(app: app, window: window, bounds: bounds, windowID: windowID,
                                          elements: [:], elementPaths: [:], elementTraits: [:],
                                          screenshotWidth: nil, screenshotHeight: nil))
        let windowTitle = axString(window, kAXTitleAttribute) ?? ""
        let focused = elementAttribute(application, kAXFocusedUIElementAttribute)
        let tree = accessibilityTree(window: window, bounds: bounds, application: application, focused: focused,
                                     expanded: expandedMenusPID == app.pid ? expandedMenus : [])
        var lines = ["App: \(quoted(app.name)) (\(app.id), pid \(app.pid), \(app.isFrontmost ? "foreground" : "background"))",
                     "Window: \(quoted(windowTitle))",
                     "Window bounds: x=\(bounds.minX), y=\(bounds.minY), width=\(bounds.width), height=\(bounds.height) points."]
        lines.append(contentsOf: tree.lines)
        let presentation = windowID.flatMap(windowPresentation)
        // Visibility is not a capture capability test: Blender can retain a
        // full-size backing surface off-stage. Report the capture result below.
        let limits = "Background screenshots and window commands may be unavailable; Chromium web content may stop rendering"
        if let presentation, !presentation.onscreen {
            lines.append("This window is not on screen (hidden by Stage Manager or the app, or on another Space). \(limits). Keyboard input may not arrive; reading and exposed AX actions remain available. Use activate_app for steps that need more.")
        } else if let presentation, abs(presentation.size.width - bounds.width) > 1 || abs(presentation.size.height - bounds.height) > 1 {
            lines.append("Stage Manager shows this window only as a \(presentation.size.width) x \(presentation.size.height) point thumbnail. \(limits). Keyboard delivery depends on the app; reading and exposed AX actions remain available. Use activate_app for steps that need more.")
        } else if !tree.webContent, let url = app.application.bundleURL, isChromium(url) {
            lines.append("Web content unavailable: Chromium does not render pages in a fully covered window, so only browser controls are exposed. Use activate_app or keep the window visible, then read the state again.")
        }

        var screenshot: [String: Any]?
        var width: Int?
        var height: Int?
        if includeScreenshot {
            do {
                let captured = try await capture(app: app, window: window, windowID: windowID, bounds: bounds)
                screenshot = captured.image
                windowID = captured.windowID
                width = captured.width
                height = captured.height
                lines.append("Screenshot: \(captured.width) x \(captured.height) pixels. Coordinates start at the top-left of this window image; window shadows are excluded.")
            } catch let error as OpenCUError where Self.lastingCaptureFailures.contains(error.code) {
                // The text state remains valid; coordinate input stays unavailable without an image.
                lines.append("Screenshot unavailable (\(error.code)): \(error.message) Indexed elements above can still be used.")
            }
        }
        guard let currentWindow = axSelectedWindow(application), CFEqual(currentWindow, window),
              let currentBounds = axRect(window), sameBounds(currentBounds, bounds),
              (axString(window, kAXTitleAttribute) ?? "") == windowTitle else {
            throw OpenCUError("WINDOW_CHANGED", "The selected window changed while it was being observed. Read the application state again before interacting.")
        }
        let snapshot = WindowSnapshot(app: app, window: window, bounds: bounds, windowID: windowID,
                                      elements: tree.elements, elementPaths: tree.paths, elementTraits: tree.traits,
                                      screenshotWidth: width, screenshotHeight: height)
        if !app.isFrontmost, snapshot.isOpaque {
            lines.append("Background pointer and keyboard input is unsupported for this custom-drawn window (BACKGROUND_INPUT_UNSUPPORTED). Only title-bar decorations are accessible, so the engine cannot verify where input lands. Use activate_app explicitly, then read the state before input. Exposed AX actions remain available.")
        }
        return Observation(text: lines.joined(separator: "\n"), screenshot: screenshot, snapshot: snapshot)
    }

    private func resolveURL(_ url: URL, running: [NSRunningApplication], launch: Bool) async throws -> TargetApp {
        guard Bundle(url: url)?.bundleIdentifier != "dev.opencu.engine" else {
            throw OpenCUError("INVALID_TARGET", "OpenCU's own interface is reserved for the person and cannot be targeted.")
        }
        let existing = running.filter { $0.bundleURL.map(canonicalURL) == url }
        if !existing.isEmpty { return try uniqueRunningApp(existing, query: url.path) }
        guard launch else { throw OpenCUError("APP_NOT_RUNNING", "\(url.lastPathComponent) is not running.") }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.addsToRecentItems = false
        configuration.allowsRunningApplicationSubstitution = false
        do {
            let application = try await workspace.openApplication(at: url, configuration: configuration)
            return TargetApp(application: application)
        } catch {
            throw OpenCUError("APP_LAUNCH_FAILED", "Could not open \(url.lastPathComponent): \(error.localizedDescription)")
        }
    }

    private func uniqueRunningApp(_ applications: [NSRunningApplication], query: String) throws -> TargetApp {
        guard applications.count == 1 else {
            throw OpenCUError("AMBIGUOUS_APP", "Multiple running applications match \(quoted(query)). Use a full application path or close the extra instances. Matching process IDs: \(applications.map { String($0.processIdentifier) }.joined(separator: ", ")).")
        }
        return TargetApp(application: applications[0])
    }

    private func ambiguousApplication(_ query: String, urls: [URL]) -> OpenCUError {
        OpenCUError("AMBIGUOUS_APP", "Multiple applications match \(quoted(query)). Specify a full path: \(urls.map(\.path).sorted().joined(separator: "; ")).")
    }

    private func installedApplications() -> [URL] {
        let roots = [URL(fileURLWithPath: "/Applications"), URL(fileURLWithPath: "/System/Applications"),
                     URL(fileURLWithPath: "/System/Library/CoreServices"),
                     FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications")]
        var applications: [URL] = []
        for root in roots {
            guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey],
                                                                  options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
            for case let url as URL in enumerator where url.pathExtension.lowercased() == "app" {
                enumerator.skipDescendants()
                if Bundle(url: url)?.executableURL != nil { applications.append(url) }
            }
        }
        return uniqueURLs(applications)
    }

    private func applicationMetadata(_ url: URL) -> (id: String, name: String) {
        let info = Bundle(url: url)?.infoDictionary ?? [:]
        return (info["CFBundleIdentifier"] as? String ?? url.path, AppNames.name(appURL: url, info: info))
    }

    private func canonicalURL(_ url: URL) -> URL { url.standardizedFileURL.resolvingSymlinksInPath() }
    private func uniqueURLs(_ urls: [URL]) -> [URL] { Array(Set(urls.map(canonicalURL))).sorted { $0.path < $1.path } }
    private func matches(_ value: String?, _ query: String) -> Bool { value?.caseInsensitiveCompare(query) == .orderedSame }

    private func observedWindow(_ application: AXUIElement) async throws -> AXUIElement? {
        for attempt in 0..<8 {
            if let window = axSelectedWindow(application) {
                if axValue(window, kAXMinimizedAttribute) as? Bool == true {
                    throw OpenCUError("WINDOW_MINIMIZED", "The selected application window is minimized. Restore the intended window and try again.")
                }
                return window
            }
            if attempt < 7 { try await Task.sleep(nanoseconds: 125_000_000) }
        }
        let windows = axWindows(application)
        if windows.count > 1 {
            throw OpenCUError("AMBIGUOUS_WINDOW", "The application has several windows but no focused or main Accessibility window. Select the intended window and read its state again.")
        }
        return nil
    }

    private func elementAttribute(_ element: AXUIElement, _ name: String) -> AXUIElement? {
        guard let value = axValue(element, name), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private struct AXNode {
        static let attributes = [kAXRoleAttribute, kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute,
                                 kAXIdentifierAttribute, "AXPlaceholderValue", kAXEnabledAttribute, kAXSelectedAttribute,
                                 kAXExpandedAttribute, kAXPositionAttribute, kAXSizeAttribute,
                                 kAXRoleDescriptionAttribute] as CFArray
        static let containers: Set<String> = [kAXGroupRole, kAXUnknownRole, kAXSplitGroupRole, "AXLayoutArea", "AXLayoutItem"]
        static let passiveActions: Set<String> = ["AXShowMenu", "AXScrollToVisible"]
        static let editable: Set<String> = [kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole]

        let role: String
        let title, description, identifier, placeholder: String?
        /// A container's localized kind, such as a web landmark, video or dialog.
        let kind: String?
        let value: CFTypeRef?
        let enabled, selected, expanded: Bool?
        let frame: CGRect?
        let actions: [String]

        /// One IPC round trip for the attributes, one for the actions.
        init(_ element: AXUIElement) {
            var raw: CFArray?
            var values = [AnyObject?](repeating: nil, count: CFArrayGetCount(Self.attributes))
            if AXUIElementCopyMultipleAttributeValues(element, Self.attributes, AXCopyMultipleAttributeOptions(rawValue: 0), &raw) == .success,
               let array = raw as? [AnyObject], array.count == values.count {
                values = array.map { value in
                    CFGetTypeID(value) == AXValueGetTypeID() && AXValueGetType(value as! AXValue) == .axError ? nil : value
                }
            }
            let text = { (index: Int) in (values[index] as? String).flatMap { $0.isEmpty ? nil : $0 } }
            role = values[0] as? String ?? "AXUnknown"
            title = text(1); description = text(2); identifier = text(4); placeholder = text(5)
            value = values[3]
            enabled = values[6] as? Bool; selected = values[7] as? Bool; expanded = values[8] as? Bool
            var point = CGPoint.zero, size = CGSize.zero
            if let position = values[9], let extent = values[10], CFGetTypeID(position) == AXValueGetTypeID(),
               CFGetTypeID(extent) == AXValueGetTypeID(), AXValueGetValue(position as! AXValue, .cgPoint, &point),
               AXValueGetValue(extent as! AXValue, .cgSize, &size) {
                frame = CGRect(origin: point, size: size)
            } else { frame = nil }
            // Web pages mark nearly every container; only a kind other than the
            // role's ordinary description, such as a form or dialog, is useful.
            // Info.plist lets AppKit describe roles in the user's language.
            let ordinary = NSAccessibility.Role(rawValue: role).description(with: nil)
            kind = Self.containers.contains(role) ? text(11).flatMap { $0 == ordinary ? nil : $0 } : nil
            var names: CFArray?
            actions = AXUIElementCopyActionNames(element, &names) == .success ? names as? [String] ?? [] : []
        }

        /// Text made only of private-use characters is an icon font glyph, not readable text.
        var valueText: String? {
            if let text = value as? String {
                let icon = text.unicodeScalars.allSatisfy { (0xE000...0xF8FF).contains($0.value) || $0.value >= 0xF0000 }
                return text.isEmpty || icon ? nil : text
            }
            return (value as? NSNumber).map { "\($0)" }
        }

        /// Unlabelled layout containers and text without readable text are omitted;
        /// their children take their place.
        var informative: Bool {
            guard Self.containers.contains(role) || role == kAXStaticTextRole else { return true }
            return kind != nil || title != nil || description != nil || identifier != nil || placeholder != nil
                || valueText != nil || actions.contains { !Self.passiveActions.contains($0) }
        }
    }

    private func accessibilityTree(window: AXUIElement?, bounds: CGRect, application: AXUIElement, focused: AXUIElement?,
                                   expanded: Set<AXIdentity>) -> (lines: [String], elements: [Int: AXUIElement], paths: [Int: [AXUIElement]], traits: [Int: ObservedElementTraits], webContent: Bool) {
        var lines: [String] = []
        var elements: [Int: AXUIElement] = [:]
        var paths: [Int: [AXUIElement]] = [:]
        var traits: [Int: ObservedElementTraits] = [:]
        var indexes: [AXIdentity: Int] = [:]
        var webContent = false
        var inspected = Set<AXIdentity>()
        // Element, printed depth, nesting depth, menu bar membership, and the
        // nearest printed ancestor's label.
        var pending: [(AXUIElement, Int, Int, Bool, String?, [AXUIElement])] = []
        if let menuBar = elementAttribute(application, kAXMenuBarAttribute) { pending.append((menuBar, 0, 0, true, nil, [menuBar])) }
        if let window { pending.append((window, 0, 0, false, nil, [window])) }
        let focusedIdentity = focused.map(AXIdentity.init)
        let deadline = Date().addingTimeInterval(4)
        var characters = 0
        var outside = 0
        var nestingLimited = false
        var childListLimited = false
        var stopReason: String?
        while let (element, depth, nesting, inMenuBar, label, path) = pending.popLast() {
            let identity = AXIdentity(element)
            guard inspected.insert(identity).inserted else { continue }
            if elements.count >= maximumElements { stopReason = "\(maximumElements) element limit"; break }
            if inspected.count > maximumInspected { stopReason = "\(maximumInspected) inspected element limit"; break }
            if Date() >= deadline { stopReason = "4 second traversal limit"; break }
            AXUIElementSetMessagingTimeout(element, 0.5)
            let node = AXNode(element)
            // Content scrolled outside the window is skipped with its subtree.
            // Menu bar items lie outside every window and are always listed.
            if !inMenuBar, let frame = node.frame, frame.width > 0, frame.height > 0, !frame.intersects(bounds) {
                outside += 1
                continue
            }
            var childDepth = depth
            var childLabel = label
            // A link or button's own text child repeats its label.
            let repeatsLabel = node.role == kAXStaticTextRole && label != nil && node.valueText == label
            if (node.informative && !repeatsLabel) || identity == focusedIdentity {
                let index = elements.count + 1
                let line = String(repeating: "  ", count: depth) + "[\(index)] " + describe(element, node, focused: focusedIdentity)
                if characters + line.count > maximumTextCharacters { stopReason = "\(maximumTextCharacters) character limit"; break }
                elements[index] = element
                paths[index] = path
                traits[index] = ObservedElementTraits(role: node.role,
                    hasLabel: [node.title, node.description, node.identifier, node.placeholder, node.valueText, node.kind].contains { $0 != nil },
                    actions: node.actions.filter { !AXNode.passiveActions.contains($0) }.map(axActionLabel))
                indexes[identity] = index
                lines.append(line)
                characters += line.count + 1
                childDepth += 1
                childLabel = node.title ?? node.description
            }
            if node.role == kAXMenuBarItemRole || node.role == kAXMenuItemRole,
               node.selected != true, node.expanded != true, !expanded.contains(identity) {
                continue // Read submenu contents after the caller opens them.
            }
            var childCount: CFIndex = 0
            guard AXUIElementGetAttributeValueCount(element, kAXChildrenAttribute as CFString, &childCount) == .success,
                  childCount > 0 else { continue }
            if node.role == "AXWebArea" { webContent = true }
            if nesting >= maximumNesting {
                nestingLimited = true
            } else {
                let count = min(childCount, max(0, maximumInspected - inspected.count - pending.count))
                childListLimited = childListLimited || count < childCount
                var values: CFArray?
                if count > 0, AXUIElementCopyAttributeValues(element, kAXChildrenAttribute as CFString, 0, count, &values) == .success,
                   let children = values as? [AXUIElement] {
                    pending.append(contentsOf: children.reversed().map { ($0, childDepth, nesting + 1, inMenuBar, childLabel, path + [$0]) })
                }
            }
        }
        if let stopReason { lines.append("Tree truncated: \(stopReason). Remaining descendants were not inspected.") }
        if nestingLimited { lines.append("Tree truncated: descendants nested deeper than \(maximumNesting) levels were not inspected.") }
        if childListLimited { lines.append("Tree truncated: child lists exceeded the remaining \(maximumInspected) inspected element budget.") }
        if outside > 0 { lines.append("\(outside) element groups outside the window bounds were omitted; scroll to bring them into view.") }
        // A focused element outside the traversed roots must not acquire an
        // index: AXFocusedUIElement alone does not prove window membership.
        if let focusedIdentity, let index = indexes[focusedIdentity] {
            lines.append("Focused element: [\(index)].")
        } else { lines.append("Focused element: unavailable within the observed window/menu bar.") }
        return (lines, elements, paths, traits, webContent)
    }

    private func describe(_ element: AXUIElement, _ node: AXNode, focused: AXIdentity?) -> String {
        let englishRole = (node.role.hasPrefix("AX") ? String(node.role.dropFirst(2)) : node.role)
            .replacingOccurrences(of: "([a-z0-9])([A-Z])", with: "$1 $2", options: .regularExpression)
        var parts = [englishRole]
        if let kind = node.kind { parts.append("kind=\(quoted(kind, limit: 128))") }
        if let title = node.title { parts.append("title=\(quoted(title, limit: 512))") }
        if let description = node.description, description != node.title {
            parts.append("description=\(quoted(description, limit: 512))")
        }
        if let placeholder = node.placeholder, placeholder != node.title, placeholder != node.description {
            parts.append("placeholder=\(quoted(placeholder, limit: 512))")
        }
        if node.value is String, let text = node.valueText { parts.append("value=\(quoted(text, limit: 2048))") }
        else if let number = node.value as? NSNumber { parts.append("value=\(number)") }
        if let identifier = node.identifier { parts.append("ID=\(quoted(identifier, limit: 512))") }
        var settable = DarwinBoolean(false)
        if node.valueText != nil || AXNode.editable.contains(node.role),
           AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable) == .success, settable.boolValue {
            parts.append("settable")
        }
        if node.enabled == false { parts.append("disabled") }
        if let focused, AXIdentity(element) == focused { parts.append("focused") }
        // Context-menu and scroll-into-view actions are on nearly every element.
        let actions = node.actions.filter { !AXNode.passiveActions.contains($0) }.map(axActionLabel)
        if !actions.isEmpty { parts.append("Secondary Actions: \(actions.joined(separator: ", "))") }
        return parts.joined(separator: " ")
    }

    private func capture(app: TargetApp, window: AXUIElement, windowID: CGWindowID?, bounds: CGRect) async throws -> (image: [String: Any], windowID: CGWindowID, width: Int, height: Int) {
        try requireCaptureAllowed?()
        try Task.checkCancellation()
        try EngineResponsibility.requireCapture()
        guard let windowID else {
            throw OpenCUError("WINDOW_ID_UNAVAILABLE", "The selected Accessibility window could not be linked to a WindowServer window. This macOS version may not support the required window identity lookup. Text-only observation remains available.")
        }
        let content: SCShareableContent
        do { content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false) }
        catch { throw OpenCUError("SCREENSHOT_UNAVAILABLE", "Could not enumerate capture windows: \(error.localizedDescription)") }
        let matches = content.windows.filter { $0.owningApplication?.processID == app.pid && $0.windowID == windowID }
        guard matches.count == 1 else {
            let message = matches.isEmpty ? "The selected Accessibility window's exact window ID is not available for capture."
                : "Several capture entries share the selected Accessibility window's exact ID."
            throw OpenCUError("SCREENSHOT_WINDOW_UNAVAILABLE", message + " A hidden window or a Stage Manager thumbnail cannot be captured; use activate_app to show it. No other window was captured.")
        }
        let selected = matches[0]
        let filter = SCContentFilter(desktopIndependentWindow: selected)
        let scale = CGFloat(filter.pointPixelScale)
        guard scale.isFinite, scale > 0,
              abs(filter.contentRect.width - bounds.width) <= 1,
              abs(filter.contentRect.height - bounds.height) <= 1 else {
            throw OpenCUError("SCREENSHOT_THUMBNAIL", "Stage Manager shows this window as a \(filter.contentRect.width) x \(filter.contentRect.height) point thumbnail instead of its \(bounds.width) x \(bounds.height) point window, and macOS provides no full image of it. Use activate_app to show the window, then read it again.")
        }
        let pixelWidth = (bounds.width * scale).rounded()
        let pixelHeight = (bounds.height * scale).rounded()
        guard pixelWidth >= 1, pixelHeight >= 1, pixelWidth <= 16_384, pixelHeight <= 16_384,
              pixelWidth * pixelHeight <= 64_000_000 else {
            throw OpenCUError("SCREENSHOT_TOO_LARGE", "This window is too large to capture. Resize the intended window or request text-only state.")
        }
        let configuration = SCStreamConfiguration()
        configuration.width = Int(pixelWidth)
        configuration.height = Int(pixelHeight)
        configuration.showsCursor = false
        configuration.ignoreShadowsSingleWindow = true
        configuration.ignoreGlobalClipSingleWindow = true
        configuration.captureResolution = .best
        if #available(macOS 14.2, *) { configuration.includeChildWindows = false }
        let image: CGImage
        try EngineResponsibility.requireCapture() // Recheck after asynchronous enumeration.
        do { image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration) }
        catch { throw OpenCUError("SCREENSHOT_FAILED", "Could not capture the selected window: \(error.localizedDescription)") }
        try requireCaptureAllowed?()
        try Task.checkCancellation()
        guard image.width == configuration.width, image.height == configuration.height,
              let currentBounds = axRect(window), sameBounds(currentBounds, bounds) else {
            throw OpenCUError("SCREENSHOT_GEOMETRY_MISMATCH", "The window geometry changed during capture. Read its state again before using coordinates.")
        }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else {
            throw OpenCUError("SCREENSHOT_ENCODING_FAILED", "Could not prepare the window PNG image.")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw OpenCUError("SCREENSHOT_ENCODING_FAILED", "Could not encode the window PNG image.") }
        return (["data": (data as Data).base64EncodedString(), "mimeType": "image/png", "width": image.width, "height": image.height],
                selected.windowID, image.width, image.height)
    }

    /// How WindowServer presents the window: its composited size differs from the
    /// Accessibility size for a Stage Manager thumbnail, and a hidden window is
    /// not on screen. No capture permission is needed.
    private func windowPresentation(_ windowID: CGWindowID) -> (size: CGSize, onscreen: Bool)? {
        guard let records = CGWindowListCopyWindowInfo(.optionIncludingWindow, windowID) as? [[String: Any]],
              let record = records.first(where: { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value == windowID }),
              let dictionary = record[kCGWindowBounds as String] as? NSDictionary,
              let rect = CGRect(dictionaryRepresentation: dictionary as CFDictionary) else { return nil }
        return (rect.size, record[kCGWindowIsOnscreen as String] as? Bool ?? false)
    }

    // Stage Manager can translate or scale rendered windows independently of AX
    // bounds. This OS-exported SPI links the actual AX window to its WindowServer
    // ID without guessing by title or geometry. Its availability and result are
    // checked at runtime; it is an explicit macOS compatibility boundary.
    private func inputWindowID(app: TargetApp, window: AXUIElement) -> CGWindowID? {
        var owner: pid_t = 0
        guard AXUIElementGetPid(window, &owner) == .success, owner == app.pid else { return nil }
        let framework = "/System/Library/Frameworks/ApplicationServices.framework/Frameworks/HIServices.framework/HIServices"
        guard let handle = dlopen(framework, RTLD_LAZY | RTLD_LOCAL) else { return nil }
        defer { dlclose(handle) }
        guard let address = dlsym(handle, "_AXUIElementGetWindow") else { return nil }
        typealias GetWindow = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> Int32
        let getWindow = unsafeBitCast(address, to: GetWindow.self)
        var windowID: CGWindowID = 0
        guard getWindow(window, &windowID) == AXError.success.rawValue, windowID != kCGNullWindowID else { return nil }
        return windowID
    }

    private func usableBounds(_ bounds: CGRect) -> Bool {
        [bounds.origin.x, bounds.origin.y, bounds.width, bounds.height].allSatisfy(\.isFinite)
            && bounds.width > 0 && bounds.height > 0
    }

    private func sameBounds(_ first: CGRect, _ second: CGRect) -> Bool {
        usableBounds(first) && usableBounds(second)
            && abs(first.minX - second.minX) <= 1 && abs(first.minY - second.minY) <= 1
            && abs(first.width - second.width) <= 1 && abs(first.height - second.height) <= 1
    }

    private func quoted(_ text: String, limit: Int = 2048) -> String {
        let value = text.count > limit ? String(text.prefix(limit)) + "… [truncated]" : text
        return String(reflecting: value)
    }
}
