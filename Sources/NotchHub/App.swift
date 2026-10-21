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
    private let shelf = Shelf()
    private let clipboard = ClipboardHistory()
    private let battery = BatteryMonitor()
    private let arrivals = FileArrivals()
    private lazy var model = NotchModel(claude: claude, shelf: shelf, clipboard: clipboard, battery: battery)
    private lazy var windowController = NotchWindowController(model: model)
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
        battery.start()
        clipboard.start()
        windowController.start()
        setUpStatusItem()

        claude.onPeek = { [weak self] reason in self?.peek(reason) }
        battery.onEvent = { [weak self] event in
            switch event {
            case .pluggedChanged: self?.peek(.power)
            case .charged: self?.peek(.charged)
            case .low: self?.peek(.lowBattery)
            }
        }
        clipboard.onNewItem = { [weak self] item in self?.peek(.copied(item.text)) }
        claude.hooksInstalled = HookInstaller.isInstalled()
        arrivals.onArrival = { [weak self] url, kind in
            guard let self else { return }
            withAnimation(.snappy) { self.shelf.add([url], source: kind) }
            self.peek(kind == .screenshot ? .screenshot(url.path) : .downloaded(url.lastPathComponent))
        }
        arrivals.start()

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
            MainActor.assumeIsolated {
                self?.claude.removeExpiredSessions()
                self?.shelf.removeExpired()
            }
        }
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

    private func setUpStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "rectangle.topthird.inset.filled", accessibilityDescription: "NotchHub")
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let installed = HookInstaller.isInstalled()
        let status = NSMenuItem(title: installed ? "Claude Code hook'ları kurulu" : "Claude Code hook'ları kurulu değil", action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        menu.addItem(withTitle: installed ? "Hook'ları kaldır" : "Hook'ları kur", action: #selector(toggleHooks), keyEquivalent: "")
            .target = self
        menu.addItem(.separator())

        let login = menu.addItem(withTitle: "Girişte başlat", action: #selector(toggleLoginItem), keyEquivalent: "")
        login.target = self
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(.separator())

        menu.addItem(withTitle: "NotchHub'dan çık", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
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
            showError("Hook ayarı değiştirilemedi", error)
        }
        claude.hooksInstalled = HookInstaller.isInstalled()
        arrivals.onArrival = { [weak self] url, kind in
            guard let self else { return }
            withAnimation(.snappy) { self.shelf.add([url], source: kind) }
            self.peek(kind == .screenshot ? .screenshot(url.path) : .downloaded(url.lastPathComponent))
        }
        arrivals.start()
    }

    /// The bundled hook binary, so a build run from outside /Applications still installs a working path.
    private var hookPath: String {
        let bundled = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/notch-hook").path
        return FileManager.default.isExecutableFile(atPath: bundled) && bundled.contains(HookInstaller.marker)
            ? bundled : HookInstaller.defaultHookPath
    }

    @objc private func toggleLoginItem() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            showError("Girişte başlatma ayarlanamadı", error)
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
