import AppKit
import Foundation
import Testing
@testable import NotchHub

private func hook(_ name: String, _ fields: [String: Any] = [:], session: String = "s1") -> HookEvent {
    var object: [String: Any] = ["hook_event_name": name, "session_id": session, "cwd": "/tmp/project"]
    object.merge(fields) { $1 }
    return HookEvent(json: try! JSONSerialization.data(withJSONObject: object))!
}

private func bash(_ command: String, id: String? = nil) -> [String: Any] {
    var fields: [String: Any] = ["tool_name": "Bash", "tool_input": ["command": command]]
    if let id { fields["tool_use_id"] = id }
    return fields
}

@MainActor
private func makeModel() -> NotchModel {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("model-\(UUID().uuidString)")
    return NotchModel(
        claude: ClaudeStore(),
        shelf: Shelf(storeURL: dir.appendingPathComponent("shelf.json")),
        clipboard: ClipboardHistory(pasteboard: NSPasteboard(name: .init("notchhub-test-\(UUID())"))),
        battery: BatteryMonitor()
    )
}

@MainActor @Suite struct NotchModelTests {
    @Test func compactActivityShowsWhenClosed() {
        let model = makeModel()
        model.showPeek(.copied("hello"), hovering: false)
        #expect(model.presentation == .compact)
        #expect(model.compactWingWidth == PeekReason.copied("").wingWidth)
    }

    @Test func peeksNeverInterruptAPanelTheUserOpened() {
        let model = makeModel()
        model.open(tab: .shelf)
        model.showPeek(.copied("x"), hovering: false)
        model.showPeek(.permission, hovering: false)
        #expect(model.presentation == .open)
        #expect(model.tab == .shelf)
        #expect(!model.isPeeking)
    }

    @Test func noPeekWhileHoveringOrDragging() {
        let model = makeModel()
        model.showPeek(.power, hovering: true)
        #expect(model.presentation == .closed)
        model.drag = .files
        model.showPeek(.power, hovering: false)
        #expect(model.presentation == .closed)
    }

    @Test func claudeFinishingOnlyMakesTheMascotHop() {
        let model = makeModel()
        model.showPeek(.claudeDone("dolphydesk"), hovering: false)
        #expect(model.presentation == .closed)
        #expect(model.claudeCelebration == 1)
    }

    @Test func closedContentStaysRightOfTheNotch() {
        let model = makeModel()
        #expect(NotchRootView.wings(model) == (NotchRootView.closedTopRadius, NotchRootView.closedTopRadius))
        model.claude.handle(hook("UserPromptSubmit"))
        let busy = NotchRootView.wings(model)
        #expect(busy.left == NotchRootView.closedTopRadius)
        #expect(busy.right > busy.left)
        model.showPeek(.copied("x"), hovering: false)
        #expect(NotchRootView.wings(model).left == NotchRootView.closedTopRadius)
    }

    @Test func compactActivityDoesNotReplaceAClaudePeek() {
        let model = makeModel()
        model.showPeek(.permission, hovering: false)
        model.showPeek(.copied("x"), hovering: false)
        #expect(model.presentation == .open)
        #expect(model.peek == .permission)
    }

    @Test func claudePeekReplacesACompactActivity() {
        let model = makeModel()
        model.showPeek(.power, hovering: false)
        model.showPeek(.permission, hovering: false)
        #expect(model.presentation == .open)
        #expect(model.tab == .claude)
    }

    @Test func peekEndsByItself() async throws {
        let model = makeModel()
        model.showPeek(.copied("x"), hovering: false)
        try await Task.sleep(for: .milliseconds(1900))
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

    @Test func dragKeepsThePanelOpen() {
        let model = makeModel()
        model.open()
        model.drag = .files
        model.close()
        #expect(model.isOpen)
        model.drag = nil
        model.close()
        #expect(!model.isOpen)
    }

    @Test func defaultTabFollowsClaudeActivity() {
        let model = makeModel()
        model.select(.clipboard)
        model.close()
        model.open()
        #expect(model.tab == .clipboard)

        model.close()
        model.claude.handle(hook("UserPromptSubmit"))
        model.open()
        #expect(model.tab == .claude)
    }

    @Test func requestedTabWins() {
        let model = makeModel()
        model.claude.handle(hook("UserPromptSubmit"))
        model.open(tab: .shelf)
        #expect(model.tab == .shelf)
    }
}

@MainActor @Suite struct BatteryMonitorTests {
    @Test func stateAtLaunchIsNotNews() {
        let battery = BatteryMonitor()
        #expect(battery.update(percent: 10, plugged: false, charging: false).isEmpty)
        let full = BatteryMonitor()
        #expect(full.update(percent: 100, plugged: true, charging: false).isEmpty)
    }

    @Test func plugAndUnplug() {
        let battery = BatteryMonitor()
        battery.update(percent: 60, plugged: false, charging: false)
        #expect(battery.update(percent: 60, plugged: true, charging: true) == [.pluggedChanged])
        #expect(battery.update(percent: 60, plugged: false, charging: false) == [.pluggedChanged])
    }

    @Test func lowBatteryWarnsOncePerDischarge() {
        let battery = BatteryMonitor()
        battery.update(percent: 30, plugged: false, charging: false)
        #expect(battery.update(percent: 20, plugged: false, charging: false) == [.low])
        #expect(battery.update(percent: 15, plugged: false, charging: false).isEmpty)
        battery.update(percent: 15, plugged: true, charging: true)
        #expect(battery.update(percent: 15, plugged: false, charging: false) == [.pluggedChanged, .low])
    }

    @Test func fullChargeAnnouncedOnce() {
        let battery = BatteryMonitor()
        battery.update(percent: 98, plugged: true, charging: true)
        #expect(battery.update(percent: 100, plugged: true, charging: false) == [.charged])
        #expect(battery.update(percent: 100, plugged: true, charging: false).isEmpty)
    }
}

@MainActor @Suite struct ClipboardBehaviorTests {
    private func history() -> (ClipboardHistory, NSPasteboard) {
        let pasteboard = NSPasteboard(name: .init("notchhub-test-\(UUID())"))
        return (ClipboardHistory(pasteboard: pasteboard), pasteboard)
    }

    @Test func pollAnnouncesNewCopies() {
        let (history, pasteboard) = history()
        var announced: [String] = []
        history.onNewItem = { announced.append($0.text) }
        pasteboard.clearContents()
        pasteboard.setString("from another app", forType: .string)
        history.poll()
        history.poll()
        #expect(announced == ["from another app"])
    }

    @Test func ownWritesAreNotAnnounced() {
        let (history, pasteboard) = history()
        var announced = 0
        history.onNewItem = { _ in announced += 1 }
        history.add("dropped text")
        history.poll()
        #expect(announced == 0)
        #expect(pasteboard.string(forType: .string) == "dropped text")
        #expect(history.items.first?.text == "dropped text")

        history.copy(history.items[0])
        history.poll()
        #expect(announced == 0)
    }

    @Test func finderFileCopiesAreIgnored() {
        let (history, pasteboard) = history()
        pasteboard.clearContents()
        pasteboard.writeObjects([URL(fileURLWithPath: "/etc/hosts") as NSURL])
        history.poll()
        #expect(history.items.isEmpty)
    }

    @Test func pinnedItemsStayOnTopAndSurviveClear() {
        let (history, _) = history()
        history.record("a")
        history.record("b")
        history.togglePin(history.items.first { $0.text == "a" }!)
        #expect(history.items.map(\.text) == ["a", "b"])

        for i in 0..<30 { history.record("n\(i)") }
        #expect(history.items.first?.text == "a")
        #expect(history.items.filter { !$0.isPinned }.count == ClipboardHistory.limit)

        history.clear()
        #expect(history.items.map(\.text) == ["a"])
    }

    @Test func recopyingAPinnedItemKeepsItPinned() {
        let (history, _) = history()
        history.record("keep")
        history.togglePin(history.items[0])
        history.record("other")
        history.record("keep")
        #expect(history.items.filter { $0.text == "keep" }.count == 1)
        #expect(history.items.first { $0.text == "keep" }?.isPinned == true)
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
        store.handle(hook("Stop", ["background_tasks": [["id": "b"]]]))
        #expect(peeks.isEmpty)
        store.handle(hook("Stop", ["background_tasks": []]))
        #expect(peeks == [.claudeDone("project")])
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
