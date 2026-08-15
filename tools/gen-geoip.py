#!/usr/bin/env python3
"""Compile the five RIRs' delegation statistics into Tracker/geoip.dat.

Each registry publishes a `delegated-<rir>-extended-latest` file daily, listing
every allocation it has made with the country it was delegated to:

    arin|US|ipv4|1.178.0.0|512|20250113|allocated|20c786e8...
    ripencc|NL|ipv6|2001:4b98::|32|20080114|allocated|...

That is the *registry's* country — who holds the block — which is exactly what
the `whois` lookups this replaces were reporting. It is not geolocation: an
anycast address reads as its owner's home country, not the datacentre you
actually reached.

Run via `make geodata`. Stdlib only, so CI needs nothing installed.

Output format, all integers little-endian:

    0   magic "TGEO"                     4 bytes
    4   format version (1)               1
    5   country count, including slot 0  1
    6   IPv4 row count                   4
    10  IPv6 row count                   4
    14  country table, 2 ASCII each      count * 2   (slot 0 is "\0\0" = unknown)
        IPv4 rows: start u32, country u8      5 each, ascending by start
        IPv6 rows: start u64, country u8      9 each, ascending by start

The rows partition the address space rather than listing only allocations:
every gap gets an explicit row pointing at country slot 0. That makes a lookup
"the last row whose start is <= the address" with no range-end to store and no
"did I fall off the end of a block" case to get wrong.

The IPv6 key is the top 64 bits. No registry currently delegates a prefix
longer than /64 (checked across all five files), so that is lossless, not an
approximation — but assert it rather than trusting it to stay true.
"""

import struct
import sys
import urllib.request
from pathlib import Path

SOURCES = {
    "arin": "https://ftp.arin.net/pub/stats/arin/delegated-arin-extended-latest",
    "ripencc": "https://ftp.ripe.net/pub/stats/ripencc/delegated-ripencc-extended-latest",
    "apnic": "https://ftp.apnic.net/stats/apnic/delegated-apnic-extended-latest",
    "lacnic": "https://ftp.lacnic.net/pub/stats/lacnic/delegated-lacnic-extended-latest",
    "afrinic": "https://ftp.afrinic.net/pub/stats/afrinic/delegated-afrinic-extended-latest",
}

# Rows in any other state (reserved, available) have no country to report.
DELEGATED = {"allocated", "assigned"}

# A registry that hands back a truncated file would silently shrink the table,
# so refuse anything implausibly small rather than shipping it.
MIN_ROWS = {"arin": 40_000, "ripencc": 50_000, "apnic": 30_000,
            "lacnic": 10_000, "afrinic": 3_000}


def fetch(name, url, cache):
    """Download a registry file, reusing a cached copy when one is offered.

    `cache` is only set when a directory is passed on the command line — these
    files are 1–18 MB each and have no business landing in the working tree by
    default.
    """
    path = cache / f"{name}.txt" if cache else None
    if path and path.exists():
        print(f"  {name}: cached ({path.stat().st_size:,} bytes)")
        return path.read_text(encoding="utf-8", errors="replace")
    print(f"  {name}: fetching {url}")
    with urllib.request.urlopen(url, timeout=120) as r:
        body = r.read()
    if path:
        path.write_bytes(body)
    print(f"    {len(body):,} bytes")
    return body.decode("utf-8", errors="replace")


def parse(text, name):
    """Yield (family, start, end_exclusive, country) for delegated rows."""
    kept = 0
    for line in text.splitlines():
        if not line or line.startswith("#"):
            continue
        f = line.split("|")
        # Header and summary lines are shorter and carry no status column.
        if len(f) < 7 or f[6] not in DELEGATED:
            continue
        _, cc, kind, start, value = f[0], f[1], f[2], f[3], f[4]
        if len(cc) != 2 or not cc.isalpha():
            continue
        if kind == "ipv4":
            # The ipv4 "value" is a host count, not a prefix length, and is not
            # always a power of two — ARIN records merged assignments this way.
            octets = [int(x) for x in start.split(".")]
            lo = (octets[0] << 24) | (octets[1] << 16) | (octets[2] << 8) | octets[3]
            yield 4, lo, lo + int(value), cc.upper()
        elif kind == "ipv6":
            bits = int(value)
            assert bits <= 64, f"{name}: /{bits} prefix exceeds the 64-bit key"
            lo = ipv6_top64(start)
            yield 6, lo, lo + (1 << (64 - bits)), cc.upper()
        else:
            continue
        kept += 1
    floor = MIN_ROWS.get(name, 0)
    if kept < floor:
        sys.exit(f"error: {name} yielded {kept:,} rows, expected at least "
                 f"{floor:,} — refusing to build a truncated table")
    print(f"    {kept:,} delegated ranges")


def ipv6_top64(addr):
    """The high 64 bits of an IPv6 address written in :: form."""
    head, _, tail = addr.partition("::")
    h = [int(g, 16) for g in head.split(":") if g]
    t = [int(g, 16) for g in tail.split(":") if g] if "::" in addr else []
    groups = h + [0] * (8 - len(h) - len(t)) + t
    v = 0
    for g in groups[:4]:
        v = (v << 16) | g
    return v


def compile_rows(ranges, ccindex):
    """Turn (start, end, cc) ranges into a gap-filled, merged row list."""
    rows = []
    cursor = 0
    for lo, hi, cc in sorted(ranges):
        # Registries occasionally publish overlapping records; the earlier
        # (lower) one wins and the overlap is dropped, so the table stays a
        # strict partition.
        if lo < cursor:
            lo = cursor
            if lo >= hi:
                continue
        if lo > cursor:
            rows.append((cursor, 0))
        rows.append((lo, ccindex[cc]))
        cursor = hi
    rows.append((cursor, 0))
    # Adjacent rows with the same country carry no information.
    merged = []
    for start, idx in rows:
        if merged and merged[-1][1] == idx:
            continue
        merged.append((start, idx))
    return merged


def main():
    out = Path(sys.argv[1]) if len(sys.argv) > 1 else Path("Tracker/geoip.dat")
    cache = Path(sys.argv[2]) if len(sys.argv) > 2 else None

    v4, v6, countries = [], [], set()
    print("reading registry data")
    for name, url in SOURCES.items():
        for family, lo, hi, cc in parse(fetch(name, url, cache), name):
            (v4 if family == 4 else v6).append((lo, hi, cc))
            countries.add(cc)

    # Slot 0 means "no country here"; the rest are sorted so the table is
    # reproducible across runs.
    order = ["\0\0"] + sorted(countries)
    if len(order) > 256:
        sys.exit(f"error: {len(order)} countries exceeds the u8 country index")
    ccindex = {cc: i for i, cc in enumerate(order)}

    v4rows = compile_rows(v4, ccindex)
    v6rows = compile_rows(v6, ccindex)
    print(f"compiled {len(v4rows):,} IPv4 rows, {len(v6rows):,} IPv6 rows, "
          f"{len(order) - 1} countries")

    blob = bytearray(b"TGEO")
    blob += struct.pack("<BBII", 1, len(order), len(v4rows), len(v6rows))
    for cc in order:
        blob += cc.encode("ascii")
    for start, idx in v4rows:
        blob += struct.pack("<IB", start, idx)
    for start, idx in v6rows:
        blob += struct.pack("<QB", start, idx)

    out.parent.mkdir(parents=True, exist_ok=True)
    previous = out.stat().st_size if out.exists() else 0
    out.write_bytes(blob)
    delta = f" (was {previous:,})" if previous else ""
    print(f"wrote {out}: {len(blob):,} bytes{delta}")


if __name__ == "__main__":
    main()
