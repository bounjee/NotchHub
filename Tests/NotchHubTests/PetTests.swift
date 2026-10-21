import Foundation
import Testing
@testable import NotchHub

@Suite struct ClawdArtTests {
    @Test func everyPoseIsAFullGrid() {
        for pose in Clawd.Pose.allCases {
            let rows = Clawd.rows(pose)
            #expect(rows.count == Clawd.height, "\(pose)")
            #expect(rows.allSatisfy { $0.count == Clawd.width }, "\(pose)")
            #expect(rows.joined().allSatisfy { "#._".contains($0) }, "\(pose)")
            #expect(Clawd.image(pose, color: Clawd.orange) != nil)
        }
    }

    @Test func eyesOpenAndBlink() {
        let eyes = { (pose: Clawd.Pose) in Clawd.rows(pose)[1].enumerated().filter { $0.element == "." && (3...14).contains($0.offset) }.map(\.offset) }
        #expect(eyes(.normal) == [5, 12])
        #expect(eyes(.blink).isEmpty)
    }

    @Test func sleepingEyesAreThinLinesWhereTheEyesAre() {
        let row = Clawd.rows(.asleep)[1]
        #expect(row.enumerated().filter { $0.element == "_" }.map(\.offset) == [5, 12])
        guard let image = Clawd.image(.asleep, color: .white),
              let data = image.dataProvider?.data, let bytes = CFDataGetBytePtr(data) else {
            Issue.record("no image")
            return
        }
        let alpha = { (x: Int, yFromTop: Int) in bytes[yFromTop * image.bytesPerRow + x * 4 + 3] }
        #expect(image.height == Clawd.height * Clawd.subrows)
        // Row 1 spans image rows 4...7 from the top; the line is row 6.
        for x in [5, 12] {
            #expect(alpha(x, 4) > 0)
            #expect(alpha(x, 5) > 0)
            #expect(alpha(x, 6) == 0)
            #expect(alpha(x, 7) > 0)
        }
        // Only the eye column is cut, a single pixel wide.
        for x in [4, 6, 11, 13] { #expect(alpha(x, 6) > 0) }
    }}

@MainActor @Suite struct PetBrainTests {
    private func store(working: Bool = false, usage: Double? = nil) -> ClaudeStore {
        let store = ClaudeStore()
        if working {
            store.handle(HookEvent(json: Data(#"{"hook_event_name":"UserPromptSubmit","session_id":"a","cwd":"/x/my-app"}"#.utf8))!)
        }
        if let usage {
            let resets = Date().addingTimeInterval(3600).timeIntervalSince1970
            store.handle(HookEvent(json: Data(#"{"hook_event_name":"NotchHubStatusLine","session_id":"a","rate_limits":{"five_hour":{"used_percentage":\#(usage),"resets_at":\#(resets)}}}"#.utf8))!)
        }
        return store
    }

    @Test func factsComeOneAtATimeInAFixedOrder() {
        let facts = PetBrain.info(store: store(working: true, usage: 42))
        #expect(facts == ["my-app · Working", "5-hour limit: 42% used"])
    }

    @Test func idleWithoutData() {
        #expect(PetBrain.info(store: store()) == ["No Claude session running", "Usage: no data yet"])
    }

    @Test func latestFinishIsNamed() {
        let store = ClaudeStore()
        let start = Date()
        for (id, project, end) in [("a", "studio", 10.0), ("b", "my-app", 50.0)] {
            store.handle(HookEvent(json: Data(#"{"hook_event_name":"UserPromptSubmit","session_id":"\#(id)","cwd":"/x","notchhub_project":"\#(project)"}"#.utf8))!, now: start)
            store.handle(HookEvent(json: Data(#"{"hook_event_name":"PreToolUse","session_id":"\#(id)","tool_name":"Bash","tool_input":{"command":"ls"},"tool_use_id":"\#(id)"}"#.utf8))!, now: start)
            store.handle(HookEvent(json: Data(#"{"hook_event_name":"Stop","session_id":"\#(id)","background_tasks":[]}"#.utf8))!, now: start.addingTimeInterval(end))
        }
        let lines = PetBrain.info(store: store, now: start.addingTimeInterval(170))
        #expect(lines[0] == "2 done")
        #expect(lines[2] == "my-app finished 2m ago")
    }

    @Test func napsAfterAWhile() {
        #expect(PetBrain.sleepAfter >= 30)
    }
}

@Suite struct TypingPoseTests {
    @Test func typingKeepsTheMascotsFootprintAndAlternatesArms() throws {
        for pose in [Clawd.Pose.typeLeft, .typeRight, .typeIdle] {
            let grid = try #require(Clawd.typingGrid(pose))
            #expect(grid.count == Clawd.height * 2)
            #expect(grid.allSatisfy { $0.count == Clawd.width })
        }
        let left = try #require(Clawd.typingGrid(.typeLeft)), right = try #require(Clawd.typingGrid(.typeRight))
        // The pressing arm sits on the lid's edge, the other stays up.
        #expect(left[7][1] == "#" && left[4][1] == ".")
        #expect(left[4][16] == "#" && left[7][16] == ".")
        #expect(right[7][16] == "#" && right[4][1] == "#")
        #expect(Clawd.typingGrid(.normal) == nil)
        #expect(Clawd.image(.typeLeft, color: Clawd.orange)?.width == Clawd.width)
    }
}

@Suite struct PetDoubleClickTests {
    @Test func doubleClickGoesToTheMostUrgentSessionWithATerminal() {
        let terminal = TerminalLocation(appPID: 1, bundleID: "com.apple.Terminal", tty: "/dev/ttys001", cwd: nil)
        var asking = ClaudeSession(id: "a", label: "api")
        asking.status = .needsApproval
        var done = ClaudeSession(id: "b", label: "web", terminal: terminal)
        done.status = .done
        var waiting = ClaudeSession(id: "c", label: "docs", terminal: terminal)
        waiting.status = .waitingForUser
        // Sorted most urgent first; the asking one has no known terminal, so it is skipped.
        #expect(PetBrain.sessionToOpen([asking, waiting, done])?.id == "c")
        #expect(PetBrain.sessionToOpen([asking]) == nil)
        #expect(PetBrain.sessionToOpen([]) == nil)
    }
}
