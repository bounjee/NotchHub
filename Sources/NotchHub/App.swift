import AppKit
import ServiceManagement
import SwiftUI

@main
@MainActor
enum NotchHubApp {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        // --regular shows a Dock icon, which UI automation tools need to find the app.
        app.setActivationPolicy(CommandLine.arguments.contains("--regular") ? .regular : .accessory)
        app.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let claude = ClaudeStore(limitsURL: ClaudeStore.defaultLimitsURL)
    private lazy var model = NotchModel(claude: claude)
    private lazy var windowController = NotchWindowController(model: model)
    private lazy var pet = DesktopPet(model: model) { [weak self] in
        guard let self else { return }
        withAnimation(.notchOpen) { self.model.showPeek(.summoned, hovering: false) }
    }
    private var server: HubServer?
    private var statusItem: NSStatusItem?
    private var maintenanceTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let arguments = CommandLine.arguments
        if let index = arguments.firstIndex(of: "--snapshot"), index + 1 < arguments.count {
            Snapshot.run(into: URL(fileURLWithPath: arguments[index + 1]))
            return
        }
        // Launch at login plus a manual launch must not give two panels fighting over the socket.
        if HubServer.isServing(at: HubServer.defaultPath) {
            NSLog("NotchHub: another instance is running, quitting")
            NSApp.terminate(nil)
            return
        }
        windowController.start()
        setUpStatusItem()

        claude.onPeek = { [weak self] reason in self?.peek(reason) }
        claude.hooksInstalled = HookInstaller.isInstalled()
        if DesktopPet.isEnabled { pet.start() }

        let claude = claude
        let server = HubServer(
            onEvent: { event, connection in
                Task { @MainActor in claude.handle(event, responder: connection) }
            },
            onClose: { connection in
                Task { @MainActor in claude.responderClosed(connection) }
            }
        )
        do {
            try server.start()
            self.server = server
        } catch {
            NSLog("NotchHub: socket server failed: \(error)")
        }

        maintenanceTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.claude.removeExpiredSessions() }
        }
        maintenanceTimer?.tolerance = 5
    }

    func applicationWillTerminate(_ notification: Notification) {
        server?.removeSocketFile()
    }

    private func peek(_ reason: PeekReason) {
        withAnimation(reason.opensPanel ? .notchOpen : .notchActivity) {
            model.showPeek(reason, hovering: windowController.isPointerInside)
        }
        if reason == .permission {
            NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
        }
    }

    // MARK: - Menu bar

    /// A laptop screen with a notch, drawn as a template so it follows the menu bar's colour.
    static let menuBarIcon: NSImage = {
        let image = NSImage(size: NSSize(width: 20, height: 16), flipped: true) { _ in
            let screen = NSBezierPath(roundedRect: NSRect(x: 1.75, y: 2.25, width: 16.5, height: 11.5), xRadius: 2.5, yRadius: 2.5)
            screen.lineWidth = 1.5
            NSColor.black.setStroke()
            screen.stroke()
            let notch = NSBezierPath(roundedRect: NSRect(x: 7, y: 1.5, width: 6, height: 4), xRadius: 1.4, yRadius: 1.4)
            NSColor.black.setFill()
            notch.fill()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "NotchHub"
        return image
    }()

    private func setUpStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = Self.menuBarIcon
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let installed = HookInstaller.isInstalled()
        let status = NSMenuItem(
            title: installed ? String(localized: "Claude Code hooks installed") : String(localized: "Claude Code hooks not installed"),
            action: nil, keyEquivalent: ""
        )
        status.isEnabled = false
        menu.addItem(status)
        menu.addItem(withTitle: installed ? String(localized: "Remove Hooks") : String(localized: "Install Hooks"),
                     action: #selector(toggleHooks), keyEquivalent: "").target = self
        menu.addItem(.separator())

        let petItem = menu.addItem(withTitle: String(localized: "Desktop Mascot"), action: #selector(togglePet), keyEquivalent: "")
        petItem.target = self
        petItem.state = pet.isRunning ? .on : .off

        let login = menu.addItem(withTitle: String(localized: "Open at Login"), action: #selector(toggleLoginItem), keyEquivalent: "")
        login.target = self
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(.separator())

        menu.addItem(withTitle: String(localized: "Quit NotchHub"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    }

    @objc private func toggleHooks() {
        do {
            if HookInstaller.isInstalled() {
                try HookInstaller.uninstall()
            } else {
                guard FileManager.default.isExecutableFile(atPath: hookPath) else { throw HookInstaller.Failure.hookMissing(hookPath) }
                try HookInstaller.install(hookPath: hookPath)
            }
        } catch {
            showError(String(localized: "Could not change the hooks"), error)
        }
        claude.hooksInstalled = HookInstaller.isInstalled()
    }

    /// The bundled hook binary, so a build run from outside /Applications still installs a working path.
    private var hookPath: String {
        let bundled = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/notch-hook").path
        return FileManager.default.isExecutableFile(atPath: bundled) && bundled.contains(HookInstaller.marker)
            ? bundled : HookInstaller.defaultHookPath
    }

    @objc private func togglePet() {
        if pet.isRunning {
            pet.stop()
            DesktopPet.isEnabled = false
        } else {
            pet.start()
            DesktopPet.isEnabled = true
        }
    }

    @objc private func toggleLoginItem() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            showError(String(localized: "Could not change Open at Login"), error)
        }
    }

    private func showError(_ title: String, _ error: Error) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        NSApp.activate()
        alert.runModal()
    }
}
