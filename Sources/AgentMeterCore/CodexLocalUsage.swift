import Foundation

public struct CodexLocalUsageResult: Sendable {
    public var days: [DayUsage]
    public var incomplete: Bool
    public var latestUsageAt: Date?
    public var records: [UsageRecord]
    public var scannedFileCount: Int
    public var totalFileCount: Int
    public var readBytes: UInt64
}

struct CodexLogReadLimits {
    var fileBytes = 64 * 1024 * 1024
    var scanBytes = 256 * 1024 * 1024
    var lineBytes = 4 * 1024 * 1024
}

/// Incrementally reads usage metadata only. It never retains conversation records.
public final class CodexLocalUsageReader: @unchecked Sendable {
    public typealias CostEstimate = (String, TokenCounts, Int64, String?) -> Double?
    private let root: URL
    private let estimateCost: CostEstimate
    private let limits: CodexLogReadLimits
    private let includeAllHistory: Bool
    private let lock = NSLock()
    private var files: [String: FileState] = [:]
    private let fractionalDate = ISO8601DateFormatter()
    private let wholeDate = ISO8601DateFormatter()
    private let typePattern = try! NSRegularExpression(pattern: #""type"\s*:\s*"([^"\\]+)""#)

    public convenience init(root: URL, includeAllHistory: Bool = false, estimateCost: @escaping CostEstimate = { _, _, _, _ in nil }) {
        self.init(root: root, estimateCost: estimateCost, readLimits: .init(), includeAllHistory: includeAllHistory)
    }

    init(root: URL, estimateCost: @escaping CostEstimate, readLimits: CodexLogReadLimits, includeAllHistory: Bool = false) {
        self.root = root
        self.estimateCost = estimateCost
        limits = readLimits
        self.includeAllHistory = includeAllHistory
        fractionalDate.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        wholeDate.formatOptions = [.withInternetDateTime]
    }

    public func scan(now: Date = Date(), calendar: Calendar = .current) -> CodexLocalUsageResult {
        lock.lock()
        defer { lock.unlock() }
        let today = calendar.startOfDay(for: now)
        guard let recentStart = calendar.date(byAdding: .day, value: -6, to: today),
              let end = calendar.date(byAdding: .day, value: 1, to: today) else {
            return .init(days: [], incomplete: true, latestUsageAt: nil, records: [], scannedFileCount: 0, totalFileCount: 0, readBytes: 0)
        }
        let start = includeAllHistory ? Date.distantPast : recentStart
        var incomplete = false
        let candidates = discoverFiles(since: start, incomplete: &incomplete)
        let paths = Set(candidates.map { $0.url.path })
        files = files.filter { paths.contains($0.key) }
        var remaining = limits.scanBytes
        for candidate in candidates {
            var state = files[candidate.url.path] ?? FileState()
            if state.fileID != candidate.fileID || candidate.size < state.offset
                || (candidate.size == state.offset && candidate.modified != state.modified) {
                state = FileState()
            }
            state.fileID = candidate.fileID
            state.modified = candidate.modified
            if candidate.size > state.offset {
                read(candidate.url, state: &state, remaining: &remaining, start: start, end: end)
            }
            if state.offset < candidate.size || !state.pending.isEmpty || state.malformed {
                incomplete = true
            }
            state.events.removeAll { $0.date < start || $0.date >= end }
            files[candidate.url.path] = state
        }
        let scanned = candidates.filter { (files[$0.url.path]?.offset ?? 0) >= $0.size }.count
        return aggregate(start: start, end: end, now: now, calendar: calendar, incomplete: incomplete,
                         scannedFileCount: scanned, totalFileCount: candidates.count)
    }

    private struct Candidate {
        var url: URL
        var size: UInt64
        var modified: Date?
        var fileID: String
    }

    private func discoverFiles(since start: Date, incomplete: inout Bool) -> [Candidate] {
        let manager = FileManager.default
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey, .fileSizeKey, .fileResourceIdentifierKey]
        var result: [Candidate] = []
        for directory in ["sessions", "archived_sessions"] {
            let folder = root.appendingPathComponent(directory, isDirectory: true)
            guard manager.fileExists(atPath: folder.path) else { continue }
            var directoryFailed = false
            guard let enumerator = manager.enumerator(at: folder, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles], errorHandler: { _, _ in
                directoryFailed = true
                return true
            }) else { incomplete = true; continue }
            for case let url as URL in enumerator {
                guard url.pathExtension == "jsonl" else { continue }
                guard let metadata = try? url.resourceValues(forKeys: keys) else { incomplete = true; continue }
                guard metadata.isRegularFile == true, metadata.isSymbolicLink != true else { continue }
                if !includeAllHistory, let date = metadata.contentModificationDate, date < start { continue }
                guard let size = metadata.fileSize, size >= 0 else { incomplete = true; continue }
                let attributes = try? manager.attributesOfItem(atPath: url.path)
                let identity = (attributes?[.systemFileNumber] as? NSNumber)?.stringValue ?? url.path
                result.append(.init(url: url, size: UInt64(size), modified: metadata.contentModificationDate, fileID: identity))
            }
            incomplete = incomplete || directoryFailed
        }
        return result.sorted {
            if $0.modified != $1.modified { return ($0.modified ?? .distantPast) > ($1.modified ?? .distantPast) }
            return $0.url.path < $1.url.path
        }
    }

    private struct RawUsage: Equatable {
        var input: Int64
        var read: Int64
        var write: Int64
        var output: Int64
        var reasoning: Int64
        var signature: String { "\(input):\(read):\(write):\(output):\(reasoning)" }
        var counts: TokenCounts {
            .init(input: input - read - write, output: output, cacheRead: read, cacheWrite: write, reasoning: reasoning)
        }
    }

    private struct UsageEvent {
        var id: String
        var date: Date
        var model: String
        var tier: String?
        var usage: RawUsage
        var legacy: Bool
        var pairedRecord: String?
        var cumulative: RawUsage?
        var segment: Int
        var sessionID: String
        var conversationID: String?
        var firstConversationID: String?
        var turnProjectPath: String?
        var firstProjectPath: String?
        var attributionQuality: Int
    }

    private struct ThreadMetadata {
        var id: String?
        var conversationID: String?
        var projectPath: String?
        var parentID: String?
    }

    private struct TurnMetadata {
        var model: String?
        var tier: String?
        var projectPath: String?
    }

    private struct FileState {
        var offset: UInt64 = 0
        var modified: Date?
        var fileID = ""
        var pending = Data()
        var discardingLine = false
        var malformed = false
        var model = "未知模型"
        var tier: String?
        var session = ""
        var segment = 0
        var firstMetadata: ThreadMetadata?
        var metadata: [String: ThreadMetadata] = [:]
        var turns: [String: TurnMetadata] = [:]
        var currentTurn: TurnMetadata?
        var cumulativeBySession: [String: RawUsage] = [:]
        var events: [UsageEvent] = []
        var pairedRecordIDs: Set<String> = []
    }

    private func read(_ url: URL, state: inout FileState, remaining: inout Int, start: Date, end: Date) {
        guard remaining > 0 else { return }
        guard let handle = try? FileHandle(forReadingFrom: url) else { state.malformed = true; return }
        defer { try? handle.close() }
        do { try handle.seek(toOffset: state.offset) }
        catch { state.malformed = true; return }
        var fileBudget = min(limits.fileBytes, remaining)
        while fileBudget > 0 {
            let data: Data
            do { data = try handle.read(upToCount: min(65_536, fileBudget)) ?? Data() }
            catch { state.malformed = true; break }
            if data.isEmpty { break }
            state.offset += UInt64(data.count)
            remaining -= data.count
            fileBudget -= data.count
            state.pending.append(data)
            while let newline = state.pending.firstIndex(of: 10) {
                let line = Data(state.pending[..<newline])
                state.pending.removeSubrange(...newline)
                if !state.discardingLine {
                    if line.count <= limits.lineBytes { consume(line, state: &state, start: start, end: end) }
                    else { state.malformed = true }
                }
                state.discardingLine = false
            }
            if state.pending.count > limits.lineBytes {
                state.pending.removeAll(keepingCapacity: false)
                state.discardingLine = true
                state.malformed = true
            }
            // Do not retain a partial response_item or conversation line between scans.
            if !state.pending.isEmpty, state.discardingLine || isConversationPrefix(state.pending)
                || (!mayContainMetadata(state.pending) && state.pending.count > 256) {
                state.pending.removeAll(keepingCapacity: false)
                state.discardingLine = true
            }
        }
    }

    private func headerTypes(_ data: Data) -> [String] {
        let text = String(decoding: data.prefix(1024), as: UTF8.self)
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return typePattern.matches(in: text, range: range).prefix(2).compactMap {
            guard let match = Range($0.range(at: 1), in: text) else { return nil }
            return String(text[match])
        }
    }

    private func isConversationPrefix(_ data: Data) -> Bool {
        let types = headerTypes(data)
        guard let type = types.first else { return false }
        if type == "event_msg" { return types.count > 1 && types[1] != "token_count" }
        return !["session_meta", "turn_context", "token_usage_record"].contains(type)
    }

    private func mayContainMetadata(_ data: Data) -> Bool {
        let types = headerTypes(data)
        guard let type = types.first else { return false }
        if type == "event_msg" { return types.count > 1 && types[1] == "token_count" }
        return ["session_meta", "turn_context", "token_usage_record"].contains(type)
    }

    private func rawUsage(_ object: Any?) -> RawUsage? {
        guard let value = object as? [String: Any] else { return nil }
        func count(_ key: String, optional: Bool = false) -> Int64? {
            if value[key] == nil, optional { return 0 }
            guard let number = value[key] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                  number.doubleValue.isFinite, number.doubleValue >= 0, number.doubleValue <= 1_000_000_000_000,
                  number.doubleValue.rounded() == number.doubleValue else { return nil }
            return number.int64Value
        }
        guard let input = count("input_tokens"), let output = count("output_tokens"),
              let read = count("cached_input_tokens", optional: true), let write = count("cache_write_input_tokens", optional: true),
              let reasoning = count("reasoning_output_tokens", optional: true), read + write <= input, reasoning <= output else { return nil }
        if value["total_tokens"] != nil, count("total_tokens") != input + output { return nil }
        return .init(input: input, read: read, write: write, output: output, reasoning: reasoning)
    }

    private func nonempty(_ value: Any?) -> String? {
        guard let value = value as? String, !value.isEmpty else { return nil }
        return value
    }

    private func mergeMetadata(_ preferred: ThreadMetadata, fallback: ThreadMetadata) -> ThreadMetadata {
        .init(id: preferred.id ?? fallback.id, conversationID: preferred.conversationID ?? fallback.conversationID,
              projectPath: preferred.projectPath ?? fallback.projectPath, parentID: preferred.parentID ?? fallback.parentID)
    }

    private func consume(_ line: Data, state: inout FileState, start: Date, end: Date) {
        guard !line.isEmpty, mayContainMetadata(line) else { return }
        guard let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
              let type = object["type"] as? String, let payload = object["payload"] as? [String: Any] else {
            state.malformed = true; return
        }
        if type == "session_meta" {
            let source = payload["source"] as? [String: Any]
            let subagent = source?["subagent"] as? [String: Any]
            let spawn = subagent?["thread_spawn"] as? [String: Any]
            let metadata = ThreadMetadata(id: nonempty(payload["id"]), conversationID: nonempty(payload["session_id"]),
                projectPath: nonempty(payload["cwd"]), parentID: nonempty(payload["parent_thread_id"]) ?? nonempty(spawn?["parent_thread_id"]))
            if state.firstMetadata == nil { state.firstMetadata = metadata }
            if let id = metadata.id {
                state.session = id
                state.metadata[id] = state.metadata[id].map { mergeMetadata($0, fallback: metadata) } ?? metadata
            }
            state.segment += 1
            return
        }
        if type == "turn_context" {
            state.model = payload["model"] as? String ?? "未知模型"
            state.tier = payload["service_tier"] as? String
            let turn = TurnMetadata(model: nonempty(payload["model"]), tier: nonempty(payload["service_tier"]), projectPath: nonempty(payload["cwd"]))
            state.currentTurn = turn
            if let id = nonempty(payload["turn_id"]) { state.turns[id] = turn }
            return
        }
        guard type == "token_usage_record" || (type == "event_msg" && payload["type"] as? String == "token_count") else { return }
        let usage: RawUsage
        let legacy = type != "token_usage_record"
        var cumulative: RawUsage?
        if legacy {
            guard let info = payload["info"] as? [String: Any] else { return }
            if let total = info["total_token_usage"] as? [String: Any],
               (total["input_tokens"] as? NSNumber)?.int64Value == 0,
               (total["output_tokens"] as? NSNumber)?.int64Value == 0,
               let contextSize = total["total_tokens"] as? NSNumber, contextSize.doubleValue > 0 {
                // Codex recomputes a context-size estimate after compaction; this is not a billable request.
                return
            }
            cumulative = rawUsage(info["total_token_usage"])
            if let total = info["total_token_usage"], !(total is NSNull), cumulative == nil {
                state.malformed = true; return
            }
            if let cumulative, state.cumulativeBySession[state.session] == cumulative { return }
            if let cumulative { state.cumulativeBySession[state.session] = cumulative }
            guard let sample = rawUsage(info["last_token_usage"]) else {
                if info["last_token_usage"] != nil || cumulative != nil { state.malformed = true }
                return
            }
            usage = sample
        } else {
            guard let sample = rawUsage(payload["usage"]) else { state.malformed = true; return }
            usage = sample
            cumulative = rawUsage(payload["thread_token_usage"])
        }
        guard let stamp = object["timestamp"] as? String,
              let date = fractionalDate.date(from: stamp) ?? wholeDate.date(from: stamp) else { state.malformed = true; return }
        guard date >= start, date < end else { return }
        let id: String
        if legacy {
            // Cloned legacy history retains both its timestamp and cumulative counters.
            id = "legacy:\(stamp):\(cumulative?.signature ?? "none"):\(usage.signature)"
        } else if let response = payload["response_id"] as? String, !response.isEmpty {
            id = "response:\(response)"
        } else {
            id = "record:\(stamp):\(payload["thread_id"] as? String ?? state.session):\(usage.signature)"
        }
        let sessionID = nonempty(payload["thread_id"]) ?? state.firstMetadata?.id ?? "file:\(state.fileID)"
        let turnID = nonempty(payload["turn_id"])
        let matchedTurn = turnID.flatMap { state.turns[$0] }
        let turn = matchedTurn ?? (turnID == nil ? state.currentTurn : nil)
        let model = matchedTurn?.model ?? state.model
        let conversationID = nonempty(payload["session_id"])
        let quality = (state.firstMetadata?.id == sessionID ? 8 : 0) + (matchedTurn != nil ? 4 : 0)
            + (model == "未知模型" ? 0 : 2) + (conversationID != nil ? 1 : 0)
        var event = UsageEvent(id: id, date: date, model: model, tier: nonempty(payload["service_tier"]) ?? turn?.tier,
            usage: usage, legacy: legacy, cumulative: cumulative, segment: state.segment, sessionID: sessionID,
            conversationID: conversationID, firstConversationID: state.firstMetadata?.conversationID,
            turnProjectPath: turn?.projectPath, firstProjectPath: state.firstMetadata?.projectPath, attributionQuality: quality)
        // Prefer exact counters before considering a nearby pair with less metadata.
        // The two formats can use different cumulative bases after a fork or compaction;
        // in that case only the nearest unpaired usage record can establish a pairing.
        let unpaired = state.events.indices.reversed().filter {
            let previous = state.events[$0]
            return previous.segment == state.segment
                && (previous.legacy ? previous.pairedRecord == nil : !state.pairedRecordIDs.contains(previous.id))
        }
        let exact = unpaired.first {
            let previous = state.events[$0]
            guard previous.legacy != legacy, previous.usage == usage,
                  let total = previous.cumulative, let cumulative else { return false }
            return total == cumulative
        }
        let nearby = unpaired.first.flatMap { index -> Int? in
            let previous = state.events[index]
            return previous.legacy != legacy && previous.usage == usage ? index : nil
        }
        if let index = exact ?? nearby {
            let recordID: String
            if legacy {
                recordID = state.events[index].id
                event.pairedRecord = recordID
            } else {
                recordID = event.id
                state.events[index].pairedRecord = recordID
            }
            state.pairedRecordIDs.insert(recordID)
        }
        state.events.append(event)
    }

    private func aggregate(start: Date, end: Date, now: Date, calendar: Calendar, incomplete: Bool,
                           scannedFileCount: Int, totalFileCount: Int) -> CodexLocalUsageResult {
        var metadata: [String: ThreadMetadata] = [:]
        var primaryMetadata: Set<String> = []
        for path in files.keys.sorted() {
            let state = files[path]!
            for (id, value) in state.metadata {
                let primary = state.firstMetadata?.id == id
                if let old = metadata[id] {
                    metadata[id] = primary && !primaryMetadata.contains(id)
                        ? mergeMetadata(value, fallback: old) : mergeMetadata(old, fallback: value)
                } else { metadata[id] = value }
                if primary { primaryMetadata.insert(id) }
            }
        }
        func conversationRoot(_ session: String) -> String {
            var current = session
            var seen: Set<String> = []
            while let parent = metadata[current]?.parentID {
                guard seen.insert(current).inserted else { return session }
                current = parent
            }
            return current
        }
        let all = files.keys.sorted().flatMap { files[$0]!.events }.filter { $0.date >= start && $0.date < end && $0.date <= now }
        let pairedLegacy = Set(all.filter { $0.legacy && $0.pairedRecord != nil }.map(\.id))
        var unique: [String: UsageEvent] = [:]
        for event in all where !event.legacy || (!pairedLegacy.contains(event.id) && event.pairedRecord == nil) {
            if let old = unique[event.id] {
                var preferred = old.attributionQuality >= event.attributionQuality ? old : event
                let fallback = old.attributionQuality >= event.attributionQuality ? event : old
                if preferred.model == "未知模型" {
                    preferred.model = fallback.model
                    preferred.tier = preferred.tier ?? fallback.tier
                }
                unique[event.id] = preferred
            } else { unique[event.id] = event }
        }
        let values = unique.values.sorted { $0.date == $1.date ? $0.id < $1.id : $0.date < $1.date }
        let records: [UsageRecord] = values.map { event in
            let estimate = estimateCost(event.model, event.usage.counts, event.usage.input, event.tier)
            let cost = estimate.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
            return .init(id: event.id, date: event.date, provider: .codex, model: event.model, tokens: event.usage.counts,
                estimatedCostUSD: cost, projectPath: event.turnProjectPath ?? metadata[event.sessionID]?.projectPath ?? event.firstProjectPath,
                sessionID: event.sessionID, conversationID: event.conversationID ?? event.firstConversationID ?? conversationRoot(event.sessionID))
        }
        let byDay = Dictionary(grouping: records) { MeterDate.day($0.date, calendar: calendar) }
        var days: [DayUsage] = []
        for (day, events) in byDay {
            let byModel = Dictionary(grouping: events, by: \.model)
            var models: [ModelUsage] = []
            for (model, samples) in byModel {
                var counts = TokenCounts()
                var cost = 0.0
                var priced = true
                for sample in samples {
                    counts = counts + sample.tokens
                    if let estimate = sample.estimatedCostUSD {
                        cost += estimate
                    } else { priced = false }
                }
                models.append(.init(model: model, tokens: counts, estimatedCostUSD: priced ? cost : nil))
            }
            models.sort { $0.tokens.total == $1.tokens.total ? $0.model < $1.model : $0.tokens.total > $1.tokens.total }
            let counts = models.reduce(TokenCounts()) { $0 + $1.tokens }
            let missing = models.filter { $0.estimatedCostUSD == nil }.map(\.model).sorted()
            let cost: Double? = missing.isEmpty ? models.reduce(0.0) { $0 + ($1.estimatedCostUSD ?? 0) } : nil
            days.append(.init(day: day, totalTokens: counts.total, tokens: counts, models: models,
                              estimatedCostUSD: cost, unpricedModels: missing))
        }
        days.sort { $0.day < $1.day }
        return .init(days: days, incomplete: incomplete, latestUsageAt: values.last?.date, records: records,
                     scannedFileCount: scannedFileCount, totalFileCount: totalFileCount,
                     readBytes: files.values.reduce(UInt64(0)) { $0 + $1.offset })
    }
}
