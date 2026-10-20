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
    private var isFileDragActive = false
    private var screen: NSScreen?

    static let openDelay: Duration = .milliseconds(150)
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

        withObservationTracking { _ = model.presentation } onChange: { [weak self] in
            Task { @MainActor in self?.presentationChanged() }
        }
    }

    // MARK: - Geometry

    /// Places a fixed-size transparent panel at the top center of the built-in display.
    func layout() {
        guard let screen = NotchGeometry.builtInScreen() else {
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
        let size: CGSize = switch model.presentation {
        case .open: model.openSize
        case .compact: CGSize(width: model.notchSize.width + 2 * NotchRootView.compactWingWidth, height: model.notchSize.height)
        case .closed: CGSize(width: model.notchSize.width + 2 * NotchRootView.closedWingWidth(model), height: model.notchSize.height)
        }
        return NSRect(x: screen.frame.midX - size.width / 2, y: screen.frame.maxY - size.height, width: size.width, height: size.height)
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
        case .leftMouseDragged:
            detectFileDrag(at: location)
        case .leftMouseUp:
            if isFileDragActive {
                isFileDragActive = false
                scheduleCloseIfOutside(location)
            }
        default:
            break
        }
        evaluateHover(at: location)
        updateMouseHandling()
    }

    private func detectFileDrag(at location: NSPoint) {
        let pasteboard = NSPasteboard(name: .drag)
        guard pasteboard.changeCount != dragChangeCount,
              pasteboard.types?.contains(.fileURL) == true,
              let screen
        else { return }
        let notch = NSRect(
            x: screen.frame.midX - model.notchSize.width / 2, y: screen.frame.maxY - model.notchSize.height,
            width: model.notchSize.width, height: model.notchSize.height
        )
        let isNear = notch.insetBy(dx: -140, dy: -90).contains(location)
        if isNear && !isFileDragActive {
            isFileDragActive = true
            closeTask?.cancel()
            withAnimation(.notchOpen) { model.open(tab: .shelf) }
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        }
    }

    private func evaluateHover(at location: NSPoint) {
        // A drag can end without us seeing its mouse-up (dropped onto another app).
        if isFileDragActive && NSEvent.pressedMouseButtons & 1 == 0 { isFileDragActive = false }
        let inside = hoverRect().contains(location)
        if inside {
            closeTask?.cancel()
            closeTask = nil
            if model.isPeeking && model.isOpen {
                model.adoptPeekAsHover()
            } else if !model.isOpen, openTask == nil {
                openTask = Task { [weak self] in
                    try? await Task.sleep(for: Self.openDelay)
                    guard !Task.isCancelled, let self else { return }
                    self.openTask = nil
                    if self.hoverRect().contains(NSEvent.mouseLocation) {
                        withAnimation(.notchOpen) { self.model.open() }
                    }
                }
            }
        } else {
            openTask?.cancel()
            openTask = nil
            scheduleCloseIfOutside(location)
        }
    }

    private func scheduleCloseIfOutside(_ location: NSPoint) {
        guard model.isOpen, !model.isPeeking, !isFileDragActive, closeTask == nil,
              !hoverRect().contains(location)
        else { return }
        closeTask = Task { [weak self] in
            try? await Task.sleep(for: Self.closeDelay)
            guard !Task.isCancelled, let self else { return }
            self.closeTask = nil
            if !self.hoverRect().contains(NSEvent.mouseLocation), !self.isFileDragActive {
                withAnimation(.notchClose) { self.model.close() }
            }
        }
    }

    /// Accept mouse events only while the pointer is over the visible notch,
    /// so the rest of the transparent panel never blocks the apps below.
    private func updateMouseHandling() {
        let interactive = isFileDragActive || interactiveScreenRect().insetBy(dx: -2, dy: -2).contains(NSEvent.mouseLocation)
        if panel.ignoresMouseEvents == interactive { panel.ignoresMouseEvents = !interactive }
    }

    private func presentationChanged() {
        withObservationTracking { _ = model.presentation } onChange: { [weak self] in
            Task { @MainActor in self?.presentationChanged() }
        }
        log.notice("presentation=\(String(describing: self.model.presentation), privacy: .public) tab=\(self.model.tab.rawValue, privacy: .public)")
        updateMouseHandling()
        // Mouse-moved events stop once the pointer is over our own window,
        // so poll lightly while open to notice the pointer leaving.
        exitTimer?.invalidate()
        exitTimer = nil
        if model.presentation == .open {
            exitTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    let location = NSEvent.mouseLocation
                    self.evaluateHover(at: location)
                    self.updateMouseHandling()
                }
            }
        }
    }
}

extension Animation {
    static let notchOpen = Animation.spring(response: 0.42, dampingFraction: 0.8)
    static let notchClose = Animation.spring(response: 0.45, dampingFraction: 1.0)
}
