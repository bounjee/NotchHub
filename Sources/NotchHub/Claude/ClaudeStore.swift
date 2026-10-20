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

    /// Called when the panel should briefly open by itself.
    var onPeek: ((PeekReason) -> Void)?

    static let doneLifetime: TimeInterval = 10 * 60
    /// Sessions closed without SessionEnd (terminal window closed) stop sending events.
    static let staleLifetime: TimeInterval = 30 * 60

    /// Recent PreToolUse calls per session, used to find the `tool_use_id` of a permission request.
    private var recentToolUses: [String: [(name: String, inputKey: String?, id: String)]] = [:]

    var sortedSessions: [ClaudeSession] {
        sessions.values.sorted { $0.lastEventAt > $1.lastEventAt }
    }

    /// The most urgent status across sessions, used by the closed-notch indicator.
    var headlineStatus: SessionStatus? {
        let statuses = Set(sessions.values.map(\.status))
        for status in [SessionStatus.needsApproval, .error, .working, .waitingForUser, .done] where statuses.contains(status) {
            return status
        }
        return nil
    }

    func handle(_ event: HookEvent, responder: PermissionReplying? = nil, now: Date = Date()) {
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
                // async hooks may deliver PreToolUse after its PermissionRequest
                if let index = pending.firstIndex(where: {
                    $0.sessionID == sid && $0.toolUseID == nil && $0.toolName == name && $0.toolInputKey == event.toolInputKey
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
            let match = recentToolUses[sid]?.last { $0.name == name && $0.inputKey == event.toolInputKey }
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
            // A late async PostToolUse must not revive a finished session.
            guard sessions[sid]?.status != .done else { touch(sid, now); return }
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
            if !event.hasBackgroundTasks { onPeek?(.claudeDone) }

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

    /// Answers a pending request from the panel.
    func answer(_ id: PendingPermission.ID, _ decision: PermissionDecision, now: Date = Date()) {
        guard let index = pending.firstIndex(where: { $0.id == id }) else { return }
        let request = pending.remove(at: index)
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
        log.notice("hook connection closed, request dropped")
        if var session = sessions[request.sessionID], session.status == .needsApproval, !hasPending(request.sessionID) {
            session.status = .working
            sessions[request.sessionID] = session
        }
    }

    func removeExpiredSessions(now: Date = Date()) {
        sessions = sessions.filter { _, session in
            if session.status == .done { return now.timeIntervalSince(session.statusSince) < Self.doneLifetime }
            if session.status == .needsApproval { return true }
            return now.timeIntervalSince(session.lastEventAt) < Self.staleLifetime
        }
    }

    func dismiss(_ id: ClaudeSession.ID) {
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
