import AppKit
import Observation
import SwiftUI

enum NotchTab: String, CaseIterable, Identifiable {
    case claude, shelf, clipboard
    var id: Self { self }

    var title: String {
        switch self {
        case .claude: "Claude"
        case .shelf: String(localized: "Shelf")
        case .clipboard: String(localized: "Clipboard")
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

/// Something that briefly shows itself without the pointer.
enum PeekReason: Equatable {
    /// A permission request: opens the panel, since it needs an answer.
    case permission
    /// Opened from the desktop mascot; stays a while for the pointer to arrive.
    case summoned
    /// A session finished: "✓ <project> done" right of the notch.
    case claudeDone(String)
    /// A session asked something and waits for the answer: "? <project> asks you".
    case question(String)
    /// Text copied in another app.
    case copied(String)
    /// A new screenshot (its path) or download (its name) landed on the shelf.
    case screenshot(String)
    case downloaded(String)
    /// Five-hour plan usage reached this percentage.
    case usage(Int)

    var opensPanel: Bool { self == .permission || self == .summoned }

    /// Announcements about one session; several in a row are shown one after another.
    var isAnnouncement: Bool {
        switch self {
        case .claudeDone, .question: true
        default: false
        }
    }

    var duration: Duration {
        switch self {
        case .copied: .milliseconds(1600)
        case .claudeDone: .seconds(3)
        case .question: .seconds(4)
        case .screenshot, .downloaded: .milliseconds(3500)
        case .permission, .usage: .seconds(4)
        case .summoned: .seconds(6)
        }
    }

    /// Width of the activity's wing right of the notch. Nothing goes on the left:
    /// app menus reach the notch there.
    var wingWidth: CGFloat {
        switch self {
        case .claudeDone(let label), .question(let label):
            min(250, 102 + (label as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 11.5, weight: .semibold)]).width)
        case .copied, .downloaded: 190
        case .screenshot: 200
        case .usage: 170
        case .permission, .summoned: 30
        }
    }
}

/// What is being dragged over the notch.
enum DragKind: Equatable {
    case files, text
}

/// UI state of the notch: closed, a compact activity, or open.
@MainActor @Observable
final class NotchModel {
    enum Presentation: Equatable { case closed, compact, open }

    let claude: ClaudeStore
    let shelf: Shelf
    let clipboard: ClipboardHistory

    var notchSize = CGSize(width: 185, height: 32)
    private(set) var presentation: Presentation = .closed
    private(set) var tab: NotchTab = .claude
    private var lastUserTab: NotchTab = .claude
    /// Measured size of the open panel, used for hit testing.
    var openSize = CGSize(width: NotchModel.openWidth, height: 160)
    /// The pointer rests on the closed notch and it is about to open.
    var isHoverPrimed = false
    /// A drag with files or text is near the notch; the panel shows drop zones.
    var drag: DragKind?
    private(set) var peek: PeekReason?
    /// Bumped when a Claude session finishes (the desktop mascot hops).
    private(set) var claudeCelebration = 0
    /// Project of the most recently finished session.
    private(set) var lastFinished: String?
    private var queuedPeeks: [PeekReason] = []
    /// Bumped when something lands on the notch; drives a small bounce.
    private(set) var dropCount = 0

    static let openWidth: CGFloat = 640
    static let maxOpenHeight: CGFloat = 410

    private var peekTask: Task<Void, Never>?

    init(claude: ClaudeStore, shelf: Shelf, clipboard: ClipboardHistory) {
        self.claude = claude
        self.shelf = shelf
        self.clipboard = clipboard
    }

    var isOpen: Bool { presentation == .open }
    var isPeeking: Bool { peek != nil }

    /// Something keeps the panel open regardless of the pointer.
    var isPinnedOpen: Bool { shelf.isSharing || drag != nil }

    /// Wing width of the current compact activity.
    var compactWingWidth: CGFloat { peek?.wingWidth ?? 150 }

    func select(_ tab: NotchTab) {
        self.tab = tab
        lastUserTab = tab
    }

    func open(tab requested: NotchTab? = nil) {
        peekTask?.cancel()
        peek = nil
        isHoverPrimed = false
        if presentation != .open { tab = requested ?? defaultTab }
        else if let requested { tab = requested }
        presentation = .open
        queuedPeeks.removeAll()
        claude.markSeen()
    }

    func close() {
        guard !isPinnedOpen else { return }
        peekTask?.cancel()
        peek = nil
        presentation = .closed
    }

    /// Shows a peek for a few seconds. Never interrupts a panel the user opened,
    /// and a compact activity never replaces an open peek.
    func showPeek(_ reason: PeekReason, hovering: Bool) {
        if case .claudeDone(let label) = reason {
            claudeCelebration += 1
            lastFinished = label
        }
        // Several sessions can finish or ask together: announce each one in turn.
        if reason.isAnnouncement, peek?.isAnnouncement == true { queuedPeeks.append(reason); return }
        guard !hovering, drag == nil else { return }
        if presentation == .open && peek == nil { return }
        if let current = peek, current.opensPanel, !reason.opensPanel { return }

        peekTask?.cancel()
        peek = reason
        if reason.opensPanel {
            tab = .claude
            presentation = .open
            claude.markSeen()
        } else {
            presentation = .compact
        }
        peekTask = Task { [weak self] in
            try? await Task.sleep(for: reason.duration)
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
        claude.markSeen()
    }

    func noteDrop() {
        dropCount += 1
        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
    }

    /// Peeks end with the same springs as a hover, never with a cut.
    private func endPeek() {
        if !queuedPeeks.isEmpty, presentation == .compact {
            peek = nil
            withAnimation(.notchActivity) { showPeek(queuedPeeks.removeFirst(), hovering: false) }
            return
        }
        queuedPeeks.removeAll()
        withAnimation(.notchClose) {
            peek = nil
            if !isPinnedOpen { presentation = .closed }
        }
    }

    /// Claude while it needs you or was busy lately, else the tab the user last picked.
    private var defaultTab: NotchTab {
        if !claude.pending.isEmpty { return .claude }
        if let last = claude.lastEventAt, Date().timeIntervalSince(last) < 5 * 60 { return .claude }
        return lastUserTab
    }
}
