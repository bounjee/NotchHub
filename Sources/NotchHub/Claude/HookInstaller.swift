import Foundation

/// Adds and removes NotchHub's entries in `~/.claude/settings.json`, leaving everything else intact.
enum HookInstaller {
    static let marker = "NotchHub.app/Contents/MacOS/notch-hook"
    static let defaultHookPath = "/Applications/NotchHub.app/Contents/MacOS/notch-hook"

    /// (event, uses a tool matcher, runs async)
    static let events: [(name: String, matcher: Bool, async: Bool)] = [
        ("SessionStart", false, true),
        ("UserPromptSubmit", false, true),
        ("PreToolUse", true, true),
        ("PermissionRequest", true, false),
        ("PostToolUse", true, true),
        ("PostToolUseFailure", true, true),
        ("Notification", false, true),
        ("Stop", false, true),
        ("StopFailure", false, true),
        ("SessionEnd", false, true),
    ]

    enum Failure: LocalizedError {
        case invalidJSON, hookMissing(String)
        var errorDescription: String? {
            switch self {
            case .invalidJSON: "~/.claude/settings.json geçerli bir JSON değil. Dosyaya dokunulmadı."
            case .hookMissing(let path): "\(path) bulunamadı. NotchHub'ı /Applications klasörüne kopyalayıp tekrar dene."
            }
        }
    }

    static var settingsURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/settings.json")
    }

    // MARK: - Pure transforms

    static func installing(into settings: [String: Any], hookPath: String = defaultHookPath) -> [String: Any] {
        var settings = removing(from: settings)
        var hooks = settings["hooks"] as? [String: Any] ?? [:]
        for event in events {
            var hook: [String: Any] = ["type": "command", "command": shellQuoted(hookPath)]
            if event.async { hook["async"] = true } else { hook["timeout"] = 86400 }
            var group: [String: Any] = ["hooks": [hook]]
            if event.matcher { group["matcher"] = "*" }
            hooks[event.name] = (hooks[event.name] as? [Any] ?? []) + [group]
        }
        settings["hooks"] = hooks
        return settings
    }

    static func removing(from settings: [String: Any]) -> [String: Any] {
        guard var hooks = settings["hooks"] as? [String: Any] else { return settings }
        var settings = settings
        for (event, value) in hooks {
            guard let groups = value as? [Any] else { continue }
            let kept: [Any] = groups.compactMap { item in
                guard var group = item as? [String: Any], let entries = group["hooks"] as? [Any] else { return item }
                let remaining = entries.filter { !isOurs($0) }
                if remaining.count == entries.count { return item }
                if remaining.isEmpty { return nil }
                group["hooks"] = remaining
                return group
            }
            hooks[event] = kept.isEmpty ? nil : kept
        }
        settings["hooks"] = hooks.isEmpty ? nil : hooks
        return settings
    }

    static func isInstalled(in settings: [String: Any]) -> Bool {
        guard let hooks = settings["hooks"] as? [String: Any] else { return false }
        return hooks.values.contains { value in
            (value as? [Any] ?? []).contains { group in
                ((group as? [String: Any])?["hooks"] as? [Any] ?? []).contains(where: isOurs)
            }
        }
    }

    /// Claude Code runs `command` through a shell, so paths with spaces must be quoted.
    static func shellQuoted(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func isOurs(_ entry: Any) -> Bool {
        ((entry as? [String: Any])?["command"] as? String)?.contains(marker) == true
    }

    // MARK: - File operations

    static func isInstalled(at url: URL = settingsURL) -> Bool {
        (try? read(url)).map { isInstalled(in: $0) } ?? false
    }

    static func install(at url: URL = settingsURL, hookPath: String = defaultHookPath) throws {
        try modify(url) { installing(into: $0, hookPath: hookPath) }
    }

    static func uninstall(at url: URL = settingsURL) throws {
        try modify(url) { removing(from: $0) }
    }

    private static func modify(_ link: URL, _ transform: ([String: Any]) -> [String: Any]) throws {
        let fm = FileManager.default
        // Dotfile setups often symlink settings.json; write through the link instead of replacing it.
        let url = link.resolvingSymlinksInPath()
        let exists = fm.fileExists(atPath: url.path)
        let current = try read(url)
        let backup = link.appendingPathExtension("notchhub-backup")
        // Keep the first backup: it is the state from before NotchHub ever touched the file.
        if exists && !fm.fileExists(atPath: backup.path) {
            try fm.copyItem(at: url, to: backup)
        } else if !exists {
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        }
        let data = try JSONSerialization.data(withJSONObject: transform(current), options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try data.write(to: url, options: .atomic)
    }

    /// Missing or empty file reads as `{}`; anything that is not a JSON object throws.
    private static func read(_ url: URL) throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        let data = try Data(contentsOf: url)
        if data.allSatisfy({ [0x20, 0x0A, 0x0D, 0x09].contains($0) }) { return [:] }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw Failure.invalidJSON }
        return object
    }
}
