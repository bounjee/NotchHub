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

    @Test func eyesMoveWhenLooking() {
        let eyes = { (pose: Clawd.Pose) in Clawd.rows(pose)[1].enumerated().filter { $0.element == "." && (3...14).contains($0.offset) }.map(\.offset) }
        #expect(eyes(.normal) == [5, 12])
        #expect(eyes(.lookLeft) == [4, 11])
        #expect(eyes(.lookRight) == [6, 13])
        #expect(eyes(.blink).isEmpty)
    }

    @Test func sleepingEyesAreClosedNotGone() {
        let row = Clawd.rows(.asleep)[1]
        #expect(row.enumerated().filter { $0.element == "_" }.map(\.offset) == [4, 5, 12, 13])
        // In the double-height image, the upper half of each eye is body and the lower half is open.
        guard let image = Clawd.image(.asleep, color: .white),
              let data = image.dataProvider?.data, let bytes = CFDataGetBytePtr(data) else {
            Issue.record("no image")
            return
        }
        let alpha = { (x: Int, yFromTop: Int) in bytes[yFromTop * image.bytesPerRow + x * 4 + 3] }
        #expect(image.height == Clawd.height * 2)
        for x in [4, 5, 12, 13] {
            #expect(alpha(x, 2) > 0)   // eyelid
            #expect(alpha(x, 3) == 0)  // closed-eye line, two pixels wide
        }
        #expect(alpha(3, 3) > 0)   // body next to it
        #expect(alpha(6, 3) > 0)
    }
}

@MainActor @Suite struct PetBrainTests {
    private func store(working: Bool = false, usage: Double? = nil) -> ClaudeStore {
        let store = ClaudeStore()
        if working {
            store.handle(HookEvent(json: Data(#"{"hook_event_name":"UserPromptSubmit","session_id":"a","cwd":"/x/dolphydesk"}"#.utf8))!)
        }
        if let usage {
            let resets = Date().addingTimeInterval(3600).timeIntervalSince1970
            store.handle(HookEvent(json: Data(#"{"hook_event_name":"NotchHubStatusLine","session_id":"a","rate_limits":{"five_hour":{"used_percentage":\#(usage),"resets_at":\#(resets)}}}"#.utf8))!)
        }
        return store
    }

    @Test func threeFactsWhenNothingIsGoingOn() {
        let battery = BatteryMonitor()
        battery.update(percent: 80, plugged: true, charging: true)
        #expect(PetBrain.info(store: store(), battery: battery) == ["Claude: boşta", "Limit: bilgi yok", "Pil: %80 · şarjda"])
    }

    @Test func threeFactsWhileWorking() {
        let store = store(working: true, usage: 42)
        let lines = PetBrain.info(store: store, battery: nil)
        #expect(lines[0] == "Claude: dolphydesk çalışıyor")
        #expect(lines[1] == "Limit: 5 saat %42")
        #expect(lines.count == 2)
    }

    @Test func latestFinishIsNamed() {
        let store = ClaudeStore()
        let start = Date()
        for (id, project, end) in [("a", "studio", 10.0), ("b", "dolphydesk", 50.0)] {
            store.handle(HookEvent(json: Data(#"{"hook_event_name":"UserPromptSubmit","session_id":"\#(id)","cwd":"/x","notchhub_project":"\#(project)"}"#.utf8))!, now: start)
            store.handle(HookEvent(json: Data(#"{"hook_event_name":"PreToolUse","session_id":"\#(id)","tool_name":"Bash","tool_input":{"command":"ls"},"tool_use_id":"\#(id)"}"#.utf8))!, now: start)
            store.handle(HookEvent(json: Data(#"{"hook_event_name":"Stop","session_id":"\#(id)","background_tasks":[]}"#.utf8))!, now: start.addingTimeInterval(end))
        }
        let lines = PetBrain.info(store: store, battery: nil, now: start.addingTimeInterval(170))
        #expect(lines[0] == "Claude: 2 bitti")
        #expect(lines[2] == "Son biten: dolphydesk · 2 dk önce")
    }

    @Test func napsAfterAWhile() {
        #expect(PetBrain.sleepAfter >= 30)
    }
}
