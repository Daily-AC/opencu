// Standalone AppKit acceptance fixture. It records only events delivered to its
// own controls; it never observes global input or reads other applications.
// Build from the repository root (the bundle needs CFBundleIdentifier
// dev.opencu.fixture and CFBundleExecutable OpenCUFixture in Contents/Info.plist):
// xcrun swiftc tests/fixtures/OpenCUFixture.swift -target arm64-apple-macosx14.0 \
//   -framework AppKit -o '.cache/opencu-independent/OpenCU Fixture.app/Contents/MacOS/OpenCUFixture'
// codesign --force --sign - --identifier dev.opencu.fixture \
//   '.cache/opencu-independent/OpenCU Fixture.app'
// Launch with --output /absolute/path/to/fixture-state.json. No GUI launches
// are performed by the build command.

import AppKit
import CryptoKit

final class InputProbe: NSView {
    private(set) var events: [[String: Any]] = []
    private(set) var eventCount = 0
    private(set) var marker = CGPoint(x: 100, y: 105)
    private var draggingMarker = false

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityIdentifier("inputProbe")
        setAccessibilityLabel("Input probe")
        setAccessibilityHelp("Blue area for mouse, keyboard, drag, and scroll acceptance tests.")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func becomeFirstResponder() -> Bool { needsDisplay = true; return true }
    override func resignFirstResponder() -> Bool { needsDisplay = true; return true }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.systemBlue.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 10, yRadius: 10).fill()
        if window?.firstResponder === self {
            NSColor.white.withAlphaComponent(0.8).setStroke()
            let focus = NSBezierPath(roundedRect: bounds.insetBy(dx: 5, dy: 5), xRadius: 7, yRadius: 7)
            focus.lineWidth = 2
            focus.stroke()
        }
        drawText("Input probe", at: CGPoint(x: 18, y: 16), size: 16, weight: .semibold)
        drawText("Click, hold a key, drag the white marker, or scroll.", at: CGPoint(x: 18, y: 42), size: 12)
        NSColor.white.setFill()
        NSBezierPath(ovalIn: NSRect(x: marker.x - 17, y: marker.y - 17, width: 34, height: 34)).fill()
        NSColor.systemBlue.setFill()
        NSBezierPath(ovalIn: NSRect(x: marker.x - 4, y: marker.y - 4, width: 8, height: 8)).fill()
        drawText("Events: \(eventCount)", at: CGPoint(x: 18, y: bounds.height - 27), size: 12)
    }

    private func drawText(_ text: String, at point: CGPoint, size: CGFloat, weight: NSFont.Weight = .regular) {
        (text as NSString).draw(at: point, withAttributes: [.font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: NSColor.white])
    }

    private func record(_ kind: String, _ event: NSEvent, pointer: Bool = false, keyboard: Bool = false, scroll: Bool = false) {
        eventCount += 1
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var value: [String: Any] = ["sequence": eventCount, "kind": kind, "time": event.timestamp,
                                    "flags": flags.rawValue, "shift": flags.contains(.shift),
                                    "control": flags.contains(.control), "option": flags.contains(.option),
                                    "command": flags.contains(.command), "capsLock": flags.contains(.capsLock)]
        if pointer || scroll {
            let point = convert(event.locationInWindow, from: nil)
            value["x"] = point.x
            value["y"] = point.y
        }
        if pointer {
            value["button"] = event.buttonNumber
            value["clickCount"] = event.clickCount
        }
        if keyboard {
            value["keyCode"] = event.keyCode
            value["characters"] = event.characters ?? ""
            value["isRepeat"] = event.isARepeat
        }
        if scroll {
            value["deltaX"] = event.scrollingDeltaX
            value["deltaY"] = event.scrollingDeltaY
            value["precise"] = event.hasPreciseScrollingDeltas
        }
        events.append(value)
        if events.count > 100 { events.removeFirst(events.count - 100) }
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        draggingMarker = hypot(point.x - marker.x, point.y - marker.y) <= 24
        record("mouseDown", event, pointer: true)
    }
    override func mouseUp(with event: NSEvent) { record("mouseUp", event, pointer: true); draggingMarker = false }
    override func rightMouseDown(with event: NSEvent) { window?.makeFirstResponder(self); record("rightMouseDown", event, pointer: true) }
    override func rightMouseUp(with event: NSEvent) { record("rightMouseUp", event, pointer: true) }
    override func otherMouseDown(with event: NSEvent) { window?.makeFirstResponder(self); record("otherMouseDown", event, pointer: true) }
    override func otherMouseUp(with event: NSEvent) { record("otherMouseUp", event, pointer: true) }
    override func mouseDragged(with event: NSEvent) {
        if draggingMarker {
            let point = convert(event.locationInWindow, from: nil)
            marker = CGPoint(x: min(max(20, point.x), bounds.width - 20), y: min(max(74, point.y), bounds.height - 38))
        }
        record("mouseDragged", event, pointer: true)
    }
    override func rightMouseDragged(with event: NSEvent) { record("rightMouseDragged", event, pointer: true) }
    override func otherMouseDragged(with event: NSEvent) { record("otherMouseDragged", event, pointer: true) }
    override func keyDown(with event: NSEvent) { record("keyDown", event, keyboard: true) }
    override func keyUp(with event: NSEvent) { record("keyUp", event, keyboard: true) }
    override func flagsChanged(with event: NSEvent) { record("flagsChanged", event) }
    override func scrollWheel(with event: NSEvent) { record("scrollWheel", event, scroll: true) }
}

final class FixtureDelegate: NSObject, NSApplicationDelegate, NSTextFieldDelegate, NSMenuDelegate, NSMenuItemValidation {
    private let output: URL
    private var window: NSWindow!
    private var clicks = 0
    private let counterValue = NSTextField(labelWithString: "Clicks: 0")
    private let textField = NSTextField(string: "")
    private let notes = NSTextView()
    private let slider = NSSlider(value: 25, minValue: 0, maxValue: 100, target: nil, action: nil)
    private let sliderValue = NSTextField(labelWithString: "25")
    private let checkbox = NSButton(checkboxWithTitle: "Enabled", target: nil, action: nil)
    private let probe = InputProbe(frame: .zero)
    private let bottomScroll = NSScrollView()
    private var lastTextSelection = NSRange(location: 0, length: 0)
    private var timer: Timer?
    private var selectionObserver: NSObjectProtocol?
    private var reportedWriteFailure = false
    private var localEventMonitor: Any?
    private var windowEvents: [[String: Any]] = []
    private var activationObserver: NSObjectProtocol?
    private var activations: [[String: Any]] = []
    private var menuObserver: NSObjectProtocol?
    private var menuActions: [String] = []
    private var menuTrackingObservers: [NSObjectProtocol] = []
    private var menuTracking: [[String: Any]] = []
    private var menuUpdates = 0
    private var validations = 0
    private var gatedActions = 0
    private var savePanel: NSSavePanel?
    private var savedPath = ""
    private var panelError = ""
    private var newCommands = 0
    private var openCommands = 0
    private var auxiliaryWindow: NSWindow?
    private var saveDirectory: URL { output.deletingLastPathComponent().appendingPathComponent("saved") }

    init(output: URL) { self.output = output }

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu()
        window = NSWindow(contentRect: NSRect(x: 160, y: 80, width: 700, height: 750),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "OpenCU Acceptance Fixture"
        window.isReleasedWhenClosed = false
        // Keep this disposable fixture in the ordinary window compositor so the
        // same test covers obscured background windows even with Stage Manager
        // enabled. --stage-managed separately reproduces transformed thumbnails.
        if !CommandLine.arguments.contains("--stage-managed") { window.collectionBehavior = .canJoinAllApplications }
        window.setAccessibilityIdentifier("acceptanceWindow")
        window.minSize = NSSize(width: 650, height: 745)
        let container = window.contentView!
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
                                     stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),
                                     stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 20)])

        let title = NSTextField(labelWithString: "OpenCU acceptance controls")
        title.font = .systemFont(ofSize: 18, weight: .semibold)
        add(title, to: stack, height: 24)

        let button = NSButton(title: "Add click", target: self, action: #selector(incrementCounter))
        button.bezelStyle = .rounded
        button.setAccessibilityIdentifier("counterButton")
        counterValue.setAccessibilityIdentifier("counterValue")
        let counterRow = horizontal([button, counterValue])
        add(counterRow, to: stack, height: 34)

        textField.placeholderString = "Single-line text"
        textField.font = .systemFont(ofSize: 14)
        textField.delegate = self
        textField.setAccessibilityIdentifier("textField")
        textField.setAccessibilityLabel("Single-line text")
        add(textField, to: stack, height: 30)

        notes.string = "First line\nSecond line"
        configureTextView(notes, identifier: "notes")
        notes.isEditable = true
        notes.isSelectable = true
        notes.allowsUndo = true
        notes.setAccessibilityLabel("Notes")
        let noteScroll = NSScrollView()
        noteScroll.borderType = .bezelBorder
        noteScroll.hasVerticalScroller = true
        noteScroll.documentView = notes
        noteScroll.setAccessibilityIdentifier("notesScrollArea")
        add(noteScroll, to: stack, height: 90)

        slider.setAccessibilityIdentifier("slider")
        slider.setAccessibilityLabel("Level")
        slider.isContinuous = true
        slider.setContentHuggingPriority(.defaultLow, for: .horizontal)
        sliderValue.alignment = .right
        sliderValue.widthAnchor.constraint(equalToConstant: 50).isActive = true
        let sliderRow = horizontal([NSTextField(labelWithString: "Level"), slider, sliderValue])
        add(sliderRow, to: stack, height: 28)
        checkbox.setAccessibilityIdentifier("checkbox")
        add(checkbox, to: stack, height: 24)
        add(probe, to: stack, height: 190)

        bottomScroll.borderType = .bezelBorder
        bottomScroll.hasVerticalScroller = true
        bottomScroll.setAccessibilityIdentifier("scrollArea")
        bottomScroll.setAccessibilityLabel("Scrollable rows")
        let scrollContent = NSTextView()
        configureTextView(scrollContent, identifier: "scrollContent")
        scrollContent.isEditable = false
        scrollContent.isSelectable = false
        scrollContent.string = (1...30).map { String(format: "Row %02d  —  Scroll target", $0) }.joined(separator: "\n")
        bottomScroll.documentView = scrollContent
        scrollContent.sizeToFit()
        add(bottomScroll, to: stack, height: 125)
        let footer = NSTextField(labelWithString: "This fixture records only its own controls and input events.")
        footer.font = .systemFont(ofSize: 11)
        footer.textColor = .secondaryLabelColor
        add(footer, to: stack, height: 16)

        selectionObserver = NotificationCenter.default.addObserver(forName: NSTextView.didChangeSelectionNotification, object: nil, queue: .main) { [weak self] notification in
            guard let self, let editor = notification.object as? NSTextView, editor === self.textField.currentEditor() else { return }
            self.lastTextSelection = editor.selectedRange()
        }
        if CommandLine.arguments.contains("--background") {
            // With Stage Manager, an orderBack window stays out of AXWindows until it is
            // ordered front; ordering front without activating keeps it in the strip.
            if CommandLine.arguments.contains("--stage-managed") { window.makeKeyAndOrderFront(nil) } else { window.orderBack(nil) }
        } else {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
        window.makeFirstResponder(textField)
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] notification in
            guard let self, let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            self.activations.append(["pid": app.processIdentifier, "time": ProcessInfo.processInfo.systemUptime])
            if self.activations.count > 100 { self.activations.removeFirst(self.activations.count - 100) }
        }
        menuObserver = NotificationCenter.default.addObserver(forName: NSMenu.didSendActionNotification, object: nil, queue: .main) { [weak self] note in
            let items = (note.userInfo ?? [:]).values.compactMap { $0 as? NSMenuItem }
            self?.menuActions.append(contentsOf: items.map(\.title))
        }
        for (name, label) in [(NSMenu.didBeginTrackingNotification, "begin"), (NSMenu.didEndTrackingNotification, "end")] {
            menuTrackingObservers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                self?.menuTracking.append(["event": label, "menu": (note.object as? NSMenu)?.title ?? "", "time": ProcessInfo.processInfo.systemUptime])
            })
        }
        localEventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp, .leftMouseDragged, .rightMouseDown, .rightMouseUp, .scrollWheel]) { [weak self] event in
            guard let self else { return event }
            let p = event.locationInWindow
            let cg = event.cgEvent?.location ?? .zero
            self.windowEvents.append(["type": event.type.rawValue, "windowNumber": event.windowNumber,
                                      "x": p.x, "y": p.y, "globalX": cg.x, "globalY": cg.y,
                                      "time": event.timestamp, "button": event.buttonNumber])
            if self.windowEvents.count > 100 { self.windowEvents.removeFirst(self.windowEvents.count - 100) }
            return event
        }
        timer = Timer(timeInterval: 0.1, target: self, selector: #selector(writeState), userInfo: nil, repeats: true)
        RunLoop.main.add(timer!, forMode: .common)
        writeState()
    }

    private func add(_ view: NSView, to stack: NSStackView, height: CGFloat) {
        stack.addArrangedSubview(view)
        view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([view.widthAnchor.constraint(equalTo: stack.widthAnchor), view.heightAnchor.constraint(equalToConstant: height)])
    }

    private func horizontal(_ views: [NSView]) -> NSStackView {
        let row = NSStackView(views: views)
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 12
        return row
    }

    private func configureTextView(_ view: NSTextView, identifier: String) {
        view.frame = NSRect(x: 0, y: 0, width: 640, height: 90)
        view.minSize = NSSize(width: 0, height: 0)
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]
        view.textContainer?.containerSize = NSSize(width: 640, height: CGFloat.greatestFiniteMagnitude)
        view.textContainer?.widthTracksTextView = true
        view.textContainerInset = NSSize(width: 8, height: 8)
        view.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        view.isRichText = false
        view.setAccessibilityIdentifier(identifier)
    }

    private func buildMenu() {
        let menu = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu(title: "OpenCU Fixture")
        appMenu.addItem(withTitle: "Quit OpenCU Fixture", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        menu.addItem(appItem)
        let fileItem = NSMenuItem()
        let fileMenu = NSMenu(title: "File")
        for (title, action, key) in [("New", #selector(newWindow), "n"),
                                     ("Open…", #selector(openDocument), "o"),
                                     ("Save Fixture…", #selector(saveDocument), "s"),
                                     ("Close All Windows", #selector(closeAllWindows), "w")] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.target = self
            fileMenu.addItem(item)
        }
        fileItem.submenu = fileMenu
        menu.addItem(fileItem)
        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        let counterAction = NSMenuItem(title: "Add fixture click", action: #selector(incrementCounter), keyEquivalent: "")
        counterAction.target = self
        let fixtureActions = NSMenuItem(title: "Fixture Actions", action: nil, keyEquivalent: "")
        fixtureActions.submenu = NSMenu(title: "Fixture Actions")
        fixtureActions.submenu?.addItem(counterAction)
        editMenu.addItem(fixtureActions)
        let gated = NSMenuItem(title: "Requires checkbox", action: #selector(gatedAction), keyEquivalent: "")
        gated.target = self
        editMenu.addItem(gated)
        editItem.submenu = editMenu
        menu.addItem(editItem)
        // Populated only when AppKit asks the delegate, like recent-items menus.
        let dynamicItem = NSMenuItem()
        let dynamicMenu = NSMenu(title: "Dynamic")
        dynamicMenu.delegate = self
        dynamicItem.submenu = dynamicMenu
        menu.addItem(dynamicItem)
        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        let move = NSMenuItem(title: "Move to display", action: nil, keyEquivalent: "")
        move.submenu = NSMenu(title: "Move to display")
        let mainDisplay = NSMenuItem(title: "Main display", action: #selector(moveToPhysicalDisplay), keyEquivalent: "")
        mainDisplay.target = self
        move.submenu?.addItem(mainDisplay)
        windowMenu.addItem(move); windowItem.submenu = windowMenu; menu.addItem(windowItem)
        NSApp.mainMenu = menu
    }

    // Person-operated fixture command; acceptance never invokes it through OpenCU.
    @objc private func moveToPhysicalDisplay() {
        guard let screen = NSScreen.screens.first(where: {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32) == CGMainDisplayID()
        }) else { return }
        window.setFrameOrigin(NSPoint(x: screen.visibleFrame.minX + 80, y: screen.visibleFrame.minY + 80))
        writeState()
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menuUpdates += 1
        menu.removeAllItems()
        let item = NSMenuItem(title: "Dynamic item \(menuUpdates)", action: #selector(incrementCounter), keyEquivalent: "")
        item.target = self
        menu.addItem(item)
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        guard item.action == #selector(gatedAction) else { return true }
        validations += 1
        return checkbox.state == .on
    }

    @objc private func gatedAction() { gatedActions += 1; writeState() }

    @objc private func incrementCounter() { clicks += 1; counterValue.stringValue = "Clicks: \(clicks)"; writeState() }

    @objc private func newWindow() {
        newCommands += 1
        window.makeKeyAndOrderFront(nil)
        writeState()
    }

    @objc private func closeAllWindows() {
        for candidate in NSApp.windows { candidate.close() }
        writeState()
    }

    @objc private func otherWindow() {
        let other = NSWindow(contentRect: NSRect(x: 180, y: 120, width: 320, height: 160),
                             styleMask: [.titled, .closable], backing: .buffered, defer: false)
        other.isReleasedWhenClosed = false
        other.title = "Other Fixture Window"
        other.collectionBehavior = window.collectionBehavior
        let button = NSButton(title: "Other window button", target: self, action: #selector(incrementCounter))
        button.frame = NSRect(x: 20, y: 40, width: 260, height: 40)
        button.setAccessibilityIdentifier("otherWindowButton")
        other.contentView?.addSubview(button)
        auxiliaryWindow = other
        other.makeKeyAndOrderFront(nil)
        writeState()
    }

    @objc private func saveDocument() {
        guard window.isVisible, savePanel == nil else { return }
        do { try FileManager.default.createDirectory(at: saveDirectory, withIntermediateDirectories: true) }
        catch { panelError = error.localizedDescription; writeState(); return }
        let panel = NSSavePanel()
        panel.directoryURL = saveDirectory
        panel.nameFieldStringValue = "fixture-default.txt"
        // Independent of the owner's "show all filename extensions" setting.
        panel.isExtensionHidden = false
        panel.canCreateDirectories = false
        savePanel = panel
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            defer { self.savePanel = nil; self.writeState() }
            guard response == .OK, let url = panel.url else { return }
            // This disposable fixture never writes outside its temporary folder.
            guard url.deletingLastPathComponent().standardizedFileURL == self.saveDirectory.standardizedFileURL else {
                self.panelError = "Save escaped the fixture directory"; return
            }
            do {
                try Data("OpenCU save-panel fixture\n".utf8).write(to: url, options: .atomic)
                self.savedPath = url.path
            } catch { self.panelError = error.localizedDescription }
        }
        writeState()
    }

    @objc private func openDocument() {
        openCommands += 1
        let panel = NSOpenPanel()
        panel.directoryURL = saveDirectory
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.begin { [weak self] response in
            guard let self else { return }
            if response == .OK { self.newWindow() }
            self.writeState()
        }
        writeState()
    }

    private func rangeJSON(_ range: NSRange) -> [String: Int] {
        ["location": range.location == NSNotFound ? -1 : range.location, "length": range.length]
    }

    private func rectJSON(_ rect: NSRect) -> [String: Double] {
        ["x": rect.minX, "y": rect.minY, "width": rect.width, "height": rect.height]
    }

    @objc private func writeState() {
        // A fixture-only control file makes stale-observation tests deterministic:
        // change the UI externally, wait for completion, then use the old index.
        let commandURL = output.appendingPathExtension("command")
        if let command = try? String(contentsOf: commandURL, encoding: .utf8) {
            try? FileManager.default.removeItem(at: commandURL)
            if command == "dismiss-panel" { savePanel?.cancel(nil) }
            if command == "other-window" { otherWindow() }
        }
        if let editor = textField.currentEditor() as? NSTextView { lastTextSelection = editor.selectedRange() }
        sliderValue.stringValue = String(format: "%.1f", slider.doubleValue)
        let state: [String: Any] = ["visibleWindows": NSApp.windows.filter { $0.isVisible }.count,
                                   "windowFrame": ["x": window.frame.minX, "y": window.frame.minY,
                                                   "width": window.frame.width, "height": window.frame.height],
                                   "backingScale": window.backingScaleFactor,
                                   "screenID": (window.screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32) ?? 0,
                                   "probeInWindow": rectJSON(probe.convert(probe.bounds, to: nil)),
                                   "savePanelVisible": savePanel?.isVisible ?? false,
                                   "savedPath": savedPath, "panelError": panelError,
                                   "newCommands": newCommands, "openCommands": openCommands,
                                   "clicks": clicks, "text": textField.currentEditor()?.string ?? textField.stringValue, "notes": notes.string,
                                   "appActive": NSApp.isActive, "windowKey": window.isKeyWindow,
                                   "appKeyWindow": NSApp.keyWindow?.windowNumber ?? 0,
                                   "appMainWindow": NSApp.mainWindow?.windowNumber ?? 0,
                                   "menuActions": menuActions, "menuTracking": menuTracking,
                                   "menuUpdates": menuUpdates, "validations": validations, "gatedActions": gatedActions,
                                   "frontmostPID": NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0,
                                   "activations": activations,
                                   "windowNumber": window.windowNumber, "windowEvents": windowEvents,
                                   "selection": ["unit": "utf16", "text": rangeJSON(lastTextSelection), "notes": rangeJSON(notes.selectedRange())],
                                   "slider": slider.doubleValue, "checkbox": checkbox.state == .on,
                                   "probe": ["marker": ["x": probe.marker.x, "y": probe.marker.y],
                                             "events": probe.events, "eventCount": probe.eventCount, "isFirstResponder": window?.firstResponder === probe],
                                   "scroll": ["x": bottomScroll.contentView.bounds.origin.x, "y": bottomScroll.contentView.bounds.origin.y]]
        do {
            let data = try JSONSerialization.data(withJSONObject: state, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: output, options: .atomic)
            reportedWriteFailure = false
        } catch {
            if !reportedWriteFailure {
                FileHandle.standardError.write(Data("Fixture state could not be written: \(error.localizedDescription)\n".utf8))
                reportedWriteFailure = true
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) { writeState(); timer?.invalidate() }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

let arguments = Array(CommandLine.arguments.dropFirst())
// Metadata-only acceptance query. Branch before creating NSApplication.
if arguments.count == 2, arguments[0] == "--window-metadata", let id = UInt32(arguments[1]) {
    let rows = CGWindowListCopyWindowInfo(.optionIncludingWindow, id) as? [[String: Any]] ?? []
    let row = rows.first { ($0[kCGWindowNumber as String] as? UInt32) == id }
    var result: [String: Any] = ["present": row != nil]
    if let row {
        result["pid"] = row[kCGWindowOwnerPID as String]
        result["frame"] = row[kCGWindowBounds as String]
        result["onScreen"] = row[kCGWindowIsOnscreen as String]
    }
    print(String(decoding: try JSONSerialization.data(withJSONObject: result), as: UTF8.self))
    exit(0)
}
// Non-GUI image inspection for the agent-display probe. Inspect the actual PNG
// bytes rather than accepting screenshot metadata as proof of rendered content.
if arguments.count == 4, arguments[0] == "--inspect-image",
   let bytes = try? Data(contentsOf: URL(fileURLWithPath: arguments[1])),
   let bitmap = NSBitmapImageRep(data: bytes),
   let x = Int(arguments[2]), let y = Int(arguments[3]),
   x >= 0, y >= 0, x < bitmap.pixelsWide, y < bitmap.pixelsHigh,
   let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) {
    let result: [String: Any] = ["width": bitmap.pixelsWide, "height": bitmap.pixelsHigh,
                               "r": color.redComponent, "g": color.greenComponent, "b": color.blueComponent]
    print(String(decoding: try JSONSerialization.data(withJSONObject: result), as: UTF8.self))
    exit(0)
}
if arguments == ["--clipboard-digest"] || arguments == ["--clipboard-state"] {
    var digest = SHA256()
    for (index, item) in (NSPasteboard.general.pasteboardItems ?? []).enumerated() {
        digest.update(data: Data("item:\(index)\n".utf8))
        for type in item.types.sorted(by: { $0.rawValue < $1.rawValue }) {
            guard let data = item.data(forType: type) else { exit(3) }
            digest.update(data: Data("\(type.rawValue):\(data.count)\n".utf8))
            digest.update(data: data)
        }
    }
    let checksum = digest.finalize().map { String(format: "%02x", $0) }.joined()
    if arguments == ["--clipboard-state"] {
        let state: [String: Any] = ["digest": checksum, "changeCount": NSPasteboard.general.changeCount]
        let data = try JSONSerialization.data(withJSONObject: state, options: [.sortedKeys])
        print(String(decoding: data, as: UTF8.self))
    } else { print(checksum) }
    exit(0)
}
guard arguments.count >= 2, arguments[0] == "--output", arguments[1].hasPrefix("/"),
      arguments.dropFirst(2).allSatisfy({ ["--stage-managed", "--background"].contains($0) }) else {
    FileHandle.standardError.write(Data("Usage: OpenCUFixture --output /absolute/path/to/fixture-state.json [--stage-managed] [--background]\n".utf8))
    exit(2)
}
let outputURL = URL(fileURLWithPath: arguments[1])
do { try FileManager.default.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true) }
catch { FileHandle.standardError.write(Data("Cannot create fixture output directory: \(error.localizedDescription)\n".utf8)); exit(2) }
let application = NSApplication.shared
application.setActivationPolicy(.regular)
let delegate = FixtureDelegate(output: outputURL)
application.delegate = delegate
application.run()
