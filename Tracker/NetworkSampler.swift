import Foundation

/// Per-process network throughput, sampled by running `nettop -n -P -x -L 1`.
/// nettop is the only non-private way to get per-process network on macOS
/// (Activity Monitor uses the private NetworkStatistics.framework). With name
/// resolution off (-n) a sample costs ~10 ms, so it runs on a utility queue
/// and the UI reads whatever sample completed last.
final class NetworkSampler {
    struct Stats {
        var rxPerSec = 0.0
        var txPerSec = 0.0
        var rxTotal = 0.0   // cumulative bytes received (socket lifetimes)
        var txTotal = 0.0
        var rxPackets = 0.0
        var txPackets = 0.0
    }

    private let queue = DispatchQueue(label: "net.acheris.tracker.nettop",
                                      qos: .utility)
    private var inFlight = false

    // Queue-confined sampling state.
    private var prevTotals: [Int32: Totals] = [:]
    private var prevDate: Date?

    /// Latest completed sample — main-thread only.
    private(set) var latest: [Int32: Stats] = [:]

    /// System-wide sums of the latest sample — main-thread only.
    var totals: Stats {
        latest.values.reduce(into: Stats()) {
            $0.rxPerSec += $1.rxPerSec
            $0.txPerSec += $1.txPerSec
            $0.rxTotal += $1.rxTotal
            $0.txTotal += $1.txTotal
        }
    }

    /// Start an async sample; the result lands in `latest` on the main thread
    /// before some future tick. Overlapping kicks are dropped.
    func kick() {
        guard !inFlight else { return }
        inFlight = true
        queue.async { [weak self] in
            let parsed = Self.runNettop()
            DispatchQueue.main.async {
                guard let self else { return }
                self.inFlight = false
                guard let parsed else { return }   // nettop failed; keep last
                let now = Date()
                let elapsed = self.prevDate.map { now.timeIntervalSince($0) } ?? 0
                var stats: [Int32: Stats] = [:]
                for (pid, t) in parsed {
                    var s = Stats(rxPerSec: 0, txPerSec: 0,
                                  rxTotal: t.rx, txTotal: t.tx,
                                  rxPackets: t.rxPkts, txPackets: t.txPkts)
                    if elapsed > 0.5, let p = self.prevTotals[pid] {
                        s.rxPerSec = max(0, t.rx - p.rx) / elapsed
                        s.txPerSec = max(0, t.tx - p.tx) / elapsed
                    }
                    stats[pid] = s
                }
                self.prevTotals = parsed
                self.prevDate = now
                self.latest = stats
            }
        }
    }

    struct Totals { var rx = 0.0, tx = 0.0, rxPkts = 0.0, txPkts = 0.0 }

    /// Run nettop once and parse its per-process CSV. Column positions come
    /// from the header line — nettop reorders -J requests to its own liking.
    /// Returns nil if nettop couldn't run or produced nothing.
    private static func runNettop() -> [Int32: Totals]? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/nettop")
        p.arguments = ["-n", "-P", "-x", "-L", "1",
                       "-J", "bytes_in,bytes_out,packets_in,packets_out"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        do { try p.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0,
              let text = String(data: data, encoding: .utf8) else { return nil }

        let lines = text.split(separator: "\n")
        guard let header = lines.first else { return nil }
        let names = header.split(separator: ",", omittingEmptySubsequences: false)
            .map(String.init)
        guard let iRx = names.firstIndex(of: "bytes_in"),
              let iTx = names.firstIndex(of: "bytes_out") else { return nil }
        let iRxP = names.firstIndex(of: "packets_in")
        let iTxP = names.firstIndex(of: "packets_out")

        var totals: [Int32: Totals] = [:]
        for line in lines.dropFirst() {
            let cols = line.split(separator: ",", omittingEmptySubsequences: false)
            guard cols.count > max(iRx, iTx) else { continue }
            // Process names can contain dots; the pid is after the last one.
            guard let dot = cols[0].lastIndex(of: "."),
                  let pid = Int32(cols[0][cols[0].index(after: dot)...]),
                  let rx = Double(cols[iRx]), let tx = Double(cols[iTx]) else { continue }
            var t = Totals(rx: rx, tx: tx)
            if let i = iRxP, cols.count > i { t.rxPkts = Double(cols[i]) ?? 0 }
            if let i = iTxP, cols.count > i { t.txPkts = Double(cols[i]) ?? 0 }
            totals[pid] = t
        }
        return totals.isEmpty ? nil : totals
    }
}
