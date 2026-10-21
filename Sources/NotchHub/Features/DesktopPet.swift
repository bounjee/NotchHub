import AppKit
import SwiftUI

/// The pet's words and moods, kept free of timing and drawing so they can be tested.
enum PetBrain {
    /// Seconds without a touch before it dozes off.
    static let sleepAfter: TimeInterval = 45

    /// The three things worth knowing at a glance: Claude, plan usage, the latest finish
    /// (or the battery when nothing has finished yet).
    @MainActor
    static func info(store: ClaudeStore, battery: BatteryMonitor?, now: Date = Date()) -> [String] {
        var lines = ["Claude: \(store.statusSummary ?? "boşta")"]

        let limits = store.limits.current(at: now)
        var usage: [String] = []
        if let window = limits.fiveHour { usage.append("5 saat %\(Int(window.usedPercentage.rounded()))") }
        if let window = limits.sevenDay { usage.append("hafta %\(Int(window.usedPercentage.rounded()))") }
        lines.append("Limit: " + (usage.isEmpty ? "bilgi yok" : usage.joined(separator: " · ")))

        if let finished = store.sessions.values.filter({ $0.status == .done }).max(by: { $0.statusSince < $1.statusSince }) {
            lines.append("Son biten: \(finished.label) · \(shortElapsed(from: finished.statusSince, to: now)) önce")
        } else if let battery, battery.hasBattery {
            lines.append("Pil: %\(battery.percent)\(battery.isPluggedIn ? " · şarjda" : "")")
        }
        return lines
    }
}

private final class PetPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    /// Can be dragged into the menu bar area or partly off screen.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

/// The pet's stage: a small window holding the sprite, blush, speech bubble and sleep z's.
final class PetView: NSView {
    let sprite = ClawdSprite()
    private let body = CALayer()
    private let blush = CALayer()
    private let bubble = CALayer()
    private let bubbleText = CATextLayer()
    private let sleepZs = CALayer()

    var onClick: ((Int) -> Void)?
    var onRightClick: ((NSEvent) -> Void)?
    var onDragChanged: ((Bool) -> Void)?
    var onDragEnded: ((NSPoint) -> Void)?

    static let pixel: CGFloat = 4
    static var spriteSize: CGSize {
        CGSize(width: CGFloat(Clawd.width) * pixel, height: CGFloat(Clawd.height) * pixel * Clawd.pixelAspect)
    }
    /// Room for the bubble and the z's above the mascot.
    static let stageSize = CGSize(width: 260, height: spriteSize.height + 100)

    private var dragStart: (mouse: NSPoint, origin: NSPoint)?
    private var isDragging = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = false

        let size = Self.spriteSize
        body.bounds = CGRect(origin: .zero, size: size)
        body.anchorPoint = CGPoint(x: 0.5, y: 0)
        body.position = CGPoint(x: Self.stageSize.width / 2, y: 4)
        sprite.frame = body.bounds
        body.addSublayer(sprite)

        // Rosy cheeks under the eyes, shown when it is happy or touched.
        blush.frame = body.bounds
        blush.opacity = 0
        let pixel = Self.pixel
        for column in [3.0, 13.0] {
            let cheek = CALayer()
            cheek.backgroundColor = NSColor(srgbRed: 1, green: 0.55, blue: 0.62, alpha: 0.9).cgColor
            cheek.frame = CGRect(x: column * pixel, y: size.height - 2 * pixel * Clawd.pixelAspect, width: 2 * pixel, height: pixel * 0.9)
            cheek.cornerRadius = pixel * 0.4
            blush.addSublayer(cheek)
        }
        body.addSublayer(blush)

        bubble.backgroundColor = NSColor(white: 0.1, alpha: 0.94).cgColor
        bubble.cornerRadius = 11
        bubble.borderColor = NSColor(white: 1, alpha: 0.18).cgColor
        bubble.borderWidth = 0.5
        bubble.opacity = 0
        bubbleText.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        bubbleText.fontSize = 12
        bubbleText.foregroundColor = NSColor.white.cgColor
        bubbleText.alignmentMode = .center
        bubbleText.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
        bubble.addSublayer(bubbleText)

        sleepZs.frame = CGRect(x: body.position.x + size.width * 0.25, y: size.height, width: 40, height: 50)
        sleepZs.opacity = 0
        for index in 0..<3 {
            let z = CATextLayer()
            z.string = "z"
            z.font = NSFont.systemFont(ofSize: 11 + CGFloat(index) * 3, weight: .heavy)
            z.fontSize = 11 + CGFloat(index) * 3
            z.foregroundColor = NSColor(white: 1, alpha: 0.85).cgColor
            z.contentsScale = bubbleText.contentsScale
            z.frame = CGRect(x: 0, y: 0, width: 20, height: 20)
            z.opacity = 0
            let rise = CABasicAnimation(keyPath: "position")
            rise.fromValue = CGPoint(x: 6, y: 6)
            rise.toValue = CGPoint(x: 26, y: 44)
            let fade = CAKeyframeAnimation(keyPath: "opacity")
            fade.values = [0, 1, 1, 0]
            fade.keyTimes = [0, 0.2, 0.7, 1]
            let group = CAAnimationGroup()
            group.animations = [rise, fade]
            group.duration = 2.4
            group.beginTime = CACurrentMediaTime() + Double(index) * 0.8
            group.repeatCount = .infinity
            group.isRemovedOnCompletion = false
            z.add(group, forKey: "float")
            sleepZs.addSublayer(z)
        }

        layer?.addSublayer(sleepZs)
        layer?.addSublayer(body)
        layer?.addSublayer(bubble)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Only the mascot itself takes the mouse.
    override func hitTest(_ point: NSPoint) -> NSView? {
        mascotFrame.insetBy(dx: -6, dy: -6).contains(convert(point, from: superview)) ? self : nil
    }

    var mascotFrame: CGRect { body.frame }

    // MARK: - Mouse: click to talk, drag to move

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        dragStart = (NSEvent.mouseLocation, window.frame.origin)
        isDragging = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = dragStart, let window else { return }
        let mouse = NSEvent.mouseLocation
        let delta = NSPoint(x: mouse.x - start.mouse.x, y: mouse.y - start.mouse.y)
        if !isDragging, hypot(delta.x, delta.y) > 3 {
            isDragging = true
            onDragChanged?(true)
        }
        if isDragging {
            window.setFrameOrigin(NSPoint(x: start.origin.x + delta.x, y: start.origin.y + delta.y))
        }
    }

    override func rightMouseDown(with event: NSEvent) { onRightClick?(event) }

    override func mouseUp(with event: NSEvent) {
        defer { dragStart = nil; isDragging = false }
        if isDragging {
            onDragChanged?(false)
            if let origin = window?.frame.origin { onDragEnded?(origin) }
        } else {
            onClick?(event.clickCount)
        }
    }

    // MARK: - Looks

    func say(_ text: String, for seconds: TimeInterval = 2.8) {
        say(lines: [text], for: seconds)
    }

    /// A bubble above the mascot, one row per line.
    func say(lines: [String], for seconds: TimeInterval = 2.8) {
        let font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        let widest = lines.map { ceil(($0 as NSString).size(withAttributes: [.font: font]).width) }.max() ?? 0
        let width = min(Self.stageSize.width - 8, widest + 24)
        let lineHeight: CGFloat = 16
        let height = CGFloat(lines.count) * lineHeight + 10
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        bubbleText.string = lines.joined(separator: "\n")
        bubbleText.alignmentMode = lines.count > 1 ? .left : .center
        bubbleText.isWrapped = false
        bubble.bounds = CGRect(x: 0, y: 0, width: width, height: height)
        bubble.position = CGPoint(x: Self.stageSize.width / 2, y: Self.spriteSize.height + height / 2 + 12)
        bubbleText.frame = CGRect(x: 12, y: 4, width: width - 24, height: height - 8)
        bubbleText.truncationMode = .end
        CATransaction.commit()

        let fade = CAKeyframeAnimation(keyPath: "opacity")
        fade.values = [0, 1, 1, 0]
        fade.keyTimes = [0, 0.07, 0.9, 1]
        fade.duration = seconds
        let pop = CASpringAnimation(keyPath: "transform.scale")
        pop.fromValue = 0.6
        pop.toValue = 1
        pop.damping = 11
        pop.initialVelocity = 6
        pop.duration = pop.settlingDuration
        bubble.add(fade, forKey: "fade")
        bubble.add(pop, forKey: "pop")
    }

    func blushFor(_ seconds: TimeInterval) {
        let glow = CAKeyframeAnimation(keyPath: "opacity")
        glow.values = [0, 1, 1, 0]
        glow.keyTimes = [0, 0.1, 0.8, 1]
        glow.duration = seconds
        blush.add(glow, forKey: "blush")
    }

    func setSleeping(_ sleeping: Bool) {
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.6)
        sleepZs.opacity = sleeping ? 1 : 0
        CATransaction.commit()
        breathe(slow: sleeping)
    }

    /// A soft squash and stretch, slower while asleep.
    func breathe(slow: Bool) {
        let breath = CABasicAnimation(keyPath: "transform.scale.y")
        breath.fromValue = 1
        breath.toValue = slow ? 0.93 : 0.97
        breath.duration = slow ? 1.6 : 1.2
        breath.autoreverses = true
        breath.repeatCount = .infinity
        breath.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        breath.isRemovedOnCompletion = false
        body.add(breath, forKey: "breathe")
    }

    /// Squash on landing after a drag.
    func land() {
        let squash = CAKeyframeAnimation(keyPath: "transform.scale.y")
        squash.values = [1, 0.78, 1.08, 1]
        squash.keyTimes = [0, 0.3, 0.65, 1]
        squash.duration = 0.4
        body.add(squash, forKey: "land")
        sprite.hop()
    }

    /// Dangles a little while carried.
    func dangle(_ carried: Bool) {
        if carried {
            let swing = CABasicAnimation(keyPath: "transform.rotation.z")
            swing.fromValue = -0.08
            swing.toValue = 0.08
            swing.duration = 0.35
            swing.autoreverses = true
            swing.repeatCount = .infinity
            swing.isRemovedOnCompletion = false
            body.add(swing, forKey: "dangle")
        } else {
            body.removeAnimation(forKey: "dangle")
        }
    }
}

/// A Claude mascot that sits where you put it, naps when left alone and talks when clicked.
@MainActor
final class DesktopPet {
    private let model: NotchModel
    private let openPanel: () -> Void
    private var panel: PetPanel?
    private var view: PetView?
    private var monitors: [Any] = []
    private var sleepTask: Task<Void, Never>?
    private var isAsleep = false
    private var isCarried = false
    private var celebrationsSeen = 0
    private var lastStatus: SessionStatus??

    static let enabledKey = "desktopPetEnabled"
    static let positionKey = "desktopPetOrigin"

    static var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    init(model: NotchModel, openPanel: @escaping () -> Void) {
        self.model = model
        self.openPanel = openPanel
    }

    var isRunning: Bool { panel != nil }

    func start() {
        guard panel == nil else { return }
        let panel = PetPanel(contentRect: NSRect(origin: .zero, size: PetView.stageSize),
                             styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true

        let view = PetView(frame: NSRect(origin: .zero, size: PetView.stageSize))
        view.onClick = { [weak self] count in self?.clicked(count) }
        view.onRightClick = { [weak self] event in self?.showMenu(event) }
        view.onDragChanged = { [weak self] carried in self?.carried(carried) }
        view.onDragEnded = { [weak self] origin in self?.dropped(at: origin) }
        panel.contentView = view
        panel.setFrameOrigin(savedOrigin() ?? defaultOrigin())
        self.panel = panel
        self.view = view
        panel.orderFrontRegardless()

        let handler: (NSEvent) -> Void = { [weak self] _ in
            MainActor.assumeIsolated { self?.trackPointer() }
        }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved], handler: handler) { monitors.append(global) }
        if let local = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved], handler: { handler($0); return $0 }) { monitors.append(local) }

        celebrationsSeen = model.claudeCelebration
        wake(greeting: nil)
        observeClaude()
    }

    func stop() {
        sleepTask?.cancel()
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
        panel?.orderOut(nil)
        panel = nil
        view = nil
    }

    // MARK: - Position

    private func defaultOrigin() -> NSPoint {
        let visible = (NotchGeometry.builtInScreen() ?? NSScreen.main)?.visibleFrame ?? .zero
        return NSPoint(x: visible.maxX - PetView.stageSize.width - 24, y: visible.minY + 8)
    }

    private func savedOrigin() -> NSPoint? {
        guard let values = UserDefaults.standard.array(forKey: Self.positionKey) as? [Double], values.count == 2 else { return nil }
        let origin = NSPoint(x: values[0], y: values[1])
        // Only if it is still on a connected screen.
        let center = NSPoint(x: origin.x + PetView.stageSize.width / 2, y: origin.y + 20)
        return NSScreen.screens.contains { $0.frame.contains(center) } ? origin : nil
    }

    // MARK: - Moods

    private func observeClaude() {
        withObservationTracking {
            _ = model.claude.headlineStatus
            _ = model.claudeCelebration
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self, self.panel != nil else { return }
                self.claudeChanged()
                self.observeClaude()
            }
        }
    }

    private func claudeChanged() {
        guard let view else { return }
        if model.claudeCelebration != celebrationsSeen {
            celebrationsSeen = model.claudeCelebration
            wake(greeting: nil)
            view.sprite.hop(twice: true)
            view.blushFor(2.5)
            view.say("\(model.lastFinished ?? "Claude") bitti ✓")
        }
        let status = model.claude.headlineStatus
        if lastStatus != .some(status), status == .needsApproval {
            wake(greeting: nil)
            view.sprite.hop()
            view.say("İzin lazım! 🙋", for: 3.5)
        }
        lastStatus = .some(status)
        if !isAsleep { restingAnimation() }
    }

    /// What the sprite does while awake, depending on Claude.
    private func restingAnimation() {
        guard let view, !isCarried else { return }
        view.sprite.removeAnimation(forKey: "frames")
        switch model.claude.headlineStatus {
        case .needsApproval:
            view.sprite.show(.armsUp)
            view.sprite.loop([.armsUp, .normal], duration: 0.6)
        case .done:
            view.sprite.blink(open: .normal, every: 3.6)
        default:
            view.sprite.blink(open: .normal, every: 3.2)
        }
    }

    private func wake(greeting: String?) {
        guard let view else { return }
        if isAsleep {
            isAsleep = false
            view.setSleeping(false)
            view.sprite.play([(.armsUp, 0.7), (.blink, 0.2), (.normal, 0.1)])
        } else {
            view.breathe(slow: false)
        }
        if let greeting { view.say(greeting) }
        restingAnimation()
        scheduleSleep()
    }

    private func scheduleSleep() {
        sleepTask?.cancel()
        sleepTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(PetBrain.sleepAfter))
            guard !Task.isCancelled, let self else { return }
            // Stay up while Claude needs an answer.
            if self.model.claude.headlineStatus == .needsApproval {
                self.scheduleSleep()
                return
            }
            self.fallAsleep()
        }
    }

    private func fallAsleep() {
        guard let view, !isAsleep, !isCarried else { return }
        isAsleep = true
        view.sprite.removeAnimation(forKey: "frames")
        view.sprite.show(.asleep)
        view.setSleeping(true)
    }

    // MARK: - Touch

    private func clicked(_ count: Int) {
        guard let view else { return }
        if count >= 2 {
            openPanel()
            return
        }
        if isAsleep {
            wake(greeting: "Günaydın! ☀️")
            return
        }
        view.sprite.hop()
        view.blushFor(2)
        view.say(lines: PetBrain.info(store: model.claude, battery: model.battery), for: 4.5)
        scheduleSleep()
    }

    private func showMenu(_ event: NSEvent) {
        guard let view else { return }
        let menu = NSMenu()
        menu.addItem(ClosureMenuItem("Bilgileri göster", symbol: "info.circle") { [weak self] in self?.clicked(1) })
        menu.addItem(ClosureMenuItem("Paneli aç", symbol: "rectangle.topthird.inset.filled") { [weak self] in self?.openPanel() })
        if isAsleep {
            menu.addItem(ClosureMenuItem("Uyandır", symbol: "sun.max") { [weak self] in self?.wake(greeting: "Günaydın! ☀️") })
        } else {
            menu.addItem(ClosureMenuItem("Uyut", symbol: "moon.zzz") { [weak self] in self?.fallAsleep() })
        }
        menu.addItem(ClosureMenuItem("Konumu sıfırla", symbol: "arrow.uturn.backward") { [weak self] in self?.resetPosition() })
        menu.addItem(.separator())
        let hide = ClosureMenuItem("Maskotu gizle", symbol: "eye.slash") { [weak self] in
            self?.stop()
            DesktopPet.isEnabled = false
        }
        hide.toolTip = "Menü çubuğundaki NotchHub menüsünden tekrar açabilirsin."
        menu.addItem(hide)
        NSMenu.popUpContextMenu(menu, with: event, for: view)
    }

    private func resetPosition() {
        UserDefaults.standard.removeObject(forKey: Self.positionKey)
        panel?.setFrameOrigin(defaultOrigin())
        view?.land()
    }

    private func carried(_ carried: Bool) {
        guard let view else { return }
        isCarried = carried
        if carried {
            if isAsleep { isAsleep = false; view.setSleeping(false) }
            sleepTask?.cancel()
            view.sprite.removeAnimation(forKey: "frames")
            view.sprite.loop([.armsUp, .wave], duration: 0.3)
            view.dangle(true)
        } else {
            view.dangle(false)
        }
    }

    private func dropped(at origin: NSPoint) {
        UserDefaults.standard.set([origin.x, origin.y], forKey: Self.positionKey)
        view?.land()
        wake(greeting: nil)
    }

    // MARK: - Pointer

    /// Accept the mouse only right over the mascot, so it never blocks anything else.
    private func trackPointer() {
        guard let panel, let view, !isCarried else { return }
        let point = NSEvent.mouseLocation
        let local = NSPoint(x: point.x - panel.frame.minX, y: point.y - panel.frame.minY)
        let inside = view.mascotFrame.insetBy(dx: -6, dy: -6).contains(local)
        if panel.ignoresMouseEvents == inside { panel.ignoresMouseEvents = !inside }
    }
}

/// A menu item that runs a closure.
private final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, symbol: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
    }

    required init(coder: NSCoder) { fatalError() }

    @objc private func fire() { handler() }
}
