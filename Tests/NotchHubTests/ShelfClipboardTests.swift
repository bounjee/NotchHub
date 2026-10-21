import AppKit
import Foundation
import Testing
@testable import NotchHub

private func hook(_ name: String, session: String = "s1") -> HookEvent {
    HookEvent(json: Data(#"{"hook_event_name":"\#(name)","session_id":"\#(session)","cwd":"/Users/me/code/project"}"#.utf8))!
}

@MainActor @Suite struct NotchTabTests {
    @Test func noPeekWhileDragging() {
        let model = makeModel()
        model.drag = .files
        model.showPeek(.copied("x"), hovering: false)
        #expect(model.presentation == .closed)
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

    @Test func permissionPeekShowsClaude() {
        let model = makeModel()
        model.select(.shelf)
        model.showPeek(.permission, hovering: false)
        #expect(model.tab == .claude)
    }

    @Test func headlineStaysShortBesideTheTabs() {
        let store = ClaudeStore()
        store.handle(hook("UserPromptSubmit", session: "a"))
        #expect(ClaudeHeadline.summary(store.sortedSessions) == "project · Working")
        store.handle(hook("UserPromptSubmit", session: "b"))
        store.handle(hook("Notification", session: "c"))
        let waiting = HookEvent(json: Data(#"{"hook_event_name":"Notification","session_id":"b","notification_type":"elicitation_dialog"}"#.utf8))!
        store.handle(waiting)
        #expect(ClaudeHeadline.summary(store.sortedSessions) == "1 waiting for you · 1 more")
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

@MainActor @Suite struct ClipboardHistoryTests {
    @Test func dedupesAndLimits() {
        let history = ClipboardHistory(pasteboard: NSPasteboard(name: .init("notchhub-test-\(UUID())")))
        for i in 0..<25 { history.record("item \(i)") }
        history.record("item 3")
        #expect(history.items.count == ClipboardHistory.limit)
        #expect(history.items.first?.text == "item 3")
        #expect(history.items.filter { $0.text == "item 3" }.count == 1)
        history.record("   ")
        history.record(String(repeating: "x", count: 10_001))
        #expect(history.items.first?.text == "item 3")
    }

    @Test func skipsConcealedItems() {
        let pasteboard = NSPasteboard(name: .init("notchhub-test-\(UUID())"))
        let history = ClipboardHistory(pasteboard: pasteboard)
        pasteboard.clearContents()
        pasteboard.declareTypes([.string, .init("org.nspasteboard.ConcealedType")], owner: nil)
        pasteboard.setString("hunter2", forType: .string)
        history.poll()
        #expect(history.items.isEmpty)

        pasteboard.clearContents()
        pasteboard.setString("hello", forType: .string)
        history.poll()
        #expect(history.items.map(\.text) == ["hello"])
    }
}

@MainActor @Suite struct ShelfTests {
    @Test func persistsPathsAndDropsDeletedFiles() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("shelf-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let keep = dir.appendingPathComponent("keep.txt"), gone = dir.appendingPathComponent("gone.txt")
        try Data("a".utf8).write(to: keep)
        try Data("b".utf8).write(to: gone)
        let store = dir.appendingPathComponent("shelf.json")

        let shelf = Shelf(storeURL: store)
        shelf.add([keep, gone, keep])
        #expect(shelf.items.count == 2)

        try FileManager.default.removeItem(at: gone)
        let reloaded = Shelf(storeURL: store)
        #expect(reloaded.items.map(\.url.lastPathComponent) == ["keep.txt"])
        #expect(FileManager.default.fileExists(atPath: keep.path))
    }
}

@MainActor @Suite struct ClipboardKindTests {
    @Test func detectsColors() {
        #expect(ClipboardKind.detect("#ff8800") == .color(red: 1, green: 136.0 / 255, blue: 0, alpha: 1))
        #expect(ClipboardKind.detect("#FFF") == .color(red: 1, green: 1, blue: 1, alpha: 1))
        #expect(ClipboardKind.detect("#12345") == .text)
        #expect(ClipboardKind.detect("#hello") == .text)
    }

    @Test func detectsLinks() {
        #expect(ClipboardKind.detect("https://notchy.dev/pricing") == .link(URL(string: "https://notchy.dev/pricing")!))
        #expect(ClipboardKind.detect("see https://notchy.dev") == .text)
        #expect(ClipboardKind.detect("ftp://x.y") == .text)
    }

    @Test func detectsJSONAndCode() {
        #expect(ClipboardKind.detect(#"{"a": [1, 2]}"#) == .json)
        #expect(ClipboardKind.detect("{not json") == .text)
        #expect(ClipboardKind.detect("func a() {\n    return 1\n}") == .code)
        #expect(ClipboardKind.detect("Merhaba\ndünya") == .text)
    }

    @Test func formatsJSON() {
        let history = ClipboardHistory(pasteboard: NSPasteboard(name: .init("notchhub-test-\(UUID())")))
        history.record(#"{"b":1,"a":2}"#)
        history.copyFormattedJSON(history.items[0])
        #expect(history.items.first?.text == "{\n  \"a\" : 2,\n  \"b\" : 1\n}")
    }
}

@MainActor @Suite struct FileArrivalTests {
    @Test func unfinishedDownloadsAreNotArrivals() {
        #expect(!FileArrivals.isFinished("movie.mp4.crdownload", siblings: []))
        #expect(!FileArrivals.isFinished("Report.pdf.download", siblings: []))
        #expect(!FileArrivals.isFinished(".DS_Store", siblings: []))
        #expect(!FileArrivals.isFinished("big.zip", siblings: ["big.zip", "big.zip.part"]))
        #expect(FileArrivals.isFinished("big.zip", siblings: ["big.zip"]))
    }

    @Test func noticesANewDownload() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("dl-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("old".utf8).write(to: folder.appendingPathComponent("old.txt"))
        let arrivals = FileArrivals(downloadsURL: folder)
        var arrived: [String] = []
        arrivals.onArrival = { url, kind in if kind == .download { arrived.append(url.lastPathComponent) } }
        arrivals.start(screenshots: false)

        // In progress, then renamed when complete, as browsers do.
        try Data("data".utf8).write(to: folder.appendingPathComponent("new.zip.crdownload"))
        try await Task.sleep(for: .milliseconds(300))
        try FileManager.default.moveItem(at: folder.appendingPathComponent("new.zip.crdownload"), to: folder.appendingPathComponent("new.zip"))
        for _ in 0..<40 where arrived.isEmpty { try await Task.sleep(for: .milliseconds(100)) }
        #expect(arrived == ["new.zip"])
    }
}

@MainActor @Suite struct ShelfExpiryTests {
    @Test func automaticItemsExpireManualOnesStay() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("shelf-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let manual = dir.appendingPathComponent("manual.txt"), shot = dir.appendingPathComponent("shot.png")
        try Data("a".utf8).write(to: manual)
        try Data("b".utf8).write(to: shot)
        let shelf = Shelf(storeURL: dir.appendingPathComponent("shelf.json"))
        let long = Date().addingTimeInterval(-2 * 86_400)
        shelf.add([manual], now: long)
        shelf.add([shot], source: .screenshot, now: long)
        shelf.removeExpired()
        #expect(shelf.items.map(\.url.lastPathComponent) == ["manual.txt"])
    }

    @Test func oldShelfFilesStillLoad() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("shelf-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("a.txt")
        try Data("a".utf8).write(to: file)
        let store = dir.appendingPathComponent("shelf.json")
        try Data(#"[{"path":"\#(file.path)"}]"#.utf8).write(to: store)
        #expect(Shelf(storeURL: store).items.count == 1)
    }
}

