import SwiftUI

/// One line of text that fades out at the trailing edge when it does not fit, instead of
/// ending in "…". Short text is left untouched.
struct OneLine<Content: View>: View {
    @ViewBuilder var content: Content
    @State private var natural: CGFloat = 0
    @State private var available: CGFloat = 0

    private static var fade: CGFloat { 28 }

    var body: some View {
        content
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .onGeometryChange(for: CGFloat.self, of: \.size.width) { natural = $0 }
            .frame(maxWidth: .infinity, alignment: .leading)
            .onGeometryChange(for: CGFloat.self, of: \.size.width) { available = $0 }
            .clipped()
            .mask {
                if natural > available + 0.5, available > Self.fade {
                    LinearGradient(stops: [
                        .init(color: .black, location: 1 - Self.fade / available),
                        .init(color: .clear, location: 1),
                    ], startPoint: .leading, endPoint: .trailing)
                } else {
                    Color.black
                }
            }
    }
}

/// Up to `maxHeight` of wrapped text; anything below fades out instead of ending in "…".
struct FewLines<Content: View>: View {
    let maxHeight: CGFloat
    @ViewBuilder var content: Content
    @State private var natural: CGFloat = 0

    private static var fade: CGFloat { 14 }

    var body: some View {
        content
            .fixedSize(horizontal: false, vertical: true)
            .onGeometryChange(for: CGFloat.self, of: \.size.height) { natural = $0 }
            // As tall as the text, up to the limit (a max-height frame would grow to the limit).
            .frame(height: natural > 0 ? min(natural, maxHeight) : nil, alignment: .top)
            .clipped()
            .mask {
                if natural > maxHeight + 0.5 {
                    LinearGradient(stops: [
                        .init(color: .black, location: 1 - Self.fade / maxHeight),
                        .init(color: .clear, location: 1),
                    ], startPoint: .top, endPoint: .bottom)
                } else {
                    Color.black
                }
            }
    }
}
