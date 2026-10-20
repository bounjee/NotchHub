import AppKit
import SwiftUI

struct ShelfTab: View {
    let shelf: Shelf

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if shelf.items.isEmpty {
                EmptyState(
                    symbol: "tray.and.arrow.down",
                    title: "Raf boş",
                    detail: "Dosyaları çentiğe sürükle. Yolları saklanır, dosyalar kopyalanmaz."
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
            Text(selected.isEmpty ? "\(shelf.items.count) öğe · çift tıkla aç" : "\(selected.count) seçili")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .contentTransition(.numericText())
            Spacer()
            Button { shelf.airDrop(targets) } label: {
                Label { Text(selected.isEmpty ? "Tümünü AirDrop'la" : "AirDrop") } icon: { AirDropIcon() }
            }
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
            Text(item.name)
                .font(.system(size: 10.5))
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .truncationMode(.middle)
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
                .help("Raftan kaldır")
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
            Button("Aç") { shelf.open(item) }
            Button("AirDrop") { shelf.airDrop(isSelected ? shelf.selectedItems : [item]) }
            Button("Finder'da göster") { shelf.revealInFinder([item]) }
            Divider()
            Button("Raftan kaldır") { shelf.remove([item]) }
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
