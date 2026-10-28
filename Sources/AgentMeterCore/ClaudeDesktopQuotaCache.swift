import Foundation
import CoreFoundation
import Darwin

/// A read-only view of the active organization's last observed five-hour desktop limit.
enum ClaudeDesktopQuotaCache {
    struct Sample { let window: LimitWindow; let observedAt: Date }
    static func load(home: URL, organizationID: String, now: Date = Date()) -> Sample? {
        guard UUID(uuidString: organizationID) != nil else { return nil }
        let root = home.appendingPathComponent("Library/Application Support/Claude/Local Storage/leveldb")
        let key = Data("_https://claude.ai\0\u{1}claudeai.ochre_heron_tide.\(organizationID)".utf8)
        // Do not acquire LevelDB's LOCK or open its database: that can interfere with Claude.
        for _ in 0..<2 {
            do {
                guard let raw = try DesktopLevelDB.value(for: key, at: root) else { return nil }
                return parse(raw, now: now)
            } catch { continue } // A concurrent compaction can remove a file between reads.
        }
        return nil
    }

    static func parse(_ bytes: Data, now: Date) -> Sample? {
        guard let encoding = bytes.first, encoding == 0 || encoding == 1, bytes.count <= 16 * 1024,
              let text = String(data: bytes.dropFirst(), encoding: encoding == 1 ? .utf8 : .utf16LittleEndian),
              let data = text.data(using: .utf8), let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let used = number(object["utilization"]), (0...1).contains(used),
              let reset = number(object["resetsAt"]), reset > now.timeIntervalSince1970,
              reset <= now.timeIntervalSince1970 + 21_600,
              let observed = number(object["observedAt"]), observed > 0, observed <= now.timeIntervalSince1970,
              let wall = object["atWall"] as? NSNumber, CFGetTypeID(wall) == CFBooleanGetTypeID() else { return nil }
        return Sample(window: .init(id: "claude.five_hour", title: "5 小时", usedPercent: wall.boolValue ? 100 : used * 100,
                                    resetsAt: Date(timeIntervalSince1970: reset)),
                      observedAt: Date(timeIntervalSince1970: observed))
    }

    private static func number(_ value: Any?) -> Double? {
        guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), n.doubleValue.isFinite else { return nil }
        return n.doubleValue
    }
}

/// Bounded LevelDB table/log reader, restricted to one exact local-storage key.
/// https://github.com/google/leveldb/blob/main/doc/table_format.md
/// https://github.com/google/leveldb/blob/main/doc/log_format.md
private enum DesktopLevelDB {
    private enum Invalid: Error { case data }
    private static let maxFile = 16 * 1024 * 1024
    private static let maxBlock = 4 * 1024 * 1024

    private struct Cursor {
        let bytes: [UInt8]
        var position = 0
        var remaining: Int { bytes.count - position }
        mutating func take(_ count: Int) throws -> [UInt8] {
            guard count >= 0, count <= remaining else { throw Invalid.data }
            defer { position += count }
            return Array(bytes[position..<position + count])
        }
        mutating func byte() throws -> UInt8 {
            guard remaining > 0 else { throw Invalid.data }
            defer { position += 1 }; return bytes[position]
        }
        mutating func integer(_ count: Int) throws -> UInt64 {
            let b = try take(count)
            return b.enumerated().reduce(0) { $0 | UInt64($1.element) << ($1.offset * 8) }
        }
        mutating func varint() throws -> UInt64 {
            var n: UInt64 = 0
            for i in 0..<10 {
                let b = try byte()
                guard i < 9 || b <= 1 else { throw Invalid.data }
                n |= UInt64(b & 127) << (7 * i)
                if b < 128 { return n }
            }
            throw Invalid.data
        }
        mutating func lengthPrefixed() throws -> [UInt8] {
            let n = try varint()
            guard n <= UInt64(maxBlock) else { throw Invalid.data }
            return try take(Int(n))
        }
    }

    private struct Manifest {
        var tables: [UInt64: UInt64] = [:]
        var log: UInt64?
        var previousLog: UInt64 = 0
        var next: UInt64?
        var sequence: UInt64?
    }

    static func value(for key: Data, at root: URL) throws -> Data? {
        // Reject links on Claude's storage directories as well as on individual files.
        for directory in [root, root.deletingLastPathComponent(), root.deletingLastPathComponent().deletingLastPathComponent()] {
            let info = try directory.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
            guard info.isSymbolicLink != true, info.isDirectory == true else { throw Invalid.data }
        }
        let current = try read(root.appendingPathComponent("CURRENT"), limit: 128)
        guard let name = String(data: current, encoding: .utf8), name.hasSuffix("\n"),
              name.dropLast().range(of: "^MANIFEST-[0-9]+$", options: .regularExpression) != nil else { throw Invalid.data }
        let manifestURL = root.appendingPathComponent(String(name.dropLast()))
        let manifestBytes = try read(manifestURL)
        let manifest = try decodeManifest(Array(manifestBytes))
        guard let logNumber = manifest.log, manifest.next != nil, manifest.sequence != nil else { throw Invalid.data }
        let files = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        guard files.count <= 1024, manifest.tables.count <= 256 else { throw Invalid.data }
        var budget = manifestBytes.count
        var decodedWork = 0
        var newest: (sequence: UInt64, value: Data?)?
        func accept(_ sequence: UInt64, _ value: [UInt8]?) {
            if newest == nil || sequence > newest!.sequence { newest = (sequence, value.map { Data($0) }) }
        }
        func readBudgeted(_ url: URL) throws -> [UInt8] {
            let data = try read(url)
            budget += data.count
            guard budget <= 64 * 1024 * 1024 else { throw Invalid.data }
            return Array(data)
        }
        for number in manifest.tables.keys.sorted() {
            let stem = String(format: "%06llu", number)
            guard let file = files.first(where: { $0.lastPathComponent == stem + ".ldb" || $0.lastPathComponent == stem + ".sst" }) else { throw Invalid.data }
            try table(readBudgeted(file), work: &decodedWork) { internalKey, value in
                guard internalKey.count >= 8 else { throw Invalid.data }
                guard Data(internalKey.dropLast(8)) == key else { return }
                var tag = Cursor(bytes: Array(internalKey.suffix(8)))
                let packed = try tag.integer(8), type = packed & 255
                guard type <= 1 else { throw Invalid.data }
                accept(packed >> 8, type == 0 ? nil : value)
            }
        }
        let logs = files.compactMap { file -> (UInt64, URL)? in
            guard file.pathExtension == "log", let n = UInt64(file.deletingPathExtension().lastPathComponent),
                  n >= logNumber || n == manifest.previousLog else { return nil }
            return (n, file)
        }.sorted { $0.0 < $1.0 }
        for (_, file) in logs {
            for record in try logRecords(readBudgeted(file)) {
                var cursor = Cursor(bytes: record)
                let sequence = try cursor.integer(8), count = try cursor.integer(4)
                guard count <= 100_000, sequence <= (UInt64.max >> 8) - count else { throw Invalid.data }
                var selected: [(UInt64, [UInt8]?)] = []
                for index in 0..<count {
                    let type = try cursor.byte()
                    guard type <= 1 else { throw Invalid.data }
                    let entryKey = try cursor.lengthPrefixed()
                    let value = type == 1 ? try cursor.lengthPrefixed() : nil
                    if Data(entryKey) == key { selected.append((sequence + index, value)) }
                }
                guard cursor.remaining == 0 else { throw Invalid.data }
                for (sequence, value) in selected { accept(sequence, value) }
            }
        }
        // Retry rather than combine file sets across a concurrent manifest rotation/edit.
        guard try read(root.appendingPathComponent("CURRENT"), limit: 128) == current,
              try read(manifestURL) == manifestBytes else { throw Invalid.data }
        return newest?.value
    }

    private static func read(_ file: URL, limit: Int = maxFile) throws -> Data {
        let fd = open(file.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw Invalid.data }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_size >= 0,
              info.st_size <= limit else { throw Invalid.data }
        if info.st_size == 0 { return Data() }
        guard let data = try handle.read(upToCount: Int(info.st_size)),
              data.count == info.st_size else { throw Invalid.data }
        return data
    }

    private static func decodeManifest(_ bytes: [UInt8]) throws -> Manifest {
        var result = Manifest()
        for record in try logRecords(bytes) {
            var c = Cursor(bytes: record)
            var deleted: [UInt64] = [], added: [(UInt64, UInt64)] = []
            while c.remaining > 0 {
                switch try c.varint() {
                case 1:
                    guard String(bytes: try c.lengthPrefixed(), encoding: .utf8) == "leveldb.BytewiseComparator" else { throw Invalid.data }
                case 2: result.log = try c.varint()
                case 3: result.next = try c.varint()
                case 4: result.sequence = try c.varint()
                case 5: _ = try c.varint(); _ = try c.lengthPrefixed()
                case 6: _ = try c.varint(); deleted.append(try c.varint())
                case 7:
                    _ = try c.varint()
                    let number = try c.varint(), size = try c.varint()
                    _ = try c.lengthPrefixed(); _ = try c.lengthPrefixed()
                    added.append((number, size))
                case 9: result.previousLog = try c.varint()
                default: throw Invalid.data
                }
            }
            for number in deleted { result.tables.removeValue(forKey: number) }
            for (number, size) in added { result.tables[number] = size }
        }
        return result
    }

    private static func logRecords(_ bytes: [UInt8]) throws -> [[UInt8]] {
        var result: [[UInt8]] = [], partial: [UInt8]?, p = 0
        while p < bytes.count {
            let remaining = 32768 - p % 32768
            if remaining < 7 { p += remaining; continue }
            if bytes.count - p < 7 { break }
            var header = Cursor(bytes: Array(bytes[p..<p + 7]))
            let checksum = try header.integer(4), length = Int(try header.integer(2)), type = try header.byte()
            if type == 0 && length == 0 { partial = nil; p += remaining; continue }
            guard length <= remaining - 7 else { throw Invalid.data }
            if p + 7 + length > bytes.count { break } // An append in progress is not a committed sample.
            let payload = Array(bytes[p + 7..<p + 7 + length]); p += 7 + length
            guard checksum == UInt64(crc([type] + payload)) else { throw Invalid.data }
            switch type {
            case 1:
                guard partial == nil else { throw Invalid.data }; result.append(payload)
            case 2:
                guard partial == nil else { throw Invalid.data }; partial = payload
            case 3, 4:
                guard partial != nil, partial!.count + payload.count <= maxBlock else { throw Invalid.data }
                partial!.append(contentsOf: payload)
                if type == 4 { result.append(partial!); partial = nil }
            default: throw Invalid.data
            }
            guard result.count <= 100_000 else { throw Invalid.data }
        }
        return result
    }

    private static func table(_ bytes: [UInt8], work: inout Int, consume: ([UInt8], [UInt8]) throws -> Void) throws {
        guard bytes.count >= 48 else { throw Invalid.data }
        var footer = Cursor(bytes: Array(bytes.suffix(48)))
        _ = try footer.varint(); _ = try footer.varint() // metaindex
        let indexOffset = try footer.varint(), indexSize = try footer.varint()
        footer.position = 40
        guard try footer.integer(8) == 0xdb4775248b80fb57 else { throw Invalid.data }
        let index = try block(bytes, offset: indexOffset, size: indexSize)
        var handles: [(UInt64, UInt64)] = [], previousEnd: UInt64 = 0
        try entries(index, work: &work) { _, handle in
            var c = Cursor(bytes: handle)
            let offset = try c.varint(), size = try c.varint()
            guard c.remaining == 0, offset >= previousEnd, offset <= indexOffset,
                  size <= indexOffset - offset, size + 5 <= indexOffset - offset else { throw Invalid.data }
            previousEnd = offset + size + 5
            handles.append((offset, size))
        }
        for (offset, size) in handles {
            try entries(block(bytes, offset: offset, size: size), work: &work, consume: consume)
        }
    }

    private static func block(_ bytes: [UInt8], offset: UInt64, size: UInt64) throws -> [UInt8] {
        guard bytes.count >= 48, size <= UInt64(maxBlock), offset <= UInt64(bytes.count - 48),
              size + 5 <= UInt64(bytes.count - 48) - offset else { throw Invalid.data }
        let p = Int(offset), n = Int(size), codec = bytes[p + n]
        let raw = Array(bytes[p..<p + n])
        var check = Cursor(bytes: Array(bytes[p + n + 1..<p + n + 5]))
        guard try check.integer(4) == UInt64(crc(raw + [codec])) else { throw Invalid.data }
        if codec == 0 { return raw }
        guard codec == 1 else { throw Invalid.data }
        return try snappy(raw)
    }

    private static func entries(_ bytes: [UInt8], work: inout Int, consume: ([UInt8], [UInt8]) throws -> Void) throws {
        guard bytes.count >= 8 else { throw Invalid.data }
        var tail = Cursor(bytes: Array(bytes.suffix(4)))
        let restarts = try tail.integer(4)
        guard restarts > 0, restarts <= UInt64((bytes.count - 4) / 4) else { throw Invalid.data }
        let end = bytes.count - 4 - Int(restarts) * 4
        work += bytes.count
        guard work <= 64 * 1024 * 1024 else { throw Invalid.data }
        var c = Cursor(bytes: Array(bytes.prefix(end))), previous: [UInt8] = []
        while c.remaining > 0 {
            let shared = try c.varint(), nonshared = try c.varint(), valueSize = try c.varint()
            guard shared <= previous.count, nonshared <= maxBlock, valueSize <= maxBlock else { throw Invalid.data }
            work += Int(shared + nonshared + valueSize)
            guard work <= 64 * 1024 * 1024 else { throw Invalid.data }
            var key = Array(previous.prefix(Int(shared)))
            key += try c.take(Int(nonshared))
            guard key.count <= maxBlock else { throw Invalid.data }
            let value = try c.take(Int(valueSize))
            try consume(key, value); previous = key
        }
    }

    private static func snappy(_ bytes: [UInt8]) throws -> [UInt8] {
        var c = Cursor(bytes: bytes)
        let size = try c.varint()
        guard size <= maxBlock else { throw Invalid.data }
        var out: [UInt8] = []; out.reserveCapacity(Int(size))
        while c.remaining > 0 {
            let tag = try c.byte(), type = tag & 3
            if type == 0 {
                let encodedLength = Int(tag >> 2)
                let n = encodedLength < 60 ? UInt64(encodedLength) : try c.integer(encodedLength - 59)
                guard n < size, UInt64(out.count) + n + 1 <= size else { throw Invalid.data }
                out += try c.take(Int(n) + 1)
            } else {
                let length: Int, offset: Int
                if type == 1 {
                    length = 4 + Int((tag >> 2) & 7)
                    offset = Int(tag & 224) << 3 | Int(try c.byte())
                } else {
                    length = 1 + Int(tag >> 2)
                    offset = Int(try c.integer(type == 2 ? 2 : 4))
                }
                guard offset > 0, offset <= out.count, out.count + length <= Int(size) else { throw Invalid.data }
                for _ in 0..<length { out.append(out[out.count - offset]) }
            }
        }
        guard out.count == Int(size) else { throw Invalid.data }
        return out
    }

    private static let crcTable: [UInt32] = (0..<256).map { value in
        var c = UInt32(value)
        for _ in 0..<8 { c = (c >> 1) ^ (c & 1 == 1 ? 0x82f63b78 : 0) }
        return c
    }
    private static func crc(_ bytes: [UInt8]) -> UInt32 {
        var c = UInt32.max
        for b in bytes { c = (c >> 8) ^ crcTable[Int((c ^ UInt32(b)) & 255)] }
        c = ~c
        return ((c >> 15) | (c << 17)) &+ 0xa282ead8
    }
}
