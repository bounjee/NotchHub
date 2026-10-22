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
    /// When the current turn started working, and how many tools it used.
    var workStartedAt: Date?
    var toolUses = 0
    /// Shells or agents still running in the background after the turn finished.
    var backgroundTasks = 0
    /// A finished (or failed) turn the user has not looked at yet.
    var unseen = false

    /// Claude Code and the desktop app run quick helper sessions (titles, suggestions) that
    /// also send hooks. A turn counts as real work if it used a tool or took a few seconds.
    func didRealWork(at now: Date) -> Bool {
        toolUses > 0 || now.timeIntervalSince(workStartedAt ?? now) >= ClaudeStore.minimumWork
    }
}

/// What the closed notch shows: the most urgent kind of activity and how many sessions have it.
struct ClosedIndicator: Equatable {
    var kind: SessionStatus
    var count: Int
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
    /// Closed-notch summary across sessions; nil when there is nothing worth showing.
    private(set) var indicator: ClosedIndicator?
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

    static let doneLifetime: TimeInterval = 60 * 60
    /// How long the notch's green check for unseen finished work stays.
    static let checkLifetime: TimeInterval = 5 * 60
    nonisolated static let minimumWork: TimeInterval = 4
    /// Sessions closed without SessionEnd (terminal window closed) stop sending events.
    static let staleLifetime: TimeInterval = 30 * 60

    /// Recent PreToolUse calls per session, used to find the `tool_use_id` of a permission request.
    private(set) var recentToolUses: [String: [(name: String, inputKey: String?, id: String)]] = [:]
    /// Questions asked in the Claude app's wrap-up box this turn, per session; the turn ends on them.
    private(set) var pendingAsks: [String: String] = [:]
    /// Tool calls that already finished; their ids must never be given to a new request.
    private var finishedToolUseIDs: [String] = []
    /// Sessions run by `claude -p`, with their last event; their events are ignored.
    private(set) var headlessSessions: [String: Date] = [:]

    /// Most urgent first: waiting on you, working, then the most recently finished.
    var sortedSessions: [ClaudeSession] {
        sessions.values.sorted { a, b in
            let (ra, rb) = (Self.urgency(a.status), Self.urgency(b.status))
            if ra != rb { return ra < rb }
            // Working sessions keep their place (newest turn first) instead of reshuffling.
            if a.status == .working { return (a.workStartedAt ?? a.statusSince) > (b.workStartedAt ?? b.statusSince) }
            return a.statusSince > b.statusSince
        }
    }

    /// "my-app · Working" for one session, "2 working · 1 done" for several, most urgent first.
    var statusSummary: String? {
        let all = sortedSessions
        guard let first = all.first else { return nil }
        if all.count == 1 { return "\(Self.shortLabel(first.label)) · \(first.status.title)" }
        var counts: [SessionStatus: Int] = [:]
        for session in all { counts[session.status, default: 0] += 1 }
        return counts.keys.sorted { Self.urgency($0) < Self.urgency($1) }
            .map { "\(counts[$0]!) \($0.title.localizedLowercase)" }
            .joined(separator: " · ")
    }

    static func urgency(_ status: SessionStatus) -> Int {
        switch status {
        case .needsApproval: 0
        case .waitingForUser: 1
        case .working: 2
        case .error: 3
        case .done: 4
        case .idle: 5
        }
    }

    private func refreshHeadline() {
        let statuses = Set(sessions.values.map(\.status))
        let headline = [SessionStatus.needsApproval, .error, .working, .waitingForUser, .done].first { statuses.contains($0) }
        if headline != headlineStatus { headlineStatus = headline }

        func count(_ match: (ClaudeSession) -> Bool) -> Int { sessions.values.filter(match).count }
        let approvals = count { $0.status == .needsApproval }
        let working = count { $0.status == .working }
        let waiting = count { $0.status == .waitingForUser }
        let failed = count { $0.status == .error && $0.unseen }
        let finished = count { $0.status == .done && $0.unseen }
        let next: ClosedIndicator? =
            approvals > 0 ? ClosedIndicator(kind: .needsApproval, count: approvals)
            : working > 0 ? ClosedIndicator(kind: .working, count: working)
            : waiting > 0 ? ClosedIndicator(kind: .waitingForUser, count: waiting)
            : failed > 0 ? ClosedIndicator(kind: .error, count: failed)
            : finished > 0 ? ClosedIndicator(kind: .done, count: finished)
            : nil
        if next != indicator { indicator = next }
    }

    /// The panel was opened: finished turns count as seen.
    /// Something else happened in the notch: the green check for finished work steps aside.
    /// Errors keep their warning until the panel is opened.
    func markFinishedSeen() {
        let finished = sessions.keys.filter { sessions[$0]?.status == .done && sessions[$0]?.unseen == true }
        guard !finished.isEmpty else { return }
        for id in finished { sessions[id]?.unseen = false }
        refreshHeadline()
    }

    func markSeen() {
        guard sessions.values.contains(where: \.unseen) else { return }
        for id in sessions.keys where sessions[id]?.unseen == true { sessions[id]?.unseen = false }
        refreshHeadline()
    }

    func handle(_ event: HookEvent, responder: PermissionReplying? = nil, now: Date = Date()) {
        if event.isStatusLine {
            updateLimits(event, now: now)
            locateTerminal(event)
            return
        }
        if event.isHeadless || headlessSessions[event.sessionID] != nil { headlessSessions[event.sessionID] = now }
        if headlessSessions[event.sessionID] != nil {
            // Never leave a hook waiting, and forget anything shown before we knew.
            responder?.reply(Self.replyLine(.none, suggestions: nil))
            if sessions.removeValue(forKey: event.sessionID) != nil { refreshHeadline() }
            if event.name == "SessionEnd" { headlessSessions[event.sessionID] = nil }
            return
        }
        defer { refreshHeadline() }
        defer { locateTerminal(event) }
        defer {
            log.debug("hook \(event.name, privacy: .public) session=\(String(event.sessionID.prefix(8)), privacy: .public) label=\(self.sessions[event.sessionID]?.label ?? "-", privacy: .public) type=\(event.notificationType ?? "-", privacy: .public) pending=\(self.pending.count) status=\(String(describing: self.sessions[event.sessionID]?.status), privacy: .public)")
        }
        lastEventAt = now
        let sid = event.sessionID

        switch event.name {
        case "SessionStart":
            sessions[sid] = ClaudeSession(id: sid, label: label(for: event), statusSince: now, lastEventAt: now)

        case "UserPromptSubmit":
            resolvePending(in: sid, with: .none)
            pendingAsks[sid] = nil
            sessions[sid]?.backgroundTasks = 0
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
            if let question = event.askedQuestion { pendingAsks[sid] = question }
            if let name = event.toolName, Self.questionTools.contains(name) {
                askUser(sid, event, now)
                return
            }
            update(sid, event, now) {
                $0.status = self.hasPending(sid) ? .needsApproval : .working
                $0.currentTool = Self.toolLine(event)
            }

        case "PermissionRequest":
            guard let responder else { return }
            let name = event.toolName ?? "?"
            // A question or a plan needs a real answer, which only the terminal can give.
            if Self.questionTools.contains(name) {
                responder.reply(Self.replyLine(.none, suggestions: nil))
                if sessions[sid]?.status != .waitingForUser { askUser(sid, event, now) }
                return
            }
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
            // `idle_prompt` only means a finished turn has sat unanswered for a minute: the session
            // stays done. Only a question asked in the middle of a turn waits for the user.
            guard ["agent_needs_input", "elicitation_dialog"].contains(event.notificationType ?? ""),
                  sessions[sid]?.status == .working
            else { touch(sid, now); return }
            update(sid, event, now) { $0.status = .waitingForUser }

        case "Stop":
            resolvePending(in: sid, with: .none)
            let worked = sessions[sid]?.didRealWork(at: now) ?? false
            // A turn that ends on a question is waiting for the user, not done.
            let boxQuestion = pendingAsks.removeValue(forKey: sid)
            let asks = boxQuestion != nil || Self.asksQuestion(event.lastAssistantMessage ?? "")
            // The turn is over even if it left a shell (a dev server, a watcher) running in the
            // background: that is done, with a note, not "thinking" for as long as the shell lives.
            update(sid, event, now) {
                $0.status = asks ? .waitingForUser : .done
                $0.currentTool = asks ? boxQuestion : nil
                $0.backgroundTasks = event.backgroundTaskCount
                if let message = event.lastAssistantMessage, !message.isEmpty { $0.lastMessage = message }
                if worked || asks { $0.unseen = true }
            }
            let label = Self.shortLabel(sessions[sid]?.label ?? "Claude")
            if asks { onPeek?(.question(label)) }
            else if worked { onPeek?(.claudeDone(label)) }

        case "StopFailure":
            resolvePending(in: sid, with: .none)
            update(sid, event, now) {
                $0.status = .error
                $0.currentTool = nil
                $0.unseen = true
                $0.lastMessage = event.lastAssistantMessage ?? event.errorMessage ?? $0.lastMessage
            }

        case "SessionEnd":
            resolvePending(in: sid, with: .none)
            recentToolUses[sid] = nil
            pendingAsks[sid] = nil
            // `claude -p` ends right after Stop; keep its answer visible until it expires,
            // but let helper sessions that never really worked disappear.
            if let session = sessions[sid], session.status == .done, session.didRealWork(at: session.statusSince) {
                break
            }
            sessions[sid] = nil

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
        guard var session = sessions[event.sessionID], session.terminal == nil else { return }
        // Tool events skip the process walk to stay cheap; do it once here if still unknown.
        let ancestors = event.ancestors.isEmpty ? event.parentPID.map { ProcessTree.ancestors(of: $0) } ?? [] : event.ancestors
        guard !ancestors.isEmpty, let location = TerminalJump.locate(ancestors: ancestors, cwd: event.cwd) else { return }
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
        log.debug("answered \(String(describing: decision), privacy: .public)")
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
        log.debug("hook connection closed, request dropped")
        if var session = sessions[request.sessionID], session.status == .needsApproval, !hasPending(request.sessionID) {
            session.status = .working
            sessions[request.sessionID] = session
        }
    }

    func removeExpiredSessions(now: Date = Date()) {
        defer { refreshHeadline() }
        // The notch's check fades after a few minutes; the session stays listed for an hour.
        for (id, session) in sessions where session.status == .done && session.unseen
            && now.timeIntervalSince(session.statusSince) >= Self.checkLifetime {
            sessions[id]?.unseen = false
        }
        sessions = sessions.filter { _, session in
            if session.status == .done { return now.timeIntervalSince(session.statusSince) < Self.doneLifetime }
            if session.status == .needsApproval { return true }
            return now.timeIntervalSince(session.lastEventAt) < Self.staleLifetime
        }
        // Sessions killed without SessionEnd leave bookkeeping behind; drop it with them.
        recentToolUses = recentToolUses.filter { sessions[$0.key] != nil }
        pendingAsks = pendingAsks.filter { sessions[$0.key] != nil }
        headlessSessions = headlessSessions.filter { now.timeIntervalSince($0.value) < Self.staleLifetime }
    }

    func dismiss(_ id: ClaudeSession.ID) {
        defer { refreshHeadline() }
        resolvePending(in: id, with: .none)
        sessions[id] = nil
        recentToolUses[id] = nil
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

    /// A session's name short enough for the notch and the mascot's bubble: whole words up to
    /// `max` characters ("NotchHub macOS uygulaması" -> "NotchHub macOS"), never cut with "…".
    nonisolated static func shortLabel(_ label: String, max: Int = 16) -> String {
        guard label.count > max else { return label }
        var result = ""
        for word in label.split(separator: " ") {
            let next = result.isEmpty ? String(word) : result + " " + word
            if next.count > max { break }
            result = next
        }
        // A single word longer than the limit keeps its start.
        return result.isEmpty ? String(label.prefix(max)) : result
    }

    /// Tools that stop and wait for the user's answer in the terminal.
    nonisolated static let questionTools: Set<String> = ["AskUserQuestion", "ExitPlanMode"]

    /// Whether a reply ends by asking the user something: its last line ends with a question mark.
    nonisolated static func asksQuestion(_ message: String) -> Bool {
        // Prose only: a code block's last line is not the reply asking anything.
        var inCode = false
        var prose: [String] = []
        for line in message.components(separatedBy: .newlines).map({ $0.trimmingCharacters(in: .whitespaces) }) {
            if line.hasPrefix("```") { inCode.toggle(); continue }
            if !inCode, !line.isEmpty { prose.append(line) }
        }
        guard let last = prose.last else { return false }
        let stripped = last.trimmingCharacters(in: CharacterSet(charactersIn: "*_)\"'”’`. ").union(.whitespaces))
        return stripped.hasSuffix("?") || stripped.hasSuffix("？")
    }

    /// Claude asked a question (or showed a plan) and waits for the answer in the terminal.
    private func askUser(_ sid: String, _ event: HookEvent, _ now: Date) {
        let question = event.toolName == "ExitPlanMode" ? String(localized: "Plan ready for your review") : event.toolSummary
        update(sid, event, now) {
            $0.status = .waitingForUser
            $0.currentTool = question.flatMap { $0.isEmpty ? nil : $0 }
            $0.unseen = true
        }
        onPeek?(.question(Self.shortLabel(sessions[sid]?.label ?? "Claude")))
    }

    nonisolated static func toolLine(_ event: HookEvent) -> String? {
        guard var name = event.toolName else { return nil }
        // mcp__server__tool -> server · tool
        let parts = name.components(separatedBy: "__")
        if parts.count == 3, parts[0] == "mcp" { name = "\(parts[1]) · \(parts[2])" }
        let summary = (event.toolSummary ?? "").replacingOccurrences(of: "\n", with: " ")
        return summary.isEmpty ? name : "\(name): \(summary)"
    }

    /// The project name from notch-hook; for scratch and temporary folders the session title.
    private func label(for event: HookEvent) -> String {
        if let project = event.project { return project }
        if let title = event.sessionTitle { return title }
        let cwd = event.cwd
        let temporary = cwd.contains("/scratch-workspaces/") || ["/private/tmp/", "/tmp/", "/private/var/folders/", "/var/folders/"].contains(where: cwd.hasPrefix)
        let name = URL(fileURLWithPath: cwd).lastPathComponent
        return name.isEmpty || cwd.isEmpty || temporary ? "Claude" : name
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
        var session = sessions[sid] ?? ClaudeSession(id: sid, label: label(for: event), statusSince: now, lastEventAt: now)
        // A session first seen through a tool event has only the folder name; improve it later.
        if let project = event.project { session.label = project }
        else if session.label == "Claude", let title = event.sessionTitle { session.label = title }
        let previous = session.status
        change(&session)
        if session.status != previous { session.statusSince = now }
        if event.name == "UserPromptSubmit" {
            session.workStartedAt = now
            session.toolUses = 0
            session.unseen = false
        } else if session.workStartedAt == nil, session.status == .working {
            session.workStartedAt = now
        }
        if event.name == "PreToolUse" { session.toolUses += 1 }
        session.lastEventAt = now
        sessions[sid] = session
    }
}
