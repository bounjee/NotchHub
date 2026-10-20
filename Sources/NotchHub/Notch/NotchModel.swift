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

/// Something that briefly shows itself without the pointer.
/// Claude events open the panel; the rest are compact "activities" beside the notch.
enum PeekReason: Equatable {
    case permission, claudeDone
    case power, charged, lowBattery
    case copied(String)

    var opensPanel: Bool {
        switch self {
        case .permission, .claudeDone: true
        default: false
        }
    }

    var duration: Duration {
        switch self {
        case .copied: .milliseconds(1600)
        case .power, .charged: .seconds(3)
        case .lowBattery, .permission, .claudeDone: .seconds(4)
        }
    }

    /// Width of each side wing of the compact activity.
    var wingWidth: CGFloat {
        switch self {
        case .copied: 112
        default: 78
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
    let battery: BatteryMonitor

    var notchSize = CGSize(width: 185, height: 32)
    private(set) var presentation: Presentation = .closed
    var tab: NotchTab = .claude
    private var lastUserTab: NotchTab = .shelf
    /// Measured size of the open panel, used for hit testing.
    var openSize = CGSize(width: NotchModel.openWidth, height: 160)
    /// The pointer rests on the closed notch and it is about to open.
    var isHoverPrimed = false
    /// A drag with files or text is near the notch; the panel shows drop zones.
    var drag: DragKind?
    private(set) var peek: PeekReason?
    /// Bumped when something lands on the notch, drives a small bounce.
    private(set) var dropCount = 0

    static let openWidth: CGFloat = 640
    static let maxOpenHeight: CGFloat = 380

    private var peekTask: Task<Void, Never>?

    init(claude: ClaudeStore, shelf: Shelf, clipboard: ClipboardHistory, battery: BatteryMonitor) {
        self.claude = claude
        self.shelf = shelf
        self.clipboard = clipboard
        self.battery = battery
    }

    var isOpen: Bool { presentation == .open }
    var isPeeking: Bool { peek != nil }

    /// Something forces the panel to stay open regardless of the pointer.
    var isPinnedOpen: Bool { shelf.isSharing || drag != nil }

    /// Wing width of the current compact activity.
    var compactWingWidth: CGFloat { peek?.wingWidth ?? 78 }

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
    }

    func close() {
        guard !isPinnedOpen else { return }
        peekTask?.cancel()
        peek = nil
        presentation = .closed
    }

    /// Shows a peek for a few seconds. Never interrupts a panel the user opened,
    /// and a compact activity never replaces an open Claude peek.
    func showPeek(_ reason: PeekReason, hovering: Bool) {
        guard !hovering, drag == nil else { return }
        if presentation == .open && peek == nil { return }
        if let current = peek, current.opensPanel, !reason.opensPanel { return }

        peekTask?.cancel()
        peek = reason
        if reason.opensPanel {
            tab = .claude
            presentation = .open
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
    }

    private func endPeek() {
        peek = nil
        if !isPinnedOpen { presentation = .closed }
    }

    func noteDrop() {
        dropCount += 1
        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
    }

    private var defaultTab: NotchTab {
        if !claude.pending.isEmpty { return .claude }
        if let last = claude.lastEventAt, Date().timeIntervalSince(last) < 5 * 60 { return .claude }
        return lastUserTab
    }
}
