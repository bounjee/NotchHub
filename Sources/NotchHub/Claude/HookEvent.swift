import Foundation

/// One rate-limit window from Claude Code's status line data.
struct UsageWindow: Equatable, Sendable, Codable {
    var usedPercentage: Double
    var resetsAt: Date
}

/// A Claude Code hook payload, reduced to the fields NotchHub uses.
struct HookEvent: Sendable {
    var name: String
    var sessionID: String
    var cwd: String
    /// Git repository (or folder) name worked out by notch-hook; nil for scratch folders.
    var project: String?
    var sessionTitle: String?
    var toolName: String?
    var toolInputKey: String?
    var toolSummary: String?
    /// A question the turn ends with, asked through the Claude app's wrap-up box rather than in the reply.
    var askedQuestion: String?
    var toolUseID: String?
    var lastAssistantMessage: String?
    var hasBackgroundTasks = false
    var notificationType: String?
    var errorMessage: String?
    /// `permission_suggestions` re-encoded as JSON, passed back as `updatedPermissions`.
    var permissionSuggestions: Data?
    /// Sent by `notch-hook --statusline`; carries plan usage instead of a hook event.
    var isStatusLine = false
    var fiveHour: UsageWindow?
    var sevenDay: UsageWindow?
    /// Claude Code and the processes above it, for jumping to the session's terminal.
    var ancestors: [ProcessTree.Entry] = []
    /// From `claude -p` (scripts, other apps): not a conversation, so not shown.
    var isHeadless = false

    /// Events after which the terminal is looked up; tool events skip it to stay cheap.
    static let locatingEvents: Set<String> = ["SessionStart", "UserPromptSubmit", "PermissionRequest", "Stop", "Notification"]

    init(name: String, sessionID: String, cwd: String = "") {
        self.name = name
        self.sessionID = sessionID
        self.cwd = cwd
    }

    init?(json data: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let name = object["hook_event_name"] as? String,
              let sessionID = object["session_id"] as? String
        else { return nil }
        self.init(name: name, sessionID: sessionID, cwd: object["cwd"] as? String ?? "")

        project = (object["notchhub_project"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        sessionTitle = (object["session_title"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        toolName = object["tool_name"] as? String
        toolUseID = object["tool_use_id"] as? String
        if let input = object["tool_input"] {
            // JSONSerialization raises an Objective-C exception (not a Swift error) for scalars.
            toolInputKey = JSONSerialization.isValidJSONObject(input)
                ? (try? JSONSerialization.data(withJSONObject: input, options: [.sortedKeys])).flatMap { String(data: $0, encoding: .utf8) }
                : String(describing: input)
            if let toolName { toolSummary = Self.summary(tool: toolName, input: input as? [String: Any] ?? [:]) }
            if toolName?.hasSuffix("__wrap_up") == true, let ask = (input as? [String: Any])?["ask"] as? String,
               !ask.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                askedQuestion = ask
            }
        }
        lastAssistantMessage = object["last_assistant_message"] as? String
        if let tasks = object["background_tasks"] as? [Any] { hasBackgroundTasks = !tasks.isEmpty }
        notificationType = object["notification_type"] as? String
        if let error = object["error"] as? String { errorMessage = error }
        if let suggestions = object["permission_suggestions"] as? [Any], !suggestions.isEmpty,
           JSONSerialization.isValidJSONObject(suggestions) {
            permissionSuggestions = try? JSONSerialization.data(withJSONObject: suggestions)
        }

        // The status line JSON may carry its own `hook_event_name` ("Status").
        isStatusLine = name == "NotchHubStatusLine" || name == "Status"
        if let limits = object["rate_limits"] as? [String: Any] {
            fiveHour = Self.window(limits["five_hour"])
            sevenDay = Self.window(limits["seven_day"])
        }
        if let parent = (object["notchhub_ppid"] as? NSNumber)?.int32Value, parent > 1,
           isStatusLine || Self.locatingEvents.contains(name) {
            ancestors = ProcessTree.ancestors(of: parent)
            isHeadless = !isStatusLine && ProcessTree.isHeadlessClaude(ancestors)
        }
    }

    private static func window(_ value: Any?) -> UsageWindow? {
        guard let object = value as? [String: Any],
              let used = (object["used_percentage"] as? NSNumber)?.doubleValue,
              let resets = (object["resets_at"] as? NSNumber)?.doubleValue
        else { return nil }
        return UsageWindow(usedPercentage: used, resetsAt: Date(timeIntervalSince1970: resets))
    }

    /// Short human-readable description of a tool call, e.g. the Bash command or edited file.
    static func summary(tool: String, input: [String: Any]) -> String {
        if tool == "AskUserQuestion" {
            let questions = input["questions"] as? [[String: Any]] ?? []
            return (questions.first?["question"] as? String) ?? ""
        }
        if tool == "ExitPlanMode" { return "" }
        let keys: [String] = switch tool {
        case "Bash": ["command"]
        case "Edit", "MultiEdit", "Write", "Read", "NotebookEdit": ["file_path", "notebook_path"]
        case "Grep", "Glob": ["pattern"]
        case "WebFetch": ["url"]
        case "WebSearch": ["query"]
        case "Task", "Agent": ["description", "prompt"]
        default: []
        }
        for key in keys {
            if let value = input[key] as? String, !value.isEmpty { return abbreviatingHome(value) }
        }
        if let first = input.keys.sorted().lazy.compactMap({ input[$0] as? String }).first(where: { !$0.isEmpty }) {
            return first
        }
        return ""
    }

    private static func abbreviatingHome(_ path: String) -> String {
        let home = NSHomeDirectory()
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }
}
