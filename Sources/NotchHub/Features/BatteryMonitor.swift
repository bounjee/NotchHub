import Foundation
import IOKit.ps
import Observation

@MainActor @Observable
final class BatteryMonitor {
    private(set) var percent = 0
    private(set) var isCharging = false
    private(set) var isPluggedIn = false
    private(set) var hasBattery = false

    /// Called when the adapter is connected or disconnected.
    var onPowerSourceChange: (() -> Void)?

    private var source: CFRunLoopSource?

    func start() {
        refresh(notify: false)
        let context = Unmanaged.passUnretained(self).toOpaque()
        source = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            let monitor = Unmanaged<BatteryMonitor>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { monitor.refresh(notify: true) }
        }, context)?.takeRetainedValue()
        if let source { CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode) }
    }

    private func refresh(notify: Bool) {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef]
        else { return }
        for item in list {
            guard let description = IOPSGetPowerSourceDescription(info, item)?.takeUnretainedValue() as? [String: Any],
                  (description[kIOPSTypeKey] as? String) == kIOPSInternalBatteryType
            else { continue }
            let current = description[kIOPSCurrentCapacityKey] as? Int ?? 0
            let max = description[kIOPSMaxCapacityKey] as? Int ?? 100
            let plugged = (description[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue
            let changed = hasBattery && plugged != isPluggedIn

            hasBattery = true
            percent = max > 0 ? Int((Double(current) / Double(max) * 100).rounded()) : current
            isCharging = description[kIOPSIsChargingKey] as? Bool ?? false
            isPluggedIn = plugged
            if notify && changed { onPowerSourceChange?() }
            return
        }
    }
}
