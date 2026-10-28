import Foundation

@main
enum ClaudeDesktopQuotaCacheSmoke {
    static func main() throws {
        let now = Date(timeIntervalSince1970: 1_793_100_000)
        let org = "00000000-0000-4000-8000-000000000001"
        let other = "00000000-0000-4000-8000-000000000002"
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let root = home.appendingPathComponent("Library/Application Support/Claude/Local Storage/leveldb")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        func key(_ id: String = org) -> [UInt8] { Array("_https://claude.ai\0\u{1}claudeai.ochre_heron_tide.\(id)".utf8) }
        func json(_ used: Double, _ reset: Double = 3600, _ observed: Double = -30, wall: Bool = false) -> [UInt8] {
            [1] + Array("{\"resetsAt\":\(now.timeIntervalSince1970 + reset),\"observedAt\":\(now.timeIntervalSince1970 + observed),\"utilization\":\(used),\"atWall\":\(wall),\"fired\":[],\"shown\":false}".utf8)
        }
        func file(_ name: String, _ bytes: [UInt8]) throws { try Data(bytes).write(to: root.appendingPathComponent(name)) }
        func table(_ entries: [([UInt8], [UInt8], UInt64, UInt8)], compressed: Bool = false, repeatedIndex: Bool = false) -> [UInt8] {
            let body = entries.flatMap { k, v, seq, type in entry(k + le(seq << 8 | UInt64(type), 8), v) }
                + le(0, 4) + le(1, 4)
            let payload = compressed ? snappyLiteral(body) : body
            let dataBlock = payload + [compressed ? 1 : 0] + le(UInt64(crc(payload + [compressed ? 1 : 0])), 4)
            var index = entry([122], vint(0) + vint(UInt64(payload.count)))
            if repeatedIndex { index += entry([123], vint(0) + vint(UInt64(payload.count))) }
            index += le(0, 4) + le(1, 4)
            let indexBlock = index + [0] + le(UInt64(crc(index + [0])), 4)
            var footer = vint(0) + vint(0) + vint(UInt64(dataBlock.count)) + vint(UInt64(index.count))
            footer += Array(repeating: 0, count: 40 - footer.count)
            return dataBlock + indexBlock + footer + le(0xdb4775248b80fb57, 8)
        }
        func manifest(_ live: [UInt64], delete: [UInt64] = []) throws {
            let header = vint(1) + lp(Array("leveldb.BytewiseComparator".utf8)) + vint(2) + vint(20)
                + vint(3) + vint(40) + vint(4) + vint(100)
            var edits: [UInt8] = []
            for number in delete { edits += vint(6) + vint(0) + vint(number) }
            for number in live {
                edits += vint(7) + vint(0) + vint(number)
                edits += vint(1) + lp([1]) + lp([122])
            }
            try file("MANIFEST-000001", log(header + edits))
            try file("CURRENT", Array("MANIFEST-000001\n".utf8))
        }
        func load(_ id: String = org) -> ClaudeDesktopQuotaCache.Sample? {
            ClaudeDesktopQuotaCache.load(home: home, organizationID: id, now: now)
        }
        try file("000010.ldb", table([(key(), json(0.24), 10, 1)], compressed: true))
        try manifest([10])
        let first = load()
        precondition(first?.window.usedPercent == 24 && first?.window.remaining == 76,
                     "Read the real Free fraction from a live Snappy table, never assume empty API means unlimited")
        precondition(first?.observedAt == now.addingTimeInterval(-30))
        precondition(first?.window.resetsAt == now.addingTimeInterval(3600))
        try file("000010.ldb", table([(key(), json(0.24), 10, 1)], repeatedIndex: true))
        precondition(load() == nil, "Repeated block handles must not amplify decompression work")
        try file("000010.ldb", table([(key(), json(0.24), 10, 1)], compressed: true))
        precondition(load(other) == nil, "Never reuse another organization's quota")
        // Latest WAL entry wins even when utilization falls; an unrelated origin is ignored.
        var batch: [UInt8] = le(11, 8) + le(2, 4)
        batch += [1] + lp(key()) + lp(json(0.13, 3600, -10))
        batch += [1] + lp(Array("_https://example.com\0\u{1}claudeai.ochre_heron_tide.\(org)".utf8)) + lp(json(0.99))
        try file("000020.log", log(batch))
        precondition(load()?.window.usedPercent == 13 && load()?.observedAt == now.addingTimeInterval(-10))
        // Incomplete trailing writes must not replace the last complete batch.
        try file("000020.log", log(batch) + [0, 1, 2])
        precondition(load()?.window.usedPercent == 13)
        let deleted = le(30, 8) + le(1, 4) + [0] + lp(key())
        try file("000020.log", log(batch) + log(deleted))
        precondition(load() == nil, "WAL tombstones must suppress old table values")
        // An unselected obsolete WAL must never resurrect an old account sample.
        try file("000019.log", log(le(99, 8) + le(1, 4) + [1] + lp(key()) + lp(json(0.95))))
        try file("000020.log", [])
        precondition(load()?.window.usedPercent == 24)
        try file("000011.ldb", table([(key(), json(0.73), 50, 1)]))
        precondition(load()?.window.usedPercent == 24, "Obsolete tables outside MANIFEST are not live")
        try manifest([11], delete: [10])
        precondition(load()?.window.usedPercent == 73)
        try file("000011.ldb", table([(key(), [], 50, 0)]))
        precondition(load() == nil, "Table tombstones must suppress quota")
        for invalid in [json(0.1, -1), json(0.1, 21601), json(-0.1), json(1.1), json(0.2, 3600, 60)] {
            try file("000011.ldb", table([(key(), invalid, 50, 1)]))
            precondition(load() == nil, "Expired, far-future, invalid fractions and future observations must remain unavailable")
        }
        try file("000011.ldb", table([(key(), json(0.2, wall: true), 50, 1)]))
        precondition(load()?.window.usedPercent == 100, "An explicit exhausted status overrides a stale fraction")
        // A corrupt live table must not cause fallback to an obsolete valid table.
        var corrupt = table([(key(), json(0.2), 50, 1)])
        corrupt[2] ^= 1
        try file("000011.ldb", corrupt)
        precondition(load() == nil, "Verify CRC32C before using local quota")
        try file("000011.ldb", table([(key(), json(0.2), 50, 1)]))
        var fragmentedBatch: [UInt8] = le(60, 8) + le(2, 4)
        fragmentedBatch += [1] + lp(key()) + lp(json(0.47))
        fragmentedBatch += [1] + lp([120]) + lp(Array(repeating: UInt8(42), count: 33000))
        let split = 32768 - 7
        let part1 = log(Array(fragmentedBatch[..<split]), type: 2)
        try file("000020.log", part1 + log(Array(fragmentedBatch[split...]), type: 4))
        precondition(load()?.window.usedPercent == 47, "Read a complete fragmented WAL batch")
        try file("000020.log", log(le(70, 8) + le(2, 4) + [1] + lp(key()) + lp(json(0.99))))
        precondition(load() == nil, "A batch with a bad operation count must not partially apply")
        try file("000020.log", [])
        try FileManager.default.removeItem(at: root.appendingPathComponent("000011.ldb"))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("000011.ldb"), withDestinationURL: root.appendingPathComponent("000010.ldb"))
        precondition(load() == nil, "Do not follow cache-file symlinks")
        print("Claude Free cache: fraction, freshness, origin/account, live tables, Snappy, WAL, tombstone and corruption checks passed")
    }

    static func le(_ n: UInt64, _ count: Int) -> [UInt8] { (0..<count).map { UInt8(truncatingIfNeeded: n >> (8 * $0)) } }
    static func vint(_ n: UInt64) -> [UInt8] {
        var n = n, b: [UInt8] = []
        while n >= 128 { b.append(UInt8(n & 127) | 128); n >>= 7 }; b.append(UInt8(n)); return b
    }
    static func lp(_ b: [UInt8]) -> [UInt8] { vint(UInt64(b.count)) + b }
    static func entry(_ key: [UInt8], _ value: [UInt8]) -> [UInt8] { [0] + vint(UInt64(key.count)) + vint(UInt64(value.count)) + key + value }
    static func crc(_ b: [UInt8]) -> UInt32 {
        var c = UInt32.max
        for v in b { c ^= UInt32(v); for _ in 0..<8 { c = (c >> 1) ^ (c & 1 == 1 ? 0x82f63b78 : 0) } }
        c = ~c
        return ((c >> 15) | (c << 17)) &+ 0xa282ead8
    }
    static func log(_ b: [UInt8], type: UInt8 = 1) -> [UInt8] {
        le(UInt64(crc([type] + b)), 4) + le(UInt64(b.count), 2) + [type] + b
    }
    static func snappyLiteral(_ b: [UInt8]) -> [UInt8] {
        let n = b.count - 1
        if n < 60 { return vint(UInt64(b.count)) + [UInt8(n << 2)] + b }
        return vint(UInt64(b.count)) + [244] + le(UInt64(n), 2) + b
    }
}
