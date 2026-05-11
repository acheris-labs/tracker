// host_processor_info sampling approach adapted from exelban/stats (MIT).

import Darwin
import Foundation

struct CPUFrame {
    var pUser: Double = 0
    var pSys: Double = 0
    var eUser: Double = 0
    var eSys: Double = 0
}

final class CPUSampler {
    private var prevInfo: processor_info_array_t?
    private var prevCount: mach_msg_type_number_t = 0
    private var numCPUs: natural_t = 0

    let numP: Int
    let numE: Int

    init() {
        let p = Self.sysctlInt("hw.perflevel0.logicalcpu") ?? 0
        let e = Self.sysctlInt("hw.perflevel1.logicalcpu") ?? 0
        self.numP = p
        self.numE = e
    }

    deinit {
        if let prev = prevInfo {
            let bytes = vm_size_t(MemoryLayout<integer_t>.stride * Int(prevCount))
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: prev), bytes)
        }
    }

    func sample() -> CPUFrame {
        var count: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0

        let kr = host_processor_info(mach_host_self(),
                                     PROCESSOR_CPU_LOAD_INFO,
                                     &count, &info, &infoCount)
        guard kr == KERN_SUCCESS, let info else { return CPUFrame() }
        self.numCPUs = count

        defer {
            if let prev = prevInfo {
                let bytes = vm_size_t(MemoryLayout<integer_t>.stride * Int(prevCount))
                vm_deallocate(mach_task_self_, vm_address_t(bitPattern: prev), bytes)
            }
            prevInfo = info
            prevCount = infoCount
        }

        guard let prev = prevInfo else { return CPUFrame() }

        // Split cores: assume P-cores [0..numP), E-cores [numP..numP+numE).
        // Fall back to "all P" if topology is unknown or doesn't match.
        let total = Int(count)
        let pRange: Range<Int>
        let eRange: Range<Int>
        if numP > 0, numE > 0, numP + numE == total {
            pRange = 0..<numP
            eRange = numP..<(numP + numE)
        } else {
            pRange = 0..<total
            eRange = 0..<0
        }

        let p = Self.aggregate(prev: prev, curr: info, range: pRange)
        let e = Self.aggregate(prev: prev, curr: info, range: eRange)
        return CPUFrame(pUser: p.user, pSys: p.sys, eUser: e.user, eSys: e.sys)
    }

    private static func aggregate(prev: processor_info_array_t,
                                  curr: processor_info_array_t,
                                  range: Range<Int>) -> (user: Double, sys: Double) {
        if range.isEmpty { return (0, 0) }
        var dUser: Int64 = 0
        var dSys: Int64 = 0
        var dNice: Int64 = 0
        var dIdle: Int64 = 0
        let stride = Int(CPU_STATE_MAX)
        for i in range {
            let base = i * stride
            dUser += Int64(curr[base + Int(CPU_STATE_USER)] - prev[base + Int(CPU_STATE_USER)])
            dSys  += Int64(curr[base + Int(CPU_STATE_SYSTEM)] - prev[base + Int(CPU_STATE_SYSTEM)])
            dNice += Int64(curr[base + Int(CPU_STATE_NICE)] - prev[base + Int(CPU_STATE_NICE)])
            dIdle += Int64(curr[base + Int(CPU_STATE_IDLE)] - prev[base + Int(CPU_STATE_IDLE)])
        }
        let total = dUser + dSys + dNice + dIdle
        guard total > 0 else { return (0, 0) }
        let user = Double(dUser + dNice) / Double(total)
        let sys = Double(dSys) / Double(total)
        return (user, sys)
    }

    private static func sysctlInt(_ name: String) -> Int? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        if size == MemoryLayout<Int32>.size {
            var v: Int32 = 0
            guard sysctlbyname(name, &v, &size, nil, 0) == 0 else { return nil }
            return Int(v)
        } else if size == MemoryLayout<Int64>.size {
            var v: Int64 = 0
            guard sysctlbyname(name, &v, &size, nil, 0) == 0 else { return nil }
            return Int(v)
        }
        return nil
    }
}
