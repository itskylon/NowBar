import Foundation

public struct ClaudeUsageHistoryResult: Sendable {
    public var records: [UsageRecord]
    public var incomplete: Bool
    public var scannedFileCount: Int
    public var totalFileCount: Int
    public var readBytes: UInt64
}

struct ClaudeHistoryReadLimits {
    var fileBytes = 64 * 1024 * 1024
    var scanBytes = 256 * 1024 * 1024
    var lineBytes = 4 * 1024 * 1024
}

/// Incremental local usage metadata. Conversation text is never retained between scans.
public final class ClaudeUsageHistoryReader: @unchecked Sendable {
    private var roots: [URL]
    private let limits: ClaudeHistoryReadLimits
    private let lock = NSLock()
    private var files: [String: FileState] = [:]

    public convenience init(root: URL) { self.init(roots: [root], limits: .init()) }
    public convenience init(roots: [URL]) { self.init(roots: roots, limits: .init()) }
    convenience init(root: URL, limits: ClaudeHistoryReadLimits) { self.init(roots: [root], limits: limits) }
    init(roots: [URL], limits: ClaudeHistoryReadLimits) {
        self.roots = Array(Set(roots.map(\.standardizedFileURL))).sorted { $0.path < $1.path }
        self.limits = limits
    }

    /// Reconfigure discovered session roots while retaining incremental state for existing files.
    public func updateRoots(_ roots: [URL]) {
        lock.lock()
        defer { lock.unlock() }
        self.roots = Array(Set(roots.map(\.standardizedFileURL))).sorted { $0.path < $1.path }
    }

    private struct Candidate {
        var url: URL
        var size: UInt64
        var modified: Date?
        var identity: String
    }
    private struct Entry {
        var id: String
        var date: Date
        var model: String
        var tokens: TokenCounts
        var write1h: Int64
        var ttlUpdatedAt: Date?
        var project: String?
        var session: String
        var conversation: String
    }
    private struct FileState {
        var identity = ""
        var modified: Date?
        // Resume at the start of a partial line rather than storing its private content.
        var offset: UInt64 = 0
        var readThrough: UInt64 = 0
        var discardingLine = false
        var partialLine = false
        var malformed = false
        var entries: [Entry] = []
    }

    public func scan(now: Date = Date()) -> ClaudeUsageHistoryResult {
        lock.lock()
        defer { lock.unlock() }
        var incomplete = false
        let candidates = discover(incomplete: &incomplete)
        let paths = Set(candidates.map { $0.url.path })
        files = files.filter { paths.contains($0.key) }
        var remaining = limits.scanBytes
        for file in candidates {
            var state = files[file.url.path] ?? FileState()
            if state.identity != file.identity || file.size < state.readThrough
                || (file.size == state.readThrough && state.modified != file.modified) {
                state = FileState()
            }
            let changed = state.modified != file.modified
            state.identity = file.identity
            state.modified = file.modified
            if state.readThrough < file.size || (state.partialLine && changed) {
                read(file, state: &state, remaining: &remaining)
            }
            if state.readThrough < file.size || state.partialLine || state.malformed { incomplete = true }
            files[file.url.path] = state
        }
        var unique: [String: Entry] = [:]
        var entries: [Entry] = []
        for path in files.keys.sorted() { entries.append(contentsOf: files[path]!.entries) }
        entries.removeAll { $0.date > now }
        entries.sort { lhs, rhs in
            if lhs.date == rhs.date { return lhs.id < rhs.id }
            return lhs.date < rhs.date
        }
        for var entry in entries {
            if let old = unique[entry.id] {
                entry.tokens = TokenCounts(input: max(old.tokens.input, entry.tokens.input),
                    output: max(old.tokens.output, entry.tokens.output),
                    cacheRead: max(old.tokens.cacheRead, entry.tokens.cacheRead),
                    cacheWrite: max(old.tokens.cacheWrite, entry.tokens.cacheWrite))
                if let oldTTL = old.ttlUpdatedAt, entry.ttlUpdatedAt == nil || oldTTL > entry.ttlUpdatedAt! {
                    entry.write1h = old.write1h
                    entry.ttlUpdatedAt = oldTTL
                }
                entry.write1h = min(entry.tokens.cacheWrite, entry.write1h)
                entry.date = old.date
                entry.project = old.project ?? entry.project
                if old.model != "未知模型" { entry.model = old.model }
            }
            unique[entry.id] = entry
        }
        var records: [UsageRecord] = unique.values.map { entry in
            let cost = ClaudeSource.estimateReferenceCost(model: entry.model, tokens: entry.tokens, write1h: entry.write1h)
            return UsageRecord(id: entry.id, date: entry.date, provider: .claude, model: entry.model,
                tokens: entry.tokens, estimatedCostUSD: cost, projectPath: entry.project,
                sessionID: entry.session, conversationID: entry.conversation)
        }
        records.sort { lhs, rhs in
            if lhs.date == rhs.date { return lhs.id < rhs.id }
            return lhs.date < rhs.date
        }
        let scanned = candidates.filter { (files[$0.url.path]?.readThrough ?? 0) >= $0.size }.count
        let readBytes = candidates.reduce(UInt64(0)) { $0 + (files[$1.url.path]?.readThrough ?? 0) }
        return .init(records: records, incomplete: incomplete, scannedFileCount: scanned,
                     totalFileCount: candidates.count, readBytes: readBytes)
    }

    private func discover(incomplete: inout Bool) -> [Candidate] {
        let manager = FileManager.default
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey, .fileSizeKey]
        var failed = false
        var candidates: [Candidate] = []
        var paths: Set<String> = []
        for root in roots {
            guard manager.fileExists(atPath: root.path) else { continue }
            guard let metadata = try? root.resourceValues(forKeys: keys),
                  metadata.isDirectory == true, metadata.isSymbolicLink != true else { continue }
            guard let enumerator = manager.enumerator(at: root, includingPropertiesForKeys: Array(keys),
                options: [.skipsHiddenFiles], errorHandler: { _, _ in failed = true; return true }) else {
                failed = true; continue
            }
            for case let url as URL in enumerator {
                guard let metadata = try? url.resourceValues(forKeys: keys) else { failed = true; continue }
                if metadata.isSymbolicLink == true { enumerator.skipDescendants(); continue }
                guard url.pathExtension == "jsonl", metadata.isRegularFile == true else { continue }
                let url = url.standardizedFileURL
                guard paths.insert(url.path).inserted else { continue }
                guard let size = metadata.fileSize, size >= 0 else { failed = true; continue }
                let attributes = try? manager.attributesOfItem(atPath: url.path)
                let identity = (attributes?[.systemFileNumber] as? NSNumber)?.stringValue ?? url.path
                candidates.append(.init(url: url, size: UInt64(size), modified: metadata.contentModificationDate, identity: identity))
            }
        }
        incomplete = incomplete || failed
        return candidates.sorted {
            if $0.modified != $1.modified { return ($0.modified ?? .distantPast) > ($1.modified ?? .distantPast) }
            return $0.url.path < $1.url.path
        }
    }

    private func read(_ file: Candidate, state: inout FileState, remaining: inout Int) {
        guard remaining > 0 else { return }
        guard let handle = try? FileHandle(forReadingFrom: file.url) else { state.malformed = true; return }
        defer { try? handle.close() }
        do { try handle.seek(toOffset: state.offset) }
        catch { state.malformed = true; return }
        var buffer = Data()
        var cursor = state.offset
        var lineStart = state.offset
        var budget = min(limits.fileBytes, remaining)
        // A resumable line must fit in one scan; production limits allow up to 4 MiB.
        let lineLimit = min(limits.lineBytes, max(1, min(limits.fileBytes, limits.scanBytes) / 2))
        state.partialLine = false
        while budget > 0 {
            let chunk: Data
            do { chunk = try handle.read(upToCount: min(65_536, budget)) ?? Data() }
            catch { state.malformed = true; break }
            guard !chunk.isEmpty else { break }
            cursor += UInt64(chunk.count)
            budget -= chunk.count
            remaining -= chunk.count
            buffer.append(chunk)
            while let newline = buffer.firstIndex(of: 10) {
                let length = buffer.distance(from: buffer.startIndex, to: newline) + 1
                if !state.discardingLine {
                    let line = Data(buffer[..<newline])
                    if line.count <= lineLimit { consume(line, file: file.url, offset: lineStart, state: &state) }
                    else { state.malformed = true }
                }
                buffer.removeSubrange(...newline)
                lineStart += UInt64(length)
                state.discardingLine = false
            }
            if buffer.count > lineLimit {
                buffer.removeAll(keepingCapacity: false)
                lineStart = cursor
                state.discardingLine = true
                state.malformed = true
            }
        }
        state.offset = lineStart
        state.readThrough = cursor
        state.partialLine = !buffer.isEmpty || state.discardingLine
        // buffer is intentionally discarded, including any partial assistant content.
    }

    private func consume(_ line: Data, file: URL, offset: UInt64, state: inout FileState) {
        guard !line.isEmpty, line.range(of: Data("\"usage\"".utf8)) != nil else { return }
        guard let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else {
            state.malformed = true; return
        }
        guard object["type"] as? String == "assistant", let message = object["message"] as? [String: Any],
              let usage = message["usage"] as? [String: Any] else { return }
        let model = message["model"] as? String ?? "未知模型"
        guard model != "<synthetic>" else { return }
        guard let stamp = object["timestamp"] as? String, let date = MeterDate.parse(stamp) else {
            state.malformed = true; return
        }
        func count(_ value: Any?) -> Int64? {
            guard let value else { return 0 }
            guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(),
                  n.doubleValue.isFinite, n.doubleValue >= 0, n.doubleValue <= 1e12,
                  n.doubleValue.rounded() == n.doubleValue else { return nil }
            return n.int64Value
        }
        let creation = usage["cache_creation"] as? [String: Any] ?? [:]
        guard let input = count(usage["input_tokens"]), let output = count(usage["output_tokens"]),
              let read = count(usage["cache_read_input_tokens"]), let write = count(usage["cache_creation_input_tokens"]),
              let oneHour = count(creation["ephemeral_1h_input_tokens"]),
              let fiveMinute = count(creation["ephemeral_5m_input_tokens"]) else { state.malformed = true; return }
        let tokens = TokenCounts(input: input, output: output, cacheRead: read, cacheWrite: max(write, oneHour + fiveMinute))
        let conversation = nonempty(object["sessionId"]) ?? nonempty(object["session_id"]) ?? file.path
        let fileAgent = file.deletingLastPathComponent().lastPathComponent == "subagents" ? file.deletingPathExtension().lastPathComponent : nil
        let agent = nonempty(object["agentId"]) ?? fileAgent
        let session = agent.map { conversation + ":agent:" + $0 } ?? conversation
        let identity = nonempty(message["id"]) ?? nonempty(object["requestId"]) ?? nonempty(object["request_id"])
            ?? nonempty(object["uuid"]) ?? "\(file.path)#\(offset)"
        let ttlKnown = creation["ephemeral_1h_input_tokens"] != nil || creation["ephemeral_5m_input_tokens"] != nil
        let cwd = nonempty(object["cwd"]).flatMap { $0.hasPrefix("/") ? $0 : nil }
        state.entries.append(.init(id: "claude:\(session):\(identity)", date: date, model: model,
            tokens: tokens, write1h: oneHour, ttlUpdatedAt: ttlKnown ? date : nil,
            project: cwd, session: session, conversation: conversation))
    }

    private func nonempty(_ value: Any?) -> String? {
        guard let value = value as? String, !value.isEmpty else { return nil }
        return value
    }
}
