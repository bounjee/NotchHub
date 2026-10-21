import AppKit
import Darwin

/// Where a Claude Code session runs: the GUI app hosting its terminal and the session's tty.
struct TerminalLocation: Equatable, Sendable {
    var appPID: pid_t
    var bundleID: String?
    var tty: String?
}

enum ProcessTree {
    struct Entry: Equatable, Sendable {
        let pid: pid_t
        let parent: pid_t
        let tty: String?
    }

    static func entry(for pid: pid_t) -> Entry? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        let device = info.kp_eproc.e_tdev
        var tty: String?
        if device != -1, let name = devname(device, S_IFCHR) {
            tty = "/dev/" + String(cString: name)
        }
        return Entry(pid: pid, parent: info.kp_eproc.e_ppid, tty: tty)
    }

    /// Command-line arguments of a process (same user only).
    static func arguments(of pid: pid_t) -> [String] {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 4 else { return [] }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0, size > 4 else { return [] }
        // Layout: argc (Int32), executable path, NUL padding, then the NUL-separated arguments.
        let argc = Int(buffer.withUnsafeBytes { $0.load(as: Int32.self) })
        var index = 4
        while index < size, buffer[index] != 0 { index += 1 }
        while index < size, buffer[index] == 0 { index += 1 }
        var arguments: [String] = []
        while arguments.count < argc, index < size {
            let start = index
            while index < size, buffer[index] != 0 { index += 1 }
            arguments.append(String(decoding: buffer[start..<index], as: UTF8.self))
            index += 1
        }
        return arguments
    }

    /// Whether a Claude Code process among the nearest ancestors runs headless (`claude -p`).
    static func isHeadlessClaude(_ ancestors: [Entry]) -> Bool {
        ancestors.prefix(3).contains { entry in
            let arguments = Self.arguments(of: entry.pid)
            guard arguments.contains(where: { $0.lowercased().contains("claude") }) else { return false }
            return arguments.contains { $0 == "-p" || $0 == "--print" || $0.hasPrefix("--print=") }
        }
    }

    /// The process and its ancestors, nearest first, stopping before launchd.
    static func ancestors(of pid: pid_t, limit: Int = 24) -> [Entry] {
        var chain: [Entry] = []
        var current = pid
        while current > 1, chain.count < limit, let entry = entry(for: current) {
            chain.append(entry)
            current = entry.parent
        }
        return chain
    }
}

@MainActor
enum TerminalJump {
    /// Finds the nearest ancestor that is a regular app (Terminal, iTerm, Ghostty, VS Code, ...).
    static func locate(ancestors: [ProcessTree.Entry]) -> TerminalLocation? {
        let tty = ancestors.first { $0.tty != nil }?.tty
        for entry in ancestors {
            if let app = NSRunningApplication(processIdentifier: entry.pid), app.activationPolicy == .regular {
                return TerminalLocation(appPID: entry.pid, bundleID: app.bundleIdentifier, tty: tty)
            }
        }
        return nil
    }

    /// Brings the terminal to the front and, for Terminal and iTerm, selects the session's tab.
    static func jump(to location: TerminalLocation) {
        // Since macOS 14 a background app's activate() is only a request the system may ignore;
        // asking NSWorkspace to open the running app activates it reliably.
        if let app = NSRunningApplication(processIdentifier: location.appPID), let url = app.bundleURL {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            NSWorkspace.shared.openApplication(at: url, configuration: configuration)
        }
        guard let tty = location.tty, let script = tabScript(bundleID: location.bundleID, tty: tty) else { return }
        // Apple events can block (first-use permission prompt), so stay off the main thread.
        Task.detached(priority: .userInitiated) {
            var error: NSDictionary?
            NSAppleScript(source: script)?.executeAndReturnError(&error)
        }
    }

    nonisolated static func tabScript(bundleID: String?, tty: String) -> String? {
        let tty = tty.replacingOccurrences(of: "\"", with: "")
        switch bundleID {
        case "com.apple.Terminal":
            return """
            tell application "Terminal"
                repeat with w in windows
                    repeat with t in tabs of w
                        if tty of t is "\(tty)" then
                            set selected of t to true
                            set index of w to 1
                            return
                        end if
                    end repeat
                end repeat
            end tell
            """
        case "com.googlecode.iterm2":
            return """
            tell application "iTerm2"
                repeat with w in windows
                    repeat with t in tabs of w
                        repeat with s in sessions of t
                            if tty of s is "\(tty)" then
                                select w
                                select t
                                select s
                                return
                            end if
                        end repeat
                    end repeat
                end repeat
            end tell
            """
        default:
            return nil
        }
    }
}
