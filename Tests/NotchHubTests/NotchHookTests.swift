import Foundation
import Testing
@testable import NotchHub

/// Runs the built `notch-hook` binary against a real `HubServer`.
@Suite(.serialized) struct NotchHookTests {
    static let binary = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent(".build/debug/notch-hook")

    let socketPath = FileManager.default.temporaryDirectory
        .appendingPathComponent("nh-\(UUID().uuidString.prefix(8))/hub.sock").path

    struct Result { let status: Int32; let stdout: String }

    func runHook(_ input: String) throws -> Result {
        let process = Process()
        process.executableURL = Self.binary
        process.environment = ["NOTCHHUB_SOCKET": socketPath, "HOME": NSHomeDirectory()]
        let stdin = Pipe(), stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        try process.run()
        stdin.fileHandleForWriting.write(Data(input.utf8))
        try stdin.fileHandleForWriting.close()
        process.waitUntilExit()
        let output = String(decoding: stdout.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return Result(status: process.terminationStatus, stdout: output)
    }

    /// Starts a server whose reply to PermissionRequest comes from `reply`.
    func startServer(reply: @escaping @Sendable (HookEvent) -> Data?) throws -> EventLog {
        let log = EventLog()
        let server = HubServer(path: socketPath, onEvent: { event, connection in
            log.append(event.name)
            if event.name == "PermissionRequest" {
                if let line = reply(event) { connection.reply(line) }
            }
        }, onClose: { _ in })
        try server.start()
        return log
    }

    let stop = #"{"hook_event_name":"Stop","session_id":"s1","cwd":"/tmp","last_assistant_message":"ok"}"#
    let permission = #"{"hook_event_name":"PermissionRequest","session_id":"s1","cwd":"/tmp","tool_name":"Bash","tool_input":{"command":"ls"}}"#

    @Test func silentWhenAppIsNotRunning() throws {
        let result = try runHook(stop)
        #expect(result.status == 0)
        #expect(result.stdout.isEmpty)
        let permissionResult = try runHook(permission)
        #expect(permissionResult.status == 0)
        #expect(permissionResult.stdout.isEmpty)
    }

    @Test func silentOnBrokenJSON() throws {
        _ = try startServer { _ in nil }
        let result = try runHook("{not json")
        #expect(result.status == 0)
        #expect(result.stdout.isEmpty)
    }

    @Test func forwardsObservedEventsWithoutOutput() throws {
        let log = try startServer { _ in nil }
        let result = try runHook(stop)
        #expect(result.status == 0)
        #expect(result.stdout.isEmpty)
        try waitUntil { log.names == ["Stop"] }
    }

    @Test func allowDecision() throws {
        _ = try startServer { _ in ClaudeStore.replyLine(.allow, suggestions: nil) }
        let result = try runHook(permission)
        #expect(result.status == 0)
        #expect(result.stdout == #"{"hookSpecificOutput":{"decision":{"behavior":"allow"},"hookEventName":"PermissionRequest"}}"# + "\n")
    }

    @Test func denyDecision() throws {
        _ = try startServer { _ in ClaudeStore.replyLine(.deny, suggestions: nil) }
        let result = try runHook(permission)
        #expect(result.status == 0)
        let object = try JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as! [String: Any]
        let output = object["hookSpecificOutput"] as! [String: Any]
        let decision = output["decision"] as! [String: Any]
        #expect(output["hookEventName"] as? String == "PermissionRequest")
        #expect(decision["behavior"] as? String == "deny")
        #expect(decision["message"] as? String == "The user denied this from the notch")
    }

    @Test func allowAlwaysForwardsRules() throws {
        let rules = try JSONSerialization.data(withJSONObject: [["type": "addRules", "behavior": "allow"]])
        _ = try startServer { _ in ClaudeStore.replyLine(.allowAlways, suggestions: rules) }
        let result = try runHook(permission)
        let object = try JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as! [String: Any]
        let decision = (object["hookSpecificOutput"] as! [String: Any])["decision"] as! [String: Any]
        #expect((decision["updatedPermissions"] as? [Any])?.count == 1)
    }

    @Test func noneDecisionPrintsNothing() throws {
        _ = try startServer { _ in ClaudeStore.replyLine(.none, suggestions: nil) }
        let result = try runHook(permission)
        #expect(result.status == 0)
        #expect(result.stdout.isEmpty)
    }

    @Test func multilineInputBecomesOneLine() throws {
        let log = try startServer { _ in nil }
        let result = try runHook("{\n  \"hook_event_name\": \"SessionStart\",\n  \"session_id\": \"s1\"\n}\n")
        #expect(result.status == 0)
        try waitUntil { log.names == ["SessionStart"] }
    }

    @Test func parallelHookProcessesAllArrive() throws {
        let log = try startServer { _ in nil }
        DispatchQueue.concurrentPerform(iterations: 40) { i in
            _ = try? runHook(#"{"hook_event_name":"PostToolUse","session_id":"p\#(i)"}"#)
        }
        try waitUntil { log.names.count == 40 }
    }

    @Test func staleSocketFileDoesNotSlowHooksDown() throws {
        // A crashed app leaves the socket file behind with nobody listening.
        try FileManager.default.createDirectory(atPath: (socketPath as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: Array(socketPath.utf8)) }
        _ = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        close(fd)
        let start = Date()
        let result = try runHook(permission)
        #expect(result.status == 0)
        #expect(result.stdout.isEmpty)
        #expect(Date().timeIntervalSince(start) < 0.5)
    }

    @Test func statusLineModeForwardsUsageAndPrintsNothing() throws {
        let received = EventBox()
        let server = HubServer(path: socketPath, onEvent: { event, _ in received.set(event) }, onClose: { _ in })
        try server.start()
        let process = Process()
        process.executableURL = Self.binary
        process.arguments = ["--statusline"]
        process.environment = ["NOTCHHUB_SOCKET": socketPath]
        let stdin = Pipe(), stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        try process.run()
        stdin.fileHandleForWriting.write(Data(#"{"hook_event_name":"Status","session_id":"s","rate_limits":{"five_hour":{"used_percentage":23.5,"resets_at":1999999999}}}"#.utf8))
        try stdin.fileHandleForWriting.close()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        #expect(stdout.fileHandleForReading.readDataToEndOfFile().isEmpty)
        try waitUntil { received.get() != nil }
        #expect(received.get()?.isStatusLine == true)
        #expect(received.get()?.fiveHour?.usedPercentage == 23.5)
        #expect(received.get()?.ancestors.isEmpty == false)
    }

    @Test func hookNamesTheGitRepositoryEvenFromAWorktree() throws {
        let received = EventBox()
        let server = HubServer(path: socketPath, onEvent: { event, _ in received.set(event) }, onClose: { _ in })
        try server.start()
        // Not under /tmp: temporary folders are deliberately unnamed.
        let base = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/notchhub-test-\(UUID().uuidString.prefix(6))")
        defer { try? FileManager.default.removeItem(at: base) }
        let repo = base.appendingPathComponent("my-app")
        let worktree = repo.appendingPathComponent(".claude/worktrees/fix-login/src")
        try FileManager.default.createDirectory(at: repo.appendingPathComponent(".git/worktrees/fix-login"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: worktree, withIntermediateDirectories: true)
        try "gitdir: \(repo.path)/.git/worktrees/fix-login\n".write(to: repo.appendingPathComponent(".claude/worktrees/fix-login/.git"), atomically: true, encoding: .utf8)

        _ = try runHook(#"{"hook_event_name":"SessionStart","session_id":"s","cwd":"\#(worktree.path)"}"#)
        try waitUntil { received.get() != nil }
        #expect(received.get()?.project == "my-app")
    }

    @Test func emptyInputExitsQuietly() throws {
        _ = try startServer { _ in nil }
        let result = try runHook("")
        #expect(result.status == 0)
        #expect(result.stdout.isEmpty)
    }

    private func waitUntil(_ condition: () -> Bool) throws {
        let deadline = Date().addingTimeInterval(2)
        while !condition() && Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
        #expect(condition())
    }
}

final class EventBox: @unchecked Sendable {
    private let lock = NSLock()
    private var event: HookEvent?
    func set(_ value: HookEvent) { lock.withLock { event = value } }
    func get() -> HookEvent? { lock.withLock { event } }
}

final class EventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []
    func append(_ name: String) { lock.withLock { storage.append(name) } }
    var names: [String] { lock.withLock { storage } }
}
