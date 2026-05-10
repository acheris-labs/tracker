import Foundation
import IOKit

/// System-wide disk throughput in bytes/second, summed across all
/// IOBlockStorageDriver instances. First call returns zeros (baseline).
final class DiskSampler {
    private var prevRead: UInt64 = 0
    private var prevWrite: UInt64 = 0
    private var prevAt: TimeInterval = 0
    private var primed = false

    func sample() -> (readBps: Double, writeBps: Double) {
        let now = Date().timeIntervalSinceReferenceDate
        let (read, write) = Self.totals()
        defer {
            prevRead = read
            prevWrite = write
            prevAt = now
            primed = true
        }
        guard primed, now > prevAt else { return (0, 0) }
        let dt = now - prevAt
        let dr = read >= prevRead ? Double(read - prevRead) : 0
        let dw = write >= prevWrite ? Double(write - prevWrite) : 0
        return (dr / dt, dw / dt)
    }

    private static func totals() -> (read: UInt64, write: UInt64) {
        var iter: io_iterator_t = 0
        guard IOServiceGetMatchingServices(
            kIOMainPortDefault,
            IOServiceMatching("IOBlockStorageDriver"),
            &iter
        ) == KERN_SUCCESS else { return (0, 0) }
        defer { IOObjectRelease(iter) }

        var read: UInt64 = 0
        var write: UInt64 = 0
        while case let entry = IOIteratorNext(iter), entry != 0 {
            defer { IOObjectRelease(entry) }
            guard let prop = IORegistryEntryCreateCFProperty(
                entry, "Statistics" as CFString, kCFAllocatorDefault, 0
            )?.takeRetainedValue() as? [String: Any] else { continue }
            if let r = prop["Bytes (Read)"] as? NSNumber {
                read &+= r.uint64Value
            }
            if let w = prop["Bytes (Write)"] as? NSNumber {
                write &+= w.uint64Value
            }
        }
        return (read, write)
    }
}
