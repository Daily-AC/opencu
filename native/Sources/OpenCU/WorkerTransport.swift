import Foundation
import Darwin

/// The byte transport deliberately has no AppKit, AX or engine dependencies.
enum WorkerTransport {
    struct Failure: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }
    static var interrupted: sig_atomic_t = 0
    static var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    static func installSignals() {
        interrupted = 0
        signal(SIGPIPE, SIG_IGN)
        for number in [SIGTERM, SIGINT, SIGHUP] {
            signal(number) { received in WorkerTransport.interrupted = received }
        }
    }

    static func constantTimeEqual(_ supplied: [UInt8], _ expected: [UInt8]) -> Bool {
        // Tokens have a public, fixed length. Never short-circuit on their bytes.
        guard supplied.count == expected.count else { return false }
        var difference: UInt8 = 0
        for index in expected.indices { difference |= supplied[index] ^ expected[index] }
        return difference == 0
    }

    static func channel(line: [UInt8], token: String, peerPID: pid_t, workerPID: pid_t) -> String? {
        guard peerPID == workerPID, workerPID > 0,
              let space = line.firstIndex(of: 32),
              constantTimeEqual(Array(line[..<space]), Array(token.utf8)) else { return nil }
        let suffix = Array(line[(space + 1)...])
        if suffix == Array("stdio\n".utf8) { return "stdio" }
        if suffix == Array("stderr\n".utf8) { return "stderr" }
        return nil
    }

    static func socketAddress(_ path: String) throws -> sockaddr_un {
        var address = sockaddr_un()
        guard !path.utf8.contains(0), path.utf8.count < MemoryLayout.size(ofValue: address.sun_path) else {
            throw Failure("worker socket path is too long")
        }
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { bytes in
            bytes.copyBytes(from: Array(path.utf8) + [0])
        }
        return address
    }

    static func withAddress<T>(_ path: String, _ body: (UnsafePointer<sockaddr>, socklen_t) -> T) throws -> T {
        var address = try socketAddress(path)
        return withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { body($0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
    }

    static func nonblocking(_ fd: Int32) throws -> Int32 {
        let flags = fcntl(fd, F_GETFL)
        guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else { throw Failure("cannot configure transport descriptor") }
        return flags
    }

    final class Listener {
        let directory: String
        let path: String
        let fd: Int32
        init() throws {
            var template = Array("/tmp/opencu.XXXXXX".utf8CString)
            guard let created = mkdtemp(&template) else { throw Failure("cannot create private worker directory") }
            directory = String(cString: created)
            path = directory + "/s"
            fd = socket(AF_UNIX, SOCK_STREAM, 0)
            do {
                guard chmod(directory, 0o700) == 0, fd >= 0 else { throw Failure("cannot create worker socket") }
                guard try withAddress(path, { Darwin.bind(fd, $0, $1) }) == 0,
                      Darwin.listen(fd, 8) == 0 else { throw Failure("cannot listen on worker socket") }
                _ = try nonblocking(fd)
                _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
            } catch {
                if fd >= 0 { close(fd) }
                unlink(path); rmdir(directory)
                throw error
            }
        }
        func removePath() { unlink(path); rmdir(directory) }
        deinit { close(fd); removePath() }

        func acceptChannels(token: String, workerPID: pid_t, doctor: Bool, timeout: TimeInterval = 20) throws -> [String: Int32] {
            let deadline = now + timeout
            var candidates: [Int32: [UInt8]] = [:]
            var channels: [String: Int32] = [:]
            var succeeded = false
            var lastRejection = "no authenticated connection"
            defer {
                for fd in candidates.keys { close(fd) }
                if !succeeded { for fd in channels.values { close(fd) } }
            }
            while now < deadline {
                if interrupted != 0 { throw Failure("worker launch interrupted") }
                var polling = [pollfd(fd: fd, events: Int16(POLLIN), revents: 0)]
                polling += candidates.keys.map { pollfd(fd: $0, events: Int16(POLLIN), revents: 0) }
                guard poll(&polling, nfds_t(polling.count), 50) >= 0 || errno == EINTR else { throw Failure("worker handshake poll failed") }
                if polling[0].revents & Int16(POLLIN) != 0 {
                    let client = Darwin.accept(fd, nil, nil)
                    if client >= 0 {
                        var peer: pid_t = 0
                        var size = socklen_t(MemoryLayout<pid_t>.size)
                        let peerResult = getsockopt(client, SOL_LOCAL, LOCAL_PEERPID, &peer, &size)
                        let peerError = errno
                        if peerResult == 0,
                           size == MemoryLayout<pid_t>.size, peer == workerPID, candidates.count < 8 {
                            do { _ = try nonblocking(client); candidates[client] = [] }
                            catch { close(client) }
                        } else {
                            lastRejection = peerResult != 0 ? "peer PID lookup failed (errno \(peerError))" : "unexpected peer PID \(peer) (expected \(workerPID))"
                            close(client)
                        }
                    } else if errno != EAGAIN && errno != EINTR {
                        throw Failure("cannot accept worker connection (errno \(errno))")
                    }
                }
                for item in polling.dropFirst() where item.revents != 0 {
                    guard var line = candidates[item.fd] else { continue }
                    var byte: UInt8 = 0
                    var rejected = false
                    // Read only the handshake; never consume a byte of the response.
                    while true {
                        let count = Darwin.read(item.fd, &byte, 1)
                        if count < 0 && (errno == EAGAIN || errno == EINTR) { break }
                        if count <= 0 { rejected = true; break }
                        line.append(byte)
                        if byte == 10 {
                            if let name = channel(line: line, token: token, peerPID: workerPID, workerPID: workerPID),
                               (!doctor || name == "stdio"), channels[name] == nil {
                                channels[name] = item.fd
                                candidates.removeValue(forKey: item.fd)
                            } else { rejected = true }
                            break
                        }
                        if line.count >= 80 { rejected = true; break }
                    }
                    if rejected { candidates.removeValue(forKey: item.fd); close(item.fd) }
                    else if candidates[item.fd] != nil { candidates[item.fd] = line }
                }
                if channels["stdio"] != nil && (doctor || channels["stderr"] != nil) {
                    removePath()
                    // Keep short-lived doctors connected until LOCAL_PEERPID has
                    // been checked: macOS returns ENOTCONN after the peer exits.
                    for fd in channels.values {
                        var acknowledgement: UInt8 = 1
                        guard Darwin.write(fd, &acknowledgement, 1) == 1 else { throw Failure("cannot acknowledge worker handshake") }
                    }
                    succeeded = true
                    return channels
                }
            }
            throw Failure("worker handshake timed out: \(lastRejection)")
        }
    }

    static func connect(path: String, token: String, channel: String) throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw Failure("cannot create worker connection") }
        do {
            guard try withAddress(path, { Darwin.connect(fd, $0, $1) }) == 0 else { throw Failure("cannot connect to relay") }
            let line = Array("\(token) \(channel)\n".utf8)
            var sent = 0
            while sent < line.count {
                let count = line.withUnsafeBytes { Darwin.write(fd, $0.baseAddress!.advanced(by: sent), line.count - sent) }
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw Failure("cannot send worker handshake") }
                sent += count
            }
            return fd
        } catch { close(fd); throw error }
    }

    static func awaitAcknowledgement(_ fd: Int32, timeout: TimeInterval = 20) throws {
        let deadline = now + timeout
        while now < deadline {
            var item = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ready = poll(&item, 1, 50)
            if ready < 0 && errno == EINTR { continue }
            guard ready >= 0 else { throw Failure("worker handshake poll failed") }
            if ready > 0 {
                var byte: UInt8 = 0
                guard Darwin.read(fd, &byte, 1) == 1, byte == 1 else { throw Failure("relay rejected worker handshake") }
                return
            }
        }
        throw Failure("relay handshake acknowledgement timed out")
    }

    /// Bounded queues and nonblocking writes keep both streams and signals live
    /// even if a client stops reading. A half-close preserves pending responses.
    static func relay(stdio: Int32, stderrSocket: Int32?, input: Int32 = STDIN_FILENO,
                      output: Int32 = STDOUT_FILENO, errorOutput: Int32 = STDERR_FILENO,
                      signalGrace: TimeInterval = 5) throws -> Int32 {
        var originals: [Int32: Int32] = [:]
        defer { for (fd, flags) in originals { _ = fcntl(fd, F_SETFL, flags) } }
        for fd in [input, output, errorOutput, stdio] + (stderrSocket.map { [$0] } ?? []) {
            if originals[fd] == nil { originals[fd] = try nonblocking(fd) }
        }
        let limit = 65_536
        var toWorker = Data(), toOutput = Data(), toError = Data()
        var inputEOF = false, workerEOF = false, errorEOF = stderrSocket == nil, writeClosed = false
        var signalDeadline: TimeInterval?
        while true {
            if interrupted != 0 && signalDeadline == nil {
                signalDeadline = now + signalGrace
                inputEOF = true
                toWorker.removeAll()
                shutdown(stdio, SHUT_WR)
                writeClosed = true
            }
            if let deadline = signalDeadline, now >= deadline { return 128 + interrupted }
            if inputEOF && toWorker.isEmpty && !writeClosed {
                shutdown(stdio, SHUT_WR); writeClosed = true
            }
            // Once stdout closes, drain currently available diagnostics but do
            // not wait for an inherited stderr descriptor in another process.
            if workerEOF, let fd = stderrSocket, !errorEOF, toError.count < limit {
                try receive(fd, into: &toError, eof: &errorEOF, eofOnWouldBlock: true)
            }
            if workerEOF && toOutput.isEmpty && toError.isEmpty && errorEOF {
                return interrupted == 0 ? 0 : 128 + interrupted
            }
            var polling: [pollfd] = []
            if !inputEOF && !workerEOF && toWorker.count < limit { polling.append(pollfd(fd: input, events: Int16(POLLIN), revents: 0)) }
            var socketEvents: Int16 = 0
            if !workerEOF && toOutput.count < limit { socketEvents |= Int16(POLLIN) }
            if !workerEOF && !toWorker.isEmpty { socketEvents |= Int16(POLLOUT) }
            if socketEvents != 0 { polling.append(pollfd(fd: stdio, events: socketEvents, revents: 0)) }
            if let fd = stderrSocket, !errorEOF && toError.count < limit { polling.append(pollfd(fd: fd, events: Int16(POLLIN), revents: 0)) }
            if !toOutput.isEmpty { polling.append(pollfd(fd: output, events: Int16(POLLOUT), revents: 0)) }
            if !toError.isEmpty { polling.append(pollfd(fd: errorOutput, events: Int16(POLLOUT), revents: 0)) }
            let ready = poll(&polling, nfds_t(polling.count), 50)
            if ready < 0 && errno == EINTR { continue }
            guard ready >= 0 else { throw Failure("relay poll failed") }
            for item in polling where item.revents != 0 {
                // Darwin poll reports POLLNVAL for /dev/null and some regular
                // files. Let read/write establish EOF or EBADF for these fds.
                if item.revents & Int16(POLLIN | POLLHUP | POLLERR | POLLNVAL) != 0 {
                    if item.fd == input { try receive(input, into: &toWorker, eof: &inputEOF) }
                    else if item.fd == stdio && !workerEOF { try receive(stdio, into: &toOutput, eof: &workerEOF) }
                    else if item.fd == stderrSocket { try receive(item.fd, into: &toError, eof: &errorEOF) }
                }
                if item.revents & Int16(POLLOUT | POLLHUP | POLLERR | POLLNVAL) != 0 {
                    if item.fd == stdio && !workerEOF { try send(stdio, from: &toWorker) }
                    else if item.fd == output { try send(output, from: &toOutput) }
                    else if item.fd == errorOutput { try send(errorOutput, from: &toError) }
                }
            }
        }
    }

    private static func receive(_ fd: Int32, into data: inout Data, eof: inout Bool, eofOnWouldBlock: Bool = false) throws {
        var buffer = [UInt8](repeating: 0, count: 4096)
        let count = Darwin.read(fd, &buffer, buffer.count)
        if count > 0 { data.append(contentsOf: buffer.prefix(count)) }
        else if count == 0 || (count < 0 && errno == ECONNRESET) { eof = true }
        else if errno == EAGAIN && eofOnWouldBlock { eof = true }
        else if errno != EAGAIN && errno != EINTR { throw Failure("relay read failed") }
    }

    private static func send(_ fd: Int32, from data: inout Data) throws {
        guard !data.isEmpty else { return }
        let count = data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, min(data.count, 4096)) }
        if count > 0 { data.removeFirst(count) }
        else if count < 0 && errno != EAGAIN && errno != EINTR { throw Failure("relay write failed") }
    }
}
