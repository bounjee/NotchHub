import AppKit
import SwiftUI

/// `NotchHub --snapshot <dir>` renders the notch and the mascot with sample data to PNG
/// files: for design review and for the README. Nothing on the real screen is captured,
/// and the user's shelf and clipboard are left alone.
@MainActor
enum Snapshot {
    static func run(into directory: URL) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("NotchHubSnapshot-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        let claude = ClaudeStore()
        let shelf = Shelf(storeURL: scratch.appendingPathComponent("shelf.json"))
        let clipboard = ClipboardHistory(pasteboard: NSPasteboard(name: NSPasteboard.Name("NotchHubSnapshot-\(UUID().uuidString)")))
        let model = NotchModel(claude: claude, shelf: shelf, clipboard: clipboard)
        model.notchSize = NotchGeometry.builtInScreen().map(NotchGeometry.notchSize(of:)) ?? CGSize(width: 185, height: 32)

        let backdrop = LinearGradient(
            colors: [Color(red: 0.16, green: 0.18, blue: 0.27), Color(red: 0.31, green: 0.24, blue: 0.33)],
            startPoint: .topLeading, endPoint: .bottomTrailing
        )
        let host = NSHostingView(rootView: NotchRootView(model: model).background(backdrop))
        let window = NSWindow(contentRect: NSRect(x: -3000, y: -3000, width: 720, height: 460), styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = host
        window.orderFrontRegardless()

        func settle(_ seconds: TimeInterval = 0.9) {
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(seconds))
        }
        /// The open panel, cropped to its own height.
        func captureOpen(_ name: String) {
            settle()
            let rect = CGRect(x: 0, y: 0, width: host.bounds.width, height: min(host.bounds.height, model.openSize.height + 30))
            write(image(of: host, in: rect), to: directory.appendingPathComponent("\(name).png"))
        }
        /// The closed notch with a strip of menu bar around it.
        func closedStrip() -> NSImage {
            settle()
            // Activities grow to the right of the notch only, so leave more room there.
            return image(of: host, in: CGRect(x: host.bounds.midX - 150, y: 0, width: 440, height: 46))
        }

        func send(_ object: [String: Any], responder: PermissionReplying? = nil) {
            claude.handle(HookEvent(json: try! JSONSerialization.data(withJSONObject: object))!, responder: responder)
        }
        func work(_ id: String, _ project: String, tool: String, input: [String: Any]) {
            send(["hook_event_name": "UserPromptSubmit", "session_id": id, "cwd": "/Users/me/code/\(project)", "notchhub_project": project])
            send(["hook_event_name": "PreToolUse", "session_id": id, "cwd": "/Users/me/code/\(project)", "tool_name": tool,
                  "tool_input": input, "tool_use_id": "t-\(id)"])
        }

        // Closed states.
        var states: [(String, String, NSImage)] = []
        work("a", "web-app", tool: "Bash", input: ["command": "npm test -- --watch=false --coverage --reporter=verbose src/routes src/models src/services src/utils"])
        work("b", "api", tool: "Edit", input: ["file_path": "/Users/me/code/api/src/routes/users.ts"])
        states.append(("Working", "Two sessions running", closedStrip()))

        model.showPeek(.claudeDone("landing-page"), hovering: false)
        states.append(("Done", "A session just finished", closedStrip()))
        model.close()

        model.showPeek(.copied("ssh deploy@203.0.113.7"), hovering: false)
        states.append(("Copied", "Text copied in any app", closedStrip()))
        model.close()

        let responder = SnapshotResponder()
        send(["hook_event_name": "PermissionRequest", "session_id": "b", "cwd": "/Users/me/code/api", "tool_name": "Bash",
              "tool_input": ["command": "rm -rf node_modules && npm install"],
              "permission_suggestions": [["type": "addRules", "behavior": "allow", "destination": "localSettings"]]], responder: responder)
        states.append(("Permission", "Waiting for your answer", closedStrip()))
        write(gallery(rows: states), to: directory.appendingPathComponent("states.png"))

        // The Claude tab.
        send(["hook_event_name": "NotchHubStatusLine", "session_id": "a", "rate_limits": [
            "five_hour": ["used_percentage": 42, "resets_at": Date().addingTimeInterval(2 * 3600 + 840).timeIntervalSince1970],
            "seven_day": ["used_percentage": 23, "resets_at": Date().addingTimeInterval(4 * 86_400).timeIntervalSince1970],
        ]])
        send(["hook_event_name": "UserPromptSubmit", "session_id": "c", "cwd": "/Users/me/code/landing-page", "notchhub_project": "landing-page"])
        send(["hook_event_name": "PreToolUse", "session_id": "c", "cwd": "/Users/me/code/landing-page", "tool_name": "Write",
              "tool_input": ["file_path": "/Users/me/code/landing-page/index.html"], "tool_use_id": "t-c"])
        send(["hook_event_name": "Stop", "session_id": "c", "cwd": "/Users/me/code/landing-page", "background_tasks": [],
              "last_assistant_message": "The hero section is responsive now and the contact form validates its fields."])
        model.open(tab: .claude)
        captureOpen("open-panel")
        claude.answer(claude.pending[0].id, .allow)

        // The shelf, with a few sample files.
        let samples = ["Q3 report.pdf", "hero@2x.png", "notes.md", "build.zip"].map { scratch.appendingPathComponent($0) }
        for url in samples { FileManager.default.createFile(atPath: url.path, contents: sampleContents(for: url)) }
        shelf.add(Array(samples.dropFirst().reversed()))
        shelf.add([samples[0]], source: .download)
        model.select(.shelf)
        captureOpen("open-shelf")

        // The clipboard.
        let start = Date()
        for (offset, text) in [
            "Meeting moved to Thursday 14:00, same room.",
            "{\"name\": \"NotchHub\", \"version\": 1, \"tabs\": [\"claude\", \"shelf\", \"clipboard\"]}",
            "#D97757",
            "https://github.com/bounjee/NotchHub",
            "ssh deploy@203.0.113.7",
        ].enumerated() {
            clipboard.record(text, now: start.addingTimeInterval(Double(offset - 5) * 60))
        }
        if let pinned = clipboard.items.first(where: { $0.text.hasPrefix("ssh") }) { clipboard.togglePin(pinned) }
        model.select(.clipboard)
        captureOpen("open-clipboard")

        // The desktop mascot: talking, then napping.
        write(mascots(), to: directory.appendingPathComponent("mascot.png"))

        NSApp.terminate(nil)
    }

    // MARK: - Drawing

    private static let galleryBackground = NSColor(srgbRed: 0.09, green: 0.1, blue: 0.13, alpha: 1)

    private static func image(of view: NSView, in rect: CGRect) -> NSImage {
        let image = NSImage(size: rect.size)
        if let rep = view.bitmapImageRepForCachingDisplay(in: rect) {
            view.cacheDisplay(in: rect, to: rep)
            image.addRepresentation(rep)
        }
        return image
    }

    /// Rows of "title, caption | picture" on a dark card.
    private static func gallery(rows: [(String, String, NSImage)]) -> NSImage {
        let padding: CGFloat = 24, labelWidth: CGFloat = 200, gap: CGFloat = 14
        let pictureSize = rows.first?.2.size ?? .zero
        let size = CGSize(width: padding * 2 + labelWidth + pictureSize.width,
                          height: padding * 2 + CGFloat(rows.count) * pictureSize.height + CGFloat(rows.count - 1) * gap)
        return render(size: size) {
            for (index, row) in rows.enumerated() {
                let top = padding + CGFloat(index) * (pictureSize.height + gap)
                let picture = CGRect(x: padding + labelWidth, y: top, width: pictureSize.width, height: pictureSize.height)
                NSBezierPath(roundedRect: picture, xRadius: 10, yRadius: 10).addClip()
                row.2.draw(in: picture)
                NSGraphicsContext.current?.cgContext.resetClip()
                draw(row.0, at: CGPoint(x: padding, y: top + pictureSize.height / 2 - 18), size: 15, weight: .semibold, alpha: 0.95)
                draw(row.1, at: CGPoint(x: padding, y: top + pictureSize.height / 2 + 2), size: 12, weight: .regular, alpha: 0.55)
            }
        }
    }

    /// The mascot talking and napping, drawn from its pixel art so it stays crisp.
    private static func mascots() -> NSImage {
        let pixel: CGFloat = 7, cell = CGSize(width: 260, height: 210), padding: CGFloat = 24, gap: CGFloat = 20
        let sprite = CGSize(width: CGFloat(Clawd.width) * pixel, height: CGFloat(Clawd.height) * pixel * Clawd.pixelAspect)
        let moods: [(Clawd.Pose, String)] = [
            (.normal, "Click it: status, usage, last done"), (.typeLeft, "Types along with Claude"), (.asleep, "Leave it alone: it naps"),
        ]
        let size = CGSize(width: padding * 2 + cell.width * CGFloat(moods.count) + gap * CGFloat(moods.count - 1),
                          height: padding * 2 + cell.height)
        return render(size: size) {
            for (index, mood) in moods.enumerated() {
                let left = padding + CGFloat(index) * (cell.width + gap)
                let spriteRect = CGRect(x: left + (cell.width - sprite.width) / 2, y: padding + cell.height - 34 - sprite.height,
                                        width: sprite.width, height: sprite.height)
                if let image = Clawd.image(mood.0, color: Clawd.orange) {
                    NSImage(cgImage: image, size: sprite).draw(in: spriteRect, from: .zero, operation: .sourceOver, fraction: 1,
                                                               respectFlipped: true, hints: [.interpolation: NSImageInterpolation.none.rawValue])
                }
                if mood.0 == .typeLeft {
                    // The typing pose already holds the laptop.
                } else if mood.0 == .asleep {
                    for (step, z) in ["z", "z", "Z"].enumerated() {
                        draw(z, at: CGPoint(x: spriteRect.maxX - 10 + CGFloat(step) * 16, y: spriteRect.minY - 26 - CGFloat(step) * 20),
                             size: 14 + CGFloat(step) * 4, weight: .heavy, alpha: 0.85 - CGFloat(step) * 0.15)
                    }
                } else {
                    let text = NSAttributedString(string: "web-app · Working", attributes: attributes(size: 13, weight: .semibold, alpha: 1))
                    let bubble = CGRect(x: left + (cell.width - text.size().width - 28) / 2, y: spriteRect.minY - 58,
                                        width: text.size().width + 28, height: 36)
                    let path = NSBezierPath(roundedRect: bubble, xRadius: 12, yRadius: 12)
                    NSColor(white: 0.16, alpha: 1).setFill()
                    path.fill()
                    NSColor(white: 1, alpha: 0.18).setStroke()
                    path.lineWidth = 1
                    path.stroke()
                    text.draw(at: CGPoint(x: bubble.minX + 14, y: bubble.midY - text.size().height / 2))
                }
                let caption = NSAttributedString(string: mood.1, attributes: attributes(size: 12.5, weight: .medium, alpha: 0.55))
                caption.draw(at: CGPoint(x: left + (cell.width - caption.size().width) / 2, y: padding + cell.height - caption.size().height))
            }
        }
    }

    /// Draws on a dark rounded card at twice the size, in a top-left coordinate space.
    private static func render(size: CGSize, _ body: () -> Void) -> NSImage {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = size
        NSGraphicsContext.saveGraphicsState()
        let context = NSGraphicsContext(bitmapImageRep: rep)!
        NSGraphicsContext.current = context
        context.cgContext.translateBy(x: 0, y: size.height)
        context.cgContext.scaleBy(x: 1, y: -1)
        context.imageInterpolation = .high
        galleryBackground.setFill()
        NSBezierPath(roundedRect: CGRect(origin: .zero, size: size), xRadius: 18, yRadius: 18).fill()
        // Text and images expect a flipped context to draw upright.
        let flipped = NSGraphicsContext(cgContext: context.cgContext, flipped: true)
        NSGraphicsContext.current = flipped
        body()
        NSGraphicsContext.restoreGraphicsState()
        let image = NSImage(size: size)
        image.addRepresentation(rep)
        return image
    }

    private static func attributes(size: CGFloat, weight: NSFont.Weight, alpha: CGFloat) -> [NSAttributedString.Key: Any] {
        [.font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: NSColor(white: 1, alpha: alpha)]
    }

    private static func draw(_ text: String, at point: CGPoint, size: CGFloat, weight: NSFont.Weight, alpha: CGFloat) {
        NSAttributedString(string: text, attributes: attributes(size: size, weight: weight, alpha: alpha)).draw(at: point)
    }

    private static func write(_ image: NSImage, to url: URL) {
        guard let rep = image.representations.first as? NSBitmapImageRep ?? image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)),
              let data = rep.representation(using: .png, properties: [:])
        else { return }
        try? data.write(to: url)
    }

    /// Real content, so Quick Look draws proper thumbnails.
    private static func sampleContents(for url: URL) -> Data {
        switch url.pathExtension {
        case "png":
            let picture = NSImage(size: NSSize(width: 480, height: 320), flipped: false) { rect in
                NSGradient(colors: [NSColor(srgbRed: 0.98, green: 0.62, blue: 0.42, alpha: 1),
                                    NSColor(srgbRed: 0.55, green: 0.3, blue: 0.75, alpha: 1)])?.draw(in: rect, angle: -35)
                NSColor(white: 1, alpha: 0.85).setFill()
                NSBezierPath(ovalIn: NSRect(x: 300, y: 170, width: 90, height: 90)).fill()
                return true
            }
            return picture.tiffRepresentation.flatMap { NSBitmapImageRep(data: $0)?.representation(using: .png, properties: [:]) } ?? Data()
        case "md":
            return Data("# Launch notes\n\n- Ship the notch build\n- Record the demo\n- Update the README\n- Tag v1.0\n".utf8)
        default:
            return Data(repeating: 0x20, count: 2048)
        }
    }
}

private final class SnapshotResponder: PermissionReplying, @unchecked Sendable {
    func reply(_ line: Data) {}
}
