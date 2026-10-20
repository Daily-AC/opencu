import Foundation

// No display or AX calls: shared by production and the native logic runner.
enum AgentDisplayGeometry {
    static func valid(_ rect: CGRect) -> Bool {
        [rect.minX, rect.minY, rect.width, rect.height].allSatisfy(\.isFinite)
            && rect.width > 0 && rect.height > 0
    }

    static func close(_ a: CGRect, _ b: CGRect) -> Bool {
        valid(a) && valid(b) && abs(a.minX - b.minX) <= 1 && abs(a.minY - b.minY) <= 1
            && abs(a.width - b.width) <= 1 && abs(a.height - b.height) <= 1
    }

    static func placement(main: CGRect, others: [CGRect], size: CGSize) throws -> CGRect {
        guard valid(main), others.allSatisfy(valid), valid(CGRect(origin: .zero, size: size)) else {
            throw OpenCUError("AGENT_DISPLAY_GEOMETRY", "Invalid display geometry.")
        }
        // Quartz global points, origin at the main display's top left. Prefer
        // bottom right; never translate an existing display to make room.
        for point in [CGPoint(x: main.maxX, y: main.maxY),
                      CGPoint(x: main.minX - size.width, y: main.maxY),
                      CGPoint(x: main.maxX, y: main.minY - size.height),
                      CGPoint(x: main.minX - size.width, y: main.minY - size.height)] {
            let rect = CGRect(origin: point, size: size)
            if ([main] + others).allSatisfy({
                let intersection = rect.intersection($0)
                return intersection.isNull || (intersection.width == 0 && intersection.height == 0)
            }), abs(point.x) < Double(Int32.max), abs(point.y) < Double(Int32.max) { return rect }
        }
        throw OpenCUError("AGENT_DISPLAY_GEOMETRY", "No free corner of the main display; existing displays will not be moved.")
    }

    static func destination(original: CGRect, display: CGRect) throws -> CGRect {
        // Leave room for the menu bar and a possible Dock. Do not resize a
        // target that already fits; oversized windows are explicitly clamped.
        let usable = display.insetBy(dx: 64, dy: 64)
        guard valid(original), valid(usable) else {
            throw OpenCUError("AGENT_DISPLAY_GEOMETRY", "Window or display has unusable bounds.")
        }
        return CGRect(x: usable.minX, y: usable.minY,
                      width: min(original.width, usable.width), height: min(original.height, usable.height))
    }
}

struct AgentDisplayLedger {
    struct SavedFrame: Equatable {
        let windowID: UInt32
        let displayID: UInt32
        let frame: CGRect
    }
    enum CleanupStep: Equatable { case restore, releaseDisplay }
    private(set) var displayID: UInt32?
    private(set) var pending: [SavedFrame] = []
    var restorePending: Bool { !pending.isEmpty }

    mutating func created(_ id: UInt32) throws {
        guard displayID == nil, !restorePending else {
            throw OpenCUError("AGENT_DISPLAY_BUSY", "Destroy/restore the previous agent display before creating another.")
        }
        displayID = id
    }
    mutating func remember(_ value: SavedFrame) throws {
        guard displayID != nil,
              !pending.contains(where: { $0.windowID == value.windowID }) else {
            throw OpenCUError("AGENT_DISPLAY_BUSY", "Create a display and do not overwrite an outstanding original window frame.")
        }
        // Commit before the first AX write, including when that write fails.
        pending.append(value)
    }
    func restorations(windowID: UInt32? = nil) -> [SavedFrame] {
        pending.reversed().filter { windowID == nil || $0.windowID == windowID }
    }
    mutating func restored(_ windowID: UInt32? = nil) {
        if let windowID { pending.removeAll { $0.windowID == windowID } }
        else { pending.removeAll() }
    }
    mutating func released() { displayID = nil }
    var cleanupSteps: [CleanupStep] {
        (restorePending ? [.restore] : []) + (displayID == nil ? [] : [.releaseDisplay])
    }
}

func agentDisplayRectJSON(_ rect: CGRect) -> [String: Double] {
    ["x": rect.minX, "y": rect.minY, "width": rect.width, "height": rect.height]
}

/// Relocation identity matching. Ordinary input/capture still requires its
/// existing exact-window identity path. On-screen state is never a match filter.
struct AgentDisplayWindowIdentity {
    struct Candidate {
        let id: UInt32
        let pid: Int32
        let title: String?
        let frame: CGRect
        let onScreen: Bool
    }
    static func resolve(pid: Int32, title: String?, frame: CGRect, exactID: UInt32?,
                        candidates: [Candidate]) throws -> (id: UInt32, source: String) {
        let owned = candidates.filter { $0.pid == pid }
        if let exactID, owned.contains(where: { $0.id == exactID }) { return (exactID, "AXWindowID") }
        let bounds = owned.filter { AgentDisplayGeometry.close($0.frame, frame) }
        if let title, !title.isEmpty {
            let titled = owned.filter { $0.title == title }
            let both = titled.filter { AgentDisplayGeometry.close($0.frame, frame) }
            if both.count == 1 { return (both[0].id, "PID+title+bounds") }
            if titled.count == 1 { return (titled[0].id, "PID+unique-title (WindowServer may transform bounds)") }
            if !titled.isEmpty { throw OpenCUError("AGENT_DISPLAY_AMBIGUOUS_WINDOW", "Several WindowServer windows match the AX title and no unique bounds match exists.") }
            // If CG hides names, a unique bounds match still identifies the AX
            // window. A positively conflicting title must not match by bounds.
            let unnamed = bounds.filter { $0.title?.isEmpty != false }
            if unnamed.count == 1 { return (unnamed[0].id, "PID+bounds (CG title unavailable)") }
        } else if bounds.count == 1 { return (bounds[0].id, "PID+unique-bounds") }
        throw OpenCUError("AGENT_DISPLAY_WINDOW_ID_UNAVAILABLE", "No unambiguous AX-to-WindowServer match by PID, title and bounds; see move diagnostics.")
    }
}
