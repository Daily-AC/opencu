import AppKit
import ApplicationServices
import Darwin
import ImageIO
import ScreenCaptureKit

@MainActor
final class MacObserver {
    private let workspace = NSWorkspace.shared
    private let maximumElements = 800
    private let maximumDepth = 18
    private let maximumTextCharacters = 180_000

    func listApps() -> [[String: Any]] {
        let running = workspace.runningApplications.filter { !$0.isTerminated }
        var records: [String: [String: Any]] = [:]
        for url in installedApplications() {
            let metadata = applicationMetadata(url)
            records[url.path] = ["id": metadata.id, "displayName": metadata.name,
                                 "path": url.path, "isRunning": false]
        }
        for application in running {
            let target = TargetApp(application: application)
            let key = application.bundleURL.map(canonicalURL)?.path ?? "pid:\(target.pid)"
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
        case .chose: expandedMenus = []
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
        let window = try await observedWindow(application)
        guard let bounds = axRect(window), usableBounds(bounds) else {
            throw OpenCUError("WINDOW_BOUNDS_UNAVAILABLE", "The selected window does not expose usable Accessibility bounds. Select a visible window and try again.")
        }
        let windowTitle = axString(window, kAXTitleAttribute) ?? ""
        let focused = elementAttribute(application, kAXFocusedUIElementAttribute)
        let tree = accessibilityTree(window: window, application: application, focused: focused,
                                     expanded: expandedMenusPID == app.pid ? expandedMenus : [])
        var lines = ["App: \(quoted(app.name)) (\(app.id), pid \(app.pid), \(app.application.isActive ? "foreground" : "background"))",
                     "Window: \(quoted(windowTitle))",
                     "Window bounds: x=\(bounds.minX), y=\(bounds.minY), width=\(bounds.width), height=\(bounds.height) points."]
        lines.append(contentsOf: tree.lines)

        var screenshot: [String: Any]?
        var windowID = inputWindowID(app: app, window: window)
        var width: Int?
        var height: Int?
        if includeScreenshot {
            let captured = try await capture(app: app, window: window, windowID: windowID, bounds: bounds)
            screenshot = captured.image
            windowID = captured.windowID
            width = captured.width
            height = captured.height
            lines.append("Screenshot: \(captured.width) x \(captured.height) pixels. Coordinates start at the top-left of this window image; window shadows are excluded.")
        }
        guard let currentWindow = selectedWindow(application), CFEqual(currentWindow, window),
              let currentBounds = axRect(window), sameBounds(currentBounds, bounds),
              (axString(window, kAXTitleAttribute) ?? "") == windowTitle else {
            throw OpenCUError("WINDOW_CHANGED", "The selected window changed while it was being observed. Read the application state again before interacting.")
        }
        return Observation(text: lines.joined(separator: "\n"), screenshot: screenshot,
                           snapshot: WindowSnapshot(app: app, window: window, bounds: bounds, windowID: windowID,
                                                    elements: tree.elements, screenshotWidth: width, screenshotHeight: height))
    }

    private func resolveURL(_ url: URL, running: [NSRunningApplication], launch: Bool) async throws -> TargetApp {
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
        let bundle = Bundle(url: url)
        let name = bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? url.deletingPathExtension().lastPathComponent
        return (bundle?.bundleIdentifier ?? url.path, name)
    }

    private func canonicalURL(_ url: URL) -> URL { url.standardizedFileURL.resolvingSymlinksInPath() }
    private func uniqueURLs(_ urls: [URL]) -> [URL] { Array(Set(urls.map(canonicalURL))).sorted { $0.path < $1.path } }
    private func matches(_ value: String?, _ query: String) -> Bool { value?.caseInsensitiveCompare(query) == .orderedSame }

    private func observedWindow(_ application: AXUIElement) async throws -> AXUIElement {
        for attempt in 0..<8 {
            if let window = selectedWindow(application) {
                if axValue(window, kAXMinimizedAttribute) as? Bool == true {
                    throw OpenCUError("WINDOW_MINIMIZED", "The selected application window is minimized. Restore the intended window and try again.")
                }
                return window
            }
            if attempt < 7 { try await Task.sleep(nanoseconds: 125_000_000) }
        }
        let windows = axValue(application, kAXWindowsAttribute) as? [AXUIElement] ?? []
        if windows.count > 1 {
            throw OpenCUError("AMBIGUOUS_WINDOW", "The application has several windows but no focused or main Accessibility window. Select the intended window and read its state again.")
        }
        throw OpenCUError("NO_ACCESSIBLE_WINDOW", "The application does not expose an accessible window yet. Open its intended window, confirm Accessibility permission, and try again.")
    }

    private func selectedWindow(_ application: AXUIElement) -> AXUIElement? {
        if let focused = elementAttribute(application, kAXFocusedWindowAttribute) { return focused }
        if let main = elementAttribute(application, kAXMainWindowAttribute) { return main }
        let windows = axValue(application, kAXWindowsAttribute) as? [AXUIElement] ?? []
        return windows.count == 1 ? windows[0] : nil
    }

    private func elementAttribute(_ element: AXUIElement, _ name: String) -> AXUIElement? {
        guard let value = axValue(element, name), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private func accessibilityTree(window: AXUIElement, application: AXUIElement, focused: AXUIElement?,
                                   expanded: Set<AXIdentity>) -> (lines: [String], elements: [Int: AXUIElement]) {
        var lines: [String] = []
        var elements: [Int: AXUIElement] = [:]
        var indexes: [AXIdentity: Int] = [:]
        var pending: [(AXUIElement, Int)] = []
        if let menuBar = elementAttribute(application, kAXMenuBarAttribute) { pending.append((menuBar, 0)) }
        pending.append((window, 0))
        let deadline = Date().addingTimeInterval(4)
        var characters = 0
        var depthLimited = false
        var childListLimited = false
        var stopReason: String?
        while let (element, depth) = pending.popLast() {
            if indexes[AXIdentity(element)] != nil { continue }
            if elements.count >= maximumElements { stopReason = "\(maximumElements) element limit"; break }
            if Date() >= deadline { stopReason = "4 second traversal limit"; break }
            AXUIElementSetMessagingTimeout(element, 0.5)
            let index = elements.count + 1
            let line = String(repeating: "  ", count: depth) + "[\(index)] " + describe(element, focused: focused)
            if characters + line.count > maximumTextCharacters { stopReason = "\(maximumTextCharacters) character limit"; break }
            elements[index] = element
            indexes[AXIdentity(element)] = index
            lines.append(line)
            characters += line.count + 1
            let role = axString(element, kAXRoleAttribute)
            if role == kAXMenuBarItemRole || role == kAXMenuItemRole {
                let open = axValue(element, kAXSelectedAttribute) as? Bool == true
                    || axValue(element, kAXExpandedAttribute) as? Bool == true
                if !open && !expanded.contains(AXIdentity(element)) { continue } // Read submenu contents after the caller opens them.
            }
            var childCount: CFIndex = 0
            guard AXUIElementGetAttributeValueCount(element, kAXChildrenAttribute as CFString, &childCount) == .success,
                  childCount > 0 else { continue }
            if depth >= maximumDepth {
                depthLimited = true
            } else {
                let count = min(childCount, max(0, maximumElements - elements.count - pending.count))
                childListLimited = childListLimited || count < childCount
                var values: CFArray?
                if count > 0, AXUIElementCopyAttributeValues(element, kAXChildrenAttribute as CFString, 0, count, &values) == .success,
                   let children = values as? [AXUIElement] {
                    pending.append(contentsOf: children.reversed().map { ($0, depth + 1) })
                }
            }
        }
        if let stopReason { lines.append("Tree truncated: \(stopReason). Remaining descendants were not inspected.") }
        if depthLimited { lines.append("Tree truncated: descendants below depth \(maximumDepth) were not inspected.") }
        if childListLimited { lines.append("Tree truncated: child lists exceeded the remaining \(maximumElements) element budget.") }
        if let focused {
            let index: Int
            if let existing = indexes[AXIdentity(focused)] { index = existing }
            else {
                index = elements.count + 1
                elements[index] = focused
                AXUIElementSetMessagingTimeout(focused, 0.5)
                lines.append("[\(index)] " + describe(focused, focused: focused))
            }
            lines.append("Focused element: [\(index)].")
        } else { lines.append("Focused element: unavailable.") }
        return (lines, elements)
    }

    private func describe(_ element: AXUIElement, focused: AXUIElement?) -> String {
        let role = axString(element, kAXRoleAttribute) ?? "AXUnknown"
        let englishRole = (role.hasPrefix("AX") ? String(role.dropFirst(2)) : role)
            .replacingOccurrences(of: "([a-z0-9])([A-Z])", with: "$1 $2", options: .regularExpression)
        var parts = [englishRole]
        let title = axString(element, kAXTitleAttribute)
        if let title, !title.isEmpty { parts.append("title=\(quoted(title, limit: 512))") }
        if let description = axString(element, kAXDescriptionAttribute), !description.isEmpty, description != title {
            parts.append("description=\(quoted(description, limit: 512))")
        }
        if let value = axValue(element, kAXValueAttribute) {
            if let text = value as? String { parts.append("value=\(quoted(text, limit: 2048))") }
            else if let number = value as? NSNumber { parts.append("value=\(number)") }
        }
        if let identifier = axString(element, kAXIdentifierAttribute), !identifier.isEmpty {
            parts.append("ID=\(quoted(identifier, limit: 512))")
        }
        var settable = DarwinBoolean(false)
        if AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable) == .success, settable.boolValue {
            parts.append("settable")
        }
        if axValue(element, kAXEnabledAttribute) as? Bool == false { parts.append("disabled") }
        if let focused, CFEqual(element, focused) { parts.append("focused") }
        var names: CFArray?
        if AXUIElementCopyActionNames(element, &names) == .success, let actions = names as? [String], !actions.isEmpty {
            parts.append("Secondary Actions: \(actions.joined(separator: ", "))")
        }
        return parts.joined(separator: " ")
    }

    private func capture(app: TargetApp, window: AXUIElement, windowID: CGWindowID?, bounds: CGRect) async throws -> (image: [String: Any], windowID: CGWindowID, width: Int, height: Int) {
        guard CGPreflightScreenCaptureAccess() else {
            throw OpenCUError("SCREEN_RECORDING_PERMISSION_REQUIRED", "Screenshots need macOS Screen Recording permission. Run opencu setup, grant access in System Settings, then reconnect. Text-only observations do not require Screen Recording.")
        }
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
            throw OpenCUError("SCREENSHOT_WINDOW_AMBIGUOUS", message + " If Stage Manager reduced it to a thumbnail, use activate_app and read it again. No other window was captured.")
        }
        let selected = matches[0]
        let filter = SCContentFilter(desktopIndependentWindow: selected)
        let scale = CGFloat(filter.pointPixelScale)
        guard scale.isFinite, scale > 0,
              abs(filter.contentRect.width - bounds.width) <= 1,
              abs(filter.contentRect.height - bounds.height) <= 1 else {
            throw OpenCUError("SCREENSHOT_GEOMETRY_MISMATCH", "The capture content size is \(filter.contentRect.width) x \(filter.contentRect.height) points, but the observed window is \(bounds.width) x \(bounds.height) points. Stage Manager may be showing a thumbnail. Use activate_app to restore the full window, then read it again before using coordinates.")
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
        do { image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration) }
        catch { throw OpenCUError("SCREENSHOT_FAILED", "Could not capture the selected window: \(error.localizedDescription)") }
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

private struct AXIdentity: Hashable {
    let element: AXUIElement
    init(_ element: AXUIElement) { self.element = element }
    static func == (lhs: Self, rhs: Self) -> Bool { CFEqual(lhs.element, rhs.element) }
    func hash(into hasher: inout Hasher) { hasher.combine(CFHash(element)) }
}
