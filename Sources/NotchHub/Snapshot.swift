import AppKit
import SwiftUI

/// `NotchHub --snapshot <dir>` renders each notch state with sample data to PNG files, for design review.
@MainActor
enum Snapshot {
    static func run(into directory: URL) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let claude = ClaudeStore()
        let shelf = Shelf(storeURL: directory.appendingPathComponent("shelf.json"))
        let clipboard = ClipboardHistory(pasteboard: NSPasteboard(name: .init("notchhub-snapshot")))
        let battery = BatteryMonitor()
        battery.start()
        let model = NotchModel(claude: claude, shelf: shelf, clipboard: clipboard, battery: battery)
        model.notchSize = NotchGeometry.builtInScreen().map(NotchGeometry.notchSize(of:)) ?? CGSize(width: 185, height: 32)

        let host = NSHostingView(rootView: NotchRootView(model: model).background(Color(white: 0.55)))
        let window = NSWindow(contentRect: NSRect(x: -3000, y: -3000, width: 760, height: 400), styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = host
        window.orderFrontRegardless()

        func capture(_ name: String) {
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.9))
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
            host.cacheDisplay(in: host.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent("\(name).png"))
        }

        capture("1-closed-idle")

        let responder = SnapshotResponder()
        func send(_ object: [String: Any], responder: PermissionReplying? = nil) {
            claude.handle(HookEvent(json: try! JSONSerialization.data(withJSONObject: object))!, responder: responder)
        }
        send(["hook_event_name": "UserPromptSubmit", "session_id": "a", "cwd": "/Users/me/code/dolphydesk"])
        send(["hook_event_name": "PreToolUse", "session_id": "a", "cwd": "/Users/me/code/dolphydesk", "tool_name": "Bash",
              "tool_input": ["command": "npm test -- --watch=false"], "tool_use_id": "t1"])
        capture("2-closed-working")

        send(["hook_event_name": "Stop", "session_id": "b", "cwd": "/Users/me/code/NotchHub", "background_tasks": [],
              "last_assistant_message": "Tamamlandı. **30 test** geçti.\n\n- `HookInstaller` mevcut hook'ları koruyor\n- `notch-hook` her durumda `exit 0` yapıyor\n\nSıradaki adım: gerçek Claude Code ile uçtan uca test."])
        send(["hook_event_name": "PermissionRequest", "session_id": "a", "cwd": "/Users/me/code/dolphydesk", "tool_name": "Bash",
              "tool_input": ["command": "rm -rf node_modules && npm install"],
              "permission_suggestions": [["type": "addRules", "behavior": "allow", "destination": "localSettings"]]], responder: responder)
        capture("3-closed-permission")

        model.open(tab: .claude)
        capture("4-open-claude")

        claude.answer(claude.pending[0].id, .allow)
        capture("5-open-claude-done")

        shelf.add(["/Applications/Safari.app", "/System/Applications/Notes.app", NSHomeDirectory() + "/Desktop", "/etc/hosts"].map(URL.init(fileURLWithPath:)))
        model.select(.shelf)
        capture("6-open-shelf")
        shelf.toggleSelection(shelf.items[1])
        capture("7-open-shelf-selected")
        shelf.clear()
        capture("8-open-shelf-empty")

        for text in ["git push origin main", "https://notchy.dev", "func layout() {\n    guard let screen = NotchGeometry.builtInScreen() else { return }\n}", "Merhaba dünya"] {
            clipboard.record(text)
        }
        model.select(.clipboard)
        capture("9-open-clipboard")

        model.close()
        model.showPeek(.power, hovering: false)
        capture("10-compact-power")

        NSApp.terminate(nil)
    }
}

private final class SnapshotResponder: PermissionReplying, @unchecked Sendable {
    func reply(_ line: Data) {}
}
