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
                            ClipboardRow(item: item, isCopied: copiedID == item.id) {
                                history.copy(item)
                                withAnimation(.snappy) { copiedID = history.items.first?.id }
                                Task {
                                    try? await Task.sleep(for: .seconds(1.2))
                                    withAnimation { copiedID = nil }
                                }
                            } remove: {
                                withAnimation(.snappy) { history.remove(item) }
                            }
                        }
                    }
                }
                HStack {
                    Text("Son \(history.items.count) öğe · sadece bellekte")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                    Spacer()
                    Button("Temizle") { withAnimation(.snappy) { history.clear() } }
                        .buttonStyle(PillButtonStyle(kind: .destructive))
                }
            }
        }
    }
}

private struct ClipboardRow: View {
    let item: ClipboardItem
    let isCopied: Bool
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
                Button(action: remove) { Image(systemName: "trash").font(.system(size: 11)) }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Sil")
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
        .onHover { hovering = $0 }
        .onTapGesture(perform: copy)
        .help("Tıkla: panoya kopyala")
    }
}
