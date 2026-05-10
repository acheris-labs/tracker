import Darwin
import Foundation

final class MemorySampler {
    private let totalBytes: UInt64
    private let pageSize: UInt64

    init() {
        var ts: UInt64 = 0
        var size = MemoryLayout<UInt64>.size
        sysctlbyname("hw.memsize", &ts, &size, nil, 0)
        self.totalBytes = ts

        var ps: vm_size_t = 0
        host_page_size(mach_host_self(), &ps)
        self.pageSize = UInt64(ps)
    }

    /// Returns memory used (active + wired + compressed) / total physical, in [0, 1].
    /// File cache and inactive memory are excluded — those are reclaimable, so
    /// counting them inflates the number to ~100% on a healthy macOS system.
    func sample() -> Double {
        guard totalBytes > 0 else { return 0 }
        var info = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride
        )
        let kr = withUnsafeMutablePointer(to: &info) { ptr -> kern_return_t in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return 0 }
        let active     = UInt64(info.active_count) * pageSize
        let wired      = UInt64(info.wire_count) * pageSize
        let compressed = UInt64(info.compressor_page_count) * pageSize
        let used = active + wired + compressed
        return min(1.0, Double(used) / Double(totalBytes))
    }
}
