import Darwin
import Foundation

/// Country codes for IP addresses, read from a table bundled with the app.
///
/// This is the *registry's* country — who holds the netblock — not where the
/// server physically sits. For an anycast address that means the owner's home
/// country rather than the datacentre you actually reached. Cloudflare's
/// 1.1.1.1 reads AU wherever you are.
///
/// The table is compiled from the five regional registries' published
/// delegation statistics by `tools/gen-geoip.py` (`make geodata`), refreshed on
/// every release. That replaced per-address `whois` calls, which cost a
/// subprocess each and told a registry which addresses you were connected to.
/// A lookup is now a binary search over a memory-mapped file: synchronous, no
/// cache to keep, no network, nothing to leak. An address the table doesn't
/// cover — unallocated or reserved space — simply has no country, the same
/// answer `whois` gave for it.
enum GeoDatabase {
    /// Whether to show countries at all. No longer a privacy switch — nothing
    /// leaves the machine — but the column and the map flags are still worth
    /// turning off if you don't want them. The key is the one the old
    /// whois-backed lookup used, so an existing preference carries over.
    private static let enabledKey = "ConnectionsLookUpCountries"
    static var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    /// Two-letter code, or nil when the address falls in space no registry has
    /// delegated. Cheap enough to call from cell drawing.
    static func countryCode(for ip: String) -> String? {
        guard isEnabled, !ip.isEmpty, let table = shared else { return nil }
        // Private and loopback addresses are drawn with a house before we get
        // here; they're undelegated anyway, so this is belt and braces.
        guard !ConnectionGraph.isPrivate(ip) else { return nil }
        if let v4 = ipv4Key(ip) { return table.lookupV4(v4) }
        if let v6 = ipv6Key(ip) { return table.lookupV6(v6) }
        return nil
    }

    /// The flag for a code, as regional indicator symbols — no asset needed.
    static func flag(_ code: String) -> String {
        let letters = code.uppercased().unicodeScalars.compactMap { s -> String? in
            guard s.value >= 65, s.value <= 90,
                  let scalar = Unicode.Scalar(s.value + 127_397) else { return nil }
            return String(scalar)
        }
        return letters.count == 2 ? letters.joined() : ""
    }

    // MARK: - Address keys

    static func ipv4Key(_ s: String) -> UInt32? {
        var addr = in_addr()
        guard inet_pton(AF_INET, s, &addr) == 1 else { return nil }
        return UInt32(bigEndian: addr.s_addr)
    }

    /// The top 64 bits, which is the whole key: no registry delegates a prefix
    /// longer than /64, and the generator asserts that when building the table.
    static func ipv6Key(_ s: String) -> UInt64? {
        // netstat writes link-local addresses with a scope suffix (fe80::1%en0)
        // that inet_pton won't take. Those are LAN and never reach a lookup,
        // but strip it rather than depend on that.
        let bare = s.split(separator: "%", maxSplits: 1).first.map(String.init) ?? s
        var addr = in6_addr()
        guard inet_pton(AF_INET6, bare, &addr) == 1 else { return nil }
        return withUnsafeBytes(of: &addr) { raw in
            var v: UInt64 = 0
            for i in 0..<8 { v = (v << 8) | UInt64(raw[i]) }
            return v
        }
    }

    // MARK: - The table

    /// Loaded once, on the first lookup. Nil if the resource is missing or
    /// malformed, which just means no flags — never a crash.
    private static let shared: Table? = Table.load()

    private struct Table {
        let data: Data
        let countries: [String?]        // slot 0 is nil: "no country here"
        let v4Offset: Int, v4Count: Int
        let v6Offset: Int, v6Count: Int

        static let magic: [UInt8] = Array("TGEO".utf8)
        static let headerSize = 14
        static let v4Stride = 5         // start UInt32 + country UInt8
        static let v6Stride = 9         // start UInt64 + country UInt8

        static func load() -> Table? {
            guard let url = Bundle.main.url(forResource: "geoip", withExtension: "dat"),
                  // Mapped, so a 2 MB table costs pages only where a search
                  // actually lands.
                  let data = try? Data(contentsOf: url, options: .mappedIfSafe),
                  data.count >= headerSize,
                  Array(data[0..<4]) == magic,
                  data[4] == 1 else { return nil }

            let ccCount = Int(data[5])
            let v4Count = Int(data.loadLE(UInt32.self, at: 6))
            let v6Count = Int(data.loadLE(UInt32.self, at: 10))
            let v4Offset = headerSize + ccCount * 2
            let v6Offset = v4Offset + v4Count * v4Stride
            guard data.count >= v6Offset + v6Count * v6Stride else { return nil }

            var countries: [String?] = []
            countries.reserveCapacity(ccCount)
            for i in 0..<ccCount {
                let at = headerSize + i * 2
                let pair = [data[at], data[at + 1]]
                countries.append(pair[0] == 0 ? nil : String(decoding: pair, as: UTF8.self))
            }
            return Table(data: data, countries: countries,
                         v4Offset: v4Offset, v4Count: v4Count,
                         v6Offset: v6Offset, v6Count: v6Count)
        }

        func lookupV4(_ key: UInt32) -> String? {
            let row = search(count: v4Count) { i in
                UInt64(data.loadLE(UInt32.self, at: v4Offset + i * Self.v4Stride))
            } key: { UInt64(key) }
            guard let row else { return nil }
            return countries[Int(data[v4Offset + row * Self.v4Stride + 4])]
        }

        func lookupV6(_ key: UInt64) -> String? {
            let row = search(count: v6Count) { i in
                data.loadLE(UInt64.self, at: v6Offset + i * Self.v6Stride)
            } key: { key }
            guard let row else { return nil }
            return countries[Int(data[v6Offset + row * Self.v6Stride + 8])]
        }

        /// Index of the last row whose start is <= the key. The table
        /// partitions the address space — gaps are explicit rows pointing at
        /// country slot 0 — so there is no range end to check.
        private func search(count: Int, start: (Int) -> UInt64,
                            key: () -> UInt64) -> Int? {
            let k = key()
            var lo = 0, hi = count
            while lo < hi {
                let mid = (lo + hi) / 2
                if start(mid) <= k { lo = mid + 1 } else { hi = mid }
            }
            return lo > 0 ? lo - 1 : nil
        }
    }
}

private extension Data {
    /// Rows are 5 and 9 bytes wide, so every read is unaligned. The file is
    /// written little-endian; both architectures we build for are too, but say
    /// so rather than rely on it.
    func loadLE<T: FixedWidthInteger>(_ type: T.Type, at offset: Int) -> T {
        T(littleEndian: withUnsafeBytes {
            $0.loadUnaligned(fromByteOffset: offset, as: T.self)
        })
    }
}
