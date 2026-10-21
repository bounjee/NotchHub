import Foundation
import Observation

enum SessionStatus: Equatable, Sendable {
    case idle, working, needsApproval, waitingForUser, done, error
}

struct ClaudeSession: Identifiable, Equatable {
    let id: String
    var label: String
    var status: SessionStatus = .idle
    var currentTool: String?
    var lastMessage: String?
    var statusSince = Date()
    var lastEventAt = Date()
    var terminal: TerminalLocation?
}

/// Plan usage from Claude Code's status line (Pro/Max only).
struct UsageLimits: Equatable, Codable {
    var fiveHour: UsageWindow?
    var sevenDay: UsageWindow?

    /// Windows whose reset time has passed no longer mean anything.
    func current(at now: Date = Date()) -> UsageLimits {
        UsageLimits(
            fiveHour: fiveHour.flatMap { $0.resetsAt > now ? $0 : nil },
            sevenDay: sevenDay.flatMap { $0.resetsAt > now ? $0 : nil }
        )
    }

    var isEmpty: Bool { fiveHour == nil && sevenDay == nil }
}

enum PermissionDecision: Sendable {
    case allow, allowAlways, deny, none
}

/// The open hook connection waiting for a PermissionRequest decision.
protocol PermissionReplying: AnyObject, Sendable {
    func reply(_ line: Data)
}

struct PendingPermission: Identifiable {
    let id = UUID()
    let sessionID: String
    let toolName: String
    let toolInputKey: String?
    let summary: String
    var toolUseID: String?
    let suggestions: Data?
    let responder: PermissionReplying
    let createdAt = Date()
}

@MainActor @Observable
final class ClaudeStore {
    private(set) var sessions: [String: ClaudeSession] = [:]
    private(set) var pending: [PendingPermission] = []
    private(set) var lastEventAt: Date?
    /// The most urgent status across sessions, used by the closed notch.
    /// Stored (not computed) so views that read it only update when it actually changes.
    private(set) var headlineStatus: SessionStatus?
    /// Whether our hooks are in ~/.claude/settings.json; kept here so views never read the file.
    var hooksInstalled = false
    private(set) var limits = UsageLimits()

    /// Five-hour usage levels that earn a heads-up, once per window.
    static let usageWarnings: [Double] = [80, 95]
    private let limitsURL: URL?

    init(limitsURL: URL? = nil) {
        self.limitsURL = limitsURL
        if let limitsURL, let data = try? Data(contentsOf: limitsURL),
           let saved = try? JSONDecoder().decode(UsageLimits.self, from: data) {
            limits = saved.current()
        }
    }

    static var defaultLimitsURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/NotchHub/usage.json")
    }

    /// Called when the panel should briefly open by itself.
    var onPeek: ((PeekReason) -> Void)?

    static let doneLifetime: TimeInterval = 10 * 60
    /// Sessions closed without SessionEnd (terminal window closed) stop sending events.
    static let staleLifetime: TimeInterval = 30 * 60

    /// Recent PreToolUse calls per session, used to find the `tool_use_id` of a permission request.
    private var recentToolUses: [String: [(name: String, inputKey: String?, id: String)]] = [:]
    /// Tool calls that already finished; their ids must never be given to a new request.
    private var finishedToolUseIDs: [String] = []

    var sortedSessions: [ClaudeSession] {
        sessions.values.sorted { $0.lastEventAt > $1.lastEventAt }
    }

    private func refreshHeadline() {
        let statuses = Set(sessions.values.map(\.status))
        let headline = [SessionStatus.needsApproval, .error, .working, .waitingForUser, .done].first { statuses.contains($0) }
        if headline != headlineStatus { headlineStatus = headline }
    }

    func handle(_ event: HookEvent, responder: PermissionReplying? = nil, now: Date = Date()) {
        if event.isStatusLine {
            updateLimits(event, now: now)
            locateTerminal(event)
            return
        }
        defer { refreshHeadline() }
        defer { locateTerminal(event) }
        defer { log.notice("hook \(event.name, privacy: .public) pending=\(self.pending.count) status=\(String(describing: self.sessions[event.sessionID]?.status), privacy: .public)") }
        lastEventAt = now
        let sid = event.sessionID

        switch event.name {
        case "SessionStart":
            sessions[sid] = ClaudeSession(id: sid, label: label(for: event.cwd), statusSince: now, lastEventAt: now)

        case "UserPromptSubmit":
            resolvePending(in: sid, with: .none)
            update(sid, event, now) { $0.status = .working; $0.currentTool = nil }

        case "PreToolUse":
            if let name = event.toolName, let id = event.toolUseID {
                var list = recentToolUses[sid, default: []]
                list.append((name, event.toolInputKey, id))
                recentToolUses[sid] = Array(list.suffix(16))
                // Async hooks may deliver PreToolUse after its PermissionRequest; that request
                // has no id yet, or got the id of an earlier identical call that already finished.
                if let index = pending.firstIndex(where: {
                    $0.sessionID == sid && $0.toolName == name && $0.toolInputKey == event.toolInputKey
                        && ($0.toolUseID == nil || finishedToolUseIDs.contains($0.toolUseID!))
                }) {
                    pending[index].toolUseID = id
                }
            }
            update(sid, event, now) {
                $0.status = self.hasPending(sid) ? .needsApproval : .working
                $0.currentTool = Self.toolLine(event)
            }

        case "PermissionRequest":
            guard let responder else { return }
            let name = event.toolName ?? "?"
            let taken = Set(pending.compactMap(\.toolUseID))
            let match = recentToolUses[sid]?.last {
                $0.name == name && $0.inputKey == event.toolInputKey && !taken.contains($0.id) && !finishedToolUseIDs.contains($0.id)
            }
            pending.append(PendingPermission(
                sessionID: sid, toolName: name, toolInputKey: event.toolInputKey,
                summary: event.toolSummary ?? "", toolUseID: match?.id,
                suggestions: event.permissionSuggestions, responder: responder
            ))
            update(sid, event, now) { $0.status = .needsApproval; $0.currentTool = Self.toolLine(event) }
            onPeek?(.permission)

        case "PostToolUse", "PostToolUseFailure":
            // The tool ran, so any matching request was answered in the terminal.
            if let index = pending.firstIndex(where: { $0.sessionID == sid && matches($0, event) }) {
                let request = pending.remove(at: index)
                request.responder.reply(Self.replyLine(.none, suggestions: nil))
            }
            if let id = event.toolUseID {
                recentToolUses[sid]?.removeAll { $0.id == id }
                finishedToolUseIDs = Array((finishedToolUseIDs + [id]).suffix(64))
            }
            // A late async PostToolUse must not revive a finished or failed session.
            if let status = sessions[sid]?.status, status == .done || status == .error { touch(sid, now); return }
            update(sid, event, now) { $0.status = self.hasPending(sid) ? .needsApproval : .working }

        case "Notification":
            guard ["idle_prompt", "agent_needs_input", "elicitation_dialog"].contains(event.notificationType ?? "") else { return }
            update(sid, event, now) { if $0.status != .needsApproval { $0.status = .waitingForUser } }

        case "Stop":
            resolvePending(in: sid, with: .none)
            update(sid, event, now) {
                $0.status = event.hasBackgroundTasks ? .working : .done
                $0.currentTool = nil
                if let message = event.lastAssistantMessage, !message.isEmpty { $0.lastMessage = message }
            }
            if !event.hasBackgroundTasks { onPeek?(.claudeDone(sessions[sid]?.label ?? "Claude")) }

        case "StopFailure":
            resolvePending(in: sid, with: .none)
            update(sid, event, now) {
                $0.status = .error
                $0.currentTool = nil
                $0.lastMessage = event.lastAssistantMessage ?? event.errorMessage ?? $0.lastMessage
            }

        case "SessionEnd":
            resolvePending(in: sid, with: .none)
            recentToolUses[sid] = nil
            // `claude -p` ends right after Stop; keep the answer visible until it expires.
            if sessions[sid]?.status != .done { sessions[sid] = nil }

        default:
            break
        }
    }

    private func updateLimits(_ event: HookEvent, now: Date) {
        guard event.fiveHour != nil || event.sevenDay != nil else { return }
        let previous = limits.current(at: now).fiveHour
        var updated = limits
        if let window = event.fiveHour { updated.fiveHour = window }
        if let window = event.sevenDay { updated.sevenDay = window }
        guard updated != limits else { return }
        limits = updated

        if let window = updated.fiveHour {
            // A new window starts from zero, so compare only within the same one.
            let before = previous?.resetsAt == window.resetsAt ? previous!.usedPercentage : 0
            if let crossed = Self.usageWarnings.last(where: { before < $0 && window.usedPercentage >= $0 }) {
                onPeek?(.usage(Int(crossed)))
            }
        }
        if let limitsURL, let data = try? JSONEncoder().encode(updated) {
            try? FileManager.default.createDirectory(at: limitsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: limitsURL, options: .atomic)
        }
    }

    private func locateTerminal(_ event: HookEvent) {
        guard !event.ancestors.isEmpty, var session = sessions[event.sessionID], session.terminal == nil,
              let location = TerminalJump.locate(ancestors: event.ancestors)
        else { return }
        session.terminal = location
        sessions[event.sessionID] = session
    }

    func jumpToTerminal(_ id: ClaudeSession.ID) {
        guard let location = sessions[id]?.terminal else { return }
        TerminalJump.jump(to: location)
    }

    /// Answers a pending request from the panel.
    func answer(_ id: PendingPermission.ID, _ decision: PermissionDecision, now: Date = Date()) {
        guard let index = pending.firstIndex(where: { $0.id == id }) else { return }
        let request = pending.remove(at: index)
        defer { refreshHeadline() }
        log.notice("answered \(String(describing: decision), privacy: .public)")
        request.responder.reply(Self.replyLine(decision, suggestions: request.suggestions))
        if var session = sessions[request.sessionID], session.status == .needsApproval, !hasPending(request.sessionID) {
            session.status = .working
            session.statusSince = now
            sessions[request.sessionID] = session
        }
    }

    /// The hook process went away (answered in the terminal, cancelled or timed out).
    func responderClosed(_ responder: PermissionReplying) {
        guard let index = pending.firstIndex(where: { $0.responder === responder }) else { return }
        let request = pending.remove(at: index)
        defer { refreshHeadline() }
        log.notice("hook connection closed, request dropped")
        if var session = sessions[request.sessionID], session.status == .needsApproval, !hasPending(request.sessionID) {
            session.status = .working
            sessions[request.sessionID] = session
        }
    }

    func removeExpiredSessions(now: Date = Date()) {
        defer { refreshHeadline() }
        sessions = sessions.filter { _, session in
            if session.status == .done { return now.timeIntervalSince(session.statusSince) < Self.doneLifetime }
            if session.status == .needsApproval { return true }
            return now.timeIntervalSince(session.lastEventAt) < Self.staleLifetime
        }
    }

    func dismiss(_ id: ClaudeSession.ID) {
        defer { refreshHeadline() }
        resolvePending(in: id, with: .none)
        sessions[id] = nil
    }

    // MARK: - Helpers

    nonisolated static func replyLine(_ decision: PermissionDecision, suggestions: Data?) -> Data {
        var object: [String: Any]
        switch decision {
        case .allow: object = ["decision": "allow"]
        case .allowAlways:
            object = ["decision": "allow"]
            if let suggestions, let rules = try? JSONSerialization.jsonObject(with: suggestions) {
                object["updatedPermissions"] = rules
            }
        case .deny: object = ["decision": "deny"]
        case .none: object = ["decision": "none"]
        }
        var data = (try? JSONSerialization.data(withJSONObject: object)) ?? Data(#"{"decision":"none"}"#.utf8)
        data.append(0x0A)
        return data
    }

    nonisolated static func toolLine(_ event: HookEvent) -> String? {
        guard var name = event.toolName else { return nil }
        // mcp__server__tool -> server · tool
        let parts = name.components(separatedBy: "__")
        if parts.count == 3, parts[0] == "mcp" { name = "\(parts[1]) · \(parts[2])" }
        let summary = (event.toolSummary ?? "").replacingOccurrences(of: "\n", with: " ")
        return summary.isEmpty ? name : "\(name): \(summary)"
    }

    private func label(for cwd: String) -> String {
        let name = URL(fileURLWithPath: cwd).lastPathComponent
        return name.isEmpty || cwd.isEmpty ? "Claude" : name
    }

    private func hasPending(_ sid: String) -> Bool {
        pending.contains { $0.sessionID == sid }
    }

    private func matches(_ request: PendingPermission, _ event: HookEvent) -> Bool {
        if let id = request.toolUseID, let eventID = event.toolUseID { return id == eventID }
        return request.toolName == event.toolName && request.toolInputKey == event.toolInputKey
    }

    private func resolvePending(in sid: String, with decision: PermissionDecision) {
        let (closing, keeping) = pending.reduce(into: ([PendingPermission](), [PendingPermission]())) {
            if $1.sessionID == sid { $0.0.append($1) } else { $0.1.append($1) }
        }
        guard !closing.isEmpty else { return }
        pending = keeping
        for request in closing { request.responder.reply(Self.replyLine(decision, suggestions: nil)) }
    }

    private func touch(_ sid: String, _ now: Date) {
        sessions[sid]?.lastEventAt = now
    }

    /// Applies a change to a session, creating it if a hook arrives before SessionStart.
    private func update(_ sid: String, _ event: HookEvent, _ now: Date, _ change: (inout ClaudeSession) -> Void) {
        var session = sessions[sid] ?? ClaudeSession(id: sid, label: label(for: event.cwd), statusSince: now, lastEventAt: now)
        let previous = session.status
        change(&session)
        if session.status != previous { session.statusSince = now }
        session.lastEventAt = now
        sessions[sid] = session
    }
}
