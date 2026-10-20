import AppKit
import Observation

enum NotchTab: String, CaseIterable, Identifiable {
    case claude, shelf, clipboard
    var id: Self { self }

    var title: String {
        switch self {
        case .claude: "Claude"
        case .shelf: "Raf"
        case .clipboard: "Pano"
        }
    }

    var symbol: String {
        switch self {
        case .claude: "sparkle"
        case .shelf: "tray.full"
        case .clipboard: "doc.on.clipboard"
        }
    }
}

enum PeekReason: Equatable {
    case permission, claudeDone, power
}

/// UI state of the notch: closed, a compact "activity" (battery peek), or open.
@MainActor @Observable
final class NotchModel {
    enum Presentation: Equatable { case closed, compact, open }

    let claude: ClaudeStore
    let shelf: Shelf
    let clipboard: ClipboardHistory
    let battery: BatteryMonitor

    var notchSize = CGSize(width: 185, height: 32)
    private(set) var presentation: Presentation = .closed
    var tab: NotchTab = .claude
    private var lastUserTab: NotchTab = .shelf
    /// Measured size of the open panel, used for hit testing.
    var openSize = CGSize(width: NotchModel.openWidth, height: 160)
    var isDropTargeted = false
    private(set) var peek: PeekReason?
    /// Bumped when files land on the shelf, drives a small bounce.
    private(set) var dropCount = 0

    static let openWidth: CGFloat = 640
    static let maxOpenHeight: CGFloat = 360

    private var peekTask: Task<Void, Never>?

    init(claude: ClaudeStore, shelf: Shelf, clipboard: ClipboardHistory, battery: BatteryMonitor) {
        self.claude = claude
        self.shelf = shelf
        self.clipboard = clipboard
        self.battery = battery
    }

    var isOpen: Bool { presentation == .open }

    /// Something forces the panel to stay open regardless of the pointer.
    var isPinnedOpen: Bool { shelf.isSharing }

    func select(_ tab: NotchTab) {
        self.tab = tab
        lastUserTab = tab
    }

    func open(tab requested: NotchTab? = nil) {
        peekTask?.cancel()
        peek = nil
        if presentation != .open { tab = requested ?? defaultTab }
        else if let requested { tab = requested }
        presentation = .open
    }

    func close() {
        guard !isPinnedOpen else { return }
        peekTask?.cancel()
        peek = nil
        presentation = .closed
    }

    /// Opens (or shows a compact activity) by itself for a few seconds.
    func showPeek(_ reason: PeekReason, hovering: Bool) {
        guard !hovering, presentation != .open || peek != nil else { return }
        peekTask?.cancel()
        peek = reason
        switch reason {
        case .power:
            presentation = .compact
        case .permission, .claudeDone:
            tab = .claude
            presentation = .open
        }
        let duration: Duration = reason == .power ? .seconds(3) : .seconds(4)
        peekTask = Task { [weak self] in
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled, let self, self.peek == reason else { return }
            self.endPeek()
        }
    }

    /// The pointer entered during a peek: keep it open like a normal hover.
    func adoptPeekAsHover() {
        guard peek != nil else { return }
        peekTask?.cancel()
        peek = nil
        presentation = .open
    }

    var isPeeking: Bool { peek != nil }

    private func endPeek() {
        peek = nil
        if !isPinnedOpen { presentation = .closed }
    }

    func noteDrop() { dropCount += 1 }

    private var defaultTab: NotchTab {
        if !claude.pending.isEmpty { return .claude }
        if let last = claude.lastEventAt, Date().timeIntervalSince(last) < 5 * 60 { return .claude }
        return lastUserTab
    }
}
