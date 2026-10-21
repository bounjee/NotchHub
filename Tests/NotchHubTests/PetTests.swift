import Foundation
import Testing
@testable import NotchHub

@Suite struct ClawdArtTests {
    @Test func everyPoseIsAFullGrid() {
        for pose in Clawd.Pose.allCases {
            let rows = Clawd.rows(pose)
            #expect(rows.count == Clawd.height, "\(pose)")
            #expect(rows.allSatisfy { $0.count == Clawd.width }, "\(pose)")
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

    @Test func smallTalkWhenNothingIsGoingOn() {
        let store = store()
        #expect(PetBrain.summary(of: store) == nil)
        #expect(PetBrain.line(0, store: store) == PetBrain.chatter[0])
        #expect(PetBrain.line(1, store: store) == PetBrain.chatter[1])
    }

    @Test func newsComesFirstThenUsageThenTalk() {
        let store = store(working: true, usage: 42)
        #expect(PetBrain.line(0, store: store) == "dolphydesk · çalışıyor")
        #expect(PetBrain.line(1, store: store) == "5 saatlik limit: %42")
        #expect(PetBrain.chatter.contains(PetBrain.line(2, store: store)))
        #expect(PetBrain.line(3, store: store) == "dolphydesk · çalışıyor")
    }

    @Test func napsAfterAWhile() {
        #expect(PetBrain.sleepAfter >= 30)
    }
}
