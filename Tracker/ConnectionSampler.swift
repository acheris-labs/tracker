import Darwin
import Foundation

/// One socket, from libproc (per-process) or netstat (system-wide).
///
/// Equality and hashing cover the identity fields only — dup'd descriptors
/// share a socket, so the same connection comes back several times from one fd
/// walk, and byte counters change every tick without making it a different
/// connection.
struct Connection: Hashable {
    var pid: pid_t
    var proto: ConnectionProto
    var localAddr: String       // canonical inet_ntop text
    var localPort: UInt16
    var remoteAddr: String      // "" for an unconnected socket (listeners)
    var remotePort: UInt16
    var state: Int32            // TSI_S_*; -1 for UDP, which has no state

    /// Only netstat supplies these; nil from libproc.
    var rxBytes: Double?
    var txBytes: Double?

    static func == (a: Connection, b: Connection) -> Bool {
        a.pid == b.pid && a.proto == b.proto
            && a.localPort == b.localPort && a.remotePort == b.remotePort
            && a.localAddr == b.localAddr && a.remoteAddr == b.remoteAddr
            && a.state == b.state
    }

    func hash(into h: inout Hasher) {
        h.combine(pid); h.combine(proto)
        h.combine(localPort); h.combine(remotePort)
        h.combine(localAddr); h.combine(remoteAddr)
        h.combine(state)
    }
}

/// What a pid belongs to, for the connections table's Process Name column:
/// the display name and the executable path its icon is resolved from.
struct ProcessOwner: Equatable {
    var name: String
    var execPath: String
    var user: String

    /// Resolve straight from the kernel. proc_pidpath works for every process,
    /// including other users' — proc_name doesn't (it returns nothing for
    /// root-owned daemons), and netstat's own column is truncated to 16
    /// characters, so the path is the one reliable source.
    static func forPID(_ pid: pid_t) -> ProcessOwner? {
        var buf = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 else { return nil }
        let path = String(cString: buf)
        guard !path.isEmpty else { return nil }
        return ProcessOwner(name: (path as NSString).lastPathComponent,
                            execPath: path, user: user(pid: pid))
    }

    /// Owning user, resolved the same way the process list does it.
    private static func user(pid: pid_t) -> String {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return "—" }
        guard let pw = getpwuid(info.pbi_uid) else { return "\(info.pbi_uid)" }
        return String(cString: pw.pointee.pw_name)
    }
}

enum ConnectionProto: String {
    case tcp4, tcp6, udp4, udp6

    var label: String {
        switch self {
        case .tcp4: return "TCP"
        case .tcp6: return "TCP6"
        case .udp4: return "UDP"
        case .udp6: return "UDP6"
        }
    }
}

/// Sockets are only readable for processes we own. That's most of the system
/// (roughly 340 of 880 pids here), so the caller needs to tell "nothing open"
/// apart from "not allowed to look" rather than showing a misleading empty list.
enum ConnectionScan {
    case ok([Connection])
    case notPermitted
}

enum ConnectionSampler {
    /// Every IP socket held by `pid`, or `.notPermitted` when the process
    /// belongs to another user. Ownership is checked up front (one cheap call)
    /// rather than discovered by failing halfway through a descriptor walk.
    static func connections(pid: pid_t) -> ConnectionScan {
        guard canInspect(pid: pid) else { return .notPermitted }
        guard let fds = fdList(pid: pid) else { return .notPermitted }

        var found = Set<Connection>()
        for fd in fds where Int32(fd.proc_fdtype) == PROX_FDTYPE_SOCKET {
            var si = socket_fdinfo()
            let size = Int32(MemoryLayout<socket_fdinfo>.size)
            guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDSOCKETINFO, &si, size) == size,
                  let c = connection(pid: pid, socket: si) else { continue }
            found.insert(c)
        }
        return .ok(Array(found))
    }

    /// Every readable process's sockets, plus how many processes were skipped
    /// because they belong to someone else — a view over the whole system has
    /// to say what it couldn't see. Costs ~4 ms for ~900 processes.
    static func allConnections() -> (rows: [Connection], skippedPIDs: Int) {
        var rows: [Connection] = []
        var skipped = 0
        for pid in livePIDs() {
            switch connections(pid: pid) {
            case .ok(let c):     rows.append(contentsOf: c)
            case .notPermitted:  skipped += 1
            }
        }
        return (rows, skipped)
    }

    static func stateLabel(_ s: Int32) -> String {
        switch s {
        case TSI_S_CLOSED:        return "Closed"
        case TSI_S_LISTEN:        return "Listen"
        case TSI_S_SYN_SENT:      return "SYN Sent"
        case TSI_S_SYN_RECEIVED:  return "SYN Received"
        case TSI_S_ESTABLISHED:   return "Established"
        case TSI_S__CLOSE_WAIT:   return "Close Wait"
        case TSI_S_FIN_WAIT_1:    return "FIN Wait 1"
        case TSI_S_CLOSING:       return "Closing"
        case TSI_S_LAST_ACK:      return "Last ACK"
        case TSI_S_FIN_WAIT_2:    return "FIN Wait 2"
        case TSI_S_TIME_WAIT:     return "Time Wait"
        default:                  return "—"
        }
    }

    // MARK: - libproc

    /// A process's open file descriptors, or nil when it can't be read.
    /// Shared with the inspector's Open Files & Ports listing.
    static func fdList(pid: pid_t) -> [proc_fdinfo]? {
        let bytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard bytes > 0 else { return nil }
        let capacity = Int(bytes) / MemoryLayout<proc_fdinfo>.size
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: capacity)
        let used = fds.withUnsafeMutableBytes {
            proc_pidinfo(pid, PROC_PIDLISTFDS, 0, $0.baseAddress, bytes)
        }
        guard used > 0 else { return nil }
        return Array(fds.prefix(min(capacity, Int(used) / MemoryLayout<proc_fdinfo>.size)))
    }

    /// Whether this process's descriptors are ours to read: same uid, or we're
    /// root. Checked before any fd work so unreadable processes cost one call.
    private static func canInspect(pid: pid_t) -> Bool {
        let me = getuid()
        if me == 0 { return true }
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return false }
        return info.pbi_uid == me
    }

    private static func livePIDs() -> [pid_t] {
        let bytes = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard bytes > 0 else { return [] }
        let capacity = Int(bytes) / MemoryLayout<pid_t>.size
        var pids = [pid_t](repeating: 0, count: capacity)
        let used = proc_listpids(UInt32(PROC_ALL_PIDS), 0, &pids, bytes)
        guard used > 0 else { return [] }
        return pids.prefix(Int(used) / MemoryLayout<pid_t>.size).filter { $0 > 0 }
    }

    /// TCP and UDP sockets only; other kinds (Unix, kernel control/event) have
    /// no address pair worth listing here.
    private static func connection(pid: pid_t, socket si: socket_fdinfo) -> Connection? {
        let isTCP: Bool
        switch si.psi.soi_kind {
        case Int32(SOCKINFO_TCP): isTCP = true
        case Int32(SOCKINFO_IN):  isTCP = false
        default: return nil
        }
        let ini = isTCP ? si.psi.soi_proto.pri_tcp.tcpsi_ini : si.psi.soi_proto.pri_in
        let state = isTCP ? si.psi.soi_proto.pri_tcp.tcpsi_state : -1
        let v4 = (ini.insi_vflag & UInt8(INI_IPV4)) != 0

        let local = withUnsafeBytes(of: ini.insi_laddr) { address($0, v4: v4) }
        let remote = withUnsafeBytes(of: ini.insi_faddr) { address($0, v4: v4) }
        let lport = port(ini.insi_lport)
        let rport = port(ini.insi_fport)

        // A socket bound to nothing and connected to nothing carries no
        // information — browsers hold piles of these.
        if lport == 0, rport == 0 { return nil }

        let proto: ConnectionProto = isTCP ? (v4 ? .tcp4 : .tcp6) : (v4 ? .udp4 : .udp6)
        return Connection(pid: pid, proto: proto,
                          localAddr: local, localPort: lport,
                          remoteAddr: isUnspecified(remote) ? "" : remote,
                          remotePort: rport, state: state)
    }

    /// The address union holds an IPv4 address in its trailing 4 bytes
    /// (in4in6_addr) and an IPv6 address across all 16.
    private static func address(_ raw: UnsafeRawBufferPointer, v4: Bool) -> String {
        guard let base = raw.baseAddress, raw.count >= 16 else { return "" }
        var buf = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        guard inet_ntop(v4 ? AF_INET : AF_INET6, v4 ? base.advanced(by: 12) : base,
                        &buf, socklen_t(INET6_ADDRSTRLEN)) != nil else { return "" }
        return String(cString: buf)
    }

    /// Ports come back in network byte order.
    private static func port(_ raw: Int32) -> UInt16 {
        UInt16(bigEndian: UInt16(truncatingIfNeeded: raw))
    }

    private static func isUnspecified(_ addr: String) -> Bool {
        addr.isEmpty || addr == "0.0.0.0" || addr == "::"
    }
}
