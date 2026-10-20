import AppKit
import SwiftUI

struct ShelfTab: View {
    let shelf: Shelf
    let isDropTargeted: Bool
    let dropCount: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if shelf.items.isEmpty {
                dropZone
            } else {
                ScrollView(.horizontal) {
                    HStack(spacing: 6) {
                        ForEach(shelf.items) { item in
                            ShelfTile(item: item, shelf: shelf)
                                .transition(.scale(scale: 0.6).combined(with: .opacity))
                        }
                    }
                    .padding(4)
                }
                .scrollIndicators(.never)
                .frame(height: 104)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(isDropTargeted ? Color.accentColor.opacity(0.14) : Color.cardFill)
                        .strokeBorder(isDropTargeted ? Color.accentColor.opacity(0.6) : .clear, lineWidth: 1.5)
                )
                .animation(.snappy, value: shelf.items)
                actions
            }
        }
        .animation(.snappy, value: isDropTargeted)
    }

    private var dropZone: some View {
        VStack(spacing: 6) {
            Image(systemName: isDropTargeted ? "tray.and.arrow.down.fill" : "tray.and.arrow.down")
                .font(.system(size: 24, weight: .light))
                .symbolEffect(.bounce, value: isDropTargeted)
            Text(isDropTargeted ? "Bırak" : "Dosyaları buraya sürükle")
                .font(.system(size: 13, weight: .medium))
            Text("Dosyalar kopyalanmaz, sadece yolları saklanır")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 110)
        .foregroundStyle(isDropTargeted ? Color.accentColor : .white.opacity(0.8))
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6, 5]))
                .foregroundStyle(isDropTargeted ? Color.accentColor : .white.opacity(0.22))
        )
    }

    private var actions: some View {
        let selected = shelf.selectedItems
        let targets = selected.isEmpty ? shelf.items : selected
        return HStack(spacing: 8) {
            Text(selected.isEmpty ? "\(shelf.items.count) öğe" : "\(selected.count) seçili")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .contentTransition(.numericText())
            Spacer()
            Button { shelf.airDrop(targets) } label: { Label { Text(selected.isEmpty ? "Tümünü AirDrop'la" : "AirDrop") } icon: { AirDropIcon() } }
                .buttonStyle(PillButtonStyle(kind: .secondary))
            if !selected.isEmpty {
                Button { shelf.revealInFinder(selected) } label: { Label("Finder'da göster", systemImage: "folder") }
                    .buttonStyle(PillButtonStyle(kind: .secondary))
                Button { withAnimation(.snappy) { shelf.remove(selected) } } label: { Label("Kaldır", systemImage: "minus.circle") }
                    .buttonStyle(PillButtonStyle(kind: .secondary))
            } else {
                Button { withAnimation(.snappy) { shelf.clear() } } label: { Label("Tümünü temizle", systemImage: "trash") }
                    .buttonStyle(PillButtonStyle(kind: .destructive))
            }
        }
        .labelStyle(.titleAndIcon)
    }
}

private struct ShelfTile: View {
    let item: ShelfItem
    let shelf: Shelf
    @State private var hovering = false

    private var isSelected: Bool { shelf.selection.contains(item.id) }

    var body: some View {
        VStack(spacing: 5) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: item.path))
                .resizable()
                .interpolation(.high)
                .frame(width: 46, height: 46)
                .shadow(color: .black.opacity(0.3), radius: 2, y: 1)
            Text(item.name)
                .font(.system(size: 10.5))
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .truncationMode(.middle)
                .frame(width: 78, height: 28, alignment: .top)
        }
        .padding(.vertical, 8)
        .frame(width: 86)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isSelected ? Color.accentColor.opacity(0.35) : hovering ? .white.opacity(0.08) : .clear)
        )
        .overlay(alignment: .topTrailing) {
            if hovering {
                Button { withAnimation(.snappy) { shelf.remove([item]) } } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, .gray.opacity(0.8))
                }
                .buttonStyle(.plain)
                .padding(3)
                .help("Raftan kaldır")
                .transition(.opacity)
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: 10))
        .onHover { hovering = $0 }
        .onTapGesture { withAnimation(.snappy(duration: 0.2)) { shelf.toggleSelection(item) } }
        .onDrag { NSItemProvider(contentsOf: item.url) ?? NSItemProvider() }
        .contextMenu {
            Button("AirDrop") { shelf.airDrop(isSelected ? shelf.selectedItems : [item]) }
            Button("Finder'da göster") { shelf.revealInFinder([item]) }
            Divider()
            Button("Raftan kaldır") { shelf.remove([item]) }
        }
        .help(item.path)
    }
}

/// The system's own AirDrop icon (there is no public SF Symbol for it).
private struct AirDropIcon: View {
    var body: some View {
        if let image = NSSharingService(named: .sendViaAirDrop)?.image {
            Image(nsImage: image).resizable().frame(width: 14, height: 14)
        } else {
            Image(systemName: "dot.radiowaves.left.and.right")
        }
    }
}
