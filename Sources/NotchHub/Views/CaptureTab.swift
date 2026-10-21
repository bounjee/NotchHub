import AppKit
import SwiftUI

/// One click screenshots to the clipboard, and screen recordings stopped from the notch.
struct CaptureTab: View {
    let capture: ScreenCapture

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !capture.hasPermission {
                PermissionBanner(capture: capture)
            }

            section(String(localized: "Screenshot"), note: String(localized: "Goes straight to the clipboard"))
            HStack(spacing: 8) {
                CaptureButton(title: String(localized: "Area"), symbol: "rectangle.dashed") { capture.take(.area) }
                CaptureButton(title: String(localized: "Window"), symbol: "macwindow") { capture.take(.window) }
                CaptureButton(title: String(localized: "Full screen"), symbol: "display") { capture.take(.screen) }
            }

            section(String(localized: "Recording"), note: String(localized: "Saved in Movies › NotchHub and copied as a file"))
            if let since = capture.recordingSince {
                StopButton(since: since) { capture.stopRecording() }
            } else {
                HStack(spacing: 8) {
                    CaptureButton(title: String(localized: "Record screen"), symbol: "record.circle") { capture.startRecording(.screen) }
                    CaptureButton(title: String(localized: "Record a window"), symbol: "macwindow.badge.plus") { capture.startRecording(.picked) }
                }
            }

            if let error = capture.lastError {
                Text(verbatim: error)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
            }
        }
        .onAppear { capture.refreshPermission() }
    }

    private func section(_ title: String, note: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(verbatim: title).font(.system(size: 12, weight: .semibold))
            Text(verbatim: note).font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }
}

private struct CaptureButton: View {
    let title: String
    let symbol: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: symbol).font(.system(size: 18, weight: .regular)).frame(height: 22)
                Text(verbatim: title).font(.system(size: 11.5, weight: .medium))
            }
            .frame(maxWidth: .infinity)
            .frame(height: 64)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(hovering ? .white.opacity(0.12) : Color.cardFill))
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .onHover { isHovering in withAnimation(.snappy(duration: 0.15)) { hovering = isHovering } }
    }
}

private struct StopButton: View {
    let since: Date
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: "stop.fill").font(.system(size: 13, weight: .bold))
                Text("Stop recording").font(.system(size: 13, weight: .semibold))
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let seconds = max(0, Int(context.date.timeIntervalSince(since)))
                    Text(verbatim: String(format: "%d:%02d", seconds / 60, seconds % 60))
                        .font(.system(size: 13, weight: .semibold).monospacedDigit())
                        .opacity(0.8)
                }
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .frame(height: 64)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.red.opacity(0.85)))
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
    }
}

private struct PermissionBanner: View {
    let capture: ScreenCapture

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "lock.fill").foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("NotchHub needs Screen Recording permission").font(.system(size: 12, weight: .medium))
                Text("Turn it on in System Settings, then reopen NotchHub.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Open Settings") { capture.requestPermission() }
                .buttonStyle(PillButtonStyle(kind: .secondary))
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.orange.opacity(0.12)))
    }
}
