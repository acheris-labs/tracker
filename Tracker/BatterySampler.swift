import Foundation
import IOKit
import IOKit.ps

final class BatterySampler {
    let hasBattery: Bool

    init() {
        self.hasBattery = Self.findInternalBattery() != nil
        if hasBattery {
            NSLog("battery: present")
        } else {
            NSLog("battery: none, line will be hidden")
        }
    }

    /// Returns charge fraction in [0, 1], or nil if no battery / lookup failed.
    func sample() -> Double? {
        guard hasBattery else { return nil }
        return Self.findInternalBattery()
    }

    private static func findInternalBattery() -> Double? {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else { return nil }
        guard let sources = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue()
                as? [CFTypeRef] else { return nil }
        for src in sources {
            guard let desc = IOPSGetPowerSourceDescription(blob, src)?
                    .takeUnretainedValue() as? [String: Any] else { continue }
            guard let type = desc[kIOPSTypeKey] as? String,
                  type == kIOPSInternalBatteryType else { continue }
            if let cur = desc[kIOPSCurrentCapacityKey] as? Int,
               let max = desc[kIOPSMaxCapacityKey] as? Int, max > 0 {
                return Double(cur) / Double(max)
            }
        }
        return nil
    }
}
