import Darwin
import Foundation

/// Reverse-DNS (PTR) names for IP addresses, resolved off the main thread and
/// cached. `getnameinfo` blocks — tens of milliseconds warm, seconds cold —
/// so nothing here ever runs on main, and callers draw the raw IP until a name
/// arrives (many addresses never get one: Apple, Cloudflare and Fastly ranges
/// typically have no PTR at all).
final class HostResolver {
    static let shared = HostResolver()

    /// Posted, coalesced to one per runloop hop, when new names are available.
    static let resolved = Notification.Name("net.acheris.tracker.hostResolved")

    /// nil value = looked up and known to have no name. Caching the misses is
    /// the point: most addresses land here and must not be retried per tick.
    private var cache: [String: String?] = [:]
    private var inFlight: Set<String> = []
    private var notifyScheduled = false

    /// Concurrent so one slow lookup can't stall the rest, but capped: a
    /// system-wide view can miss on a hundred addresses at once, and each
    /// blocked thread is a real thread.
    private let queue = DispatchQueue(label: "net.acheris.tracker.dns",
                                      qos: .utility, attributes: .concurrent)
    private let slots = DispatchSemaphore(value: 4)

    /// Main thread only. Returns the cached name, or nil while unknown —
    /// starting a lookup the first time an address is asked about.
    func name(for ip: String) -> String? {
        if let cached = cache[ip] { return cached }
        guard !ip.isEmpty, ip != "0.0.0.0", ip != "::" else {
            cache[ip] = String?.none
            return nil
        }
        guard inFlight.insert(ip).inserted else { return nil }
        queue.async { [weak self] in
            self?.slots.wait()
            let name = Self.lookup(ip)
            self?.slots.signal()
            DispatchQueue.main.async {
                guard let self else { return }
                self.inFlight.remove(ip)
                self.cache[ip] = name
                self.scheduleNotify()
            }
        }
        return nil
    }

    /// One notification per runloop hop: a full table's worth of lookups
    /// finishing shouldn't cause a reload each.
    private func scheduleNotify() {
        guard !notifyScheduled else { return }
        notifyScheduled = true
        DispatchQueue.main.async { [weak self] in
            self?.notifyScheduled = false
            NotificationCenter.default.post(name: HostResolver.resolved, object: nil)
        }
    }

    private static func lookup(_ ip: String) -> String? {
        var storage = sockaddr_storage()
        var length: socklen_t = 0
        if ip.contains(":") {
            var sa = sockaddr_in6()
            sa.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
            sa.sin6_family = sa_family_t(AF_INET6)
            guard inet_pton(AF_INET6, ip, &sa.sin6_addr) == 1 else { return nil }
            length = socklen_t(MemoryLayout<sockaddr_in6>.size)
            withUnsafeBytes(of: sa) { src in
                withUnsafeMutableBytes(of: &storage) { dst in
                    dst.copyMemory(from: UnsafeRawBufferPointer(rebasing: src.prefix(dst.count)))
                }
            }
        } else {
            var sa = sockaddr_in()
            sa.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            sa.sin_family = sa_family_t(AF_INET)
            guard inet_pton(AF_INET, ip, &sa.sin_addr) == 1 else { return nil }
            length = socklen_t(MemoryLayout<sockaddr_in>.size)
            withUnsafeBytes(of: sa) { src in
                withUnsafeMutableBytes(of: &storage) { dst in
                    dst.copyMemory(from: UnsafeRawBufferPointer(rebasing: src.prefix(dst.count)))
                }
            }
        }

        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let rc = withUnsafePointer(to: &storage) { raw in
            raw.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                getnameinfo(sa, length, &host, socklen_t(NI_MAXHOST), nil, 0, NI_NAMEREQD)
            }
        }
        guard rc == 0 else { return nil }
        let name = String(cString: host)
        return name.isEmpty ? nil : name
    }
}
