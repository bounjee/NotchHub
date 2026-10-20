import Foundation
import Testing
@testable import NotchHub

/// Robustness of the socket server under the conditions real hooks create.
import os
let lastConnectError = OSAllocatedUnfairLock(initialState: Int32(0))

@Suite(.serialized) struct HubServerTests {
    let path = FileManager.default.temporaryDirectory
        .appendingPathComponent("nhs-\(UUID().uuidString.prefix(8))/hub.sock").path

    final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var events: [HookEvent] = []
        private var closes = 0
        func add(_ event: HookEvent) { lock.withLock { events.append(event) } }
        func closed() { lock.withLock { closes += 1 } }
        var count: Int { lock.withLock { events.count } }
        var closeCount: Int { lock.withLock { closes } }
        var sessionIDs: Set<String> { lock.withLock { Set(events.map(\.sessionID)) } }
    }

    func start(_ recorder: Recorder, timeout: Int = 5) throws -> HubServer {
        let server = HubServer(path: path, firstLineTimeout: timeout, onEvent: { event, _ in recorder.add(event) }, onClose: { _ in recorder.closed() })
        try server.start()
        return server
    }

    /// Connects and returns the descriptor, or -1.
    func connectClient() -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: Array(path.utf8)) }
        var result: Int32 = -1
        for _ in 0..<6 {
            result = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
            }
            if result == 0 || errno != ECONNREFUSED { break }
            usleep(20_000)
        }
        if result != 0 { lastConnectError.withLock { $0 = errno } }
        return result == 0 ? fd : -1
    }

    func send(_ fd: Int32, _ text: String) {
        let data = Array(text.utf8)
        var offset = 0
        while offset < data.count {
            let n = data[offset...].withUnsafeBufferPointer { write(fd, $0.baseAddress, $0.count) }
            if n <= 0 { return }
            offset += n
        }
    }

    func waitUntil(_ seconds: Double = 3, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition() && Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
        return condition()
    }

    @Test func manyConcurrentHooksAreAllDelivered() throws {
        let recorder = Recorder()
        _ = try start(recorder)
        let failures = Recorder()
        DispatchQueue.concurrentPerform(iterations: 100) { i in
            let fd = connectClient()
            guard fd >= 0 else { failures.closed(); return }
            send(fd, #"{"hook_event_name":"PreToolUse","session_id":"s\#(i)"}"# + "\n")
            close(fd)
        }
        _ = waitUntil { recorder.count == 100 }
        #expect(failures.closeCount == 0, "connect failures \(failures.closeCount), errno \(lastConnectError.withLock { $0 })")
        #expect(recorder.count == 100, "delivered \(recorder.count), closes \(recorder.closeCount)")
        #expect(recorder.sessionIDs.count == 100)
    }

    @Test func largePayloadInManyChunks() throws {
        let recorder = Recorder()
        _ = try start(recorder)
        let big = String(repeating: "x", count: 2_000_000)
        let fd = connectClient()
        send(fd, #"{"hook_event_name":"Stop","session_id":"big","last_assistant_message":"\#(big)"}"# + "\n")
        close(fd)
        #expect(waitUntil { recorder.count == 1 })
    }

    @Test func silentClientIsDroppedAfterTheTimeout() throws {
        let recorder = Recorder()
        _ = try start(recorder, timeout: 1)
        let fd = connectClient()
        send(fd, #"{"hook_event_name":"Stop""#)  // never finishes the line
        #expect(waitUntil(3) { recorder.closeCount == 1 })
        #expect(recorder.count == 0)
        close(fd)
    }

    @Test func waitingRequestIsNotTimedOut() throws {
        let recorder = Recorder()
        _ = try start(recorder, timeout: 1)
        let fd = connectClient()
        send(fd, #"{"hook_event_name":"PermissionRequest","session_id":"p"}"# + "\n")
        #expect(waitUntil { recorder.count == 1 })
        Thread.sleep(forTimeInterval: 1.5)
        #expect(recorder.closeCount == 0)
        close(fd)
        #expect(waitUntil { recorder.closeCount == 1 })
    }

    @Test func detectsALiveServer() throws {
        #expect(!HubServer.isServing(at: path))
        _ = try start(Recorder())
        #expect(HubServer.isServing(at: path))
    }

    @Test func onlyRemovesItsOwnSocketFile() throws {
        let first = try start(Recorder())
        let second = try start(Recorder())  // takes over the path
        first.removeSocketFile()
        #expect(FileManager.default.fileExists(atPath: path))
        second.removeSocketFile()
        #expect(!FileManager.default.fileExists(atPath: path))
    }

    @Test func garbageLinesAreIgnored() throws {
        let recorder = Recorder()
        _ = try start(recorder)
        for line in ["not json\n", "[]\n", "{}\n", "\n"] {
            let fd = connectClient()
            send(fd, line)
            close(fd)
        }
        #expect(waitUntil { recorder.closeCount == 4 })
        #expect(recorder.count == 0)
    }
}
