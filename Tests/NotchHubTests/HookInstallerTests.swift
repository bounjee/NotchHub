import Foundation
import Testing
@testable import NotchHub

@Suite struct HookInstallerTests {
    let home: URL
    let settings: URL
    let hook = "/Applications/NotchHub.app/Contents/MacOS/notch-hook"

    init() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("notchhub-home-\(UUID().uuidString)")
        settings = home.appendingPathComponent(".claude/settings.json")
        try FileManager.default.createDirectory(at: settings.deletingLastPathComponent(), withIntermediateDirectories: true)
    }

    private func write(_ object: [String: Any]) throws {
        try JSONSerialization.data(withJSONObject: object).write(to: settings)
    }

    private func readSettings() throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: Data(contentsOf: settings)) as! [String: Any]
    }

    private let userHook: [String: Any] = ["matcher": "Bash", "hooks": [["type": "command", "command": "/usr/local/bin/lint.sh"]]]

    @Test func installKeepsExistingSettingsAndHooks() throws {
        try write(["model": "opus", "hooks": ["PreToolUse": [userHook]]])
        try HookInstaller.install(at: settings, hookPath: hook)

        let result = try readSettings()
        #expect(result["model"] as? String == "opus")
        let hooks = result["hooks"] as! [String: Any]
        #expect(Set(hooks.keys) == Set(HookInstaller.events.map(\.name)))
        let preToolUse = hooks["PreToolUse"] as! [[String: Any]]
        #expect(preToolUse.count == 2)
        #expect(preToolUse[0]["matcher"] as? String == "Bash")
        #expect(HookInstaller.isInstalled(at: settings))
    }

    @Test func permissionRequestIsSynchronousWithLongTimeout() throws {
        try HookInstaller.install(at: settings, hookPath: hook)
        let hooks = try readSettings()["hooks"] as! [String: Any]
        let entry = ((hooks["PermissionRequest"] as! [[String: Any]])[0]["hooks"] as! [[String: Any]])[0]
        #expect(entry["async"] == nil)
        #expect(entry["timeout"] as? Int == 86400)
        let stop = ((hooks["Stop"] as! [[String: Any]])[0]["hooks"] as! [[String: Any]])[0]
        #expect(stop["async"] as? Bool == true)
        #expect(stop["command"] as? String == hook)
    }

    @Test func installTwiceDoesNotDuplicate() throws {
        try HookInstaller.install(at: settings, hookPath: hook)
        try HookInstaller.install(at: settings, hookPath: hook)
        let hooks = try readSettings()["hooks"] as! [String: Any]
        #expect((hooks["Stop"] as! [Any]).count == 1)
    }

    @Test func uninstallRemovesOnlyOurEntries() throws {
        let mixedGroup: [String: Any] = ["hooks": [
            ["type": "command", "command": "/usr/local/bin/notify.sh"],
            ["type": "command", "command": hook],
        ]]
        try write(["hooks": ["PreToolUse": [userHook], "Stop": [mixedGroup]], "theme": "dark"])
        try HookInstaller.install(at: settings, hookPath: hook)
        try HookInstaller.uninstall(at: settings)

        let result = try readSettings()
        #expect(result["theme"] as? String == "dark")
        let hooks = result["hooks"] as! [String: Any]
        #expect(Set(hooks.keys) == ["PreToolUse", "Stop"])
        let stopHooks = (hooks["Stop"] as! [[String: Any]])[0]["hooks"] as! [[String: Any]]
        #expect(stopHooks.count == 1)
        #expect(stopHooks[0]["command"] as? String == "/usr/local/bin/notify.sh")
        #expect(!HookInstaller.isInstalled(at: settings))
    }

    @Test func uninstallDropsEmptyHooksKey() throws {
        try write(["model": "opus"])
        try HookInstaller.install(at: settings, hookPath: hook)
        try HookInstaller.uninstall(at: settings)
        let result = try readSettings()
        #expect(result["hooks"] == nil)
        #expect(result["model"] as? String == "opus")
    }

    @Test func backupHoldsPreviousContent() throws {
        try write(["model": "opus"])
        let original = try Data(contentsOf: settings)
        try HookInstaller.install(at: settings, hookPath: hook)
        let backup = try Data(contentsOf: settings.appendingPathExtension("notchhub-backup"))
        #expect(backup == original)
    }

    @Test func missingFileIsCreated() throws {
        try? FileManager.default.removeItem(at: settings.deletingLastPathComponent())
        try HookInstaller.install(at: settings, hookPath: hook)
        #expect(HookInstaller.isInstalled(at: settings))
    }

    @Test func invalidJSONIsLeftUntouched() throws {
        let broken = Data("{ \"model\": ".utf8)
        try broken.write(to: settings)
        #expect(throws: HookInstaller.Failure.self) { try HookInstaller.install(at: settings, hookPath: hook) }
        #expect(try Data(contentsOf: settings) == broken)
        #expect(!FileManager.default.fileExists(atPath: settings.appendingPathExtension("notchhub-backup").path))
    }
}
