import AppKit
import Observation
import SwiftUI

/// Something that briefly shows itself without the pointer.
enum PeekReason: Equatable {
    /// A permission request: opens the panel, since it needs an answer.
    case permission
    /// Opened from the desktop mascot; stays a while for the pointer to arrive.
    case summoned
    /// A session finished: "✓ <project> done" right of the notch.
    case claudeDone(String)
    /// Five-hour plan usage reached this percentage.
    case usage(Int)

    var opensPanel: Bool { self == .permission || self == .summoned }

    var duration: Duration {
        switch self {
        case .claudeDone: .seconds(3)
        case .permission, .usage: .seconds(4)
        case .summoned: .seconds(6)
        }
    }

    /// Width of the activity's wing right of the notch. Nothing goes on the left:
    /// app menus reach the notch there.
    var wingWidth: CGFloat {
        switch self {
        case .claudeDone(let label):
            min(240, 92 + (label as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 11.5, weight: .semibold)]).width)
        case .usage: 170
        case .permission, .summoned: 30
        }
    }
}

/// UI state of the notch: closed, a compact activity, or open.
@MainActor @Observable
final class NotchModel {
    enum Presentation: Equatable { case closed, compact, open }

    let claude: ClaudeStore

    var notchSize = CGSize(width: 185, height: 32)
    private(set) var presentation: Presentation = .closed
    /// Measured size of the open panel, used for hit testing.
    var openSize = CGSize(width: NotchModel.openWidth, height: 160)
    /// The pointer rests on the closed notch and it is about to open.
    var isHoverPrimed = false
    private(set) var peek: PeekReason?
    /// Bumped when a Claude session finishes (the desktop mascot hops).
    private(set) var claudeCelebration = 0
    /// Project of the most recently finished session.
    private(set) var lastFinished: String?
    private var queuedPeeks: [PeekReason] = []

    static let openWidth: CGFloat = 560
    static let maxOpenHeight: CGFloat = 400

    private var peekTask: Task<Void, Never>?

    init(claude: ClaudeStore) {
        self.claude = claude
    }

    var isOpen: Bool { presentation == .open }
    var isPeeking: Bool { peek != nil }

    /// Wing width of the current compact activity.
    var compactWingWidth: CGFloat { peek?.wingWidth ?? 150 }

    func open() {
        peekTask?.cancel()
        peek = nil
        isHoverPrimed = false
        presentation = .open
        queuedPeeks.removeAll()
        claude.markSeen()
    }

    func close() {
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
            // Several sessions can finish together: announce each one in turn.
            if case .claudeDone = peek { queuedPeeks.append(reason); return }
        }
        guard !hovering else { return }
        if presentation == .open && peek == nil { return }
        if let current = peek, current.opensPanel, !reason.opensPanel { return }

        peekTask?.cancel()
        peek = reason
        if reason.opensPanel {
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
            presentation = .closed
        }
    }
}
