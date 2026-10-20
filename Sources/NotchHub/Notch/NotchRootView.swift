import SwiftUI
import UniformTypeIdentifiers

struct NotchShape: Shape {
    var topRadius: CGFloat
    var bottomRadius: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(topRadius, bottomRadius) }
        set { topRadius = newValue.first; bottomRadius = newValue.second }
    }

    func path(in rect: CGRect) -> Path {
        let top = topRadius, bottom = bottomRadius
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addQuadCurve(to: CGPoint(x: rect.minX + top, y: rect.minY + top), control: CGPoint(x: rect.minX + top, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX + top, y: rect.maxY - bottom))
        path.addQuadCurve(to: CGPoint(x: rect.minX + top + bottom, y: rect.maxY), control: CGPoint(x: rect.minX + top, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX - top - bottom, y: rect.maxY))
        path.addQuadCurve(to: CGPoint(x: rect.maxX - top, y: rect.maxY - bottom), control: CGPoint(x: rect.maxX - top, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX - top, y: rect.minY + top))
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY), control: CGPoint(x: rect.maxX - top, y: rect.minY))
        path.closeSubpath()
        return path
    }
}

struct NotchRootView: View {
    let model: NotchModel

    static let compactWingWidth: CGFloat = 78
    static let openTopRadius: CGFloat = 19
    static let closedTopRadius: CGFloat = 6

    /// Width of each side "ear" next to the closed notch when there is something to show.
    @MainActor
    static func closedWingWidth(_ model: NotchModel) -> CGFloat {
        model.claude.headlineStatus == nil ? closedTopRadius : 30
    }

    var body: some View {
        container
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .environment(\.colorScheme, .dark)
    }

    private var isOpen: Bool { model.presentation == .open }
    private var topRadius: CGFloat { isOpen ? Self.openTopRadius : Self.closedTopRadius }

    private var container: some View {
        VStack(spacing: 0) {
            header
            if isOpen {
                CappedHeight(max: NotchModel.maxOpenHeight - bandHeight - 30 - 30) {
                    TabContent(model: model)
                }
                .padding(.top, 8)
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .scale(scale: 0.92, anchor: .top)).animation(.smooth(duration: 0.3).delay(0.05)),
                        removal: .opacity.animation(.smooth(duration: 0.12))
                    ))
            }
        }
        .padding(.horizontal, isOpen ? 18 : 0)
        .padding(.bottom, isOpen ? 14 : 0)
        .frame(width: bodyWidth, alignment: .top)
        .padding(.horizontal, topRadius)
        .background(.black)
        .clipShape(NotchShape(topRadius: topRadius, bottomRadius: isOpen ? 24 : 14))
        .shadow(color: .black.opacity(isOpen ? 0.55 : 0), radius: 14, y: 6)
        .onGeometryChange(for: CGSize.self, of: \.size) { size in
            if isOpen { model.openSize = size }
        }
        .onDrop(of: [.fileURL], isTargeted: Binding(get: { model.isDropTargeted }, set: { model.isDropTargeted = $0 })) { providers in
            receive(providers)
            return true
        }
        .animation(.notchOpen, value: model.claude.headlineStatus)
    }

    private var bandHeight: CGFloat { max(model.notchSize.height, 28) }

    private var bodyWidth: CGFloat {
        switch model.presentation {
        case .open: NotchModel.openWidth
        case .compact: model.notchSize.width + 2 * (Self.compactWingWidth - topRadius)
        case .closed: model.notchSize.width + 2 * (Self.closedWingWidth(model) - topRadius)
        }
    }

    @ViewBuilder
    private var header: some View {
        switch model.presentation {
        case .open:
            // The menu bar band does not receive clicks, so it only shows status;
            // the tabs sit just below it.
            VStack(spacing: 6) {
                HStack(spacing: 0) {
                    ClaudeHeadline(store: model.claude)
                    Spacer(minLength: model.notchSize.width + 12)
                    BatteryBadge(battery: model.battery)
                }
                .frame(height: bandHeight)
                TabBar(model: model)
            }
        case .compact:
            HStack(spacing: 0) {
                PowerPeekLeading(battery: model.battery)
                    .frame(width: Self.compactWingWidth - topRadius)
                Color.clear.frame(width: model.notchSize.width)
                PowerPeekTrailing(battery: model.battery)
                    .frame(width: Self.compactWingWidth - topRadius)
            }
            .frame(height: model.notchSize.height)
            .transition(.opacity)
        case .closed:
            HStack(spacing: 0) {
                if let status = model.claude.headlineStatus {
                    Image(systemName: "sparkle")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.claude)
                        .frame(width: Self.closedWingWidth(model) - topRadius)
                    Color.clear.frame(width: model.notchSize.width)
                    StatusIndicator(status: status)
                        .frame(width: Self.closedWingWidth(model) - topRadius)
                } else {
                    Color.clear.frame(width: model.notchSize.width)
                }
            }
            .frame(height: model.notchSize.height)
        }
    }

    private func receive(_ providers: [NSItemProvider]) {
        for provider in providers {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                Task { @MainActor in
                    model.shelf.add([url])
                    model.noteDrop()
                    model.select(.shelf)
                }
            }
        }
    }
}

private struct TabContent: View {
    let model: NotchModel

    var body: some View {
        Group {
            switch model.tab {
            case .claude: ClaudeTab(store: model.claude)
            case .shelf: ShelfTab(shelf: model.shelf, isDropTargeted: model.isDropTargeted, dropCount: model.dropCount)
            case .clipboard: ClipboardTab(history: model.clipboard)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .id(model.tab)
        .transition(.opacity.animation(.smooth(duration: 0.18)))
    }
}

/// Most urgent Claude session, shown left of the notch while open.
private struct ClaudeHeadline: View {
    let store: ClaudeStore

    var body: some View {
        if let session = store.sortedSessions.first(where: { $0.status == store.headlineStatus }) {
            HStack(spacing: 7) {
                StatusIndicator(status: session.status)
                Text(session.label)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(1)
                Text(session.status.title)
                    .font(.system(size: 12))
                    .foregroundStyle(session.status.tint)
                    .lineLimit(1)
            }
            .fixedSize()
        }
    }
}

private struct TabBar: View {
    let model: NotchModel
    @Namespace private var selection

    var body: some View {
        HStack(spacing: 2) {
            ForEach(NotchTab.allCases) { tab in
                Button {
                    withAnimation(.snappy(duration: 0.25)) { model.select(tab) }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: tab.symbol).font(.system(size: 10, weight: .semibold))
                        Text(tab.title).font(.system(size: 12, weight: .medium))
                        if tab == .claude, !model.claude.pending.isEmpty {
                            Circle().fill(Color.claude).frame(width: 6, height: 6)
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
