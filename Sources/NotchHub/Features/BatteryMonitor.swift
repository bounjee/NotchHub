import Foundation
import IOKit.ps
import Observation

@MainActor @Observable
final class BatteryMonitor {
    enum Event: Equatable { case pluggedChanged, charged, low }

    private(set) var percent = 0
    private(set) var isCharging = false
    private(set) var isPluggedIn = false
    private(set) var hasBattery = false

    static let lowThreshold = 20

    var onEvent: ((Event) -> Void)?

    private var source: CFRunLoopSource?
    /// Each warning fires once until the power state resets it.
    private var warnedLow = false
    private var announcedCharged = false

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
            let percent = max > 0 ? Int((Double(current) / Double(max) * 100).rounded()) : current
            let plugged = (description[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue
            let charging = description[kIOPSIsChargingKey] as? Bool ?? false
            let events = update(percent: percent, plugged: plugged, charging: charging)
            if notify { events.forEach { onEvent?($0) } }
            return
        }
    }

    /// Applies a new reading and returns the events it causes.
    @discardableResult
    func update(percent: Int, plugged: Bool, charging: Bool) -> [Event] {
        var events: [Event] = []
        let isFull = plugged && percent >= 100
        let isLow = !plugged && percent <= Self.lowThreshold
        if !hasBattery {
            // The state at launch is not news.
            announcedCharged = isFull
            warnedLow = isLow
        } else {
            if plugged != isPluggedIn { events.append(.pluggedChanged) }
            if isFull && !announcedCharged { events.append(.charged) }
            if isLow && !warnedLow { events.append(.low) }
            if plugged { warnedLow = false } else { announcedCharged = false }
            if isFull { announcedCharged = true }
            if isLow { warnedLow = true }
        }
        hasBattery = true
        self.percent = percent
        isCharging = charging
        isPluggedIn = plugged
        return events
    }
}
