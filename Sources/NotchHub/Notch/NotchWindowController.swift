import AppKit
import os
import SwiftUI

let log = Logger(subsystem: "agency.ehli.notchhub", category: "notch")

final class NotchPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// Keep the panel over the menu bar instead of letting AppKit push it below.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

/// Lets clicks reach the window below anywhere outside the visible notch.
final class PassthroughHostingView<Content: View>: NSHostingView<Content> {
    /// Interactive area in window coordinates.
    var interactiveRect: () -> NSRect = { .zero }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // `point` is in the superview's coordinates; compare in window space (this view is flipped).
        let inWindow = superview?.convert(point, to: nil) ?? point
        return interactiveRect().contains(inWindow) ? super.hitTest(point) : nil
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Owns the panel over the built-in display's notch and decides when it opens and closes.
@MainActor
final class NotchWindowController {
    private let model: NotchModel
    private let panel: NotchPanel
    private let hostingView: PassthroughHostingView<NotchRootView>
    private var monitors: [Any] = []
    private var openTask: Task<Void, Never>?
    private var closeTask: Task<Void, Never>?
    private var exitTimer: Timer?
    private var dragChangeCount = NSPasteboard(name: .drag).changeCount
    private var dragEndTask: Task<Void, Never>?
    private var lastHaptic = Date.distantPast
    private var screen: NSScreen?

    /// Long enough that passing over the notch on the way to the menu bar does not open it;
    /// the notch grows a little meanwhile, so the wait does not feel unresponsive.
    static let openDelay: Duration = .milliseconds(700)
    static let closeDelay: Duration = .milliseconds(300)
    /// Room around the open panel for the shadow.
    static let shadowPadding: CGFloat = 24

    init(model: NotchModel) {
        self.model = model
        panel = NotchPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isMovable = false
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.acceptsMouseMovedEvents = true
        // Buttons work without taking keyboard focus from the frontmost app.
        panel.becomesKeyOnlyIfNeeded = true

        hostingView = PassthroughHostingView(rootView: NotchRootView(model: model))
        hostingView.sizingOptions = []
        panel.contentView = hostingView
        hostingView.interactiveRect = { [weak self] in self?.interactiveRectInView() ?? .zero }
    }

    func start() {
        layout()
        panel.orderFrontRegardless()

        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.layout() }
        }

        let handler: (NSEvent) -> Void = { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
        }
        let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .leftMouseDown, .leftMouseUp]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: handler) { monitors.append(global) }
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { handler($0); return $0 }) { monitors.append(local) }

        observeModel()
    }

    /// Re-runs whenever anything that changes the visible notch size changes.
    private func observeModel() {
        let previous = model.presentation
        withObservationTracking {
            _ = model.presentation
            _ = model.openSize
            _ = model.isHoverPrimed
            _ = model.peek
            _ = model.drag
            _ = model.claude.headlineStatus
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                if self.model.presentation != previous { self.presentationChanged() }
                self.updateMouseHandling()
                self.observeModel()
            }
        }
    }

    // MARK: - Geometry

    /// Places a fixed-size transparent panel at the top center of the built-in display.
    func layout() {
        guard let screen = NotchGeometry.builtInScreen() else {
            // Clamshell mode or no notch: hide and forget the old geometry.
            self.screen = nil
            openTask?.cancel()
            openTask = nil
            closeTask?.cancel()
            closeTask = nil
            exitTimer?.invalidate()
            exitTimer = nil
            model.drag = nil
            model.isHoverPrimed = false
            model.close()
            panel.orderOut(nil)
            return
        }
        self.screen = screen
        model.notchSize = NotchGeometry.notchSize(of: screen)
        let width = NotchModel.openWidth + Self.shadowPadding * 2 + 40
        let height = NotchModel.maxOpenHeight + Self.shadowPadding
        let frame = NSRect(
            x: screen.frame.midX - width / 2,
            y: screen.frame.maxY - height,
            width: width,
            height: height
        )
        panel.setFrame(frame, display: true)
        panel.orderFrontRegardless()
        updateMouseHandling()
    }

    /// The area that currently reacts to the pointer, in screen coordinates.
    private func interactiveScreenRect() -> NSRect {
        guard let screen else { return .zero }
        if model.presentation == .open {
            let size = model.openSize
            return NSRect(x: screen.frame.midX - size.width / 2, y: screen.frame.maxY - size.height, width: size.width, height: size.height)
        }
        let wings = NotchRootView.wings(model)
        let height = model.presentation == .closed ? NotchRootView.closedHeight(model) : model.notchSize.height
        return NSRect(
            x: screen.frame.midX - model.notchSize.width / 2 - wings.left,
            y: screen.frame.maxY - height,
            width: model.notchSize.width + wings.left + wings.right,
            height: height
        )
    }

    private func interactiveRectInView() -> NSRect {
        panel.convertFromScreen(interactiveScreenRect())
    }

    /// The closed notch reacts a little beyond its edges so it is easy to hit.
    private func hoverRect() -> NSRect {
        let rect = interactiveScreenRect()
        return model.isOpen ? rect.insetBy(dx: -4, dy: -4) : rect.insetBy(dx: -8, dy: -6)
    }

    // MARK: - Pointer

    var isPointerInside: Bool { hoverRect().contains(NSEvent.mouseLocation) }

    private func handle(_ event: NSEvent) {
        let location = NSEvent.mouseLocation
        switch event.type {
        case .leftMouseDown:
            dragChangeCount = NSPasteboard(name: .drag).changeCount
            // A click on the closed notch opens it right away. The notch sits in the menu bar,
            // whose clicks never reach our window, so this comes from the event monitor.
            if !model.isOpen, screen != nil, hoverRect().contains(location) {
                openTask?.cancel()
                openTask = nil
                withAnimation(.notchOpen) { model.open() }
                haptic(force: true)
            }
        case .leftMouseDragged:
            trackDrag(at: location)
        case .leftMouseUp:
            endDrag()
        default:
            break
        }
        evaluateHover(at: location)
        updateMouseHandling()
    }

    private var notchRect: NSRect {
        guard let screen else { return .zero }
        return NSRect(
            x: screen.frame.midX - model.notchSize.width / 2, y: screen.frame.maxY - model.notchSize.height,
            width: model.notchSize.width, height: model.notchSize.height
        )
    }

    /// Opens drop zones when files or text are dragged near the notch, and leaves
    /// drop mode when the drag moves away. Only drags that put new content on the
    /// drag pasteboard count, so moving windows or selecting text never triggers it.
    private func trackDrag(at location: NSPoint) {
        let pasteboard = NSPasteboard(name: .drag)
        guard pasteboard.changeCount != dragChangeCount else { return }
        let types = pasteboard.types ?? []
        let kind: DragKind? = types.contains(.fileURL) ? .files
            : (types.contains(.string) || types.contains(.URL)) ? .text : nil
        guard let kind else { return }

        // Text needs a closer approach: tab bars at the top of browsers start text-like drags.
        let reach = kind == .files ? CGSize(width: 140, height: 90) : CGSize(width: 40, height: 30)
        if model.drag == nil {
            guard notchRect.insetBy(dx: -reach.width, dy: -reach.height).contains(location) else { return }
            dragEndTask?.cancel()
            closeTask?.cancel()
            closeTask = nil
            withAnimation(.notchOpen) {
                model.drag = kind
                model.open(tab: kind == .files ? .shelf : .clipboard)
            }
            haptic(force: true)
        } else if !hoverRect().insetBy(dx: -60, dy: -60).contains(location) {
            // Dragged away without dropping.
            withAnimation(.notchClose) {
                model.drag = nil
                model.close()
            }
        }
    }

    /// The drop handler runs around mouse-up, so keep the zones a moment longer.
    private func endDrag() {
        guard model.drag != nil, dragEndTask == nil else { return }
        dragEndTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled, let self else { return }
            self.dragEndTask = nil
            if self.model.drag != nil {
                withAnimation(.notchOpen) { self.model.drag = nil }
            }
            self.scheduleCloseIfOutside(NSEvent.mouseLocation)
        }
    }

    private func haptic(force: Bool = false) {
        guard force || (Date().timeIntervalSince(lastHaptic) > 0.5 && NSEvent.pressedMouseButtons == 0) else { return }
        lastHaptic = Date()
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
    }

    private func evaluateHover(at location: NSPoint) {
        guard screen != nil else { return }
        // A drag can end without us seeing its mouse-up (dropped onto another app).
        if model.drag != nil && NSEvent.pressedMouseButtons & 1 == 0 { endDrag() }
        let inside = hoverRect().contains(location)
        if inside {
            closeTask?.cancel()
            closeTask = nil
            if model.isPeeking && model.isOpen {
                model.adoptPeekAsHover()
            } else if !model.isOpen, openTask == nil {
                if !model.isHoverPrimed { model.isHoverPrimed = true }
                openTask = Task { [weak self] in
                    try? await Task.sleep(for: Self.openDelay)
                    guard !Task.isCancelled, let self else { return }
                    self.openTask = nil
                    if self.hoverRect().contains(NSEvent.mouseLocation) {
                        withAnimation(.notchOpen) { self.model.open() }
                        self.haptic()
                    } else {
                        self.model.isHoverPrimed = false
                    }
                }
            }
        } else {
            openTask?.cancel()
            openTask = nil
            if model.isHoverPrimed { model.isHoverPrimed = false }
            scheduleCloseIfOutside(location)
        }
    }

    private func scheduleCloseIfOutside(_ location: NSPoint) {
        guard model.isOpen, !model.isPeeking, model.drag == nil, closeTask == nil,
              !hoverRect().contains(location)
        else { return }
        closeTask = Task { [weak self] in
            try? await Task.sleep(for: Self.closeDelay)
            guard !Task.isCancelled, let self else { return }
            self.closeTask = nil
            // A peek (e.g. a permission request) may have opened during the delay.
            if !self.hoverRect().contains(NSEvent.mouseLocation), self.model.drag == nil, !self.model.isPeeking {
                withAnimation(.notchClose) { self.model.close() }
            }
        }
    }

    /// Accept mouse events only while the pointer is over the visible notch,
    /// so the rest of the transparent panel never blocks the apps below.
    private func updateMouseHandling() {
        let interactive = model.drag != nil || interactiveScreenRect().insetBy(dx: -2, dy: -2).contains(NSEvent.mouseLocation)
        if panel.ignoresMouseEvents == interactive { panel.ignoresMouseEvents = !interactive }
    }

    private func presentationChanged() {
        log.notice("presentation=\(String(describing: self.model.presentation), privacy: .public) tab=\(self.model.tab.rawValue, privacy: .public)")
        updateMouseHandling()
        // Mouse-moved events stop once the pointer is over our own window,
        // so poll lightly while open to notice the pointer leaving.
        exitTimer?.invalidate()
        exitTimer = nil
        if model.presentation == .open {
            let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    let location = NSEvent.mouseLocation
                    self.evaluateHover(at: location)
                    self.updateMouseHandling()
                }
            }
            timer.tolerance = 0.03
            // Common modes keep it running during drags and menu tracking.
            RunLoop.main.add(timer, forMode: .common)
            exitTimer = timer
        }
    }
}

