import AppKit
import ApplicationServices
import Darwin

@MainActor
final class AgentDesktopController {
    let display: AgentDisplay
    private(set) var state = AgentDesktopState()
    private var consent = AgentDesktopConsent()
    private let window = AgentDesktopWindow()
    private let capture = AgentDesktopCapture()
    private var timer: Timer?
    private var ownershipFD: Int32 = -1
    private var failure: OpenCUError?
    private var cleanup: Arguments = ["ok": true, "cleanupErrors": []]
    private var closing: Task<Arguments, Never>?
    private var moving = false
    private var consentAnswer: Bool?
    private var observedGeneration: Int?
    private var actionGeneration: Int?
    private(set) var observationConsent = "outside_display"
    private var observedFrame: (UInt32, CGRect)?
    private var monitorTask: Task<Void, Never>?
    var onInvalidate: (() -> Void)?
    var onPersonStop: (() -> Void)?
    var onFailure: (() -> Void)?
    var onInputPause: (() -> Void)?
    private(set) var inputPause: OpenCUError?
    var ownsDesktop: Bool { state.ownsDesktop }
    private var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    init(display: AgentDisplay) {
        self.display = display
        window.onStop = { [weak self] in self?.onPersonStop?() }
        capture.onFrame = { [weak self] image in self?.window.showFrame(image) }
        capture.mayDisplayFrame = { [weak self] in
            guard let self else { return false }
            return [.starting, .running].contains(self.state.phase) && !self.state.stoppedByPerson && !desktopLocked()
        }
        capture.onPersonStop = { [weak self] in self?.onPersonStop?() }
        capture.onFailure = { [weak self] error in self?.fail(error) }
        display.beforeMutation = { [weak self] in
            guard let self else { throw CancellationError() }
            if self.ownsDesktop {
                try self.requireUnlocked()
                if self.state.stoppedByPerson { throw AgentDesktopState.stopError }
                guard [.starting, .running].contains(self.state.phase) else { throw CancellationError() }
            }
        }
    }
    private func event() {
        _ = emit(["event": "agent_desktop", "state": state.phase.rawValue,
                  "generation": state.generation, "stoppedByPerson": state.stoppedByPerson,
                  "parentLocked": state.parentLocked,
                  "error": failure.map { ["code": $0.code, "message": $0.message] as Any } ?? NSNull()])
    }
    func invalidate() {
        state.invalidate(); observedGeneration = nil; observedFrame = nil; onInvalidate?(); event()
    }
    private func transition(_ phase: AgentDesktopPhase) {
        state.change(phase); observedGeneration = nil; onInvalidate?(); event()
    }
    private func requireUnlocked(checkDialog: Bool = true) throws {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any],
              let onConsole = session[kCGSessionOnConsoleKey as String] as? Bool, onConsole else {
            throw OpenCUError("AGENT_DESKTOP_UNAVAILABLE", "The console session could not be verified.")
        }
        // The lock key is absent on unlocked macOS sessions; a missing session is not unlocked.
        let locked = session["CGSSessionScreenIsLocked"] as? Bool ?? false
        if state.lock(locked) {
            observedGeneration = nil; onInvalidate?(); event()
            consent.cancel(); consentAnswer = false; window.clearConsent()
            if locked { window.clearFrame() }
        }
        if locked { throw OpenCUError("SCREEN_LOCKED", "macOS is locked. Unlock and read fresh state before continuing.") }
        let front = NSWorkspace.shared.frontmostApplication
        if checkDialog && ["UserNotificationCenter", "SecurityAgent"].contains(front?.bundleURL?.deletingPathExtension().lastPathComponent ?? "") {
            let error = OpenCUError("AGENT_DISPLAY_PERSON_ACTIVE", "A macOS confirmation is in the foreground. This operation was refused; the desktop and its admitted windows remain. No input was replayed.")
            inputPause = error
            throw error
        }
        if checkDialog { inputPause = nil }
    }
    private func acquireOwnership() throws {
        let count = confstr(_CS_DARWIN_USER_TEMP_DIR, nil, 0)
        guard count > 1 else { throw OpenCUError("AGENT_DISPLAY_BUSY", "Cannot identify the GUI user's temporary directory.") }
        var directory = [CChar](repeating: 0, count: count)
        guard confstr(_CS_DARWIN_USER_TEMP_DIR, &directory, count) == count else {
            throw OpenCUError("AGENT_DISPLAY_BUSY", "Cannot identify the GUI user's temporary directory.")
        }
        let path = String(cString: directory) + "dev.opencu.agent-desktop.lock"
        let fd = Darwin.open(path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw OpenCUError("AGENT_DISPLAY_BUSY", "Cannot acquire the GUI session's agent desktop ownership.") }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == getuid(), info.st_nlink == 1,
              info.st_mode & S_IFMT == S_IFREG, info.st_mode & 0o077 == 0,
              flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            Darwin.close(fd)
            throw OpenCUError("AGENT_DISPLAY_BUSY", "Another connection owns this GUI session's agent desktop.")
        }
        ownershipFD = fd // Never unlink a lock inode while another process may have it open.
    }
    func start() async throws -> Arguments {
        if state.stoppedByPerson { throw AgentDesktopState.stopError }
        if state.phase == .running { return status() }
        guard state.phase == .inactive else {
            throw failure ?? OpenCUError("AGENT_DESKTOP_UNAVAILABLE", "Finish agent desktop cleanup before starting again.")
        }
        transition(.starting)
        do {
            try requireUnlocked(); try requireAccessibility(); try EngineResponsibility.requireCapture()
            try acquireOwnership()
            consent = AgentDesktopConsent()
            try window.show()
            _ = try await display.create()
            try Task.checkCancellation()
            guard let id = display.id else { throw OpenCUError("AGENT_DESKTOP_UNAVAILABLE", "No agent display was created.") }
            try await capture.start(displayID: id)
            try Task.checkCancellation(); try requireUnlocked(checkDialog: false)
            if let failure { throw failure }
            transition(.running)
            window.status(.watchOnly)
            let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.monitor() }
            }
            RunLoop.main.add(timer, forMode: .common); self.timer = timer
            return status()
        } catch {
            failure = error as? OpenCUError ?? OpenCUError("AGENT_DESKTOP_UNAVAILABLE", error.localizedDescription)
            transition(.failed)
            _ = await stop(keepFailure: true)
            throw state.stoppedByPerson ? AgentDesktopState.stopError : failure!
        }
    }
    private func monitor() {
        guard state.phase == .running, monitorTask == nil else { return }
        monitorTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.monitorTask = nil }
            do {
                try self.requireUnlocked()
                if !self.window.visible { self.onPersonStop?(); return }
                if !self.moving {
                    try self.display.validateLayout()
                    let generation = self.state.generation
                    let frames = await self.display.sampleFrames(observedID: self.observedFrame?.0)
                    guard !Task.isCancelled, generation == self.state.generation, !self.moving, self.state.phase == .running else { return }
                    self.checkReturns(frames: frames)
                    if let (id, previous) = self.observedFrame, let current = frames[id], !AgentDisplayGeometry.close(previous, current) { self.invalidate() }
                }
                self.window.status(.watchOnly)
            } catch let error as OpenCUError where !AgentDesktopAdmissionPolicy.tearsDownDesktop(error.code) {
                self.inputPause = error
                self.onInputPause?()
                self.window.status(error.code == "SCREEN_LOCKED" ? .locked : .confirmation)
            } catch { self.fail(error as? OpenCUError ?? OpenCUError("AGENT_DESKTOP_LOST", error.localizedDescription)) }
        }
    }
    private func checkReturns(frames: [UInt32: CGRect]? = nil) {
        for returned in display.externalReturns(frames: frames) { consent.returned(returned.key); invalidate() }
    }
    func fail(_ error: OpenCUError) {
        guard state.phase != .stopping && state.phase != .inactive && state.phase != .stopped else { return }
        failure = error; transition(.failed); cancelConsent(); onFailure?()
    }
    func latchPersonStop() {
        state.stopByPerson(); failure = AgentDesktopState.stopError
        cancelConsent(); observedGeneration = nil; onInvalidate?(); event()
    }
    func cancelConsent() {
        consent.cancel(); consentAnswer = false; window.clearConsent()
    }
    func requestStop() {
        cancelConsent()
        if !state.stoppedByPerson { transition(.stopping) }
    }
    func status() -> Arguments {
        var lockFailure: OpenCUError?
        do { try requireUnlocked(checkDialog: false) }
        catch let error as OpenCUError where error.code == "SCREEN_LOCKED" { }
        catch { lockFailure = error as? OpenCUError ?? OpenCUError("AGENT_DESKTOP_UNAVAILABLE", error.localizedDescription) }
        var result: Arguments = ["state": state.phase.rawValue, "stoppedByPerson": state.stoppedByPerson,
            "parentLocked": lockFailure == nil ? state.parentLocked as Any : NSNull(), "ready": lockFailure == nil && state.ready && inputPause == nil, "workerPID": getpid(),
            "generation": state.generation,
            "displayID": display.id.map { $0 as Any } ?? NSNull(),
            "preview": ["running": capture.running, "frames": capture.frames, "interactive": false,
                        "windowID": window.windowID.map { $0 as Any } ?? NSNull()],
            "windows": display.savedWindows, "cleanup": cleanup]
        if let frame = display.frame { result["displayFrame"] = agentDisplayRectJSON(frame) }
        if let lockFailure { result["error"] = lockFailure.code; result["message"] = lockFailure.message }
        if let inputPause { result["inputPause"] = inputPause.code }
        if let failure { result["error"] = failure.code; result["message"] = failure.message }
        if let pending = consent.pending {
            result["consent"] = ["window": pending.window, "remainingSeconds": max(0, pending.deadline - now)]
        } else { result["consent"] = NSNull() }
        return result
    }
    func prepareObservation(_ app: TargetApp, explicit: Bool) async throws -> Bool {
        try requireUnlocked(); try state.requireRunning(); try display.validateLayout(); checkReturns()
        observationConsent = "outside_display"
        let proposal: AgentDisplay.Proposal
        do { guard let target = try display.propose(app) else { return false }; proposal = target }
        catch let error as OpenCUError {
            guard let reason = AgentDesktopAdmissionPolicy.reducedReason(error) else { throw error }
            observationConsent = reason
            return false
        }
        let choice = AgentDesktopAdmissionPolicy.choice(admitted: display.contains(proposal),
            onDisplay: !proposal.requiresMove, sameProcess: display.hasAdmittedProcess(app),
            sticky: consent.reduced[proposal.key] != nil, explicit: explicit)
        if choice == .admitted { observationConsent = "approved"; return true }
        if choice == .inheritProcess {
            try display.admitWithoutMoving(proposal); observationConsent = "same_process"; return true
        }
        observationConsent = consent.reduced[proposal.key] ?? "outside_display"
        guard choice != .reduced, let request = try consent.begin(window: proposal.key, now: now) else { return false }
        invalidate(); consentAnswer = nil
        window.ask(proposal) { [weak self] approve in
            guard let self else { return }
            self.consentAnswer = self.consent.decide(token: request.token, approve: approve, now: self.now)
        }
        defer { window.clearConsent() }
        do {
            while consentAnswer == nil {
                try Task.checkCancellation(); try requireUnlocked(); try state.requireRunning()
                if now >= request.deadline {
                    consentAnswer = consent.decide(token: request.token, approve: false, now: now)
                    break
                }
                try await Task.sleep(nanoseconds: 50_000_000)
            }
            try Task.checkCancellation(); try requireUnlocked(); try state.requireRunning()
            guard consentAnswer == true else { observationConsent = consent.reduced[proposal.key] ?? "cancelled"; return false }
            // Let the consent click/trackpad settle, then sample the quiet-desktop baseline.
            if proposal.requiresMove { try await Task.sleep(nanoseconds: 1_000_000_000) }
            try Task.checkCancellation(); try requireUnlocked(); try state.requireRunning()
            try display.validateProposal(proposal)
            moving = true
            defer { moving = false }
            invalidate()
            do {
                if proposal.requiresMove { _ = try await display.moveWindow(proposal) }
                else { try display.admitWithoutMoving(proposal) }
            }
            catch {
                let cause = error as? OpenCUError ?? OpenCUError("AGENT_DISPLAY_MOVE_FAILED", error.localizedDescription)
                if !AgentDesktopAdmissionPolicy.tearsDownDesktop(cause.code) || error is CancellationError {
                    // Undo only this move, even if the request was cancelled while settling.
                    do { _ = try await Task { @MainActor in try await self.display.restore(windowID: proposal.windowID) }.value }
                    catch {
                        fail(error as? OpenCUError ?? OpenCUError("AGENT_DESKTOP_CLEANUP_FAILED", error.localizedDescription))
                        throw error
                    }
                    observationConsent = cause.code; invalidate()
                } else { fail(cause) }
                if error is CancellationError { throw error }
                throw cause
            }
            invalidate()
            observationConsent = "approved"
            return true
        } catch {
            consent.cancel(); throw error
        }
    }
    func observed(_ snapshot: WindowSnapshot, generation: Int) throws {
        try state.requireGeneration(generation)
        try display.requireAdmitted(snapshot)
        observedGeneration = generation
        if let id = snapshot.windowID { observedFrame = (id, snapshot.bounds) }
    }
    /// Full identity/admission checks run once at each native action/batch step.
    func requireInput(_ app: TargetApp, snapshot: WindowSnapshot?) throws {
        try requireUnlocked(); try state.requireRunning(); try display.validateLayout()
        let target: AgentDisplay.Proposal?
        do { target = try display.propose(app) }
        catch let error as OpenCUError {
            guard AgentDesktopAdmissionPolicy.reducedReason(error) != nil else { throw error }
            throw OpenCUError("OBSERVATION_REQUIRED", "The current window cannot be verified for input. Read its reduced state for the reason.", details: ["reason": error.code])
        }
        let admitted = target.map { display.contains($0) } ?? false
        try AgentDesktopAdmissionPolicy.requireSnapshot(admitted: admitted,
            fresh: snapshot?.app.pid == app.pid && snapshot?.windowID == target?.windowID && observedGeneration == state.generation)
        try display.requireAdmitted(snapshot!)
        actionGeneration = state.generation
    }
    func endInput() { actionGeneration = nil }
    /// Per-key pauses keep stop/lock/generation checks, not window enumeration/AX.
    func requireContinuation() throws {
        if desktopLocked() { throw OpenCUError("SCREEN_LOCKED", "macOS is locked. Read fresh state after unlocking.") }
        try state.requireRunning()
        if let inputPause { throw inputPause }
        guard let generation = actionGeneration else { throw OpenCUError("OBSERVATION_REQUIRED", "Read fresh state before input.") }
        try state.requireGeneration(generation)
    }
    func stop(keepFailure: Bool = false) async -> Arguments {
        if let closing { return await closing.value }
        let task = Task { @MainActor () -> Arguments in
            if !keepFailure && !self.state.stoppedByPerson { self.transition(.stopping) }
            self.timer?.invalidate(); self.timer = nil
            self.monitorTask?.cancel()
            await self.monitorTask?.value
            self.cancelConsent(); self.invalidate()
            let captureError = await self.capture.stop()
            let report = await self.display.destroy()
            self.cleanup = ["ok": report["ok"] ?? false, "cleanupErrors": report["cleanupErrors"] ?? [],
                            "lastRemoval": report["lastRemoval"] ?? NSNull(), "windows": self.display.savedWindows]
            if let captureError {
                // The output and stream reference have been released. Capture-stop
                // diagnostics must not hide confirmed window/display cleanup.
                self.cleanup["previewWarnings"] = [captureError]
            }
            self.window.close()
            if self.display.id == nil, self.ownershipFD >= 0 {
                Darwin.close(self.ownershipFD); self.ownershipFD = -1
            }
            if self.cleanup["ok"] as? Bool == true {
                if !keepFailure && !self.state.stoppedByPerson { self.failure = nil }
                self.transition(keepFailure ? .failed : .inactive)
            } else {
                if !self.state.stoppedByPerson {
                    self.failure = OpenCUError("AGENT_DESKTOP_CLEANUP_FAILED", "Agent desktop cleanup was not fully confirmed.", details: self.cleanup)
                }
                self.transition(.failed)
            }
            return self.status()
        }
        closing = task
        let result = await task.value
        closing = nil
        return result
    }
}
