import SwiftUI

extension UsageWindow {
    var level: Color {
        switch usedPercentage {
        case ..<60: .green
        case ..<85: .orange
        default: .red
        }
    }

    func resetText(from now: Date = Date()) -> String {
        let seconds = max(0, Int(resetsAt.timeIntervalSince(now)))
        let days = seconds / 86_400, hours = seconds % 86_400 / 3600, minutes = seconds % 3600 / 60
        if days > 0 { return "\(days) gün \(hours) sa" }
        if hours > 0 { return "\(hours) sa \(minutes) dk" }
        return "\(max(1, minutes)) dk"
    }
}

/// Small ring with the five-hour usage, shown beside the battery while open.
struct UsageRing: View {
    let limits: UsageLimits

    var body: some View {
        if let window = limits.current().fiveHour {
            HStack(spacing: 5) {
                ZStack {
                    Circle().stroke(.white.opacity(0.15), lineWidth: 2.2)
                    Circle()
                        .trim(from: 0, to: min(1, window.usedPercentage / 100))
                        .stroke(window.level, style: StrokeStyle(lineWidth: 2.2, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }
                .frame(width: 12, height: 12)
                Text("\(Int(window.usedPercentage.rounded()))%")
                    .font(.system(size: 12, weight: .medium).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.8))
            }
            .help("Claude 5 saatlik kullanım · \(window.resetText()) sonra sıfırlanır")
            .animation(.smooth, value: window.usedPercentage)
        }
    }
}

/// Five-hour and weekly plan usage at the top of the Claude tab.
struct UsageSummary: View {
    let limits: UsageLimits

    var body: some View {
        let current = limits.current()
        if !current.isEmpty {
            TimelineView(.periodic(from: .now, by: 30)) { context in
                HStack(spacing: 14) {
                    if let window = current.fiveHour { bar("5 saat", window, now: context.date) }
                    if let window = current.sevenDay { bar("7 gün", window, now: context.date) }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.cardFill))
        }
    }

    private func bar(_ title: String, _ window: UsageWindow, now: Date) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Text(title).font(.system(size: 11, weight: .semibold))
                Text("\(Int(window.usedPercentage.rounded()))%")
                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
                    .foregroundStyle(window.level)
                Spacer(minLength: 4)
                Text("\(window.resetText(from: now)) sonra sıfırlanır")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.1))
                    Capsule()
                        .fill(window.level.gradient)
                        .frame(width: max(4, proxy.size.width * min(1, window.usedPercentage / 100)))
                }
            }
            .frame(height: 5)
        }
        .frame(maxWidth: .infinity)
    }
}
