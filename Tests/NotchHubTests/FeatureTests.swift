import AppKit
import Foundation
import Testing
@testable import NotchHub

private func statusLine(five: Double?, resets: Date, week: Double? = nil) -> HookEvent {
    var limits: [String: Any] = [:]
    if let five { limits["five_hour"] = ["used_percentage": five, "resets_at": resets.timeIntervalSince1970] }
    if let week { limits["seven_day"] = ["used_percentage": week, "resets_at": resets.addingTimeInterval(86_400 * 3).timeIntervalSince1970] }
    let object: [String: Any] = ["hook_event_name": "NotchHubStatusLine", "session_id": "s1", "rate_limits": limits]
    return HookEvent(json: try! JSONSerialization.data(withJSONObject: object))!
}

@MainActor @Suite struct UsageLimitTests {
    @Test func statusLineUpdatesLimitsWithoutTouchingSessions() {
        let store = ClaudeStore()
        let resets = Date().addingTimeInterval(3600)
        store.handle(statusLine(five: 23.5, resets: resets, week: 41))
        #expect(store.limits.fiveHour?.usedPercentage == 23.5)
        #expect(store.limits.sevenDay?.usedPercentage == 41)
        #expect(store.sessions.isEmpty)
        #expect(store.lastEventAt == nil)
    }

    @Test func warnsOncePerThresholdWithinAWindow() {
        let store = ClaudeStore()
        var peeks: [PeekReason] = []
        store.onPeek = { peeks.append($0) }
        let resets = Date().addingTimeInterval(3600)
        store.handle(statusLine(five: 70, resets: resets))
        store.handle(statusLine(five: 82, resets: resets))
        store.handle(statusLine(five: 85, resets: resets))
        store.handle(statusLine(five: 96, resets: resets))
        #expect(peeks == [.usage(80), .usage(95)])
        // A new window starts over.
        store.handle(statusLine(five: 81, resets: resets.addingTimeInterval(5 * 3600)))
        #expect(peeks.last == .usage(80))
        #expect(peeks.count == 3)
    }

    @Test func expiredWindowsDisappear() {
        let limits = UsageLimits(fiveHour: UsageWindow(usedPercentage: 50, resetsAt: Date().addingTimeInterval(-1)), sevenDay: nil)
        #expect(limits.current().isEmpty)
    }

    @Test func limitsSurviveARestart() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("usage-\(UUID()).json")
        let store = ClaudeStore(limitsURL: url)
        store.handle(statusLine(five: 12, resets: Date().addingTimeInterval(3600)))
        let reloaded = ClaudeStore(limitsURL: url)
        #expect(reloaded.limits.fiveHour?.usedPercentage == 12)
    }

    @Test func resetTextIsHumanReadable() {
        let now = Date()
        #expect(UsageWindow(usedPercentage: 1, resetsAt: now.addingTimeInterval(2 * 3600 + 14 * 60 + 5)).resetText(from: now) == "2 sa 14 dk")
        #expect(UsageWindow(usedPercentage: 1, resetsAt: now.addingTimeInterval(3 * 86_400 + 3600)).resetText(from: now) == "3 gün 1 sa")
        #expect(UsageWindow(usedPercentage: 1, resetsAt: now.addingTimeInterval(20)).resetText(from: now) == "1 dk")
    }
}

@MainActor @Suite struct TerminalJumpTests {
    @Test func ancestryReachesARealParent() {
        let chain = ProcessTree.ancestors(of: getpid())
        #expect(chain.first?.pid == getpid())
        #expect(chain.count >= 2)
        #expect(chain[0].parent == chain[1].pid)
    }

    @Test func hookEventsCarryAncestryOnlyWhereNeeded() {
        let ppid = getpid()
        let start = HookEvent(json: Data(#"{"notchhub_ppid":\#(ppid),"hook_event_name":"SessionStart","session_id":"a"}"#.utf8))!
        let tool = HookEvent(json: Data(#"{"notchhub_ppid":\#(ppid),"hook_event_name":"PreToolUse","session_id":"a"}"#.utf8))!
        #expect(start.ancestors.first?.pid == ppid)
        #expect(tool.ancestors.isEmpty)
    }

    @Test func tabScriptsOnlyForScriptableTerminals() {
        #expect(TerminalJump.tabScript(bundleID: "com.apple.Terminal", tty: "/dev/ttys003")?.contains("/dev/ttys003") == true)
        #expect(TerminalJump.tabScript(bundleID: "com.googlecode.iterm2", tty: "/dev/ttys003") != nil)
        #expect(TerminalJump.tabScript(bundleID: "com.mitchellh.ghostty", tty: "/dev/ttys003") == nil)
        #expect(TerminalJump.tabScript(bundleID: "com.apple.Terminal", tty: #"x" & do shell script "y"#)?.contains(#"""#) == true)
    }

    @Test func sessionRemembersItsTerminal() {
        let store = ClaudeStore()
        // The test runner's own ancestry has no regular app in CI-like runs, so feed a known one.
        store.handle(HookEvent(json: Data(#"{"hook_event_name":"SessionStart","session_id":"a","cwd":"/tmp/x"}"#.utf8))!)
        #expect(store.sessions["a"]?.terminal == nil)
        let finder = NSWorkspace.shared.runningApplications.first { $0.bundleIdentifier == "com.apple.finder" }
        if let finder {
            let location = TerminalJump.locate(ancestors: [ProcessTree.Entry(pid: finder.processIdentifier, parent: 1, tty: "/dev/ttys009")])
            #expect(location?.bundleID == "com.apple.finder")
            #expect(location?.tty == "/dev/ttys009")
        }
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
