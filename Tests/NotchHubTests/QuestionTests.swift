import AppKit
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

    @Test func aQuestionInTheAppsWrapUpBoxWaitsForTheUser() {
        let store = ClaudeStore()
        var peeks: [PeekReason] = []
        store.onPeek = { peeks.append($0) }
        store.handle(event("UserPromptSubmit"))
        store.handle(event("PreToolUse", ["tool_name": "Bash", "tool_input": ["command": "swift test"], "tool_use_id": "b"]))
        store.handle(event("PreToolUse", ["tool_name": "mcp__ccd_turn__wrap_up", "tool_use_id": "w",
                                          "tool_input": ["recap": "Tests pass.", "ask": "Shall I push it?"]]))
        store.handle(event("Stop", ["background_tasks": [], "last_assistant_message": "All tests pass and the app is installed."]))
        #expect(store.sessions["s1"]?.status == .waitingForUser)
        #expect(store.sessions["s1"]?.currentTool == "Shall I push it?")
        #expect(peeks == [.question("app")])

        // The next turn starts clean: a recap without a question finishes normally.
        store.handle(event("UserPromptSubmit"))
        store.handle(event("PreToolUse", ["tool_name": "Bash", "tool_input": ["command": "git push"], "tool_use_id": "p"]))
        store.handle(event("PreToolUse", ["tool_name": "mcp__ccd_turn__wrap_up", "tool_use_id": "w2", "tool_input": ["recap": "Pushed."]]))
        store.handle(event("Stop", ["background_tasks": [], "last_assistant_message": "Pushed."]))
        #expect(store.sessions["s1"]?.status == .done)
        #expect(store.pendingAsks.isEmpty)
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

@MainActor @Suite struct FinishedCheckTests {
    @Test func otherActivityClearsTheDoneCheckButNotErrors() {
        let model = makeModel()
        let store = model.claude
        func send(_ name: String, _ session: String, _ fields: [String: Any] = [:]) {
            var object: [String: Any] = ["hook_event_name": name, "session_id": session, "cwd": "/Users/me/code/\(session)"]
            object.merge(fields) { $1 }
            store.handle(HookEvent(json: try! JSONSerialization.data(withJSONObject: object))!)
        }
        send("UserPromptSubmit", "a")
        send("PreToolUse", "a", ["tool_name": "Bash", "tool_input": ["command": "ls"], "tool_use_id": "1"])
        send("Stop", "a", ["background_tasks": []])
        #expect(store.indicator?.kind == .done)

        model.showPeek(.copied("hello"), hovering: false)
        #expect(store.indicator == nil)
        #expect(store.sessions["a"]?.status == .done)

        send("StopFailure", "b", ["error": "rate_limit"])
        model.showPeek(.downloaded("file.zip"), hovering: false)
        #expect(store.indicator?.kind == .error)
    }
}

@MainActor @Suite struct ShortTextTests {
    @Test func labelsShortenOnWordsWithoutDots() {
        #expect(ClaudeStore.shortLabel("NotchHub macOS uygulaması") == "NotchHub macOS")
        #expect(ClaudeStore.shortLabel("web-app") == "web-app")
        #expect(ClaudeStore.shortLabel("averyveryverylongprojectname") == "averyveryverylon")
        #expect(!ClaudeStore.shortLabel("one two three four five six").contains("…"))
    }

    @Test func peeksNameTheirSourceAndFitTheirWing() {
        #expect(PeekReason.question("api").title == "api")
        #expect(PeekReason.question("api").detail == "asks you")
        #expect(PeekReason.copied("https://example.com/a").detail == "link")
        #expect(PeekReason.downloaded("a-very-long-file-name-from-the-web.zip").title == "Download")
        let short = PeekReason.claudeDone("api").wingWidth
        let long = PeekReason.claudeDone("NotchHub macOS").wingWidth
        #expect(long > short)
        #expect(PeekReason.permission.wingWidth == 30)
    }

    @Test func storeAnnouncesShortLabels() {
        let store = ClaudeStore()
        var peeks: [PeekReason] = []
        store.onPeek = { peeks.append($0) }
        let start = HookEvent(json: Data(#"{"hook_event_name":"UserPromptSubmit","session_id":"x","cwd":"/tmp/x","session_title":"NotchHub macOS uygulaması"}"#.utf8))!
        store.handle(start)
        store.handle(HookEvent(json: Data(#"{"hook_event_name":"Stop","session_id":"x","background_tasks":[],"last_assistant_message":"Shall I continue?"}"#.utf8))!)
        #expect(peeks == [.question("NotchHub macOS")])
    }

    @Test func bubbleWrapsInsteadOfCutting() {
        let font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        let lines = PetView.wrap("❔ NotchHub macOS asks you about the next release plan", width: 150, font: font)
        #expect(lines.count > 1)
        #expect(lines.joined(separator: " ") == "❔ NotchHub macOS asks you about the next release plan")
    }
}
