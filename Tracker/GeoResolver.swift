import Foundation

/// Country codes for IP addresses, looked up with `whois` off the main thread
/// and cached by netblock. Mirrors HostResolver: cached answer or nil, a
/// lookup kicked off on the first miss, one coalesced notification when
/// results land.
///
/// This is the *registry's* country — who owns the netblock — not where the
/// server physically sits. For an anycast address that means the owner's home
/// country rather than the datacentre you actually reached.
final class GeoResolver {
    static let shared = GeoResolver()

    static let resolved = Notification.Name("net.acheris.tracker.geoResolved")

    /// Sends the addresses you are talking to to a regional registry — the
    /// same class of exposure as the reverse-DNS lookups the app already does,
    /// but to a different party, so it is switchable and remembered.
    private static let enabledKey = "ConnectionsLookUpCountries"
    static var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    /// Two-letter code, or nil for "looked up, no answer". Keyed by address,
    /// bounded: a busy machine cycles through thousands of addresses over a
    /// session and there's no reason to remember all of them forever.
    private var cache: [String: String?] = [:]
    /// Least-recently-used first; the eviction order for `cache`.
    private var recency: [String] = []
    private let cacheLimit = 512
    /// Netblocks already answered: one whois covers every address inside.
    /// Also bounded, oldest dropped first.
    private var blocks: [(range: ClosedRange<UInt32>, code: String?)] = []
    private let blockLimit = 256
    private var inFlight: Set<String> = []
    private var notifyScheduled = false

    /// Registries throttle hard, so keep the concurrency tiny.
    private let queue = DispatchQueue(label: "net.acheris.tracker.whois",
                                      qos: .utility, attributes: .concurrent)
    private let slots = DispatchSemaphore(value: 2)

    /// Main thread only. What we already know, without starting a lookup —
    /// for sorting and filtering, which touch every row including ones that
    /// will never be drawn.
    func cachedCountryCode(for ip: String) -> String? {
        guard Self.isEnabled, !ip.isEmpty else { return nil }
        if let cached = cache[ip] { touch(ip); return cached }
        if let v4 = Self.ipv4Value(ip),
           let hit = blocks.first(where: { $0.range.contains(v4) }) {
            remember(ip, hit.code)
            return hit.code
        }
        return nil
    }

    /// Main thread only. Returns a cached country code, or nil while unknown —
    /// starting a lookup on the first ask. Called from cell drawing, so only
    /// addresses actually on screen cost anything.
    func countryCode(for ip: String) -> String? {
        guard Self.isEnabled, !ip.isEmpty, !ConnectionGraph.isPrivate(ip) else { return nil }
        if let cached = cache[ip] { touch(ip); return cached }
        if let v4 = Self.ipv4Value(ip),
           let hit = blocks.first(where: { $0.range.contains(v4) }) {
            remember(ip, hit.code)
            return hit.code
        }
        guard inFlight.insert(ip).inserted else { return nil }
        queue.async { [weak self] in
            self?.slots.wait()
            let result = Self.lookup(ip)
            self?.slots.signal()
            DispatchQueue.main.async {
                guard let self else { return }
                self.inFlight.remove(ip)
                self.remember(ip, result.code)
                if let range = result.range {
                    self.blocks.append((range, result.code))
                    if self.blocks.count > self.blockLimit { self.blocks.removeFirst() }
                }
                self.scheduleNotify()
            }
        }
        return nil
    }

    /// Insert or refresh an entry, evicting the least recently used once the
    /// cache is full.
    private func remember(_ ip: String, _ code: String?) {
        if cache.index(forKey: ip) == nil { recency.append(ip) } else { touch(ip) }
        cache[ip] = code
        while recency.count > cacheLimit {
            let oldest = recency.removeFirst()
            cache.removeValue(forKey: oldest)
        }
    }

    private func touch(_ ip: String) {
        guard let i = recency.firstIndex(of: ip) else { return }
        recency.remove(at: i)
        recency.append(ip)
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

    private func scheduleNotify() {
        guard !notifyScheduled else { return }
        notifyScheduled = true
        DispatchQueue.main.async { [weak self] in
            self?.notifyScheduled = false
            NotificationCenter.default.post(name: GeoResolver.resolved, object: nil)
        }
    }

    // MARK: - whois

    /// Runs whois and pulls out the country plus the netblock it applies to,
    /// so neighbouring addresses cost nothing.
    private static func lookup(_ ip: String) -> (code: String?, range: ClosedRange<UInt32>?) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/whois")
        p.arguments = [ip]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        do { try p.run() } catch { return (nil, nil) }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard let text = String(data: data, encoding: .utf8) else { return (nil, nil) }

        var code: String?
        var range: ClosedRange<UInt32>?
        for line in text.split(separator: "\n") {
            let lower = line.lowercased()
            // ARIN writes "Country:", RIPE and APNIC "country:".
            if code == nil, lower.hasPrefix("country:") {
                let value = line.drop(while: { $0 != ":" }).dropFirst()
                    .trimmingCharacters(in: .whitespaces)
                if value.count == 2 { code = value.uppercased() }
            }
            // "NetRange: a - b" (ARIN) or "inetnum: a - b" (RIPE/APNIC). The
            // narrowest wins: registries print the parent block first.
            if lower.hasPrefix("netrange:") || lower.hasPrefix("inetnum:") {
                let value = line.drop(while: { $0 != ":" }).dropFirst()
                let ends = value.split(separator: "-").map {
                    $0.trimmingCharacters(in: .whitespaces)
                }
                if ends.count == 2, let lo = ipv4Value(ends[0]), let hi = ipv4Value(ends[1]),
                   lo <= hi, range == nil || (hi - lo) < (range!.upperBound - range!.lowerBound) {
                    range = lo...hi
                }
            }
        }
        return (code, range)
    }

    static func ipv4Value(_ s: String) -> UInt32? {
        let parts = s.split(separator: ".").compactMap { UInt32($0) }
        guard parts.count == 4, parts.allSatisfy({ $0 < 256 }) else { return nil }
        return (parts[0] << 24) | (parts[1] << 16) | (parts[2] << 8) | parts[3]
    }
}
