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
                    Text("Clipboard access is off. Allow NotchHub to read the clipboard in System Settings.")
                        .font(.system(size: 12))
                    Spacer()
                    Button("Open Settings") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Pasteboard")!)
                    }
                    .buttonStyle(PillButtonStyle(kind: .secondary))
                }
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.orange.opacity(0.12)))
            }

            if history.items.isEmpty {
                EmptyState(symbol: "doc.on.clipboard", title: String(localized: "No clipboard history"),
                           detail: String(localized: "Text you copy shows up here. The history is kept in memory only."))
            } else {
                AutoScroll {
                    LazyVStack(spacing: 4) {
                        ForEach(history.items) { item in
                            ClipboardRow(item: item, isCopied: copiedID == item.id, togglePin: {
                                withAnimation(.snappy) { history.togglePin(item) }
                            }, formatJSON: {
                                history.copyFormattedJSON(item)
                                withAnimation(.snappy) { copiedID = history.items.first { !$0.isPinned }?.id }
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
                    Text("^[\(history.items.count) item](inflect: true) · in memory only · click to copy")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                    Spacer()
                    Button(history.items.contains(where: \.isPinned) ? String(localized: "Clear Unpinned") : String(localized: "Clear")) {
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
    let formatJSON: () -> Void
    let copy: () -> Void
    let remove: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            preview
                .frame(maxWidth: .infinity, alignment: .leading)
            if isCopied {
                Label("Copied", systemImage: "checkmark")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.green)
                    .transition(.opacity.combined(with: .scale(scale: 0.8)))
            } else if hovering {
                HStack(spacing: 10) {
                    if case .link(let url) = item.kind {
                        Button { NSWorkspace.shared.open(url) } label: { Image(systemName: "safari").font(.system(size: 11)) }
                            .help(String(localized: "Open in Browser"))
                    }
                    if item.kind == .json {
                        Button(action: formatJSON) { Image(systemName: "curlybraces").font(.system(size: 11)) }
                            .help(String(localized: "Copy Formatted"))
                    }
                    Button(action: togglePin) {
                        Image(systemName: item.isPinned ? "pin.slash" : "pin").font(.system(size: 11))
                    }
                    .help(item.isPinned ? String(localized: "Unpin") : String(localized: "Pin"))
                    Button(action: remove) { Image(systemName: "trash").font(.system(size: 11)) }
                        .help(String(localized: "Delete"))
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
                    Text(verbatim: seconds < 10 ? String(localized: "now") : shortElapsed(from: item.copiedAt, to: context.date))
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
        .help(String(localized: "Click to copy"))
    }

    private var trimmed: String { item.text.trimmingCharacters(in: .whitespacesAndNewlines) }

    @ViewBuilder
    private var preview: some View {
        switch item.kind {
        case .color(let red, let green, let blue, let alpha):
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(Color(.sRGB, red: red, green: green, blue: blue, opacity: alpha))
                    .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(.white.opacity(0.25), lineWidth: 0.5))
                    .frame(width: 18, height: 18)
                Text(verbatim: trimmed).font(.system(size: 12, design: .monospaced))
            }
        case .link(let url):
            HStack(spacing: 7) {
                Image(systemName: "link").font(.system(size: 10.5, weight: .semibold)).foregroundStyle(.blue)
                Text(verbatim: url.host() ?? "").font(.system(size: 12, weight: .semibold))
                + Text(verbatim: String(trimmed.dropFirst((url.scheme?.count ?? 0) + 3 + (url.host()?.count ?? 0))))
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            .lineLimit(1)
            .truncationMode(.middle)
        case .json:
            HStack(spacing: 7) {
                Text(verbatim: "JSON")
                    .font(.system(size: 9, weight: .bold))
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .background(Capsule().fill(.yellow.opacity(0.2)))
                    .foregroundStyle(.yellow)
                Text(verbatim: trimmed).font(.system(size: 11.5, design: .monospaced)).lineLimit(2)
            }
        case .code:
            Text(verbatim: trimmed).font(.system(size: 11.5, design: .monospaced)).lineLimit(3)
        case .text:
            Text(verbatim: trimmed).font(.system(size: 12)).lineLimit(2)
        }
    }
}
