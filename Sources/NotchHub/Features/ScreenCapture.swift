import AppKit
import Observation
@preconcurrency import ScreenCaptureKit

/// Screenshots to the clipboard and screen recordings to a file, from the Capture tab.
///
/// Screenshots use the system's own `screencapture` tool, so selection, window shadows and
/// the shutter sound are exactly what Cmd-Shift-4 gives. Recordings use ScreenCaptureKit's
/// file output, so they can be stopped from the notch.
@MainActor @Observable
final class ScreenCapture: NSObject {
    enum Shot: CaseIterable {
        case area, window, screen

        /// `screencapture` arguments: always to the clipboard, never to a file.
        var arguments: [String] {
            switch self {
            case .area: ["-i", "-c", "-s"]
            case .window: ["-i", "-c", "-w"]
            // The display with the notch, which macOS counts as the main one.
            case .screen: ["-c", "-m"]
            }
        }
    }

    enum Recording: Equatable {
        case screen
        /// A window (or display) chosen in the system's sharing picker.
        case picked
    }

    /// Without it macOS hands out the wallpaper instead of the windows, without an error.
    private(set) var hasPermission = CGPreflightScreenCaptureAccess()
    private(set) var recordingSince: Date?
    private(set) var lastError: String?
    var isRecording: Bool { recordingSince != nil }

    /// A screenshot reached the clipboard, or a recording was saved and copied as a file.
    var onCaptured: ((_ isVideo: Bool, _ file: URL?) -> Void)?
    /// Called just before a capture starts, so the panel can get out of the way.
    var onWillCapture: (() -> Void)?

    private var stream: SCStream?
    private var output: SCRecordingOutput?
    private var outputURL: URL?

    static var recordingsFolder: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Movies/NotchHub")
    }

    /// "Recording 2026-10-21 at 14.05.33.mov", like the system's own names.
    static func recordingName(at date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return "Recording \(formatter.string(from: date)).mov"
    }

    func refreshPermission() {
        hasPermission = CGPreflightScreenCaptureAccess()
    }

    /// Asks once; afterwards macOS only lets the user switch it on in System Settings.
    func requestPermission() {
        hasPermission = CGRequestScreenCaptureAccess()
        if !hasPermission { Self.openPrivacySettings() }
    }

    /// macOS only applies a newly granted Screen Recording permission to a fresh launch.
    static func relaunch() {
        let path = Bundle.main.bundleURL.path
        let opener = Process()
        opener.executableURL = URL(fileURLWithPath: "/bin/sh")
        // Wait for this instance to quit, or the new one sees the old socket and steps aside.
        opener.arguments = ["-c", "sleep 1; /usr/bin/open \"$0\"", path]
        try? opener.run()
        NSApp.terminate(nil)
    }

    static func openPrivacySettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
    }

    // MARK: - Screenshots

    func take(_ shot: Shot) {
        refreshPermission()
        guard hasPermission else { requestPermission(); return }
        lastError = nil
        onWillCapture?()
        let before = NSPasteboard.general.changeCount
        Task {
            // Let the panel close first so it is not in the picture.
            try? await Task.sleep(for: .milliseconds(350))
            let status = await Self.run("/usr/sbin/screencapture", shot.arguments)
            // Escape cancels the selection: nothing new on the clipboard, nothing to say.
            if status == 0, NSPasteboard.general.changeCount != before {
                onCaptured?(false, nil)
            }
        }
    }

    private static func run(_ path: String, _ arguments: [String]) async -> Int32 {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = arguments
            process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
            do { try process.run() } catch { continuation.resume(returning: -1) }
        }
    }

    // MARK: - Recording

    func startRecording(_ kind: Recording) {
        refreshPermission()
        guard !isRecording else { return }
        lastError = nil
        switch kind {
        case .screen:
            guard hasPermission else { requestPermission(); return }
            Task { await recordMainDisplay() }
        case .picked:
            // The system picker is its own consent, and keeps macOS's reminders away.
            let picker = SCContentSharingPicker.shared
            picker.add(self)
            var configuration = SCContentSharingPickerConfiguration()
            configuration.allowedPickerModes = [.singleWindow, .singleDisplay]
            configuration.excludedBundleIDs = [Bundle.main.bundleIdentifier ?? ""]
            picker.defaultConfiguration = configuration
            picker.isActive = true
            onWillCapture?()
            picker.present()
        }
    }

    func stopRecording() {
        guard let stream else { return }
        Task { try? await stream.stopCapture() }
    }

    private func recordMainDisplay() async {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            let mainID = CGMainDisplayID()
            guard let display = content.displays.first(where: { $0.displayID == mainID }) ?? content.displays.first else {
                lastError = String(localized: "No screen to record")
                return
            }
            // Leave NotchHub itself out: the panel and the recording dot would only get in the way.
            let ours = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
            let filter = SCContentFilter(display: display, excludingApplications: ours, exceptingWindows: [])
            onWillCapture?()
            try await record(filter)
        } catch {
            fail(error)
        }
    }

    private func record(_ filter: SCContentFilter) async throws {
        let configuration = SCStreamConfiguration()
        let scale = CGFloat(filter.pointPixelScale)
        configuration.width = Int(filter.contentRect.width * scale)
        configuration.height = Int(filter.contentRect.height * scale)
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        configuration.showsCursor = true
        configuration.capturesAudio = false

        try FileManager.default.createDirectory(at: Self.recordingsFolder, withIntermediateDirectories: true)
        let url = Self.recordingsFolder.appendingPathComponent(Self.recordingName(at: Date()))
        let recordingConfiguration = SCRecordingOutputConfiguration()
        recordingConfiguration.outputURL = url
        recordingConfiguration.outputFileType = .mov
        recordingConfiguration.videoCodecType = .hevc

        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        let output = SCRecordingOutput(configuration: recordingConfiguration, delegate: self)
        try stream.addRecordingOutput(output)
        self.stream = stream
        self.output = output
        outputURL = url
        try await stream.startCapture()
        recordingSince = Date()
    }

    private func finish() {
        let url = outputURL
        stream = nil
        output = nil
        outputURL = nil
        recordingSince = nil
        guard let url, FileManager.default.fileExists(atPath: url.path) else { return }
        // As a file: Finder, Messages, Slack and most chat apps paste a video file, few take raw video.
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([url as NSURL])
        onCaptured?(true, url)
    }

    private func fail(_ error: Error) {
        stream = nil
        output = nil
        outputURL = nil
        recordingSince = nil
        refreshPermission()
        lastError = hasPermission ? error.localizedDescription : nil
    }
}

extension ScreenCapture: SCStreamDelegate, SCRecordingOutputDelegate, SCContentSharingPickerObserver {
    nonisolated func stream(_ stream: SCStream, didStopWithError error: any Error) {
        Task { @MainActor in
            // Stopped from the system (the menu bar's recording indicator) keeps what was recorded.
            if self.outputURL != nil, FileManager.default.fileExists(atPath: self.outputURL!.path) { self.finish() } else { self.fail(error) }
        }
    }

    nonisolated func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) {
        Task { @MainActor in self.finish() }
    }

    nonisolated func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: any Error) {
        Task { @MainActor in self.fail(error) }
    }

    nonisolated func contentSharingPicker(_ picker: SCContentSharingPicker, didUpdateWith filter: SCContentFilter, for stream: SCStream?) {
        Task { @MainActor in
            picker.remove(self)
            picker.isActive = false
            do { try await self.record(filter) } catch { self.fail(error) }
        }
    }

    nonisolated func contentSharingPicker(_ picker: SCContentSharingPicker, didCancelFor stream: SCStream?) {
        Task { @MainActor in
            picker.remove(self)
            picker.isActive = false
        }
    }

    nonisolated func contentSharingPickerStartDidFailWithError(_ error: any Error) {
        Task { @MainActor in self.fail(error) }
    }
}
