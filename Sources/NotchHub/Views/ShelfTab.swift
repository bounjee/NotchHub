import AppKit
import SwiftUI

struct ShelfTab: View {
    let shelf: Shelf

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if shelf.items.isEmpty {
                EmptyState(
                    symbol: "tray.and.arrow.down",
                    title: String(localized: "The shelf is empty"),
                    detail: String(localized: "Drag files onto the notch. Only their paths are kept; files are never copied.")
                )
            } else {
                ScrollView(.horizontal) {
                    HStack(spacing: 6) {
                        ForEach(shelf.items) { item in
                            ShelfTile(item: item, shelf: shelf)
                                .transition(.scale(scale: 0.5).combined(with: .opacity))
                        }
                    }
                    .padding(4)
                }
                .scrollIndicators(.never)
                .frame(height: 112)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.cardFill))
                .animation(.spring(response: 0.35, dampingFraction: 0.75), value: shelf.items)
                actions
            }
        }
    }

    private var actions: some View {
        let selected = shelf.selectedItems
        let targets = selected.isEmpty ? shelf.items : selected
        return HStack(spacing: 8) {
            Group {
                if selected.isEmpty {
                    Text("^[\(shelf.items.count) item](inflect: true) · double-click to open")
                } else {
                    Text("\(selected.count) selected")
                }
            }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .contentTransition(.numericText())
            Spacer()
            Button { shelf.airDrop(targets) } label: {
                Label { selected.isEmpty ? Text("AirDrop All") : Text(verbatim: "AirDrop") } icon: { AirDropIcon() }
            }
            .buttonStyle(PillButtonStyle(kind: .secondary))
            if !selected.isEmpty {
                Button { shelf.revealInFinder(selected) } label: { Label("Show in Finder", systemImage: "folder") }
                    .buttonStyle(PillButtonStyle(kind: .secondary))
                Button { withAnimation(.snappy) { shelf.remove(selected) } } label: { Label("Remove", systemImage: "minus.circle") }
                    .buttonStyle(PillButtonStyle(kind: .secondary))
            } else {
                Button { withAnimation(.snappy) { shelf.clear() } } label: { Label("Clear All", systemImage: "trash") }
                    .buttonStyle(PillButtonStyle(kind: .destructive))
            }
        }
        .labelStyle(.titleAndIcon)
        .animation(.snappy(duration: 0.2), value: selected.isEmpty)
    }
}

private struct ShelfTile: View {
    let item: ShelfItem
    let shelf: Shelf
    @State private var hovering = false

    private var isSelected: Bool { shelf.selection.contains(item.id) }

    var body: some View {
        VStack(spacing: 6) {
            FileThumbnail(path: item.path, size: 52)
                .scaleEffect(hovering ? 1.06 : 1)
                .overlay(alignment: .bottomTrailing) {
                    if let source = item.source {
                        Image(systemName: source == .screenshot ? "camera.viewfinder" : "arrow.down.circle.fill")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(3)
                            .background(Circle().fill(source == .screenshot ? Color.purple : .blue))
                            .offset(x: 4, y: 4)
                            .help(source == .screenshot
                                  ? String(localized: "Screenshot · leaves the shelf after a day")
                                  : String(localized: "Download · leaves the shelf after a day"))
                    }
                }
            FewLines(maxHeight: 28) {
                Text(verbatim: item.name)
                    .font(.system(size: 10.5))
                    .multilineTextAlignment(.center)
                    .frame(width: 80)
            }
            .frame(width: 80, height: 28, alignment: .top)
        }
        .padding(.vertical, 8)
        .frame(width: 90)
        .background(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(isSelected ? Color.accentColor.opacity(0.35) : hovering ? .white.opacity(0.08) : .clear)
        )
        .overlay(alignment: .topTrailing) {
            if hovering {
                Button { withAnimation(.snappy) { shelf.remove([item]) } } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 15))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, .gray.opacity(0.85))
                }
                .buttonStyle(.plain)
                .padding(3)
                .help(String(localized: "Remove from Shelf"))
                .transition(.scale.combined(with: .opacity))
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: 11))
        .onHover { isHovering in withAnimation(.snappy(duration: 0.18)) { hovering = isHovering } }
        .onTapGesture { withAnimation(.snappy(duration: 0.2)) { shelf.toggleSelection(item) } }
        // A double click toggles the selection twice (back to where it was) and opens the file.
        .simultaneousGesture(TapGesture(count: 2).onEnded { shelf.open(item) })
        .onDrag { NSItemProvider(contentsOf: item.url) ?? NSItemProvider() }
        .contextMenu {
            Button("Open") { shelf.open(item) }
            Button(String("AirDrop")) { shelf.airDrop(isSelected ? shelf.selectedItems : [item]) }
            Button("Show in Finder") { shelf.revealInFinder([item]) }
            Divider()
            Button("Remove from Shelf") { shelf.remove([item]) }
        }
        .help(item.path)
    }
}

/// The system's own AirDrop icon (there is no public SF Symbol for it).
struct AirDropIcon: View {
    var body: some View {
        if let image = NSSharingService(named: .sendViaAirDrop)?.image {
            Image(nsImage: image).resizable().frame(width: 14, height: 14)
        } else {
            Image(systemName: "dot.radiowaves.left.and.right")
        }
    }
}
