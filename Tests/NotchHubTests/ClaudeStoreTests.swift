import Foundation
import Testing
@testable import NotchHub

final class RecordingResponder: PermissionReplying, @unchecked Sendable {
    private(set) var replies: [String] = []
    func reply(_ line: Data) {
        replies.append(String(decoding: line, as: UTF8.self).trimmingCharacters(in: .newlines))
    }
}

private func event(_ name: String, _ fields: [String: Any] = [:], session: String = "s1") -> HookEvent {
    var object: [String: Any] = ["hook_event_name": name, "session_id": session, "cwd": "/Users/me/code/demo"]
    object.merge(fields) { $1 }
    return HookEvent(json: try! JSONSerialization.data(withJSONObject: object))!
}

nonisolated(unsafe) private let bash: [String: Any] = ["tool_name": "Bash", "tool_input": ["command": "npm test"]]

@MainActor @Suite struct ClaudeStoreTests {
    let store = ClaudeStore()

    @Test func sessionLifecycle() {
        store.handle(event("SessionStart"))
        #expect(store.sessions["s1"]?.status == .idle)
        #expect(store.sessions["s1"]?.label == "demo")

        store.handle(event("UserPromptSubmit"))
        #expect(store.sessions["s1"]?.status == .working)

        store.handle(event("PreToolUse", bash.merging(["tool_use_id": "t1"]) { $1 }))
        #expect(store.sessions["s1"]?.currentTool == "Bash: npm test")

        store.handle(event("Stop", ["last_assistant_message": "**Bitti**", "background_tasks": []]))
        #expect(store.sessions["s1"]?.status == .done)
        #expect(store.sessions["s1"]?.lastMessage == "**Bitti**")

        store.handle(event("SessionEnd"))
        #expect(store.sessions["s1"]?.status == .done)

        store.handle(event("UserPromptSubmit", session: "s2"))
        store.handle(event("SessionEnd", session: "s2"))
        #expect(store.sessions["s2"] == nil)
    }

    @Test func mcpToolNamesAreReadable() {
        store.handle(event("PreToolUse", ["tool_name": "mcp__github__create_issue", "tool_input": ["title": "Bug"], "tool_use_id": "m1"]))
        #expect(store.sessions["s1"]?.currentTool == "github · create_issue: Bug")
    }

    @Test func stopWithBackgroundTasksKeepsWorking() {
        store.handle(event("Stop", ["background_tasks": [["id": "b1"]]]))
        #expect(store.sessions["s1"]?.status == .working)
    }

    @Test func latePostToolUseDoesNotReviveDone() {
        store.handle(event("Stop", ["background_tasks": []]))
        store.handle(event("PostToolUse", bash.merging(["tool_use_id": "t1"]) { $1 }))
        #expect(store.sessions["s1"]?.status == .done)
        store.handle(event("PreToolUse", bash.merging(["tool_use_id": "t2"]) { $1 }))
        #expect(store.sessions["s1"]?.status == .working)
    }

    @Test func questionDuringATurnMeansWaiting() {
        store.handle(event("Notification", ["notification_type": "permission_prompt"]))
        #expect(store.sessions["s1"] == nil)
        store.handle(event("UserPromptSubmit"))
        store.handle(event("Notification", ["notification_type": "elicitation_dialog"]))
        #expect(store.sessions["s1"]?.status == .waitingForUser)
    }

    @Test func idlePromptAfterAFinishedTurnStaysDone() {
        store.handle(event("UserPromptSubmit"))
        store.handle(event("Stop", ["background_tasks": []]))
        store.handle(event("Notification", ["notification_type": "idle_prompt"]))
        #expect(store.sessions["s1"]?.status == .done)
        store.handle(event("Notification", ["notification_type": "agent_needs_input"]))
        #expect(store.sessions["s1"]?.status == .done)
    }

    @Test func stopFailureIsError() {
        store.handle(event("StopFailure", ["error": "rate_limit"]))
        #expect(store.sessions["s1"]?.status == .error)
    }

    @Test func answeringFromPanel() {
        let responder = RecordingResponder()
        var peeks: [PeekReason] = []
        store.onPeek = { peeks.append($0) }
        store.handle(event("PreToolUse", bash.merging(["tool_use_id": "t1"]) { $1 }))
        store.handle(event("PermissionRequest", bash), responder: responder)
        #expect(store.sessions["s1"]?.status == .needsApproval)
        #expect(store.pending.first?.toolUseID == "t1")
        #expect(store.pending.first?.summary == "npm test")
        #expect(peeks == [.permission])

        store.answer(store.pending[0].id, .deny)
        #expect(responder.replies == [#"{"decision":"deny"}"#])
        #expect(store.pending.isEmpty)
        #expect(store.sessions["s1"]?.status == .working)
    }

    @Test func allowAlwaysPassesSuggestions() throws {
        let responder = RecordingResponder()
        let suggestion: [String: Any] = ["type": "addRules", "behavior": "allow", "destination": "localSettings",
                                         "rules": [["toolName": "Bash", "ruleContent": "npm test"]]]
        store.handle(event("PermissionRequest", bash.merging(["permission_suggestions": [suggestion]]) { $1 }), responder: responder)
        store.answer(store.pending[0].id, .allowAlways)
        let reply = try JSONSerialization.jsonObject(with: Data(responder.replies[0].utf8)) as! [String: Any]
        #expect(reply["decision"] as? String == "allow")
        #expect((reply["updatedPermissions"] as? [Any])?.count == 1)
    }

    @Test func terminalAnswerClosesRequestOnPostToolUse() {
        let responder = RecordingResponder()
        store.handle(event("PermissionRequest", bash), responder: responder)
        // async PreToolUse can arrive after the request
        store.handle(event("PreToolUse", bash.merging(["tool_use_id": "t9"]) { $1 }))
        #expect(store.pending.first?.toolUseID == "t9")
        store.handle(event("PostToolUse", ["tool_name": "Read", "tool_input": ["file_path": "/x"], "tool_use_id": "other"]))
        #expect(store.pending.count == 1)
        store.handle(event("PostToolUse", bash.merging(["tool_use_id": "t9"]) { $1 }))
        #expect(store.pending.isEmpty)
        #expect(responder.replies == [#"{"decision":"none"}"#])
    }

    @Test func userPromptCancelsPendingRequest() {
        let responder = RecordingResponder()
        store.handle(event("PermissionRequest", bash), responder: responder)
        store.handle(event("PermissionRequest", bash, session: "s2"), responder: RecordingResponder())
        store.handle(event("UserPromptSubmit"))
        #expect(responder.replies == [#"{"decision":"none"}"#])
        #expect(store.pending.map(\.sessionID) == ["s2"])
    }

    @Test func closedHookConnectionDropsRequest() {
        let responder = RecordingResponder()
        store.handle(event("PermissionRequest", bash), responder: responder)
        store.responderClosed(responder)
        #expect(store.pending.isEmpty)
        #expect(store.sessions["s1"]?.status == .working)
    }

    @Test func doneSessionsExpire() {
        let start = Date()
        store.handle(event("Stop", ["background_tasks": []]), now: start)
        store.handle(event("UserPromptSubmit", session: "s2"), now: start)
        store.removeExpiredSessions(now: start.addingTimeInterval(9 * 60))
        #expect(store.sessions.count == 2)
        store.removeExpiredSessions(now: start.addingTimeInterval(11 * 60))
        #expect(Array(store.sessions.keys) == ["s2"])
        store.removeExpiredSessions(now: start.addingTimeInterval(31 * 60))
        #expect(store.sessions.isEmpty)
    }

    @Test func toolSummaries() {
        #expect(HookEvent.summary(tool: "Edit", input: ["file_path": NSHomeDirectory() + "/a.swift"]) == "~/a.swift")
        #expect(HookEvent.summary(tool: "WebFetch", input: ["url": "https://x.dev"]) == "https://x.dev")
        #expect(HookEvent.summary(tool: "mcp__foo", input: ["b": "two", "a": "one"]) == "one")
    }
}


import AppKit

