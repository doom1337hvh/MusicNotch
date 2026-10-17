import Foundation
import IOKit.ps
import Observation

/// Whether the Mac is on battery or in Low Power Mode. Notified only when either
/// changes, so it costs nothing while idle.
@Observable @MainActor
final class PowerMonitor {
    private(set) var isOnBattery = false
    private(set) var isLowPowerMode = false

    @ObservationIgnored private var runLoopSource: CFRunLoopSource?

    init() {
        refresh()
        let context = Unmanaged.passUnretained(self).toOpaque()
        // Fires on switches between battery and external power, not on every percent of charge.
        if let source = IOPSCreateLimitedPowerNotification({ context in
            guard let context else { return }
            let monitor = Unmanaged<PowerMonitor>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { monitor.refresh() }
        }, context)?.takeRetainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
            runLoopSource = source
        }
        NotificationCenter.default.addObserver(
            forName: Notification.Name.NSProcessInfoPowerStateDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    private func refresh() {
        let info = IOPSCopyPowerSourcesInfo().takeRetainedValue()
        let source = IOPSGetProvidingPowerSourceType(info).takeUnretainedValue() as String
        let onBattery = source == kIOPSBatteryPowerValue
        let lowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
        if onBattery != isOnBattery { isOnBattery = onBattery }
        if lowPowerMode != isLowPowerMode { isLowPowerMode = lowPowerMode }
    }
}
