import AppKit
import SwiftUI

struct ClipboardTab: View {
    let history: ClipboardHistory
    @State private var copiedID: ClipboardItem.ID?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if history.accessDenied {
                HStack(spacing: 10) {
                    Image(systemName: "lock.fill").foregroundStyle(.orange)
                    Text("Pano erişimi kapalı. Sistem Ayarları'nda NotchHub için pano erişimine izin ver.")
                        .font(.system(size: 12))
                    Spacer()
                    Button("Ayarları aç") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Pasteboard")!)
                    }
                    .buttonStyle(PillButtonStyle(kind: .secondary))
                }
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.orange.opacity(0.12)))
            }

            if history.items.isEmpty {
                EmptyState(symbol: "doc.on.clipboard", title: "Pano geçmişi boş", detail: "Kopyaladığın metinler burada görünür. Geçmiş sadece bellekte tutulur.")
            } else {
                AutoScroll {
                    LazyVStack(spacing: 4) {
                        ForEach(history.items) { item in
                            ClipboardRow(item: item, isCopied: copiedID == item.id, togglePin: {
                                withAnimation(.snappy) { history.togglePin(item) }
                            }) {
                                history.copy(item)
                                withAnimation(.snappy) { copiedID = history.items.first { $0.text == item.text }?.id }
                                Task {
                                    try? await Task.sleep(for: .seconds(1.2))
                                    withAnimation { copiedID = nil }
                                }
                            } remove: {
                                withAnimation(.snappy) { history.remove(item) }
                            }
                            .transition(.move(edge: .top).combined(with: .opacity))
                        }
                    }
                }
                HStack {
                    Text("\(history.items.count) öğe · sadece bellekte · tıkla kopyala")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                    Spacer()
                    Button(history.items.contains(where: \.isPinned) ? "Sabitsizleri temizle" : "Temizle") {
                        withAnimation(.snappy) { history.clear() }
                    }
                        .buttonStyle(PillButtonStyle(kind: .destructive))
                }
            }
        }
    }
}

private struct ClipboardRow: View {
    let item: ClipboardItem
    let isCopied: Bool
    let togglePin: () -> Void
    let copy: () -> Void
    let remove: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            Text(item.text.trimmingCharacters(in: .whitespacesAndNewlines))
                .font(.system(size: 12))
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
            if isCopied {
                Label("Kopyalandı", systemImage: "checkmark")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.green)
                    .transition(.opacity.combined(with: .scale(scale: 0.8)))
            } else if hovering {
                HStack(spacing: 10) {
                    Button(action: togglePin) {
                        Image(systemName: item.isPinned ? "pin.slash" : "pin").font(.system(size: 11))
                    }
                    .help(item.isPinned ? "Sabitlemeyi kaldır" : "Sabitle")
                    Button(action: remove) { Image(systemName: "trash").font(.system(size: 11)) }
                        .help("Sil")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .transition(.opacity)
            } else if item.isPinned {
                Image(systemName: "pin.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.orange.opacity(0.9))
            } else {
                TimelineView(.periodic(from: .now, by: 10)) { context in
                    let seconds = context.date.timeIntervalSince(item.copiedAt)
                    Text(seconds < 10 ? "şimdi" : shortElapsed(from: item.copiedAt, to: context.date))
                        .font(.system(size: 10.5).monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(hovering ? .white.opacity(0.1) : Color.cardFill))
        .contentShape(Rectangle())
        .onHover { isHovering in withAnimation(.snappy(duration: 0.15)) { hovering = isHovering } }
        .onTapGesture(perform: copy)
        .help("Tıkla: panoya kopyala")
    }
}
