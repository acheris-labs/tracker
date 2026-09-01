import Darwin
import Foundation

/// The system memory picture Activity Monitor's Memory tab reports.
///
/// The category definitions are its, verified against a live side-by-side
/// sample: App Memory, Wired, Compressed and Cached Files each matched to the
/// displayed hundredth of a GiB.
///
/// `used` is Apple's documented definition — App + Wired + Compressed — and so
/// agrees with the three parts we show. Activity Monitor's own "Memory Used"
/// runs ~1.8 GiB higher on Apple Silicon than those three sum to, from
/// something the public VM counters don't expose (most likely unified-memory
/// allocations made on the GPU/kernel side); rather than invent a fudge to
/// chase it, this reports a number that adds up.
struct MemoryBreakdown {
    var total = 0.0          // bytes of physical RAM
    var app = 0.0            // anonymous pages, less purgeable
    var wired = 0.0          // can't be paged out
    var compressed = 0.0     // what the compressor actually occupies
    var cachedFiles = 0.0    // file-backed + purgeable: reclaimable on demand
    var swapUsed = 0.0
    /// App + Wired + Compressed.
    var used: Double { app + wired + compressed }
    /// Roughly what drives Activity Monitor's pressure graph: the share of RAM
    /// held in pages the system cannot simply drop.
    var pressure: Double { total > 0 ? min(1, (wired + compressed) / total) : 0 }
    /// kern.memorystatus_vm_pressure_level: 1 normal, 2 warning, 4 critical.
    var pressureLevel: Int32 = 1
}

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
        guard totalBytes > 0, let info = vmStats() else { return 0 }
        let active     = UInt64(info.active_count) * pageSize
        let wired      = UInt64(info.wire_count) * pageSize
        let compressed = UInt64(info.compressor_page_count) * pageSize
        let used = active + wired + compressed
        return min(1.0, Double(used) / Double(totalBytes))
    }

    /// The full picture behind the Memory tab's footer.
    func breakdown() -> MemoryBreakdown {
        var b = MemoryBreakdown(total: Double(totalBytes))
        b.swapUsed = SwapUsage.current().used
        b.pressureLevel = Self.pressureLevel()
        guard let info = vmStats() else { return b }
        let page = Double(pageSize)
        // internal_page_count is vm_stat's "Anonymous pages"; purgeable memory
        // sits inside it but is reclaimable, so it counts as cache, not app.
        let purgeable = Double(info.purgeable_count) * page
        b.app = max(0, Double(info.internal_page_count) * page - purgeable)
        b.wired = Double(info.wire_count) * page
        // compressor_page_count is what the compressor occupies, not the larger
        // uncompressed total it stands in for.
        b.compressed = Double(info.compressor_page_count) * page
        b.cachedFiles = Double(info.external_page_count) * page + purgeable
        return b
    }

    /// 1 normal, 2 warning, 4 critical — what the kernel is telling processes.
    private static func pressureLevel() -> Int32 {
        var level: Int32 = 1
        var size = MemoryLayout<Int32>.size
        sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0)
        return level
    }

    private func vmStats() -> vm_statistics64_data_t? {
        var info = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride
        )
        let kr = withUnsafeMutablePointer(to: &info) { ptr -> kern_return_t in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        return kr == KERN_SUCCESS ? info : nil
    }
}

/// System swap usage via sysctl vm.swapusage (what Activity Monitor's
/// "Swap Used" reports).
enum SwapUsage {
    static func current() -> (used: Double, total: Double) {
        var usage = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        var mib: [Int32] = [CTL_VM, VM_SWAPUSAGE]
        guard sysctl(&mib, 2, &usage, &size, nil, 0) == 0 else { return (0, 0) }
        return (Double(usage.xsu_used), Double(usage.xsu_total))
    }
}
