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
        #expect(decision["message"] as? String == "Kullanıcı çentikten reddetti")
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

    private func waitUntil(_ condition: () -> Bool) throws {
        let deadline = Date().addingTimeInterval(2)
        while !condition() && Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
        #expect(condition())
    }
}

final class EventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []
    func append(_ name: String) { lock.withLock { storage.append(name) } }
    var names: [String] { lock.withLock { storage } }
}
