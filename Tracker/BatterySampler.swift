import Foundation
import IOKit
import IOKit.ps

struct BatteryInfo {
    let percent: Double          // 0..1
    let watts: Double            // signed: positive = charging, negative = discharging
    let isCharging: Bool
    let externalConnected: Bool  // AC adapter present
    let minutesToFull: Int?      // nil unless actively charging with a known ETA
    let minutesToEmpty: Int?     // nil unless on battery with a known ETA
}

final class BatterySampler {
    let hasBattery: Bool

    init() {
        self.hasBattery = (Self.readSmart() != nil) || (Self.readIOPS() != nil)
        if hasBattery {
            NSLog("battery: present")
        } else {
            NSLog("battery: none, line will be hidden")
        }
    }

    /// Returns latest battery info, or nil if no battery / lookup failed.
    func sample() -> BatteryInfo? {
        guard hasBattery else { return nil }
        return Self.readSmart() ?? Self.readIOPS()
    }

    // MARK: - AppleSmartBattery (preferred — has instantaneous current)

    private static func readSmart() -> BatteryInfo? {
        let entry = IOServiceGetMatchingService(
            kIOMainPortDefault,
            IOServiceMatching("AppleSmartBattery")
        )
        guard entry != 0 else { return nil }
        defer { IOObjectRelease(entry) }

        var propsRef: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(entry, &propsRef, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let dict = propsRef?.takeRetainedValue() as? [String: Any] else {
            return nil
        }

        guard let cur = dict["AppleRawCurrentCapacity"] as? Int,
              let mx  = dict["AppleRawMaxCapacity"] as? Int, mx > 0 else {
            return nil
        }
        let pct = min(1.0, Double(cur) / Double(mx))

        let isCharging = (dict["IsCharging"] as? Bool) ?? false
        let extConnected = (dict["ExternalConnected"] as? Bool) ?? false
        // Sign convention varies across hardware; take magnitude and apply
        // sign from IsCharging / discharging.
        let ampRaw = (dict["InstantAmperage"] as? Int) ?? (dict["Amperage"] as? Int) ?? 0
        let voltRaw = (dict["Voltage"] as? Int) ?? 0
        let watts = Double(abs(ampRaw)) * Double(voltRaw) / 1_000_000.0
        let signed: Double = isCharging ? watts : (extConnected ? 0 : -watts)

        // AvgTimeTo* are reported in minutes. 0 or 65535 mean "calculating /
        // not applicable" — surface those as nil. Only populate the half
        // matching the current power flow.
        func valid(_ m: Int?) -> Int? {
            guard let m, m > 0, m < 65535 else { return nil }
            return m
        }
        let f = valid(dict["AvgTimeToFull"] as? Int)
        let e = valid(dict["AvgTimeToEmpty"] as? Int)
        let mFull  = isCharging ? f : nil
        let mEmpty = (!extConnected) ? e : nil

        return BatteryInfo(percent: pct, watts: signed,
                           isCharging: isCharging, externalConnected: extConnected,
                           minutesToFull: mFull, minutesToEmpty: mEmpty)
    }

    // MARK: - IOPS fallback (percent only)

    private static func readIOPS() -> BatteryInfo? {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else { return nil }
        guard let sources = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue()
                as? [CFTypeRef] else { return nil }
        for src in sources {
            guard let desc = IOPSGetPowerSourceDescription(blob, src)?
                    .takeUnretainedValue() as? [String: Any] else { continue }
            guard let type = desc[kIOPSTypeKey] as? String,
                  type == kIOPSInternalBatteryType else { continue }
            if let cur = desc[kIOPSCurrentCapacityKey] as? Int,
               let mx  = desc[kIOPSMaxCapacityKey] as? Int, mx > 0 {
                let pct = Double(cur) / Double(mx)
                let isCharging = (desc[kIOPSIsChargingKey] as? Bool) ?? false
                let extConnected = (desc[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue
                let f = (desc[kIOPSTimeToFullChargeKey] as? Int).flatMap {
                    ($0 > 0 && $0 < 65535) ? $0 : nil
                }
                let e = (desc[kIOPSTimeToEmptyKey] as? Int).flatMap {
                    ($0 > 0 && $0 < 65535) ? $0 : nil
                }
                return BatteryInfo(percent: pct, watts: 0,
                                   isCharging: isCharging,
                                   externalConnected: extConnected,
                                   minutesToFull: isCharging ? f : nil,
                                   minutesToEmpty: extConnected ? nil : e)
            }
        }
        return nil
    }
}
