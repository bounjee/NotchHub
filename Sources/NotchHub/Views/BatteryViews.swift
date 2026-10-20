import SwiftUI

/// A drawn battery whose fill follows the charge level.
struct BatteryGlyph: View {
    let percent: Int
    let isCharging: Bool
    let isPluggedIn: Bool

    private var fill: Color {
        if isCharging || isPluggedIn { return .green }
        return percent <= 20 ? .red : .white
    }

    var body: some View {
        HStack(spacing: 1) {
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3.5, style: .continuous)
                    .strokeBorder(.white.opacity(0.4), lineWidth: 1)
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(fill)
                    .frame(width: max(2, 20 * CGFloat(percent) / 100))
                    .padding(2)
                if isCharging || isPluggedIn {
                    Image(systemName: "bolt.fill")
                        .font(.system(size: 7, weight: .heavy))
                        .foregroundStyle(.black)
                        .frame(maxWidth: .infinity)
                }
            }
            .frame(width: 25, height: 12)
            RoundedRectangle(cornerRadius: 1).fill(.white.opacity(0.4)).frame(width: 1.5, height: 4)
        }
        .animation(.smooth, value: percent)
    }
}

struct BatteryBadge: View {
    let battery: BatteryMonitor

    var body: some View {
        if battery.hasBattery {
            HStack(spacing: 6) {
                Text("\(battery.percent)%")
                    .font(.system(size: 12, weight: .medium).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.8))
                    .contentTransition(.numericText(value: Double(battery.percent)))
                BatteryGlyph(percent: battery.percent, isCharging: battery.isCharging, isPluggedIn: battery.isPluggedIn)
            }
        }
    }
}

/// Left side of the charger peek.
struct PowerPeekLeading: View {
    let battery: BatteryMonitor

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: battery.isPluggedIn ? "bolt.fill" : "powerplug")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(battery.isPluggedIn ? .green : .white.opacity(0.7))
                .symbolEffect(.bounce, value: battery.isPluggedIn)
            Text(battery.isPluggedIn ? "Şarjda" : "Pilde")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.85))
        }
        .fixedSize()
    }
}

/// Right side of the charger peek: percentage with a filling battery.
struct PowerPeekTrailing: View {
    let battery: BatteryMonitor
    @State private var shown = 0

    var body: some View {
        HStack(spacing: 4) {
            Text("\(battery.percent)%")
                .font(.system(size: 11, weight: .semibold).monospacedDigit())
                .foregroundStyle(battery.isPluggedIn ? .green : .white)
            BatteryGlyph(percent: shown, isCharging: battery.isCharging, isPluggedIn: battery.isPluggedIn)
        }
        .fixedSize()
        .onAppear {
            shown = 0
            withAnimation(.spring(response: 0.8, dampingFraction: 0.9).delay(0.15)) { shown = battery.percent }
        }
    }
}
