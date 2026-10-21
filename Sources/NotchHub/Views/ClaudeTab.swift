import AppKit
import SwiftUI

struct ClaudeTab: View {
    let store: ClaudeStore

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
                            jump: session.terminal == nil ? nil : { store.jumpToTerminal(session.id) },
                            dismiss: { withAnimation(.snappy) { store.dismiss(session.id) } }
                        )
                        .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                }
            }
        }
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
                Image(systemName: "hand.raised.fill")
                    .foregroundStyle(Color.claude)
                    .symbolEffect(.pulse, options: .repeating)
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

/// One line per session, like the rows of a list: click it to go to its terminal.
private struct SessionRow: View {
    let session: ClaudeSession
    let jump: (() -> Void)?
    let dismiss: () -> Void
    @State private var hovering = false
    @State private var copied = false

    /// Claude is waiting on the user, so the way to its terminal stays visible.
    private var needsYou: Bool { session.status == .waitingForUser || session.status == .needsApproval }
    private var isFinished: Bool { session.status == .done || session.status == .error }

    var body: some View {
        HStack(spacing: 10) {
            StatusIndicator(status: session.status)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(session.label).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    Text(session.status.title).font(.system(size: 12)).foregroundStyle(session.status.tint).fixedSize()
                    if session.unseen {
                        Circle().fill(session.status.tint).frame(width: 5, height: 5)
                            .help("Henüz bakmadın")
                    }
                }
                Text(detail)
                    .font(.system(size: 11, design: session.currentTool != nil && !isFinished ? .monospaced : .default))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 8)
            if hovering {
                HStack(spacing: 2) {
                    if isFinished, let message = session.lastMessage {
                        iconButton(copied ? "checkmark" : "doc.on.doc", help: "Cevabı kopyala") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(message, forType: .string)
                            withAnimation(.snappy) { copied = true }
                            Task { try? await Task.sleep(for: .seconds(1.5)); copied = false }
                        }
                    }
                    if let jump { iconButton("arrow.up.forward.app", help: "Terminale git", action: jump) }
                    if isFinished { iconButton("xmark", help: "Listeden kaldır", action: dismiss) }
                }
                .transition(.opacity)
            } else if let jump, needsYou {
                iconButton("arrow.up.forward.app", help: "Terminale git", tint: session.status.tint, action: jump)
            } else {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(shortElapsed(from: session.statusSince, to: context.date))
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(hovering && jump != nil ? .white.opacity(0.1) : Color.cardFill))
        .contentShape(RoundedRectangle(cornerRadius: 12))
        .onTapGesture { jump?() }
        .onHover { isHovering in withAnimation(.snappy(duration: 0.15)) { hovering = isHovering } }
        .help(isFinished ? (session.lastMessage ?? "") : (jump == nil ? "" : "Tıkla: terminale git"))
    }

    /// The second line: the current tool while working, the answer's first line when finished.
    private var detail: String {
        switch session.status {
        case .working, .needsApproval:
            return session.currentTool ?? "Düşünüyor…"
        case .waitingForUser:
            return session.lastMessage.map(Self.firstLine) ?? "Cevabını bekliyor"
        case .done, .error:
            return session.lastMessage.map(Self.firstLine) ?? session.status.title
        case .idle:
            return "Hazır"
        }
    }

    /// First meaningful line of a Markdown answer, without its markup.
    static func firstLine(_ text: String) -> String {
        let line = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty && !$0.hasPrefix("```") } ?? ""
        return line
            .replacingOccurrences(of: #"^#+\s*|^[-*]\s+"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "`", with: "")
    }

    private func iconButton(_ symbol: String, help: String, tint: Color? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11.5, weight: .semibold))
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(tint.map { AnyShapeStyle($0) } ?? AnyShapeStyle(.secondary))
        .help(help)
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
