import Foundation
import IOKit.ps

/// The internal battery, read from IOKit's power-source list. A Mac without one
/// reads nil, so a battery guard never trips on a desktop.
enum PowerSource {
    static func reading() -> BatteryReading? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef]
        else { return nil }
        for source in list {
            guard let d = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue()
                    as? [String: Any],
                  d[kIOPSTypeKey] as? String == kIOPSInternalBatteryType
            else { continue }
            return reading(from: d)
        }
        return nil
    }

    /// Split out so the arithmetic is testable without a battery.
    static func reading(from d: [String: Any]) -> BatteryReading? {
        guard let current = d[kIOPSCurrentCapacityKey] as? Int,
              let max = d[kIOPSMaxCapacityKey] as? Int, max > 0 else { return nil }
        let state = d[kIOPSPowerSourceStateKey] as? String
        return BatteryReading(onBattery: state == kIOPSBatteryPowerValue,
                              percent: Int((Double(current) / Double(max) * 100).rounded()))
    }

    /// Calls `handler` on the main run loop whenever the power situation changes —
    /// plugged in, unplugged, a percent gone. Only installed while a mode is on:
    /// nobody needs the battery watched for a feature that is off.
    final class Watch {
        private var source: CFRunLoopSource?
        private let handler: () -> Void

        init(_ handler: @escaping () -> Void) {
            self.handler = handler
            let context = Unmanaged.passUnretained(self).toOpaque()
            source = IOPSNotificationCreateRunLoopSource({ ctx in
                guard let ctx else { return }
                Unmanaged<Watch>.fromOpaque(ctx).takeUnretainedValue().handler()
            }, context)?.takeRetainedValue()
            if let source { CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode) }
        }

        deinit {
            if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .defaultMode) }
        }
    }
}
