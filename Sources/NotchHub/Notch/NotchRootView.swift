import SwiftUI
import UniformTypeIdentifiers

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
                    if let drag = model.drag {
                        DropZones(kind: drag, receiveFiles: receiveFiles, receiveText: receiveText)
                            .transition(.notchBlur)
                    } else {
                        TabContent(model: model)
                    }
                }
                .padding(.top, 8)
                .transition(.asymmetric(
                    insertion: .notchBlur.combined(with: .scale(scale: 0.94, anchor: .top)).animation(.smooth(duration: 0.32).delay(0.04)),
                    removal: .opacity.animation(.smooth(duration: 0.12))
                ))
            }
        }
        .padding(.horizontal, isOpen ? 18 : 0)
        .padding(.bottom, isOpen ? 14 : 0)
        .frame(width: bodyWidth, alignment: .top)
        .padding(.horizontal, topRadius)
        .background(.black)
        .clipShape(NotchShape(topRadius: topRadius, bottomRadius: isOpen ? 24 : 14, neckInset: neckInset, neckHeight: isOpen ? bandHeight : 0))
        .compositingGroup()
        .shadow(color: shadowColor, radius: isOpen ? 14 : 8, y: isOpen ? 6 : 2)
        .keyframeAnimator(initialValue: 1.0, trigger: model.dropCount) { content, scale in
            content.scaleEffect(x: scale, y: scale, anchor: .top)
        } keyframes: { _ in
            SpringKeyframe(1.035, duration: 0.12, spring: .snappy)
            SpringKeyframe(1.0, duration: 0.35, spring: .bouncy)
        }
        .onGeometryChange(for: CGSize.self, of: \.size) { size in
            if isOpen { model.openSize = size }
        }
        .offset(x: horizontalShift)
        // Fallback for drops that land on the notch itself rather than a zone.
        .onDrop(of: [.fileURL, .url, .plainText], isTargeted: nil) { providers in
            if providers.contains(where: { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }) {
                receiveFiles(providers, airDrop: false)
            } else {
                receiveText(providers)
            }
            return true
        }
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
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if model.drag == nil {
                        TabBar(model: model)
                            .fixedSize()
                            .transition(.notchBlur)
                    }
                    HStack(spacing: 12) {
                        UsageRing(limits: model.claude.limits)
                        BatteryBadge(battery: model.battery)
                    }
                    .frame(maxWidth: .infinity, alignment: .trailing)
                }
                .frame(height: 30)
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

    private func receiveFiles(_ providers: [NSItemProvider], airDrop: Bool) {
        Task { @MainActor in
            var urls: [URL] = []
            for provider in providers {
                if let url = await provider.loadURL(), url.isFileURL { urls.append(url) }
            }
            guard !urls.isEmpty else { return }
            withAnimation(.notchOpen) {
                model.drag = nil
                if airDrop {
                    model.shelf.airDrop(urls: urls)
                } else {
                    model.shelf.add(urls)
                    model.select(.shelf)
                }
                model.noteDrop()
            }
        }
    }

    private func receiveText(_ providers: [NSItemProvider]) {
        Task { @MainActor in
            for provider in providers {
                guard let text = await provider.loadText() else { continue }
                withAnimation(.notchOpen) {
                    model.drag = nil
                    model.clipboard.add(text)
                    model.select(.clipboard)
                    model.noteDrop()
                }
                return
            }
        }
    }
}

extension NSItemProvider {
    @MainActor
    func loadURL() async -> URL? {
        await withCheckedContinuation { continuation in
            _ = loadObject(ofClass: URL.self) { url, _ in continuation.resume(returning: url) }
        }
    }

    /// Plain text, or the address of a dragged link.
    @MainActor
    func loadText() async -> String? {
        if canLoadObject(ofClass: String.self) {
            return await withCheckedContinuation { continuation in
                _ = loadObject(ofClass: String.self) { text, _ in continuation.resume(returning: text) }
            }
        }
        return await loadURL()?.absoluteString
    }
}

/// Compact content right of the notch for short-lived activities.
private struct CompactActivity: View {
    let model: NotchModel

    var body: some View {
        HStack(spacing: 6) {
            switch model.peek {
            case .copied(let text):
                icon("checkmark.circle.fill", .green)
                title("Kopyalandı")
                detail(text)
            case .claudeDone(let label):
                icon("checkmark.circle.fill", .green)
                title(label)
                detail("bitti")
                    .layoutPriority(2)
            case .screenshot(let path):
                FileThumbnail(path: path, size: 20)
                title("Ekran görüntüsü")
                detail("rafta")
            case .downloaded(let name):
                icon("arrow.down.circle.fill", .blue)
                title(name)
                detail("rafta")
            case .charged:
                icon("bolt.fill", .green)
                title("Şarj doldu")
                Spacer(minLength: 4)
                BatteryBadge(battery: model.battery)
            case .lowBattery:
                icon("battery.25percent", .red)
                title("Pil az")
                Spacer(minLength: 4)
                BatteryBadge(battery: model.battery)
            case .usage(let percent):
                icon("gauge.with.dots.needle.67percent", percent >= 95 ? .red : .orange)
                title("Claude limiti %\(percent)")
                if let window = model.claude.limits.current().fiveHour {
                    detail(window.resetText())
                }
            default:
                icon(model.battery.isPluggedIn ? "bolt.fill" : "powerplug", model.battery.isPluggedIn ? .green : .white.opacity(0.7))
                title(model.battery.isPluggedIn ? "Şarjda" : "Pilde")
                Spacer(minLength: 4)
                PowerPeekTrailing(battery: model.battery)
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

    private func title(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11.5, weight: .semibold))
            .foregroundStyle(.white.opacity(0.92))
            .lineLimit(1)
            .truncationMode(.middle)
            .layoutPriority(1)
    }

    private func detail(_ text: String) -> some View {
        Text(text.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\n", with: " "))
            .font(.system(size: 11))
            .foregroundStyle(.white.opacity(0.55))
            .lineLimit(1)
    }
}

/// Targets shown while something is dragged over the open notch.
private struct DropZones: View {
    let kind: DragKind
    let receiveFiles: ([NSItemProvider], Bool) -> Void
    let receiveText: ([NSItemProvider]) -> Void

    var body: some View {
        HStack(spacing: 10) {
            switch kind {
            case .files:
                DropZone(title: "Rafa ekle", detail: "Yolu saklanır, dosya kopyalanmaz", symbol: "tray.and.arrow.down.fill", types: [.fileURL]) {
                    receiveFiles($0, false)
                }
                DropZone(title: "AirDrop", detail: "Yakındaki cihazlara gönder", symbol: "dot.radiowaves.left.and.right", types: [.fileURL], airDropIcon: true) {
                    receiveFiles($0, true)
                }
            case .text:
                DropZone(title: "Panoya kaydet", detail: "Geçmişe eklenir ve yapıştırılabilir", symbol: "doc.on.clipboard.fill", types: [.plainText, .url]) {
                    receiveText($0)
                }
            }
        }
        .frame(height: 118)
    }
}

private struct DropZone: View {
    let title: String
    let detail: String
    let symbol: String
    let types: [UTType]
    var airDropIcon = false
    let perform: ([NSItemProvider]) -> Void
    @State private var targeted = false

    var body: some View {
        VStack(spacing: 6) {
            Group {
                if airDropIcon, let image = NSSharingService(named: .sendViaAirDrop)?.image {
                    Image(nsImage: image).resizable().frame(width: 30, height: 30)
                } else {
                    Image(systemName: symbol).font(.system(size: 24, weight: .regular))
                }
            }
            .symbolEffect(.bounce, value: targeted)
            .scaleEffect(targeted ? 1.12 : 1)
            Text(title).font(.system(size: 13, weight: .semibold))
            Text(detail).font(.system(size: 10.5)).foregroundStyle(.secondary)
        }
        .foregroundStyle(targeted ? Color.white : .white.opacity(0.75))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(targeted ? Color.accentColor.opacity(0.28) : .white.opacity(0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: targeted ? [] : [6, 5]))
                .foregroundStyle(targeted ? Color.accentColor : .white.opacity(0.22))
        )
        .scaleEffect(targeted ? 1.02 : 1)
        .animation(.spring(response: 0.28, dampingFraction: 0.7), value: targeted)
        .onDrop(of: types, isTargeted: $targeted) { providers in
            perform(providers)
            return true
        }
        .onChange(of: targeted) { _, isTargeted in
            if isTargeted { NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now) }
        }
    }
}

private struct TabContent: View {
    let model: NotchModel

    var body: some View {
        Group {
            switch model.tab {
            case .claude: ClaudeTab(store: model.claude)
            case .shelf: ShelfTab(shelf: model.shelf)
            case .clipboard: ClipboardTab(history: model.clipboard)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .id(model.tab)
        .transition(.notchBlur.animation(.smooth(duration: 0.22)))
    }
}

/// Session summary left of the tabs: the session itself when there is one, counts otherwise.
private struct ClaudeHeadline: View {
    let store: ClaudeStore

    var body: some View {
        let sessions = store.sortedSessions
        if let first = sessions.first {
            HStack(spacing: 7) {
                StatusIndicator(status: first.status)
                if sessions.count == 1 {
                    Text(first.label)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.85))
                        .lineLimit(1)
                    Text(first.status.title)
                        .font(.system(size: 12))
                        .foregroundStyle(first.status.tint)
                        .lineLimit(1)
                        .fixedSize()
                } else {
                    Text(Self.summary(sessions))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.85))
                        .lineLimit(1)
                }
            }
            .animation(.smooth, value: first.status)
        }
    }

    /// "2 çalışıyor · 1 bitti", most urgent first.
    static func summary(_ sessions: [ClaudeSession]) -> String {
        var counts: [SessionStatus: Int] = [:]
        for session in sessions { counts[session.status, default: 0] += 1 }
        return counts.keys.sorted { ClaudeStore.urgency($0) < ClaudeStore.urgency($1) }
            .map { "\(counts[$0]!) \($0.title.lowercased(with: Locale(identifier: "tr")))" }
            .joined(separator: " · ")
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

private struct TabBar: View {
    let model: NotchModel
    @Namespace private var selection

    var body: some View {
        HStack(spacing: 2) {
            ForEach(NotchTab.allCases) { tab in
                Button {
                    withAnimation(.snappy(duration: 0.28)) { model.select(tab) }
                } label: {
                    HStack(spacing: 4) {
                        if tab == .claude {
                            Text("✻").font(.system(size: 12, weight: .bold)).foregroundStyle(Color.claude)
                        } else {
                            Image(systemName: tab.symbol).font(.system(size: 10, weight: .semibold))
                        }
                        Text(tab.title).font(.system(size: 12, weight: .medium))
                        if let badge = badge(for: tab) {
                            Text(badge)
                                .font(.system(size: 9.5, weight: .bold).monospacedDigit())
                                .padding(.horizontal, 5)
                                .frame(minWidth: 15, minHeight: 15)
                                .background(Capsule().fill(tab == .claude ? Color.claude : .white.opacity(0.18)))
                                .foregroundStyle(.white)
                                .contentTransition(.numericText())
                        }
                    }
                    .foregroundStyle(model.tab == tab ? .white : .white.opacity(0.5))
                    .padding(.horizontal, 12)
                    .frame(height: 26)
                    .background {
                        if model.tab == tab {
                            Capsule().fill(.white.opacity(0.14)).matchedGeometryEffect(id: "tab", in: selection)
                        }
                    }
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(Capsule().fill(.white.opacity(0.06)))
    }

    private func badge(for tab: NotchTab) -> String? {
        switch tab {
        case .claude: model.claude.pending.isEmpty ? nil : "\(model.claude.pending.count)"
        case .shelf: model.shelf.items.isEmpty ? nil : "\(model.shelf.items.count)"
        case .clipboard: nil
        }
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
