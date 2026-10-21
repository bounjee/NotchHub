import Foundation
import Testing
@testable import NotchHub

@MainActor @Suite struct QuestionTests {
    private func event(_ name: String, _ fields: [String: Any] = [:], session: String = "s1") -> HookEvent {
        var object: [String: Any] = ["hook_event_name": name, "session_id": session, "cwd": "/Users/me/code/app"]
        object.merge(fields) { $1 }
        return HookEvent(json: try! JSONSerialization.data(withJSONObject: object))!
    }

    private let ask: [String: Any] = [
        "tool_name": "AskUserQuestion", "tool_use_id": "q1",
        "tool_input": ["questions": [["question": "Which database should we use?", "header": "DB", "options": [], "multiSelect": false]]],
    ]

    @Test func askUserQuestionWaitsForTheUser() {
        let store = ClaudeStore()
        var peeks: [PeekReason] = []
        store.onPeek = { peeks.append($0) }
        store.handle(event("UserPromptSubmit"))
        store.handle(event("PreToolUse", ask))
        #expect(store.sessions["s1"]?.status == .waitingForUser)
        #expect(store.sessions["s1"]?.currentTool == "Which database should we use?")
        #expect(peeks == [.question("app")])
        #expect(store.indicator?.kind == .waitingForUser)

        // Answered in the terminal: back to work.
        store.handle(event("PostToolUse", ask))
        #expect(store.sessions["s1"]?.status == .working)
    }

    @Test func questionsNeverBecomePermissionCards() {
        let store = ClaudeStore()
        let responder = RecordingResponder()
        store.handle(event("UserPromptSubmit"))
        store.handle(event("PermissionRequest", ask), responder: responder)
        #expect(store.pending.isEmpty)
        #expect(responder.replies == [#"{"decision":"none"}"#])
        #expect(store.sessions["s1"]?.status == .waitingForUser)

        store.handle(event("PermissionRequest", ["tool_name": "ExitPlanMode", "tool_input": [:]]), responder: responder)
        #expect(store.pending.isEmpty)
    }

    @Test func aTurnEndingOnAQuestionWaitsInsteadOfFinishing() {
        let store = ClaudeStore()
        var peeks: [PeekReason] = []
        store.onPeek = { peeks.append($0) }
        store.handle(event("UserPromptSubmit"))
        store.handle(event("Stop", ["background_tasks": [], "last_assistant_message": "I found two options.\n\nShould I use **Postgres** or SQLite?"]))
        #expect(store.sessions["s1"]?.status == .waitingForUser)
        #expect(peeks == [.question("app")])

        store.handle(event("UserPromptSubmit"))
        store.handle(event("PreToolUse", ["tool_name": "Bash", "tool_input": ["command": "ls"], "tool_use_id": "b"]))
        store.handle(event("Stop", ["background_tasks": [], "last_assistant_message": "All tests pass."]))
        #expect(store.sessions["s1"]?.status == .done)
        #expect(peeks.last == .claudeDone("app"))
    }

    @Test func detectsQuestions() {
        #expect(ClaudeStore.asksQuestion("Which one should we use?"))
        #expect(ClaudeStore.asksQuestion("Done.\n\n**Want me to push it?**\n"))
        #expect(ClaudeStore.asksQuestion("Hangisini istersin?"))
        #expect(ClaudeStore.asksQuestion("Shall I continue? (yes/no)") == false)
        #expect(!ClaudeStore.asksQuestion("Why? Because the cache was stale. Fixed now."))
        #expect(!ClaudeStore.asksQuestion("```swift\nlet x = a ?? b?\n```"))
        #expect(!ClaudeStore.asksQuestion(""))
    }

    @Test func doneAndQuestionAnnouncementsQueue() {
        let model = makeModel()
        model.showPeek(.claudeDone("api"), hovering: false)
        model.showPeek(.question("web"), hovering: false)
        #expect(model.peek == .claudeDone("api"))
    }
}
