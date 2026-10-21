import AppKit
import SwiftUI

/// `NotchHub --snapshot <dir>` renders the notch and the mascot with sample sessions to PNG
/// files: for design review and for the README. Nothing on the real screen is captured.
@MainActor
enum Snapshot {
    static func run(into directory: URL) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let claude = ClaudeStore()
        let model = NotchModel(claude: claude)
        model.notchSize = NotchGeometry.builtInScreen().map(NotchGeometry.notchSize(of:)) ?? CGSize(width: 185, height: 32)

        let backdrop = LinearGradient(
            colors: [Color(red: 0.16, green: 0.18, blue: 0.27), Color(red: 0.31, green: 0.24, blue: 0.33)],
            startPoint: .topLeading, endPoint: .bottomTrailing
        )
        let host = NSHostingView(rootView: NotchRootView(model: model).background(backdrop))
        let window = NSWindow(contentRect: NSRect(x: -3000, y: -3000, width: 720, height: 420), styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = host
        window.orderFrontRegardless()

        func capture(_ name: String, height: CGFloat? = nil) {
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.9))
            var bounds = host.bounds
            // The view is flipped: keep the top strip when cropping.
            if let height { bounds = CGRect(x: 0, y: 0, width: bounds.width, height: height) }
            guard let rep = host.bitmapImageRepForCachingDisplay(in: bounds) else { return }
            host.cacheDisplay(in: bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent("\(name).png"))
        }

        func send(_ object: [String: Any], responder: PermissionReplying? = nil) {
            claude.handle(HookEvent(json: try! JSONSerialization.data(withJSONObject: object))!, responder: responder)
        }
        func work(_ id: String, _ project: String, tool: String, input: [String: Any]) {
            send(["hook_event_name": "UserPromptSubmit", "session_id": id, "cwd": "/Users/me/code/\(project)", "notchhub_project": project])
            send(["hook_event_name": "PreToolUse", "session_id": id, "cwd": "/Users/me/code/\(project)", "tool_name": tool,
                  "tool_input": input, "tool_use_id": "t-\(id)"])
        }

        capture("closed-idle", height: 90)

        work("a", "web-app", tool: "Bash", input: ["command": "npm test -- --watch=false"])
        work("b", "api", tool: "Edit", input: ["file_path": "/Users/me/code/api/src/routes/users.ts"])
        capture("closed-working", height: 90)

        model.showPeek(.claudeDone("landing-page"), hovering: false)
        capture("closed-done", height: 90)
        model.close()

        let responder = SnapshotResponder()
        send(["hook_event_name": "PermissionRequest", "session_id": "b", "cwd": "/Users/me/code/api", "tool_name": "Bash",
              "tool_input": ["command": "rm -rf node_modules && npm install"],
              "permission_suggestions": [["type": "addRules", "behavior": "allow", "destination": "localSettings"]]], responder: responder)
        capture("closed-permission", height: 90)

        send(["hook_event_name": "NotchHubStatusLine", "session_id": "a", "rate_limits": [
            "five_hour": ["used_percentage": 42, "resets_at": Date().addingTimeInterval(2 * 3600 + 840).timeIntervalSince1970],
            "seven_day": ["used_percentage": 23, "resets_at": Date().addingTimeInterval(4 * 86_400).timeIntervalSince1970],
        ]])
        send(["hook_event_name": "UserPromptSubmit", "session_id": "c", "cwd": "/Users/me/code/landing-page", "notchhub_project": "landing-page"])
        send(["hook_event_name": "PreToolUse", "session_id": "c", "cwd": "/Users/me/code/landing-page", "tool_name": "Write",
              "tool_input": ["file_path": "/Users/me/code/landing-page/index.html"], "tool_use_id": "t-c"])
        send(["hook_event_name": "Stop", "session_id": "c", "cwd": "/Users/me/code/landing-page", "background_tasks": [],
              "last_assistant_message": "The hero section is responsive now and the contact form validates its fields."])
        model.open()
        capture("open-panel")

        claude.answer(claude.pending[0].id, .allow)
        capture("open-sessions")

        // The desktop mascot, awake and asleep.
        let pet = PetView(frame: NSRect(origin: .zero, size: PetView.stageSize))
        let petWindow = NSWindow(contentRect: NSRect(x: -3000, y: -2000, width: PetView.stageSize.width, height: PetView.stageSize.height),
                                 styleMask: .borderless, backing: .buffered, defer: false)
        petWindow.backgroundColor = NSColor(srgbRed: 0.18, green: 0.19, blue: 0.27, alpha: 1)
        petWindow.contentView = pet
        petWindow.orderFrontRegardless()
        func capturePet(_ name: String) {
            RunLoop.main.run(until: Date().addingTimeInterval(0.6))
            guard let rep = pet.bitmapImageRepForCachingDisplay(in: pet.bounds) else { return }
            pet.cacheDisplay(in: pet.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent("\(name).png"))
        }
        pet.sprite.show(.normal)
        capturePet("mascot-awake")
        pet.sprite.show(.asleep)
        pet.setSleeping(true)
        capturePet("mascot-asleep")

        NSApp.terminate(nil)
    }
}

private final class SnapshotResponder: PermissionReplying, @unchecked Sendable {
    func reply(_ line: Data) {}
}
