import Foundation
import IOKit

final class GPUSampler {
    private let key: String?

    init() {
        self.key = Self.detectKey()
        if let k = key {
            NSLog("GPU stat key: \(k)")
        } else {
            NSLog("GPU stat key: not found, GPU line will be 0")
        }
    }

    func sample() -> Double {
        guard let key else { return 0 }
        guard let stats = Self.performanceStatistics() else { return 0 }
        guard let raw = stats[key] else { return 0 }
        if let n = raw as? NSNumber {
            return min(1.0, max(0.0, n.doubleValue / 100.0))
        }
        return 0
    }

    private static func detectKey() -> String? {
        guard let stats = performanceStatistics() else { return nil }
        let candidates = [
            "Device Utilization %",
            "GPU Core Utilization",
            "GPU Activity(%)",
            "Renderer Utilization %",
        ]
        for k in candidates where stats[k] != nil {
            return k
        }
        return nil
    }

    private static func performanceStatistics() -> [String: Any]? {
        let matching = IOServiceMatching("IOAccelerator")
        var iter: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iter) == KERN_SUCCESS else {
            return nil
        }
        defer { IOObjectRelease(iter) }
        let entry = IOIteratorNext(iter)
        guard entry != 0 else { return nil }
        defer { IOObjectRelease(entry) }
        guard let prop = IORegistryEntryCreateCFProperty(
            entry, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0
        ) else { return nil }
        return prop.takeRetainedValue() as? [String: Any]
    }
}
