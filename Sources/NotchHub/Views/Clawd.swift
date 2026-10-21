import AppKit
import SwiftUI

/// Claude Code's pixel mascot, decoded from the half-block logo it prints in the terminal:
///
///      ▐▛███▜▌
///     ▝▜█████▛▘
///       ▘▘ ▝▝
enum Clawd {
    enum Pose: CaseIterable { case normal, blink, step, armsUp, happy, lookLeft, lookRight, wave }

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
        case .step: [middle, "...##.######.##...", body, middle, ".....#.#..#.#....."]
        case .armsUp: [".#.############.#.", ".#.##.######.##.#.", middle, middle, legs]
        case .happy: ["...##.######.##...", middle, body, middle, legs]
        case .lookLeft: [middle, "...#.######.###...", body, middle, legs]
        case .lookRight: [middle, "...###.######.#...", body, middle, legs]
        case .wave: [".#.############...", ".#.##.######.##...", "...##############.", middle, legs]
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

    /// A short routine a resting mascot plays now and then.
    enum Fidget: CaseIterable { case lookAround, wave, hop, stretch }
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

    func bob(duration: CFTimeInterval) {
        let animation = CAKeyframeAnimation(keyPath: "transform.translation.y")
        animation.values = [0, pixelHeight * 0.5, 0]
        animation.calculationMode = .discrete
        animation.duration = duration
        animation.repeatCount = .infinity
        animation.isRemovedOnCompletion = false
        add(animation, forKey: "bob")
    }

    func stopMoving() {
        removeAnimation(forKey: "frames")
        removeAnimation(forKey: "bob")
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

    func fidget(_ fidget: Clawd.Fidget, resting: Clawd.Pose) {
        switch fidget {
        case .lookAround:
            play([(.lookLeft, 0.7), (resting, 0.25), (.lookRight, 0.7), (resting, 0.1)])
        case .wave:
            play([(.wave, 0.22), (.normal, 0.22), (.wave, 0.22), (.normal, 0.22), (.wave, 0.22), (resting, 0.1)])
        case .hop:
            hop()
        case .stretch:
            play([(.armsUp, 0.9), (.blink, 0.25), (resting, 0.1)])
        }
    }
}

/// The mascot, animated by its session state.
struct ClawdView: NSViewRepresentable {
    var status: SessionStatus?
    /// Bump to make it jump for joy once.
    var celebration = 0
    var pixel: CGFloat = 1.6
    /// Plays a small random routine now and then while resting.
    var fidgets = false

    func makeNSView(context: Context) -> ClawdLayerView { ClawdLayerView() }

    func updateNSView(_ view: ClawdLayerView, context: Context) {
        view.fidgets = fidgets
        view.update(status: status, celebration: celebration)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: ClawdLayerView, context: Context) -> CGSize? {
        // Room above for jumps.
        CGSize(width: CGFloat(Clawd.width) * pixel, height: (CGFloat(Clawd.height) + 2) * pixel * Clawd.pixelAspect)
    }
}

final class ClawdLayerView: NSView {
    private let sprite = ClawdSprite()
    private var status: SessionStatus??
    private var celebration = 0
    private var fidgetTask: Task<Void, Never>?
    var fidgets = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = false
        layer?.addSublayer(sprite)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let spriteHeight = bounds.width * CGFloat(Clawd.height) * Clawd.pixelAspect / CGFloat(Clawd.width)
        let firstLayout = sprite.bounds.isEmpty
        sprite.frame = CGRect(x: 0, y: 0, width: bounds.width, height: spriteHeight)
        CATransaction.commit()
        // Motion is sized by the sprite, so set it up again once it has a size.
        if firstLayout, !bounds.isEmpty, let status { applyAnimations(for: status) }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Animations are dropped when the layer leaves a window; start over.
        if window != nil, let status { applyAnimations(for: status) }
        updateFidgeting()
    }

    func update(status: SessionStatus?, celebration: Int) {
        sprite.setColor(status == .error ? NSColor.systemRed : Clawd.orange)
        if self.status != .some(status) {
            self.status = .some(status)
            applyAnimations(for: status)
            updateFidgeting()
        }
        if celebration != self.celebration {
            self.celebration = celebration
            sprite.hop(twice: true)
        }
    }

    private var restingPose: Clawd.Pose { status == .some(.done) ? .happy : .normal }

    private var isResting: Bool {
        switch status {
        case .some(.working), .some(.needsApproval): false
        default: true
        }
    }

    private func applyAnimations(for status: SessionStatus?) {
        sprite.removeAllAnimations()
        switch status {
        case .working:
            sprite.show(.normal)
            sprite.loop([.normal, .step], duration: 0.36)
            sprite.bob(duration: 0.36)
        case .needsApproval:
            sprite.show(.armsUp)
            sprite.loop([.armsUp, .normal], duration: 0.7)
        case .done:
            sprite.blink(open: .happy, every: 4)
        default:
            sprite.blink(open: .normal, every: 3.2)
        }
    }

    /// A resting mascot looks around, waves, hops or stretches every few seconds.
    private func updateFidgeting() {
        fidgetTask?.cancel()
        fidgetTask = nil
        guard fidgets, window != nil, isResting else { return }
        fidgetTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Double.random(in: 6...12)))
                guard !Task.isCancelled, let self, self.isResting else { return }
                self.sprite.fidget(Clawd.Fidget.allCases.randomElement()!, resting: self.restingPose)
            }
        }
    }
}
