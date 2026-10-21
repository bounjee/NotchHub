import AppKit
import SwiftUI

/// Claude Code's pixel mascot, decoded from the half-block logo it prints in the terminal:
///
///      ▐▛███▜▌
///     ▝▜█████▛▘
///       ▘▘ ▝▝
enum Clawd {
    enum Pose: CaseIterable { case normal, blink, step, armsUp, happy }

    static let width = 18
    static let height = 5
    /// Terminal cells are about twice as tall as wide, so each quadrant "pixel" is too.
    static let pixelAspect: CGFloat = 2

    static func rows(_ pose: Pose) -> [String] {
        switch pose {
        case .normal:
            ["...############...",
             "...##.######.##...",
             ".################.",
             "...############...",
             "....#.#....#.#...."]
        case .blink:
            ["...############...",
             "...############...",
             ".################.",
             "...############...",
             "....#.#....#.#...."]
        case .step:
            ["...############...",
             "...##.######.##...",
             ".################.",
             "...############...",
             ".....#.#..#.#....."]
        case .armsUp:
            [".#.############.#.",
             ".#.##.######.##.#.",
             "...############...",
             "...############...",
             "....#.#....#.#...."]
        case .happy:
            ["...##.######.##...",
             "...############...",
             ".################.",
             "...############...",
             "....#.#....#.#...."]
        }
    }

    /// One image pixel per mascot pixel; the layer scales it up without smoothing.
    static func image(_ pose: Pose, color: NSColor) -> CGImage? {
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.setFillColor(color.cgColor)
        for (y, row) in rows(pose).enumerated() {
            for (x, cell) in row.enumerated() where cell == "#" {
                // CGContext's origin is bottom-left.
                context.fill(CGRect(x: x, y: height - 1 - y, width: 1, height: 1))
            }
        }
        return context.makeImage()
    }

    static let orange = NSColor(srgbRed: 0.85, green: 0.47, blue: 0.34, alpha: 1)
}

/// The mascot, animated by its session state. All motion runs as Core Animation
/// keyframes, so a walking mascot costs no CPU in the app.
struct ClawdView: NSViewRepresentable {
    var status: SessionStatus?
    /// Bump to make it jump for joy once.
    var celebration = 0
    var pixel: CGFloat = 1.6

    func makeNSView(context: Context) -> ClawdLayerView { ClawdLayerView() }

    func updateNSView(_ view: ClawdLayerView, context: Context) {
        view.update(status: status, celebration: celebration)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: ClawdLayerView, context: Context) -> CGSize? {
        // Room above for jumps.
        CGSize(width: CGFloat(Clawd.width) * pixel, height: (CGFloat(Clawd.height) + 2) * pixel * Clawd.pixelAspect)
    }
}

final class ClawdLayerView: NSView {
    private let sprite = CALayer()
    private var status: SessionStatus??
    private var celebration = 0
    private var frames: [Clawd.Pose: CGImage] = [:]
    private var color: NSColor = Clawd.orange

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = false
        sprite.magnificationFilter = .nearest
        sprite.contentsGravity = .resize
        layer?.addSublayer(sprite)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let spriteHeight = bounds.width * CGFloat(Clawd.height) * Clawd.pixelAspect / CGFloat(Clawd.width)
        sprite.frame = CGRect(x: 0, y: 0, width: bounds.width, height: spriteHeight)
        CATransaction.commit()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Animations are dropped when the layer leaves a window; start over.
        if window != nil, let status { applyAnimations(for: status) }
    }

    func update(status: SessionStatus?, celebration: Int) {
        let newColor = status == .error ? NSColor.systemRed : Clawd.orange
        if frames.isEmpty || newColor != color {
            color = newColor
            frames = Dictionary(uniqueKeysWithValues: Clawd.Pose.allCases.compactMap { pose in
                Clawd.image(pose, color: newColor).map { (pose, $0) }
            })
        }
        if self.status != .some(status) {
            self.status = .some(status)
            applyAnimations(for: status)
        }
        if celebration != self.celebration {
            self.celebration = celebration
            jump()
        }
    }

    private func applyAnimations(for status: SessionStatus?) {
        sprite.removeAllAnimations()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        switch status {
        case .working:
            sprite.contents = frames[.normal]
            cycle([.normal, .step], duration: 0.36)
            bob(height: 1, duration: 0.36)
        case .needsApproval:
            sprite.contents = frames[.armsUp]
            cycle([.armsUp, .normal], duration: 0.7)
        case .done:
            sprite.contents = frames[.happy]
            blink(open: .happy, every: 4)
        default:
            sprite.contents = frames[.normal]
            blink(open: .normal, every: 3.2)
        }
        CATransaction.commit()
    }

    private func cycle(_ poses: [Clawd.Pose], duration: CFTimeInterval) {
        let animation = CAKeyframeAnimation(keyPath: "contents")
        animation.values = poses.compactMap { frames[$0] }
        animation.calculationMode = .discrete
        animation.duration = duration
        animation.repeatCount = .infinity
        animation.isRemovedOnCompletion = false
        sprite.add(animation, forKey: "frames")
    }

    private func blink(open: Clawd.Pose, every period: CFTimeInterval) {
        let animation = CAKeyframeAnimation(keyPath: "contents")
        animation.values = [frames[open], frames[.blink], frames[open]].compactMap { $0 }
        animation.keyTimes = [0, 0.94, 0.97]
        animation.calculationMode = .discrete
        animation.duration = period
        animation.repeatCount = .infinity
        animation.isRemovedOnCompletion = false
        sprite.add(animation, forKey: "frames")
    }

    private func bob(height: CGFloat, duration: CFTimeInterval) {
        let pixel = bounds.width / CGFloat(Clawd.width) * Clawd.pixelAspect
        let animation = CAKeyframeAnimation(keyPath: "transform.translation.y")
        animation.values = [0, height * pixel, 0]
        animation.calculationMode = .discrete
        animation.duration = duration
        animation.repeatCount = .infinity
        animation.isRemovedOnCompletion = false
        sprite.add(animation, forKey: "bob")
    }

    /// A little hop with a bounce on landing.
    private func jump() {
        let pixel = max(1, bounds.width / CGFloat(Clawd.width))
        let animation = CAKeyframeAnimation(keyPath: "transform.translation.y")
        animation.values = [0, 3 * pixel, 0, 1 * pixel, 0, 3 * pixel, 0]
        animation.keyTimes = [0, 0.18, 0.36, 0.46, 0.56, 0.78, 1]
        animation.timingFunctions = Array(repeating: CAMediaTimingFunction(name: .easeInEaseOut), count: 6)
        animation.duration = 1.1
        sprite.add(animation, forKey: "jump")
    }
}
