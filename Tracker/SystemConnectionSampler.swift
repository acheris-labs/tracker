import Darwin
import Foundation

/// System-wide connections, parsed from `netstat -anv`.
///
/// libproc can only enumerate descriptors for processes we own — barely half of
/// them — so a view that claims to show *all* connections can't be built on it.
/// netstat sees every socket, attributes each to a `process:pid`, and throws in
/// per-connection byte counters for free. Its two costs are handled here: the
/// process column is truncated to 16 characters (repaired from our own process
/// list, which has the full name), and long IPv6 addresses are truncated
/// (repaired from libproc where the process is ours).
enum SystemConnectionSampler {
    /// Runs netstat and parses it. Blocking, ~20-50 ms — call off the main
    /// thread.
    static func sample() -> [Connection] {
        guard let text = runNetstat() else { return [] }
        var rows = text.split(separator: "\n").compactMap(parse)
        repairTruncatedAddresses(&rows)
        return rows
    }

    private static func runNetstat() -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/netstat")
        // -a all sockets, -n numeric (no DNS in the hot path — we resolve
        // names ourselves, asynchronously), -v for the process and byte columns.
        p.arguments = ["-anv"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        do { try p.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// A row looks like:
    ///   tcp4 0 0 192.168.2.177.55958 44.239.150.10.443 ESTABLISHED \
    ///     16800 10733 131072 131768 Brave Browser He:34504 00102 … 000000
    ///
    /// Parsed from both ends, because the process name contains spaces: the
    /// eight trailing columns are fixed, so the token before them ends in
    /// `:pid`, and the name runs left from there until the first numeric field.
    private static func parse(_ line: Substring) -> Connection? {
        let t = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard t.count >= 14 else { return nil }   // headers and blank lines
        // netstat also emits tcp46/udp46 for dual-stack sockets.
        let protoName = t[0].replacingOccurrences(of: "46", with: "6")
        guard let proto = ConnectionProto(rawValue: protoName) else { return nil }

        let pidIndex = t.count - 9
        guard pidIndex > 4, let colon = t[pidIndex].lastIndex(of: ":"),
              let pid = pid_t(t[pidIndex][t[pidIndex].index(after: colon)...]) else { return nil }

        var nameParts = [String(t[pidIndex][..<colon])]
        var i = pidIndex - 1
        while i > 4, Int(t[i]) == nil { nameParts.insert(t[i], at: 0); i -= 1 }
        let name = nameParts.joined(separator: " ")

        // TCP rows carry a state before the byte counters; UDP rows don't.
        let hasState = tcpStates[t[5]] != nil
        let state = hasState ? tcpStates[t[5]]! : Int32(-1)
        let rxIndex = hasState ? 6 : 5
        guard rxIndex + 1 < t.count else { return nil }

        let (localAddr, localPort) = endpoint(t[3])
        let (remoteAddr, remotePort) = endpoint(t[4])
        // Bound to nothing, connected to nothing: no information in the row.
        if localPort == 0, remotePort == 0 { return nil }

        return Connection(pid: pid, proto: proto,
                          localAddr: localAddr, localPort: localPort,
                          remoteAddr: remoteAddr, remotePort: remotePort,
                          state: state,
                          processName: name.isEmpty ? nil : name,
                          rxBytes: Double(t[rxIndex]),
                          txBytes: Double(t[rxIndex + 1]))
    }

    /// netstat writes `host.port`, for both families — so the port is whatever
    /// follows the last dot, and everything before it is the address.
    /// Wildcards appear as `*`.
    private static func endpoint(_ s: String) -> (String, UInt16) {
        guard let dot = s.lastIndex(of: ".") else { return (s == "*" ? "" : s, 0) }
        let addr = String(s[..<dot])
        let portText = s[s.index(after: dot)...]
        let port = UInt16(portText) ?? 0
        return (addr == "*" ? "" : addr, port)
    }

    /// netstat truncates addresses to its column width, which only bites IPv6.
    /// Where the socket belongs to us, libproc has the full text; match on the
    /// port pair, which is exact in both.
    private static func repairTruncatedAddresses(_ rows: inout [Connection]) {
        guard rows.contains(where: { $0.localAddr.contains(":") || $0.remoteAddr.contains(":") })
        else { return }
        var byPorts: [PortPair: Connection] = [:]
        for c in ConnectionSampler.allConnections().rows {
            byPorts[PortPair(local: c.localPort, remote: c.remotePort)] = c
        }
        guard !byPorts.isEmpty else { return }
        for i in rows.indices {
            let r = rows[i]
            guard r.localAddr.contains(":") || r.remoteAddr.contains(":"),
                  let full = byPorts[PortPair(local: r.localPort, remote: r.remotePort)],
                  full.pid == r.pid else { continue }
            rows[i].localAddr = full.localAddr
            rows[i].remoteAddr = full.remoteAddr
        }
    }

    private struct PortPair: Hashable {
        let local: UInt16
        let remote: UInt16
    }

    private static let tcpStates: [String: Int32] = [
        "CLOSED": TSI_S_CLOSED, "LISTEN": TSI_S_LISTEN,
        "SYN_SENT": TSI_S_SYN_SENT, "SYN_RCVD": TSI_S_SYN_RECEIVED,
        "ESTABLISHED": TSI_S_ESTABLISHED, "CLOSE_WAIT": TSI_S__CLOSE_WAIT,
        "FIN_WAIT_1": TSI_S_FIN_WAIT_1, "CLOSING": TSI_S_CLOSING,
        "LAST_ACK": TSI_S_LAST_ACK, "FIN_WAIT_2": TSI_S_FIN_WAIT_2,
        "TIME_WAIT": TSI_S_TIME_WAIT,
    ]
}
