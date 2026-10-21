import Foundation
import Testing
@testable import NotchHub

@MainActor @Suite struct CaptureTests {
    @Test func screenshotsGoToTheClipboardOnly() {
        for shot in ScreenCapture.Shot.allCases {
            #expect(shot.arguments.contains("-c"))
            // No file argument: every word is a flag.
            #expect(shot.arguments.allSatisfy { $0.hasPrefix("-") })
        }
        #expect(ScreenCapture.Shot.area.arguments.contains("-s"))
        #expect(ScreenCapture.Shot.window.arguments.contains("-w"))
        #expect(!ScreenCapture.Shot.screen.arguments.contains("-i"))
    }

    @Test func recordingsAreNamedLikeTheSystemDoes() {
        var components = DateComponents()
        components.year = 2026; components.month = 10; components.day = 21
        components.hour = 14; components.minute = 5; components.second = 33
        let date = Calendar.current.date(from: components)!
        #expect(ScreenCapture.recordingName(at: date) == "Recording 2026-10-21 at 14.05.33.mov")
        #expect(ScreenCapture.recordingsFolder.path.hasSuffix("Movies/NotchHub"))
    }

    @Test func capturePeeksSayWhatWasCopied() {
        #expect(PeekReason.captured(video: false).title == "Screenshot copied")
        #expect(PeekReason.captured(video: true).title == "Recording copied")
        #expect(PeekReason.captured(video: true).detail == nil)
        #expect(PeekReason.captured(video: false).wingWidth > 100)
    }

    @Test func captureIsATabAndIdleWithoutARecording() {
        let model = makeModel()
        #expect(NotchTab.allCases.contains(.capture))
        #expect(!model.capture.isRecording)
        model.open(tab: .capture)
        #expect(model.tab == .capture)
    }
}
