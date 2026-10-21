import AppKit
import SwiftUI

/// Claude Code's pixel mascot, decoded from the half-block logo it prints in the terminal:
///
///      ▐▛███▜▌
///     ▝▜█████▛▘
///       ▘▘ ▝▝
enum Clawd {
    enum Pose: CaseIterable { case normal, blink, armsUp, wave, asleep }

    static let width = 18
    static let height = 5
    /// Terminal cells are about twice as tall as wide, so each quadrant "pixel" is too.
    static let pixelAspect: CGFloat = 2

    static func rows(_ pose: Pose) -> [String] {
        let body = ".################."
        let middle = "...############..."
        let legs = "....#.#....#.#...."
        return switch pose {
        case .normal: [middle, "...##.######.##...", body, middle, legs]
        case .blink: [middle, middle, body, middle, legs]
        case .armsUp: [".#.############.#.", ".#.##.######.##.#.", middle, middle, legs]
        case .wave: [".#.############...", ".#.##.######.##...", "...##############.", middle, legs]
        // Closed eyes: "_" is body with a thin dark line through it, right where each eye is.
        case .asleep: [middle, "...##_######_##...", body, middle, legs]
        }
    }

    /// Image rows per mascot row: each mascot pixel is twice as tall as wide, and a closed eye
    /// is a line a quarter of a pixel thick.
    static let subrows = 4

    /// The layer scales the image up without smoothing.
    static func image(_ pose: Pose, color: NSColor) -> CGImage? {
        let imageHeight = height * subrows
        guard let context = CGContext(
            data: nil, width: width, height: imageHeight, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.setFillColor(color.cgColor)
        for (y, row) in rows(pose).enumerated() {
            // CGContext's origin is bottom-left; rows are listed top to bottom.
            let bottom = imageHeight - subrows * (y + 1)
            for (x, cell) in row.enumerated() {
                switch cell {
                case "#":
                    context.fill(CGRect(x: x, y: bottom, width: 1, height: subrows))
                case "_":
                    // Leave the second subrow from the bottom open: a thin line, slightly low.
                    context.fill(CGRect(x: x, y: bottom, width: 1, height: 1))
                    context.fill(CGRect(x: x, y: bottom + 2, width: 1, height: subrows - 2))
                default:
                    break
                }
            }
        }
        return context.makeImage()
    }

    static let orange = NSColor(srgbRed: 0.85, green: 0.47, blue: 0.34, alpha: 1)
}

/// The mascot as a layer. Every motion is a Core Animation animation, so it runs in the
/// render server and costs no CPU in the app.
final class ClawdSprite: CALayer {
    private var frames: [Clawd.Pose: CGImage] = [:]
    private(set) var color: NSColor = Clawd.orange

    override init() {
        super.init()
        magnificationFilter = .nearest
        contentsGravity = .resize
        setColor(Clawd.orange)
    }

    override init(layer: Any) { super.init(layer: layer) }
    required init?(coder: NSCoder) { fatalError() }

    /// Height of one mascot pixel in points.
    var pixelHeight: CGFloat { bounds.height / CGFloat(Clawd.height) }

    func setColor(_ color: NSColor) {
        guard frames.isEmpty || color != self.color else { return }
        self.color = color
        frames = Dictionary(uniqueKeysWithValues: Clawd.Pose.allCases.compactMap { pose in
            Clawd.image(pose, color: color).map { (pose, $0) }
        })
    }

    func show(_ pose: Clawd.Pose) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        contents = frames[pose]
        CATransaction.commit()
    }

    func loop(_ poses: [Clawd.Pose], duration: CFTimeInterval) {
        let animation = CAKeyframeAnimation(keyPath: "contents")
        animation.values = poses.compactMap { frames[$0] }
        animation.calculationMode = .discrete
        animation.duration = duration
        animation.repeatCount = .infinity
        animation.isRemovedOnCompletion = false
        add(animation, forKey: "frames")
    }

    func blink(open: Clawd.Pose, every period: CFTimeInterval) {
        show(open)
        let animation = CAKeyframeAnimation(keyPath: "contents")
        animation.values = [frames[open], frames[.blink], frames[open]].compactMap { $0 }
        animation.keyTimes = [0, 0.94, 0.97]
        animation.calculationMode = .discrete
        animation.duration = period
        animation.repeatCount = .infinity
        animation.isRemovedOnCompletion = false
        add(animation, forKey: "frames")
    }

    func stopMoving() {
        removeAnimation(forKey: "frames")
    }

    /// Plays poses once on top of the running loop, which takes over again afterwards.
    func play(_ sequence: [(Clawd.Pose, CFTimeInterval)]) {
        let total = sequence.reduce(0) { $0 + $1.1 }
        guard total > 0 else { return }
        var elapsed: CFTimeInterval = 0
        var times: [NSNumber] = []
        for step in sequence {
            times.append(NSNumber(value: elapsed / total))
            elapsed += step.1
        }
        let animation = CAKeyframeAnimation(keyPath: "contents")
        animation.values = sequence.compactMap { frames[$0.0] }
        animation.keyTimes = times
        animation.calculationMode = .discrete
        animation.duration = total
        add(animation, forKey: "once")
    }

    /// A little hop with a bounce on landing.
    func hop(twice: Bool = false) {
        let up = pixelHeight * 1.6
        let animation = CAKeyframeAnimation(keyPath: "transform.translation.y")
        if twice {
            animation.values = [0, up, 0, up * 0.35, 0, up, 0]
            animation.keyTimes = [0, 0.18, 0.36, 0.46, 0.56, 0.78, 1]
            animation.duration = 1.1
        } else {
            animation.values = [0, up, 0, up * 0.3, 0]
            animation.keyTimes = [0, 0.35, 0.7, 0.85, 1]
            animation.duration = 0.55
        }
        animation.timingFunctions = Array(repeating: CAMediaTimingFunction(name: .easeInEaseOut), count: animation.values!.count - 1)
        add(animation, forKey: "hop")
    }

    func face(left: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        transform = left ? CATransform3DMakeScale(-1, 1, 1) : CATransform3DIdentity
        CATransaction.commit()
    }
}

/// A still mascot that blinks now and then (the empty panel).
struct ClawdView: NSViewRepresentable {
    var pixel: CGFloat = 1.6

    func makeNSView(context: Context) -> ClawdLayerView { ClawdLayerView() }

    func updateNSView(_ view: ClawdLayerView, context: Context) {}

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: ClawdLayerView, context: Context) -> CGSize? {
        CGSize(width: CGFloat(Clawd.width) * pixel, height: CGFloat(Clawd.height) * pixel * Clawd.pixelAspect)
    }
}

final class ClawdLayerView: NSView {
    private let sprite = ClawdSprite()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.addSublayer(sprite)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        sprite.frame = bounds
        CATransaction.commit()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Animations are dropped when the layer leaves a window; start over.
        if window != nil { sprite.blink(open: .normal, every: 3.2) }
    }
}
