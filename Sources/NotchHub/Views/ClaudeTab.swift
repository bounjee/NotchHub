import AppKit
import SwiftUI

struct ClaudeTab: View {
    let store: ClaudeStore
    @State private var expanded: ClaudeSession.ID?

    var body: some View {
        if store.sessions.isEmpty && store.pending.isEmpty {
            VStack(spacing: 8) {
                UsageSummary(limits: store.limits)
                HStack(spacing: 14) {
                    ClawdView(status: .idle, pixel: 2.2)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Aktif Claude Code oturumu yok").font(.system(size: 13, weight: .medium))
                        Text(store.hooksInstalled ? "Bir terminalde claude çalıştır, durumu burada görünür." : "Menü çubuğundaki NotchHub menüsünden hook'ları kur.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(14)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.cardFill))
            }
        } else {
            AutoScroll {
                VStack(spacing: 8) {
                    UsageSummary(limits: store.limits)
                    ForEach(store.pending) { request in
                        PermissionCard(
                            request: request,
                            sessionLabel: store.sessions[request.sessionID]?.label ?? "Claude",
                            jump: store.sessions[request.sessionID]?.terminal == nil ? nil : { store.jumpToTerminal(request.sessionID) },
                            answer: { decision in withAnimation(.snappy) { store.answer(request.id, decision) } }
                        )
                        .transition(.move(edge: .top).combined(with: .opacity))
                    }
                    ForEach(store.sortedSessions.filter { session in !store.pending.contains { $0.sessionID == session.id } }) { session in
                        SessionRow(
                            session: session,
                            isExpanded: expanded == session.id || (expanded == nil && session.id == defaultExpanded),
                            toggle: { withAnimation(.snappy) { expanded = expanded == session.id ? "" : session.id } },
                            jump: session.terminal == nil ? nil : { store.jumpToTerminal(session.id) },
                            dismiss: { withAnimation(.snappy) { store.dismiss(session.id) } }
                        )
                    }
                }
            }
        }
    }

    /// The most recent finished session shows its answer without a click.
    private var defaultExpanded: ClaudeSession.ID? {
        store.sortedSessions.first { $0.status == .done && $0.lastMessage != nil }?.id
    }
}

private struct PermissionCard: View {
    let request: PendingPermission
    let sessionLabel: String
    let jump: (() -> Void)?
    let answer: (PermissionDecision) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                ClawdView(status: .needsApproval, pixel: 1)
                Text("İzin gerekiyor").fontWeight(.semibold)
                Text("· \(sessionLabel)").foregroundStyle(.secondary)
                Spacer()
                Text(request.toolName)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(Capsule().fill(Color.claude.opacity(0.22)))
                    .foregroundStyle(Color.claude)
            }
            .font(.system(size: 13))

            if !request.summary.isEmpty {
                Text(request.summary)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(4)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.white.opacity(0.06)))
            }

            HStack(spacing: 8) {
                if let jump {
                    Button(action: jump) {
                        Label("Terminalde cevapla", systemImage: "arrow.up.forward.app")
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                } else {
                    Text("Terminalden de cevaplayabilirsin")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                Button("Reddet") { answer(.deny) }
                    .buttonStyle(PillButtonStyle(kind: .secondary))
                if request.suggestions != nil {
                    Button("Her zaman") { answer(.allowAlways) }
                        .buttonStyle(PillButtonStyle(kind: .secondary))
                        .help("İzin ver ve Claude Code'un önerdiği kuralı kaydet")
                }
                Button("İzin ver") { answer(.allow) }
                    .buttonStyle(PillButtonStyle(kind: .primary))
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.claude.opacity(0.1))
                .strokeBorder(Color.claude.opacity(0.35), lineWidth: 1)
        )
    }
}

private struct SessionRow: View {
    let session: ClaudeSession
    let isExpanded: Bool
    let toggle: () -> Void
    let jump: (() -> Void)?
    let dismiss: () -> Void
    @State private var copied = false
    @State private var hovering = false
    /// The answer starts as a short preview; the full text is one click away.
    @State private var showsFullMessage = false

    /// Claude is waiting on the user, so the way to its terminal stays visible.
    private var needsYou: Bool { session.status == .waitingForUser || session.status == .needsApproval }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Buttons must not sit inside another button: the outer one swallows their clicks.
            HStack(spacing: 10) {
                HStack(spacing: 10) {
                    StatusIndicator(status: session.status)
                        .frame(width: 16)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(session.label).font(.system(size: 13, weight: .semibold))
                            Text(session.status.title).font(.system(size: 12)).foregroundStyle(session.status.tint)
                        }
                        if let detail = session.currentTool ?? (isExpanded ? nil : session.lastMessage) {
                            Text(detail.replacingOccurrences(of: "\n", with: " "))
                                .font(.system(size: 11, design: session.currentTool != nil ? .monospaced : .default))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: 8)
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text(shortElapsed(from: session.statusSince, to: context.date))
                            .font(.system(size: 11).monospacedDigit())
                            .foregroundStyle(.tertiary)
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture(perform: toggle)

                if let jump, hovering || needsYou {
                    Button(action: jump) {
                        Image(systemName: "arrow.up.forward.app")
                            .font(.system(size: 12, weight: .semibold))
                            .frame(width: 22, height: 22)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(needsYou ? AnyShapeStyle(session.status.tint) : AnyShapeStyle(.secondary))
                    .help("Terminale git")
                    .transition(.opacity)
                }
                if hovering && (session.status == .done || session.status == .error) {
                    Button(action: dismiss) {
                        Image(systemName: "xmark")
                            .font(.system(size: 9, weight: .bold))
                            .frame(width: 18, height: 22)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Listeden kaldır")
                }
            }

            if isExpanded, let message = session.lastMessage {
                VStack(alignment: .leading, spacing: 6) {
                    if showsFullMessage {
                        AutoScroll(maxHeight: 170) { messageText(message) }
                    } else {
                        messageText(Self.preview(message))
                            .lineLimit(3)
                    }
                    HStack(spacing: 8) {
                        if Self.preview(message) != message || message.count > 220 {
                            Button(showsFullMessage ? "Daralt" : "Tamamını göster") {
                                withAnimation(.snappy) { showsFullMessage.toggle() }
                            }
                            .buttonStyle(.plain)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Color.accentColor)
                        }
                        Spacer()
                        if let jump {
                            Button(action: jump) { Label("Terminale git", systemImage: "arrow.up.forward.app") }
                                .buttonStyle(PillButtonStyle(kind: .secondary))
                        }
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(message, forType: .string)
                            copied = true
                            Task { try? await Task.sleep(for: .seconds(1.5)); copied = false }
                        } label: {
                            Label(copied ? "Kopyalandı" : "Kopyala", systemImage: copied ? "checkmark" : "doc.on.doc")
                                .contentTransition(.symbolEffect(.replace))
                        }
                        .buttonStyle(PillButtonStyle(kind: .secondary))
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.cardFill))
        .onHover { hovering = $0 }
    }

    private func messageText(_ text: String) -> some View {
        Text(Self.markdown(text))
            .font(.system(size: 12.5))
            .foregroundStyle(.white.opacity(0.88))
            .lineSpacing(2)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// The first paragraph, without blank lines, headings markers or code fences.
    static func preview(_ text: String) -> String {
        let lines = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("```") }
            .map { $0.replacingOccurrences(of: #"^#+\s*"#, with: "", options: .regularExpression) }
        return lines.prefix(3).joined(separator: "\n")
    }

    static func markdown(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }

}

func shortElapsed(from start: Date, to now: Date) -> String {
    let seconds = max(0, Int(now.timeIntervalSince(start)))
    if seconds < 60 { return "\(seconds) sn" }
    if seconds < 3600 { return "\(seconds / 60) dk" }
    return "\(seconds / 3600) sa"
}

extension SessionStatus {
    var title: String {
        switch self {
        case .idle: "Hazır"
        case .working: "Çalışıyor"
        case .needsApproval: "İzin bekliyor"
        case .waitingForUser: "Seni bekliyor"
        case .done: "Bitti"
        case .error: "Hata"
        }
    }

    var tint: Color {
        switch self {
        case .idle: .secondary
        case .working: .white.opacity(0.75)
        case .needsApproval: .claude
        case .waitingForUser: .blue
        case .done: .green
        case .error: .red
        }
    }
}

/// Small status glyph used in the closed notch and in session rows.
struct StatusIndicator: View {
    let status: SessionStatus

    var body: some View {
        Group {
            switch status {
            case .working:
                LayerSpinner(color: NSColor(Color.claude))
            case .needsApproval:
                LayerPulseDot(color: NSColor(Color.claude))
            case .waitingForUser:
                Circle().fill(.blue).frame(width: 7, height: 7)
            case .done:
                Image(systemName: "checkmark.circle.fill").font(.system(size: 12)).foregroundStyle(.green)
                    .transition(.scale.combined(with: .opacity))
            case .error:
                Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 11)).foregroundStyle(.red)
            case .idle:
                Circle().strokeBorder(.white.opacity(0.4), lineWidth: 1.5).frame(width: 8, height: 8)
            }
        }
        .frame(height: 14)
    }
}

struct EmptyState: View {
    let symbol: String
    let title: String
    let detail: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 20, weight: .light))
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .medium))
                Text(detail).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.cardFill))
    }
}

struct PillButtonStyle: ButtonStyle {
    enum Kind { case primary, secondary, destructive }
    var kind: Kind

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .padding(.horizontal, 12)
            .frame(height: 26)
            .foregroundStyle(kind == .primary ? .white : kind == .destructive ? .red : .white.opacity(0.9))
            .background(Capsule().fill(background))
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(.snappy(duration: 0.15), value: configuration.isPressed)
            .contentShape(Capsule())
    }

    private var background: Color {
        switch kind {
        case .primary: .claude
        case .secondary: .white.opacity(0.12)
        case .destructive: .red.opacity(0.15)
        }
    }
}
