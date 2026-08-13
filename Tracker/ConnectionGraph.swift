import Darwin
import Foundation

/// One remote host in the connection map: every socket to the same address
/// folded together, with the totals and who dialled whom.
struct GraphNode {
    var address: String          // canonical IP — the identity
    var port: UInt16             // the busiest remote port, for the label
    var rxBytes: Double = 0
    var txBytes: Double = 0
    var connections: Int = 0
    var pids: Set<pid_t> = []
    var origin: ConnectionGraph.Origin = .unknown
    var isPrivate: Bool = false
    /// Set only on the overflow node that stands in for the hosts past the cap.
    var hiddenHosts: Int = 0

    var total: Double { rxBytes + txBytes }
    var isOverflow: Bool { hiddenHosts > 0 }
}

/// Folds a flat socket list into per-host nodes.
enum ConnectionGraph {
    /// Who opened the connection. UDP has no such notion, so it lands in
    /// `.unknown` rather than being guessed at.
    enum Origin {
        case weInitiated, theyInitiated, unknown
    }

    /// macOS hands out ephemeral source ports from this range
    /// (`sysctl net.inet.ip.portrange.first`/`.last`), which is what lets us
    /// tell an outbound connection from an inbound one.
    static let ephemeralRange: ClosedRange<UInt16> = 49152...65535

    /// Which origins to show. A set rather than a three-way choice because
    /// "unclear" is a real state — UDP has no handshake to read — and pairing
    /// it with in/out as if they were alternatives makes neither read right.
    struct DirectionSet: OptionSet {
        let rawValue: Int
        static let outgoing = DirectionSet(rawValue: 1 << 0)
        static let incoming = DirectionSet(rawValue: 1 << 1)
        static let unclear  = DirectionSet(rawValue: 1 << 2)
        static let all: DirectionSet = [.outgoing, .incoming, .unclear]

        /// Segment order in the map's toolbar control.
        static let ordered: [(DirectionSet, String)] = [
            (.outgoing, "Outgoing"), (.incoming, "Incoming"), (.unclear, "Unclear"),
        ]

        func allows(_ origin: Origin) -> Bool {
            switch origin {
            case .weInitiated:   return contains(.outgoing)
            case .theyInitiated: return contains(.incoming)
            case .unknown:       return contains(.unclear)
            }
        }
    }

    static func nodes(from connections: [Connection],
                      hidingLoopback: Bool = false,
                      hidingLAN: Bool = false,
                      hidingRemote: Bool = false,
                      directions: DirectionSet = .all) -> [GraphNode] {
        // Ports we're listening on: a connection whose *local* port is one of
        // them was dialled by the other end.
        var listening: Set<UInt16> = []
        for c in connections where c.state == TSI_S_LISTEN {
            listening.insert(c.localPort)
        }

        var byAddress: [String: GraphNode] = [:]
        var portTally: [String: [UInt16: Int]] = [:]
        for c in connections {
            // A socket with no peer has nothing to draw.
            guard !c.remoteAddr.isEmpty, c.state != TSI_S_LISTEN else { continue }
            if hidingLoopback, isLoopback(c.remoteAddr) { continue }
            if hidingLAN, isLAN(c.remoteAddr) { continue }
            if hidingRemote, !isPrivate(c.remoteAddr) { continue }

            var node = byAddress[c.remoteAddr]
                ?? GraphNode(address: c.remoteAddr, port: c.remotePort,
                             isPrivate: isPrivate(c.remoteAddr))
            node.rxBytes += c.rxBytes ?? 0
            node.txBytes += c.txBytes ?? 0
            node.connections += 1
            node.pids.insert(c.pid)
            node.origin = merge(node.origin, origin(of: c, listening: listening))
            byAddress[c.remoteAddr] = node
            portTally[c.remoteAddr, default: [:]][c.remotePort, default: 0] += 1
        }

        // Label each host by the port it uses most — one https node reads
        // better than one node per ephemeral pairing.
        for (addr, tally) in portTally {
            if let busiest = tally.max(by: { $0.value < $1.value })?.key {
                byAddress[addr]?.port = busiest
            }
        }

        // A host we both dialled and were dialled by folds to `.unknown`, so
        // it shows under Unclear rather than being claimed by either side.
        let kept = byAddress.values.filter { directions.allows($0.origin) }
        // Busiest first — collapsing the tail hid exactly the hosts you'd
        // want to notice.
        return kept.sorted { $0.total > $1.total }
    }

    /// How many established connections each side opened. Listeners are left
    /// out: they have no peer, so nobody has dialled anything yet.
    static func originCounts(of connections: [Connection])
    -> (outgoing: Int, incoming: Int, unclear: Int) {
        var listening: Set<UInt16> = []
        for c in connections where c.state == TSI_S_LISTEN {
            listening.insert(c.localPort)
        }
        var out = 0, incoming = 0, unclear = 0
        for c in connections where !c.remoteAddr.isEmpty && c.state != TSI_S_LISTEN {
            switch origin(of: c, listening: listening) {
            case .weInitiated:   out += 1
            case .theyInitiated: incoming += 1
            case .unknown:       unclear += 1
            }
        }
        return (out, incoming, unclear)
    }

    private static func origin(of c: Connection, listening: Set<UInt16>) -> Origin {
        // Landed on a port we're listening on: they dialled us.
        if listening.contains(c.localPort) { return .theyInitiated }
        let localEphemeral = ephemeralRange.contains(c.localPort)
        let remoteEphemeral = ephemeralRange.contains(c.remotePort)
        // Otherwise the ephemeral end is the one that opened the socket: the
        // kernel picks a high port for the caller and the callee answers on
        // its service port.
        if localEphemeral, !remoteEphemeral { return .weInitiated }
        if remoteEphemeral, !localEphemeral { return .theyInitiated }
        return .unknown
    }

    /// A host we both dialled and were dialled by is genuinely ambiguous;
    /// don't pretend otherwise.
    private static func merge(_ a: Origin, _ b: Origin) -> Origin {
        if a == b { return a }
        if a == .unknown { return b }
        if b == .unknown { return a }
        return .unknown
    }

    /// Never leaves this machine: 127.0.0.0/8 and ::1.
    static func isLoopback(_ addr: String) -> Bool {
        if addr.contains(":") { return addr == "::1" }
        return addr.hasPrefix("127.")
    }

    /// On this network but off this machine: RFC1918, link-local (including
    /// IPv6 fe80::, which is what Continuity peers use) and IPv6 ULA.
    static func isLAN(_ addr: String) -> Bool {
        if addr.contains(":") {
            let a = addr.lowercased()
            return a.hasPrefix("fe80") || a.hasPrefix("fc") || a.hasPrefix("fd")
        }
        let parts = addr.split(separator: ".").compactMap { UInt8($0) }
        guard parts.count == 4 else { return false }
        switch (parts[0], parts[1]) {
        case (10, _), (169, 254): return true
        case (192, 168):          return true
        case (172, 16...31):      return true
        default:                  return false
        }
    }

    /// Either of the above — addresses with no registry country, drawn with a
    /// house rather than a flag.
    static func isPrivate(_ addr: String) -> Bool {
        isLoopback(addr) || isLAN(addr)
    }
}
