import Foundation
import Darwin

private func check(_ value: @autoclosure () -> Bool, _ message: String) {
    if !value() { fatalError(message) }
}
private func pair() -> [Int32] {
    var fds: [Int32] = [0, 0]
    check(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0, "socketpair")
    return fds
}
private func writeBytes(_ fd: Int32, _ bytes: [UInt8]) {
    var offset = 0
    while offset < bytes.count {
        let count = bytes.withUnsafeBytes { Darwin.write(fd, $0.baseAddress!.advanced(by: offset), bytes.count - offset) }
        if count < 0 && errno == EINTR { continue }
        check(count > 0, "write")
        offset += count
    }
}
private func readAll(_ fd: Int32) -> [UInt8] {
    var result: [UInt8] = [], buffer = [UInt8](repeating: 0, count: 4096)
    while true {
        let n = Darwin.read(fd, &buffer, buffer.count)
        if n < 0 && errno == EINTR { continue }
        if n < 0 && errno == EAGAIN {
            var item = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            check(poll(&item, 1, 2000) > 0, "read readiness")
            continue
        }
        check(n >= 0, "read")
        if n == 0 { return result }
        result.append(contentsOf: buffer.prefix(n))
    }
}

@main struct TransportTests {
    static func main() throws {
        if CommandLine.arguments.count > 1 { try child(CommandLine.arguments[1]); return }
        signal(SIGPIPE, SIG_IGN)
        let token = String(repeating: "a", count: 64)
        // Parse actual socketpair bytes, with the production peer PID query.
        for (line, expected) in [(token + " stdio\n", "stdio"), (token + " stderr\n", "stderr"),
                                 ("b" + String(token.dropFirst()) + " stdio\n", ""),
                                 (String(token.dropLast()) + "b stdio\n", ""),
                                 (token + " bogus\n", ""), (token + " stdio\r\n", ""),
                                 (token + " stdio", ""), ("short stdio\n", "")] {
            let fds = pair()
            writeBytes(fds[0], Array(line.utf8)); shutdown(fds[0], SHUT_WR)
            let bytes = readAll(fds[1])
            var peer: pid_t = 0, size = socklen_t(MemoryLayout<pid_t>.size)
            check(getsockopt(fds[1], SOL_LOCAL, LOCAL_PEERPID, &peer, &size) == 0, "peer PID query")
            check(WorkerTransport.channel(line: bytes, token: token, peerPID: peer, workerPID: getpid()) == (expected.isEmpty ? nil : expected), "handshake \(expected)")
            check(WorkerTransport.channel(line: bytes, token: token, peerPID: peer, workerPID: getpid() + 1) == nil, "wrong peer PID")
            fds.forEach { close($0) }
        }
        check(!WorkerTransport.constantTimeEqual([], Array(token.utf8)), "wrong length")
        check(!WorkerTransport.constantTimeEqual(Array(token.utf8), Array((String(token.dropLast()) + "b").utf8)), "last byte mismatch")
        try listenerChecks(token)
        let payload = Data((0..<300_000).map { UInt8($0 % 251) })
        for mode in ["echo", "worker-eof", "signal", "signal-timeout"] {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
            task.arguments = [mode]
            let input = Pipe(), output = Pipe(), errors = Pipe()
            task.standardInput = input; task.standardOutput = output; task.standardError = errors
            try task.run()
            if mode == "echo" {
                // Consume concurrently so the payload exceeds every transport buffer.
                let writer = DispatchGroup(); writer.enter()
                DispatchQueue.global().async {
                    input.fileHandleForWriting.write(payload)
                    try! input.fileHandleForWriting.close()
                    writer.leave()
                }
                let actual = output.fileHandleForReading.readDataToEndOfFile()
                writer.wait()
                check(actual == payload + Data("after EOF".utf8), "stdin EOF preserves final worker output")
                check(errors.fileHandleForReading.readDataToEndOfFile() == Data("diagnostic".utf8), "stderr forwarding")
            } else if mode == "worker-eof" {
                check(output.fileHandleForReading.readDataToEndOfFile() == Data("done".utf8), "worker EOF exits despite open stdin")
            } else {
                check(output.fileHandleForReading.readData(ofLength: 1) == Data([82]), "relay ready")
                let start = WorkerTransport.now
                kill(task.processIdentifier, SIGTERM)
                let result = output.fileHandleForReading.readDataToEndOfFile()
                check(mode == "signal-timeout" || result == Data("cleaned".utf8), "signal half-close and cleanup response")
                check(WorkerTransport.now - start < 2, "signal deadline")
            }
            task.waitUntilExit()
            check(task.terminationStatus == (mode.hasPrefix("signal") ? 143 : 0), "relay exit status \(mode)")
            try? input.fileHandleForWriting.close()
        }
        let nullTask = Process()
        nullTask.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        nullTask.arguments = ["echo"]
        nullTask.standardInput = FileHandle.nullDevice
        nullTask.standardOutput = FileHandle.nullDevice
        nullTask.standardError = FileHandle.nullDevice
        try nullTask.run(); nullTask.waitUntilExit()
        check(nullTask.terminationStatus == 0, "/dev/null descriptors")
        print("Worker transport checks passed (authentication, peer PID, fragmented/invalid/duplicate handshakes, bounded relay, EOF, stderr, SIGTERM and grace deadline).")
    }

    static func listenerChecks(_ token: String) throws {
        let listener = try WorkerTransport.Listener()
        let done = DispatchGroup(); done.enter()
        DispatchQueue.global().async {
            defer { done.leave() }
            let wrong = try! WorkerTransport.connect(path: listener.path, token: String(repeating: "b", count: 64), channel: "stdio")
            // Keep connections alive until the listener has verified peer PID.
            let stdio = try! WorkerTransport.connect(path: listener.path, token: token, channel: "stdio")
            let duplicate = try! WorkerTransport.connect(path: listener.path, token: token, channel: "stdio")
            let errors = socket(AF_UNIX, SOCK_STREAM, 0)
            check(try! WorkerTransport.withAddress(listener.path, { Darwin.connect(errors, $0, $1) }) == 0, "fragmented connect")
            for byte in Array((token + " stderr\n").utf8) {
                writeBytes(errors, [byte])
                usleep(1000)
            }
            try! WorkerTransport.awaitAcknowledgement(stdio)
            try! WorkerTransport.awaitAcknowledgement(errors)
            close(wrong)
            writeBytes(stdio, Array("payload\n".utf8))
            shutdown(stdio, SHUT_WR)
            [stdio, duplicate, errors].forEach { close($0) }
        }
        let channels = try listener.acceptChannels(token: token, workerPID: getpid(), doctor: false, timeout: 2)
        check(Set(channels.keys) == ["stdio", "stderr"], "two channels")
        check(readAll(channels["stdio"]!) == Array("payload\n".utf8), "handshake preserves payload")
        check(!FileManager.default.fileExists(atPath: listener.directory), "private path removed")
        channels.values.forEach { close($0) }; done.wait()
        let doctor = try WorkerTransport.Listener()
        let doctorSocket = try WorkerTransport.connect(path: doctor.path, token: token, channel: "stdio")
        let doctorChannels = try doctor.acceptChannels(token: token, workerPID: getpid(), doctor: true, timeout: 1)
        try WorkerTransport.awaitAcknowledgement(doctorSocket)
        check(Set(doctorChannels.keys) == ["stdio"], "doctor needs only stdio")
        close(doctorSocket); doctorChannels.values.forEach { close($0) }
        let wrongPeer = try WorkerTransport.Listener()
        let rejectedSocket = try WorkerTransport.connect(path: wrongPeer.path, token: token, channel: "stdio")
        do {
            _ = try wrongPeer.acceptChannels(token: token, workerPID: getpid() + 1, doctor: true, timeout: 0.1)
            fatalError("wrong peer accepted")
        } catch {}
        var rejectedByte: UInt8 = 0
        check(Darwin.read(rejectedSocket, &rejectedByte, 1) <= 0, "wrong peer connection closed")
        close(rejectedSocket)
        let timeout = try WorkerTransport.Listener()
        do {
            _ = try timeout.acceptChannels(token: token, workerPID: getpid(), doctor: true, timeout: 0.1)
            fatalError("missing handshake accepted")
        } catch {}
    }

    static func child(_ mode: String) throws {
        WorkerTransport.installSignals()
        let stdio = pair(), errors = pair()
        DispatchQueue.global().async {
            if mode == "echo" {
                // Echo incrementally, then send one last response after stdin EOF.
                var buffer = [UInt8](repeating: 0, count: 4096)
                while true {
                    let n = Darwin.read(stdio[1], &buffer, buffer.count)
                    if n == 0 { break }
                    check(n > 0, "echo read")
                    writeBytes(stdio[1], Array(buffer.prefix(n)))
                }
                writeBytes(stdio[1], Array("after EOF".utf8))
                writeBytes(errors[1], Array("diagnostic".utf8))
            } else if mode == "worker-eof" {
                writeBytes(stdio[1], Array("done".utf8))
            } else {
                writeBytes(stdio[1], [82])
                check(readAll(stdio[1]).isEmpty, "signal produces EOF")
                if mode == "signal-timeout" { return } // Keep socket open to exercise grace timeout.
                writeBytes(stdio[1], Array("cleaned".utf8))
            }
            close(stdio[1])
            // Worker stdout EOF must not wait for another holder of stderr.
            if mode != "worker-eof" { close(errors[1]) }
        }
        exit(try WorkerTransport.relay(stdio: stdio[0], stderrSocket: errors[0], signalGrace: 0.3))
    }
}
