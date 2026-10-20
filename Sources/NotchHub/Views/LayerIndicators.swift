import AppKit
import SwiftUI

// Repeating indicators run as Core Animation animations in the render server,
// so a spinning notch costs no CPU in the app (a SwiftUI repeatForever redraws every frame).

struct LayerSpinner: NSViewRepresentable {
    var color: NSColor
    var diameter: CGFloat = 10
    var lineWidth: CGFloat = 1.8

    func makeNSView(context: Context) -> SpinnerView { SpinnerView() }

    func updateNSView(_ view: SpinnerView, context: Context) {
        view.configure(color: color, diameter: diameter, lineWidth: lineWidth)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: SpinnerView, context: Context) -> CGSize? {
        CGSize(width: diameter, height: diameter)
    }
}

final class SpinnerView: NSView {
    private let arc = CAShapeLayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        arc.fillColor = nil
        arc.lineCap = .round
        arc.strokeStart = 0.1
        arc.strokeEnd = 0.8
        layer?.addSublayer(arc)
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(color: NSColor, diameter: CGFloat, lineWidth: CGFloat) {
        arc.strokeColor = color.cgColor
        arc.lineWidth = lineWidth
        needsLayout = true
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        arc.frame = bounds
        let inset = arc.lineWidth / 2
        arc.path = CGPath(ellipseIn: bounds.insetBy(dx: inset, dy: inset), transform: nil)
        CATransaction.commit()
        startIfNeeded()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        startIfNeeded()
    }

    private func startIfNeeded() {
        guard window != nil, arc.animation(forKey: "spin") == nil else { return }
        let spin = CABasicAnimation(keyPath: "transform.rotation.z")
        spin.fromValue = 0
        spin.toValue = -2 * Double.pi
        spin.duration = 0.9
        spin.repeatCount = .infinity
        spin.isRemovedOnCompletion = false
        arc.add(spin, forKey: "spin")
    }
}

struct LayerPulseDot: NSViewRepresentable {
    var color: NSColor
    var diameter: CGFloat = 8

    func makeNSView(context: Context) -> PulseDotView { PulseDotView() }

    func updateNSView(_ view: PulseDotView, context: Context) {
        view.color = color
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: PulseDotView, context: Context) -> CGSize? {
        CGSize(width: diameter, height: diameter)
    }
}

final class PulseDotView: NSView {
    private let dot = CALayer()

    var color: NSColor = .orange {
        didSet {
            dot.backgroundColor = color.cgColor
            dot.shadowColor = color.cgColor
        }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = false
        dot.shadowOpacity = 0.9
        dot.shadowRadius = 4
        dot.shadowOffset = .zero
        layer?.addSublayer(dot)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        dot.frame = bounds
        dot.cornerRadius = bounds.width / 2
        CATransaction.commit()
        startIfNeeded()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        startIfNeeded()
    }

    private func startIfNeeded() {
        guard window != nil, dot.animation(forKey: "pulse") == nil else { return }
        let pulse = CABasicAnimation(keyPath: "opacity")
        pulse.fromValue = 1
        pulse.toValue = 0.4
        pulse.duration = 0.75
        pulse.autoreverses = true
        pulse.repeatCount = .infinity
        pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        pulse.isRemovedOnCompletion = false
        dot.add(pulse, forKey: "pulse")
    }
}
