import AppKit
import Foundation
import Testing
@testable import NotchHub

private func hook(_ name: String, _ fields: [String: Any] = [:], session: String = "s1") -> HookEvent {
    var object: [String: Any] = ["hook_event_name": name, "session_id": session, "cwd": "/Users/me/code/project"]
    object.merge(fields) { $1 }
    return HookEvent(json: try! JSONSerialization.data(withJSONObject: object))!
}

private func bash(_ command: String, id: String? = nil) -> [String: Any] {
    var fields: [String: Any] = ["tool_name": "Bash", "tool_input": ["command": command]]
    if let id { fields["tool_use_id"] = id }
    return fields
}

@MainActor
func makeModel() -> NotchModel {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("model-\(UUID().uuidString)")
    return NotchModel(
        claude: ClaudeStore(),
        shelf: Shelf(storeURL: dir.appendingPathComponent("shelf.json")),
        clipboard: ClipboardHistory(pasteboard: NSPasteboard(name: .init("notchhub-test-\(UUID())")))
    )
}

@MainActor @Suite struct NotchModelTests {
    @Test func usageWarningIsACompactActivity() {
        let model = makeModel()
        model.showPeek(.usage(80), hovering: false)
        #expect(model.presentation == .compact)
        #expect(model.compactWingWidth == PeekReason.usage(80).wingWidth)
    }

    @Test func peeksNeverInterruptAPanelTheUserOpened() {
        let model = makeModel()
        model.open()
        model.showPeek(.usage(80), hovering: false)
        model.showPeek(.permission, hovering: false)
        #expect(model.presentation == .open)
        #expect(!model.isPeeking)
    }

    @Test func noPeekWhileHovering() {
        let model = makeModel()
        model.showPeek(.usage(80), hovering: true)
        #expect(model.presentation == .closed)
    }

    @Test func summonedPanelLingersForThePointer() {
        let model = makeModel()
        model.showPeek(.summoned, hovering: false)
        #expect(model.presentation == .open)
        #expect(model.isPeeking)
    }

    @Test func finishingAnnouncesTheProjectBriefly() {
        let model = makeModel()
        model.showPeek(.claudeDone("my-app"), hovering: false)
        #expect(model.presentation == .compact)
        #expect(model.peek == .claudeDone("my-app"))
        #expect(model.lastFinished == "my-app")
        #expect(model.claudeCelebration == 1)
        // Sized to the name, never a full-width banner.
        #expect(model.compactWingWidth < 200)
    }

    @Test func simultaneousFinishesAreAnnouncedInTurn() async throws {
        let model = makeModel()
        model.showPeek(.claudeDone("a"), hovering: false)
        model.showPeek(.claudeDone("b"), hovering: false)
        #expect(model.peek == .claudeDone("a"))
        try await Task.sleep(for: .milliseconds(2800))
        #expect(model.peek == .claudeDone("a"))
        // Allow for a late timer on a busy CI runner.
        for _ in 0..<50 where model.peek == .claudeDone("a") { try await Task.sleep(for: .milliseconds(100)) }
        #expect(model.peek == .claudeDone("b"))
    }

    @Test func openingThePanelMarksFinishedTurnsSeen() {
        let model = makeModel()
        model.claude.handle(hook("UserPromptSubmit"))
        model.claude.handle(hook("PreToolUse", ["tool_name": "Bash", "tool_input": ["command": "ls"], "tool_use_id": "t"]))
        model.claude.handle(hook("Stop", ["background_tasks": []]))
        #expect(model.claude.indicator == ClosedIndicator(kind: .done, count: 1))
        model.open()
        #expect(model.claude.indicator == nil)
        #expect(model.claude.sessions["s1"]?.status == .done)
    }

    @Test func closedContentStaysRightOfTheNotch() {
        let model = makeModel()
        #expect(NotchRootView.wings(model) == (NotchRootView.closedTopRadius, NotchRootView.closedTopRadius))
        model.claude.handle(hook("UserPromptSubmit"))
        let busy = NotchRootView.wings(model)
        #expect(busy.left == NotchRootView.closedTopRadius)
        #expect(busy.right > busy.left)
        model.showPeek(.claudeDone("x"), hovering: false)
        #expect(NotchRootView.wings(model).left == NotchRootView.closedTopRadius)
    }

    @Test func compactActivityDoesNotReplaceAnOpenPeek() {
        let model = makeModel()
        model.showPeek(.permission, hovering: false)
        model.showPeek(.usage(95), hovering: false)
        #expect(model.presentation == .open)
        #expect(model.peek == .permission)
    }

    @Test func openPeekReplacesACompactActivity() {
        let model = makeModel()
        model.showPeek(.usage(80), hovering: false)
        model.showPeek(.permission, hovering: false)
        #expect(model.presentation == .open)
    }

    @Test func peekEndsByItself() async throws {
        let model = makeModel()
        model.showPeek(.claudeDone("x"), hovering: false)
        try await Task.sleep(for: .milliseconds(2800))
        #expect(model.isPeeking)
        // A busy CI runner can fire the 3 s timer late; allow a few seconds of slack.
        for _ in 0..<50 where model.isPeeking { try await Task.sleep(for: .milliseconds(100)) }
        #expect(model.presentation == .closed)
        #expect(!model.isPeeking)
    }

    @Test func hoverDuringPeekKeepsItOpen() async throws {
        let model = makeModel()
        model.showPeek(.permission, hovering: false)
        model.adoptPeekAsHover()
        try await Task.sleep(for: .milliseconds(4300))
        #expect(model.presentation == .open)
    }
}

@MainActor @Suite struct ClaudeStoreEdgeTests {
    let store = ClaudeStore()

    @Test func repeatedIdenticalCommandGetsTheRightToolUseID() {
        let first = RecordingResponder()
        store.handle(hook("PreToolUse", bash("npm test", id: "t1")))
        store.handle(hook("PostToolUse", bash("npm test", id: "t1")))
        // Second run: the request arrives before its async PreToolUse.
        store.handle(hook("PermissionRequest", bash("npm test")), responder: first)
        #expect(store.pending.first?.toolUseID == nil)
        store.handle(hook("PreToolUse", bash("npm test", id: "t2")))
        #expect(store.pending.first?.toolUseID == "t2")
        store.handle(hook("PostToolUse", bash("npm test", id: "t2")))
        #expect(store.pending.isEmpty)
    }

    @Test func parallelIdenticalRequestsGetDistinctIDs() {
        store.handle(hook("PreToolUse", bash("ls", id: "a")))
        store.handle(hook("PreToolUse", bash("ls", id: "b")))
        let r1 = RecordingResponder(), r2 = RecordingResponder()
        store.handle(hook("PermissionRequest", bash("ls")), responder: r1)
        store.handle(hook("PermissionRequest", bash("ls")), responder: r2)
        #expect(Set(store.pending.compactMap(\.toolUseID)) == ["a", "b"])
        store.handle(hook("PostToolUse", bash("ls", id: "a")))
        #expect(store.pending.count == 1)
        #expect(store.pending.first?.toolUseID == "b")
    }

    @Test func headlinePrefersTheMostUrgentStatus() {
        store.handle(hook("Stop", ["background_tasks": []], session: "done"))
        #expect(store.headlineStatus == .done)
        store.handle(hook("UserPromptSubmit", session: "busy"))
        #expect(store.headlineStatus == .working)
        store.handle(hook("PermissionRequest", bash("rm x"), session: "ask"), responder: RecordingResponder())
        #expect(store.headlineStatus == .needsApproval)
        store.answer(store.pending[0].id, .allow)
        #expect(store.headlineStatus == .working)
    }

    @Test func lateEventsDoNotReviveAFailedSession() {
        store.handle(hook("StopFailure", ["error": "rate_limit"]))
        store.handle(hook("PostToolUse", bash("ls", id: "z")))
        #expect(store.sessions["s1"]?.status == .error)
    }

    @Test func idleNotificationDoesNotHideAPendingRequest() {
        store.handle(hook("PermissionRequest", bash("ls")), responder: RecordingResponder())
        store.handle(hook("Notification", ["notification_type": "idle_prompt"]))
        #expect(store.sessions["s1"]?.status == .needsApproval)
    }

    @Test func stopWithoutMessageKeepsThePreviousAnswer() {
        store.handle(hook("Stop", ["background_tasks": [], "last_assistant_message": "first"]))
        store.handle(hook("UserPromptSubmit"))
        store.handle(hook("Stop", ["background_tasks": []]))
        #expect(store.sessions["s1"]?.lastMessage == "first")
    }

    @Test func peeksOnlyWhenReallyDone() {
        var peeks: [PeekReason] = []
        store.onPeek = { peeks.append($0) }
        store.handle(hook("UserPromptSubmit"))
        store.handle(hook("PreToolUse", bash("ls", id: "t1")))
        // A shell left running in the background does not keep the turn from being done.
        store.handle(hook("Stop", ["background_tasks": [["id": "b"]]]))
        #expect(peeks == [.claudeDone("project")])
    }

    @Test func quickHelperSessionsAreNotCelebratedOrKept() {
        var peeks: [PeekReason] = []
        store.onPeek = { peeks.append($0) }
        // A title or suggestion helper: prompt, answer, gone within a second, no tools.
        let start = Date()
        store.handle(hook("SessionStart", session: "helper"), now: start)
        store.handle(hook("UserPromptSubmit", session: "helper"), now: start)
        store.handle(hook("Stop", ["background_tasks": [], "last_assistant_message": "Başlık"], session: "helper"), now: start.addingTimeInterval(0.5))
        #expect(peeks.isEmpty)
        store.handle(hook("SessionEnd", session: "helper"), now: start.addingTimeInterval(0.6))
        #expect(store.sessions["helper"] == nil)
    }

    @Test func aLongAnswerWithoutToolsStillCounts() {
        var peeks: [PeekReason] = []
        store.onPeek = { peeks.append($0) }
        let start = Date()
        store.handle(hook("UserPromptSubmit"), now: start)
        store.handle(hook("Stop", ["background_tasks": []]), now: start.addingTimeInterval(12))
        #expect(peeks == [.claudeDone("project")])
        store.handle(hook("SessionEnd"), now: start.addingTimeInterval(12.2))
        #expect(store.sessions["s1"]?.status == .done)
    }

    @Test func dismissingASessionReleasesItsHook() {
        let responder = RecordingResponder()
        store.handle(hook("PermissionRequest", bash("ls")), responder: responder)
        store.dismiss("s1")
        #expect(store.sessions["s1"] == nil)
        #expect(responder.replies == [#"{"decision":"none"}"#])
    }

    @Test func sessionEndWithoutStartIsHarmless() {
        store.handle(hook("SessionEnd", session: "ghost"))
        #expect(store.sessions.isEmpty)
        #expect(store.headlineStatus == nil)
    }

    @Test func malformedPayloadsAreRejected() {
        #expect(HookEvent(json: Data("{}".utf8)) == nil)
        #expect(HookEvent(json: Data(#"{"hook_event_name":"Stop"}"#.utf8)) == nil)
        #expect(HookEvent(json: Data("[1,2]".utf8)) == nil)
        #expect(HookEvent(json: Data(#"{"hook_event_name":"Stop","session_id":"x","tool_input":"not an object"}"#.utf8)) != nil)
    }

    @Test func labelsComeFromTheWorkingDirectory() {
        store.handle(HookEvent(json: Data(#"{"hook_event_name":"SessionStart","session_id":"a","cwd":"/Users/me/code/my-app"}"#.utf8))!)
        store.handle(HookEvent(json: Data(#"{"hook_event_name":"SessionStart","session_id":"b","cwd":""}"#.utf8))!)
        #expect(store.sessions["a"]?.label == "my-app")
        #expect(store.sessions["b"]?.label == "Claude")
    }
}
