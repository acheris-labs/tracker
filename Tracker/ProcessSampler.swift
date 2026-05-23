import Darwin
import Foundation

struct ProcessSnapshot {
    let pid: Int32
    let name: String
    let user: String
    let cpuPercent: Double   // percent of one core; 100% = one full core
    let rssMB: Double
    let threads: Int
    let diskReadBytesPerSec: Double
    let diskWriteBytesPerSec: Double
    let powerWatts: Double   // billed + serviced energy / interval
}

final class ProcessSampler {
    private struct Prev {
        let cpuNanos: UInt64
        let diskBytesRead: UInt64
        let diskBytesWritten: UInt64
        let energyNanoJoules: UInt64
        let sampleAt: UInt64   // mach_absolute_time
    }

    private var prev: [Int32: Prev] = [:]
    private var userCache: [uid_t: String] = [:]
    private let timebase: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info
    }()

    /// Drop the per-pid baseline. The next `sample()` will return 0% CPU /
    /// 0 B/s / 0 W for every process, with real numbers landing on the call
    /// after that. Use when the consumer has been idle and a stale baseline
    /// would yield a misleading long-window average.
    func reset() {
        prev.removeAll(keepingCapacity: true)
    }

    func sample() -> [ProcessSnapshot] {
        let now = mach_absolute_time()
        let pids = listAllPIDs()
        var live: Set<Int32> = []
        var out: [ProcessSnapshot] = []
        out.reserveCapacity(pids.count)

        for pid in pids where pid > 0 {
            live.insert(pid)
            guard let snap = snapshot(pid: pid, now: now) else { continue }
            out.append(snap)
        }

        // Drop dead PIDs from the prev cache so it doesn't grow forever.
        prev = prev.filter { live.contains($0.key) }

        out.sort { $0.cpuPercent > $1.cpuPercent }
        return out
    }

    private func snapshot(pid: Int32, now: UInt64) -> ProcessSnapshot? {
        var taskInfo = proc_taskinfo()
        let ti = withUnsafeMutablePointer(to: &taskInfo) { ptr -> Int32 in
            proc_pidinfo(pid, PROC_PIDTASKINFO, 0, ptr,
                         Int32(MemoryLayout<proc_taskinfo>.size))
        }
        guard ti == Int32(MemoryLayout<proc_taskinfo>.size) else { return nil }

        let totalNanos = machTicksToNanos(taskInfo.pti_total_user + taskInfo.pti_total_system)

        // proc_pid_rusage_v6 gives cumulative disk I/O (bytes) and modeled
        // energy (nanojoules billed + serviced). Diff between samples gives
        // bytes/sec and watts respectively. V6 requires macOS 14+.
        var ru = rusage_info_v6()
        var rRead: UInt64 = 0
        var rWritten: UInt64 = 0
        var rEnergy: UInt64 = 0
        let ruOK = withUnsafeMutablePointer(to: &ru) { ptr -> Bool in
            ptr.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { rptr in
                proc_pid_rusage(pid, RUSAGE_INFO_V6, rptr) == 0
            }
        }
        if ruOK {
            rRead = ru.ri_diskio_bytesread
            rWritten = ru.ri_diskio_byteswritten
            rEnergy = ru.ri_billed_energy &+ ru.ri_serviced_energy
        }

        let cpuPercent: Double
        let diskReadPerSec: Double
        let diskWritePerSec: Double
        let powerWatts: Double
        if let p = prev[pid] {
            let deltaCPU = totalNanos &- p.cpuNanos
            let deltaWallNanos = machTicksToNanos(now &- p.sampleAt)
            cpuPercent = deltaWallNanos > 0
                ? (Double(deltaCPU) / Double(deltaWallNanos)) * 100.0 : 0
            let secs = Double(deltaWallNanos) / 1_000_000_000.0
            if secs > 0 {
                diskReadPerSec  = Double(rRead    &- p.diskBytesRead)    / secs
                diskWritePerSec = Double(rWritten &- p.diskBytesWritten) / secs
                // (delta nJ) / (delta ns) = W, so just divide raw.
                powerWatts = Double(rEnergy &- p.energyNanoJoules)
                             / Double(deltaWallNanos)
            } else {
                diskReadPerSec = 0
                diskWritePerSec = 0
                powerWatts = 0
            }
        } else {
            cpuPercent = 0          // first sample: no baseline yet
            diskReadPerSec = 0
            diskWritePerSec = 0
            powerWatts = 0
        }
        prev[pid] = Prev(cpuNanos: totalNanos,
                         diskBytesRead: rRead, diskBytesWritten: rWritten,
                         energyNanoJoules: rEnergy,
                         sampleAt: now)

        var bsd = proc_bsdinfo()
        let bi = withUnsafeMutablePointer(to: &bsd) { ptr -> Int32 in
            proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, ptr,
                         Int32(MemoryLayout<proc_bsdinfo>.size))
        }
        let uid: uid_t = (bi == Int32(MemoryLayout<proc_bsdinfo>.size)) ? bsd.pbi_uid : 0

        let name = procName(pid: pid)
        let user = username(uid: uid)
        let rssMB = Double(taskInfo.pti_resident_size) / (1024 * 1024)
        let threads = Int(taskInfo.pti_threadnum)

        return ProcessSnapshot(pid: pid, name: name, user: user,
                               cpuPercent: cpuPercent, rssMB: rssMB,
                               threads: threads,
                               diskReadBytesPerSec: diskReadPerSec,
                               diskWriteBytesPerSec: diskWritePerSec,
                               powerWatts: powerWatts)
    }

    private func listAllPIDs() -> [Int32] {
        let needed = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard needed > 0 else { return [] }
        let capacity = Int(needed) / MemoryLayout<Int32>.size + 16
        var buf = [Int32](repeating: 0, count: capacity)
        let got = buf.withUnsafeMutableBufferPointer { ptr -> Int32 in
            proc_listpids(UInt32(PROC_ALL_PIDS), 0, ptr.baseAddress,
                          Int32(capacity * MemoryLayout<Int32>.size))
        }
        guard got > 0 else { return [] }
        let count = Int(got) / MemoryLayout<Int32>.size
        return Array(buf.prefix(count))
    }

    private func procName(pid: Int32) -> String {
        var buf = [CChar](repeating: 0, count: Int(2 * MAXPATHLEN))
        let n = buf.withUnsafeMutableBufferPointer { ptr in
            proc_name(pid, ptr.baseAddress, UInt32(ptr.count))
        }
        if n > 0 { return String(cString: buf) }
        return "pid \(pid)"
    }

    private func username(uid: uid_t) -> String {
        if let cached = userCache[uid] { return cached }
        guard let pw = getpwuid(uid), let cName = pw.pointee.pw_name else {
            let fallback = "\(uid)"
            userCache[uid] = fallback
            return fallback
        }
        let name = String(cString: cName)
        userCache[uid] = name
        return name
    }

    private func machTicksToNanos(_ ticks: UInt64) -> UInt64 {
        // (ticks * numer) / denom, scaled to avoid overflow on huge counters.
        let numer = UInt64(timebase.numer)
        let denom = UInt64(timebase.denom)
        if numer == denom { return ticks }
        let high = ticks / denom
        let low = ticks % denom
        return high * numer + (low * numer) / denom
    }
}
