import SwiftUI

/// The notch outline. While open, the part inside the menu bar stays as narrow as the
/// hardware notch (a "neck") and the panel widens only below the menu bar, so app menus
/// and status items are never covered.
struct NotchShape: Shape {
    var topRadius: CGFloat
    var bottomRadius: CGFloat
    /// How much narrower than the body the neck is, on each side.
    var neckInset: CGFloat = 0
    var neckHeight: CGFloat = 0

    var animatableData: AnimatablePair<AnimatablePair<CGFloat, CGFloat>, AnimatablePair<CGFloat, CGFloat>> {
        get { AnimatablePair(AnimatablePair(topRadius, bottomRadius), AnimatablePair(neckInset, neckHeight)) }
        set {
            topRadius = newValue.first.first
            bottomRadius = newValue.first.second
            neckInset = newValue.second.first
            neckHeight = newValue.second.second
        }
    }

    func path(in rect: CGRect) -> Path {
        let top = topRadius, bottom = bottomRadius
        let inset = max(0, min(neckInset, rect.width / 2 - top - bottom))
        let neckBottom = rect.minY + min(neckHeight, rect.height - bottom)
        // Concave curve where the neck meets the body, then a convex shoulder.
        let flare = min(10, inset / 2, neckHeight / 2)
        let shoulder = min(16, inset / 2)
        let hasNeck = inset > 0.5 && neckHeight > 0.5

        var path = Path()
        let left = rect.minX + inset
        path.move(to: CGPoint(x: left, y: rect.minY))
        path.addQuadCurve(to: CGPoint(x: left + top, y: rect.minY + top), control: CGPoint(x: left + top, y: rect.minY))
        if hasNeck {
            path.addLine(to: CGPoint(x: left + top, y: neckBottom - flare))
            path.addQuadCurve(to: CGPoint(x: left + top - flare, y: neckBottom), control: CGPoint(x: left + top, y: neckBottom))
            path.addLine(to: CGPoint(x: rect.minX + top + shoulder, y: neckBottom))
            path.addQuadCurve(to: CGPoint(x: rect.minX + top, y: neckBottom + shoulder), control: CGPoint(x: rect.minX + top, y: neckBottom))
        }
        path.addLine(to: CGPoint(x: rect.minX + top, y: rect.maxY - bottom))
        path.addQuadCurve(to: CGPoint(x: rect.minX + top + bottom, y: rect.maxY), control: CGPoint(x: rect.minX + top, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX - top - bottom, y: rect.maxY))
        path.addQuadCurve(to: CGPoint(x: rect.maxX - top, y: rect.maxY - bottom), control: CGPoint(x: rect.maxX - top, y: rect.maxY))
        let right = rect.maxX - inset
        if hasNeck {
            path.addLine(to: CGPoint(x: rect.maxX - top, y: neckBottom + shoulder))
            path.addQuadCurve(to: CGPoint(x: rect.maxX - top - shoulder, y: neckBottom), control: CGPoint(x: rect.maxX - top, y: neckBottom))
            path.addLine(to: CGPoint(x: right - top + flare, y: neckBottom))
            path.addQuadCurve(to: CGPoint(x: right - top, y: neckBottom - flare), control: CGPoint(x: right - top, y: neckBottom))
        }
        path.addLine(to: CGPoint(x: right - top, y: rect.minY + top))
        path.addQuadCurve(to: CGPoint(x: right, y: rect.minY), control: CGPoint(x: right - top, y: rect.minY))
        path.closeSubpath()
        return path
    }
}

struct NotchRootView: View {
    let model: NotchModel

    static let closedTopRadius: CGFloat = 6
    /// How much the closed notch grows while the pointer rests on it.
    static let hoverLift = CGSize(width: 7.5, height: 5)

    /// Wing widths (top-corner ears included) left and right of the hardware notch while
    /// closed or compact. The left one stays minimal because app menus reach the notch there.
    @MainActor
    static func wings(_ model: NotchModel) -> (left: CGFloat, right: CGFloat) {
        if model.presentation == .compact { return (closedTopRadius, model.compactWingWidth) }
        let lift = model.isHoverPrimed ? hoverLift.width : 0
        let right: CGFloat = switch model.claude.indicator {
        case nil: closedTopRadius
        case let indicator? where indicator.count > 1: 44
        default: 30
        }
        return (closedTopRadius + lift, right + lift)
    }

    @MainActor
    static func closedHeight(_ model: NotchModel) -> CGFloat {
        model.notchSize.height + (model.isHoverPrimed ? hoverLift.height : 0)
    }

    var body: some View {
        container
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .environment(\.colorScheme, .dark)
    }

    private var isOpen: Bool { model.presentation == .open }
    /// The small top-corner ears stay the same open or closed: the neck keeps the notch's width.
    private var topRadius: CGFloat { Self.closedTopRadius }

    /// While open, the neck through the menu bar is exactly as wide as the closed notch.
    private var neckInset: CGFloat {
        guard isOpen else { return 0 }
        return (NotchModel.openWidth - model.notchSize.width) / 2
    }
    private var bandHeight: CGFloat { max(model.notchSize.height, 28) }
    private var needsAttention: Bool { !isOpen && !model.claude.pending.isEmpty }

    private var container: some View {
        VStack(spacing: 0) {
            header
            if isOpen {
                CappedHeight(max: NotchModel.maxOpenHeight - bandHeight - 70) {
                    ClaudeTab(store: model.claude)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                }
                .padding(.top, 8)
                .transition(.asymmetric(
                    insertion: .notchBlur.combined(with: .scale(scale: 0.94, anchor: .top)).animation(.smooth(duration: 0.32).delay(0.04)),
                    removal: .opacity.animation(.smooth(duration: 0.12))
                ))
            }
        }
        .padding(.horizontal, isOpen ? 16 : 0)
        .padding(.bottom, isOpen ? 14 : 0)
        .frame(width: bodyWidth, alignment: .top)
        .padding(.horizontal, topRadius)
        .background(.black)
        .clipShape(NotchShape(topRadius: topRadius, bottomRadius: isOpen ? 24 : 14, neckInset: neckInset, neckHeight: isOpen ? bandHeight : 0))
        .compositingGroup()
        .shadow(color: shadowColor, radius: isOpen ? 14 : 8, y: isOpen ? 6 : 2)
        .onGeometryChange(for: CGSize.self, of: \.size) { size in
            if isOpen { model.openSize = size }
        }
        .offset(x: horizontalShift)
        .animation(.notchOpen, value: model.claude.indicator)
        .animation(.spring(response: 0.36, dampingFraction: 0.74), value: model.isHoverPrimed)
        .animation(.smooth(duration: 0.4), value: needsAttention)
    }

    private var shadowColor: Color {
        if isOpen { return .black.opacity(0.55) }
        return needsAttention ? Color.claude.opacity(0.7) : .clear
    }

    private var bodyWidth: CGFloat {
        if isOpen { return NotchModel.openWidth }
        let wings = Self.wings(model)
        return model.notchSize.width + wings.left + wings.right - 2 * topRadius
    }

    /// Keeps the hardware notch covered when the wings are uneven.
    private var horizontalShift: CGFloat {
        if isOpen { return 0 }
        let wings = Self.wings(model)
        return (wings.right - wings.left) / 2
    }

    @ViewBuilder
    private var header: some View {
        switch model.presentation {
        case .open:
            // The menu bar band is the neck: the system draws its menus over anything placed
            // beside the notch there and keeps the clicks, so everything starts below it.
            VStack(spacing: 0) {
                Color.clear.frame(height: bandHeight)
                HStack(spacing: 8) {
                    ClaudeHeadline(store: model.claude)
                    Spacer(minLength: 8)
                    UsageRing(limits: model.claude.limits)
                }
                .frame(height: 26)
                .padding(.top, 8)
            }
        case .compact:
            HStack(spacing: 0) {
                Color.clear.frame(width: model.notchSize.width)
                CompactActivity(model: model)
                    .frame(width: model.compactWingWidth - topRadius, alignment: .leading)
            }
            .frame(height: model.notchSize.height)
            .transition(.notchBlur)
        case .closed:
            let wings = Self.wings(model)
            HStack(spacing: 0) {
                Color.clear.frame(width: model.notchSize.width + wings.left - topRadius)
                if let indicator = model.claude.indicator {
                    ClosedIndicatorView(indicator: indicator)
                        .frame(width: wings.right - topRadius)
                        .transition(.scale(scale: 0.4).combined(with: .opacity))
                }
            }
            .frame(height: Self.closedHeight(model))
            .transition(.notchBlur)
        }
    }
}

/// Compact content right of the notch for short-lived activities.
private struct CompactActivity: View {
    let model: NotchModel

    var body: some View {
        HStack(spacing: 6) {
            switch model.peek {
            case .claudeDone(let label):
                icon("checkmark.circle.fill", .green)
                Text(label)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.92))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("done")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.55))
                    .fixedSize()
            case .usage(let percent):
                icon("gauge.with.dots.needle.67percent", percent >= 95 ? .red : .orange)
                Text("Claude limit \(percent)%")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.92))
                    .lineLimit(1)
                if let window = model.claude.limits.current().fiveHour {
                    Text(window.resetText())
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.55))
                        .lineLimit(1)
                }
            default:
                EmptyView()
            }
        }
        .padding(.leading, 6)
        .padding(.trailing, 10)
        .id(model.peek.map { "\($0)" } ?? "")
    }

    private func icon(_ name: String, _ color: Color) -> some View {
        Image(systemName: name)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(color)
            .symbolEffect(.bounce.down, options: .nonRepeating)
    }
}

/// Session summary left of the panel header: the session itself when there is one, counts otherwise.
private struct ClaudeHeadline: View {
    let store: ClaudeStore

    var body: some View {
        let sessions = store.sortedSessions
        HStack(spacing: 7) {
            if let first = sessions.first {
                StatusIndicator(status: first.status)
                Text(store.statusSummary ?? "")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(1)
            } else {
                Text("✻").font(.system(size: 13, weight: .bold)).foregroundStyle(Color.claude)
                Text("Claude Code")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.85))
            }
        }
        .animation(.smooth, value: sessions.first?.status)
    }
}

/// The closed notch's status: one glyph for the most urgent activity, with a count.
private struct ClosedIndicatorView: View {
    let indicator: ClosedIndicator

    var body: some View {
        HStack(spacing: 4) {
            switch indicator.kind {
            case .working:
                LayerSpinner(color: NSColor(Color.claude))
            case .needsApproval:
                LayerPulseDot(color: NSColor(Color.claude))
            case .waitingForUser:
                Circle().fill(.blue).frame(width: 7, height: 7)
            case .error:
                Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 10)).foregroundStyle(.red)
            default:
                Image(systemName: "checkmark.circle.fill").font(.system(size: 12)).foregroundStyle(.green)
            }
            if indicator.count > 1 {
                Text("\(indicator.count)")
                    .font(.system(size: 10.5, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.75))
                    .contentTransition(.numericText())
            }
        }
        .id(indicator.kind)
        .transition(.scale(scale: 0.5).combined(with: .opacity))
    }
}

extension Color {
    static let claude = Color(red: 0.85, green: 0.47, blue: 0.34)
    static let cardFill = Color.white.opacity(0.07)
}

/// Shows `content` at its natural height up to `maxHeight`, scrolling only when it does not fit.
struct AutoScroll<Content: View>: View {
    var maxHeight: CGFloat = .infinity
    @ViewBuilder var content: Content

    var body: some View {
        CappedHeight(max: maxHeight) {
            ViewThatFits(in: .vertical) {
                content
                ScrollView(.vertical) { content }
                    .scrollIndicators(.never)
                    .mask(LinearGradient(stops: [.init(color: .black, location: 0.9), .init(color: .clear, location: 1)], startPoint: .top, endPoint: .bottom))
            }
        }
    }
}

/// Proposes at most `max` height and takes its child's size, unlike `.frame(maxHeight:)` which grows to the proposal.
struct CappedHeight: Layout {
    var max: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let height = Swift.min(proposal.height ?? max, max)
        return subviews.first?.sizeThatFits(ProposedViewSize(width: proposal.width, height: height)) ?? .zero
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, anchor: .topLeading, proposal: ProposedViewSize(bounds.size))
    }
}

/// Fades through a blur, like the Dynamic Island content swaps.
struct BlurFade: ViewModifier {
    var radius: CGFloat
    var opacity: Double

    func body(content: Content) -> some View {
        content.blur(radius: radius).opacity(opacity)
    }
}

extension AnyTransition {
    static var notchBlur: AnyTransition {
        .modifier(active: BlurFade(radius: 8, opacity: 0), identity: BlurFade(radius: 0, opacity: 1))
    }
}

extension Animation {
    static let notchOpen = Animation.spring(response: 0.42, dampingFraction: 0.8)
    static let notchClose = Animation.spring(response: 0.45, dampingFraction: 1.0)
    /// Compact activities pop in with a little bounce.
    static let notchActivity = Animation.spring(response: 0.38, dampingFraction: 0.72)
}
