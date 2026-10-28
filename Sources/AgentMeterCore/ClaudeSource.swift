import Foundation

public enum ClaudeSource {
    public enum SourceError: LocalizedError {
        case invalidBridge
        public var errorDescription: String? { "Claude 额度快照格式无效；等待 Claude Code 再次更新。" }
    }

    public static func parseBridge(_ data: Data, now: Date = Date()) throws -> ProviderSnapshot {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rawDate = object["updated_at"] as? String, let updated = MeterDate.parse(rawDate),
              let limits = object["rate_limits"] as? [String: Any] else { throw SourceError.invalidBridge }
        var windows: [LimitWindow] = []
        for (key, title) in [("five_hour", "5 小时"), ("seven_day", "每周")] {
            guard let item = limits[key] as? [String: Any],
                  let used = number(item["used_percentage"]), used >= 0, used <= 100,
                  let reset = number(item["resets_at"]), reset > 0 else { continue }
            windows.append(.init(id: "claude.\(key)", title: title, usedPercent: used,
                                 resetsAt: Date(timeIntervalSince1970: reset)))
        }
        var messages: [String] = []
        if windows.isEmpty { messages.append("当前状态栏未提供订阅额度；需使用支持额度输出的 Claude Code 版本和订阅账号。") }
        if now.timeIntervalSince(updated) > 600 { messages.append("额度为上次 Claude Code 会话快照，等待会话更新。") }
        if windows.contains(where: { $0.expired(at: now) }) { messages.append("部分额度窗口已过期，等待 Claude Code 刷新。") }
        var snapshot = ProviderSnapshot(provider: .claude, windows: windows, updatedAt: updated,
                     sourceNote: "Claude Code 官方状态栏快照；仅在会话活动时更新。",
                     message: messages.isEmpty ? nil : messages.joined(separator: " "))
        snapshot.quotaSource = .claudeCode
        return snapshot
    }

    public static func load(home: URL = FileManager.default.homeDirectoryForCurrentUser) throws -> ProviderSnapshot {
        let bridge = home.appendingPathComponent("Library/Application Support/AgentMeter/claude-usage.json")
        var snapshot: ProviderSnapshot
        if ClaudeDesktopSource.isPresent(home: home) {
            snapshot = ClaudeDesktopSource.load(home: home)
        } else if FileManager.default.fileExists(atPath: bridge.path) {
            do { snapshot = try parseBridge(Data(contentsOf: bridge)) }
            catch {
                snapshot = .init(provider: .claude, message: SourceError.invalidBridge.localizedDescription)
                snapshot.quotaReadFailed = true
            }
        } else {
            snapshot = .init(provider: .claude, message: "在设置中接入 Claude Code，首个回复后显示订阅额度。")
        }
        if snapshot.quotaSource == nil { snapshot.quotaSource = .claudeCode }
        snapshot.quotaMessage = snapshot.message
        let roots = [home.appendingPathComponent(".claude/projects")] + ClaudeDesktopProjects.roots(home: home)
        let logs = scanLogs(roots)
        snapshot.days = logs.days
        let historyNote = "Token：本机 Claude Code / Cowork 日志 · 本地日期；普通聊天 Token 未提供，参考费用非订阅账单。"
        snapshot.sourceNote = snapshot.quotaSource == .claudeDesktop ? snapshot.sourceNote + " " + historyNote : historyNote
        if logs.incomplete {
            snapshot.historyReadFailed = true
            snapshot.message = [snapshot.message, "部分日志无法读取、过大或格式损坏，统计可能不完整。"].compactMap { $0 }.joined(separator: " ")
        }
        return snapshot
    }

    private static func number(_ value: Any?) -> Double? {
        guard let value = value as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(), value.doubleValue.isFinite else { return nil }
        return value.doubleValue
    }

    private struct Entry {
        var day: String
        var model: String
        var tokens: TokenCounts
        var write1h: Int64
        var ttlUpdatedAt: Date?
        // The inferred 5-minute remainder is derived, never independently merged.
        // Late TTL details can reclassify existing tokens without adding tokens.
        var write5m: Int64 { max(0, tokens.cacheWrite - write1h) }
    }

    private static func count(_ value: Any?) -> Int64 {
        guard let n = number(value), n >= 0, n < 1e12 else { return 0 }
        return Int64(n)
    }

    private static func scanLogs(_ roots: [URL]) -> (days: [DayUsage], incomplete: Bool) {
        let calendar = Calendar.current
        let start = calendar.date(byAdding: .day, value: -6, to: calendar.startOfDay(for: Date()))!
        let end = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: Date()))!
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey, .fileSizeKey]
        var entries: [String: Entry] = [:]
        var incomplete = false
        var bytesRead = 0
        for root in Set(roots).sorted(by: { $0.path < $1.path }) {
            guard FileManager.default.fileExists(atPath: root.path) else { continue }
            guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else { incomplete = true; continue }
            for case let file as URL in enumerator {
                guard file.pathExtension == "jsonl" else { continue }
                guard let values = try? file.resourceValues(forKeys: Set(keys)), values.isRegularFile == true, values.isSymbolicLink != true else { continue }
                if let modified = values.contentModificationDate, modified < start { continue }
                if bytesRead >= 256 * 1024 * 1024 { incomplete = true; break }
                guard let handle = try? FileHandle(forReadingFrom: file) else { incomplete = true; continue }
                defer { try? handle.close() }
                var buffer = Data()
                var lineNumber = 0
                var fileRead = 0
                var discardingOversizedLine = false
                // Long-running sessions may be huge. Read their newest 64 MiB so
                // current activity remains visible; explicitly mark partial totals.
                if let size = values.fileSize, size > 64 * 1024 * 1024 {
                    do {
                        try handle.seek(toOffset: UInt64(size - 64 * 1024 * 1024))
                        discardingOversizedLine = true
                        incomplete = true
                    } catch { incomplete = true; continue }
                }
                func consume(_ line: Data) {
                    lineNumber += 1
                    guard !line.isEmpty else { return }
                    // Avoid deserializing conversation records that contain no usage.
                    guard line.range(of: Data("\"usage\"".utf8)) != nil else { return }
                    guard let obj = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else { incomplete = true; return }
                    guard obj["type"] as? String == "assistant", let message = obj["message"] as? [String: Any],
                          let usage = message["usage"] as? [String: Any],
                          let stamp = obj["timestamp"] as? String, let date = MeterDate.parse(stamp), date >= start, date < end else { return }
                    let model = message["model"] as? String ?? "未知模型"
                    guard model != "<synthetic>" else { return }
                    let creation = usage["cache_creation"] as? [String: Any] ?? [:]
                    let write1h = count(creation["ephemeral_1h_input_tokens"])
                    let write5m = count(creation["ephemeral_5m_input_tokens"])
                    let hasTTLDetails = number(creation["ephemeral_1h_input_tokens"]) != nil
                        || number(creation["ephemeral_5m_input_tokens"]) != nil
                    let totalWrite = max(count(usage["cache_creation_input_tokens"]), write1h + write5m)
                    let tokens = TokenCounts(input: count(usage["input_tokens"]), output: count(usage["output_tokens"]),
                                             cacheRead: count(usage["cache_read_input_tokens"]), cacheWrite: totalWrite)
                    let session = obj["sessionId"] as? String ?? obj["session_id"] as? String ?? file.deletingPathExtension().lastPathComponent
                    let identity = message["id"] as? String ?? obj["requestId"] as? String ?? obj["request_id"] as? String ?? obj["uuid"] as? String ?? "\(file.path)#\(lineNumber)"
                    let key = session + ":" + identity
                    var entry = Entry(day: MeterDate.day(date), model: model, tokens: tokens,
                                      write1h: write1h, ttlUpdatedAt: hasTTLDetails ? date : nil)
                    if let old = entries[key] {
                        entry.tokens = .init(input: max(old.tokens.input, tokens.input), output: max(old.tokens.output, tokens.output),
                                             cacheRead: max(old.tokens.cacheRead, tokens.cacheRead), cacheWrite: max(old.tokens.cacheWrite, tokens.cacheWrite))
                        if let oldDate = old.ttlUpdatedAt,
                           entry.ttlUpdatedAt == nil || oldDate > entry.ttlUpdatedAt! {
                            entry.write1h = old.write1h
                            entry.ttlUpdatedAt = oldDate
                        }
                        entry.write1h = min(entry.tokens.cacheWrite, entry.write1h)
                        entry.day = old.day
                    }
                    entries[key] = entry
                }
                while true {
                    guard let chunk = try? handle.read(upToCount: 65536) else { incomplete = true; break }
                    if chunk.isEmpty { break }
                    fileRead += chunk.count; bytesRead += chunk.count
                    if fileRead > 64 * 1024 * 1024 || bytesRead > 256 * 1024 * 1024 { incomplete = true; break }
                    buffer.append(chunk)
                    while let newline = buffer.firstIndex(of: 10) {
                        let line = buffer[..<newline]
                        if !discardingOversizedLine { consume(Data(line)) }
                        buffer.removeSubrange(...newline)
                        discardingOversizedLine = false
                    }
                    if buffer.count > 4 * 1024 * 1024 { buffer.removeAll(keepingCapacity: true); discardingOversizedLine = true; incomplete = true }
                }
                if !buffer.isEmpty && !discardingOversizedLine { consume(buffer) }
            }
        }
        let byDay = Dictionary(grouping: entries.values, by: \.day)
        let days = byDay.map { day, rows -> DayUsage in
            let grouped = Dictionary(grouping: rows, by: \.model)
            let models = grouped.map { model, records -> ModelUsage in
                let tokens = records.reduce(TokenCounts()) { $0 + $1.tokens }
                let cost: Double? = price(model).map { rates in
                    records.reduce(0.0) { subtotal, item in
                        subtotal + (Double(item.tokens.input) * rates.input + Double(item.tokens.output) * rates.output
                                    + Double(item.tokens.cacheRead) * rates.read + Double(item.write5m) * rates.write5m
                                    + Double(item.write1h) * rates.write1h) / 1_000_000
                    }
                }
                return ModelUsage(model: model, tokens: tokens, estimatedCostUSD: cost)
            }.sorted { $0.tokens.total > $1.tokens.total }
            let tokens = models.reduce(TokenCounts()) { $0 + $1.tokens }
            let missing = models.filter { $0.estimatedCostUSD == nil }.map(\.model).sorted()
            return DayUsage(day: day, totalTokens: tokens.total, tokens: tokens, models: models,
                            estimatedCostUSD: missing.isEmpty ? models.reduce(0) { $0 + ($1.estimatedCostUSD ?? 0) } : nil,
                            unpricedModels: missing)
        }.sorted { $0.day < $1.day }
        return (days, incomplete)
    }

    private struct Rates {
        var input: Double; var output: Double; var read: Double
        var write5m: Double { input * 1.25 }
        var write1h: Double { input * 2 }
    }

    /// Standard API reference cost; absent cache TTL details use the established 5-minute baseline.
    public static func estimateReferenceCost(model: String, tokens: TokenCounts, write1h: Int64 = 0) -> Double? {
        guard tokens.input >= 0, tokens.output >= 0, tokens.cacheRead >= 0, tokens.cacheWrite >= 0,
              write1h >= 0, write1h <= tokens.cacheWrite, let rates = price(model) else { return nil }
        return (Double(tokens.input) * rates.input + Double(tokens.output) * rates.output
                + Double(tokens.cacheRead) * rates.read + Double(tokens.cacheWrite - write1h) * rates.write5m
                + Double(write1h) * rates.write1h) / 1_000_000
    }

    /// Standard global list prices, USD / million tokens, verified 2026-10-27.
    /// https://platform.claude.com/docs/en/about-claude/pricing
    /// Excludes fast mode, residency premiums, tools, discounts, and subscriptions.
    private static func price(_ model: String) -> Rates? {
        let base = model.replacingOccurrences(of: "-[0-9]{8}$", with: "", options: .regularExpression)
        switch base {
        case "claude-sonnet-4", "claude-sonnet-4-5", "claude-sonnet-4-6": return Rates(input: 3, output: 15, read: 0.3)
        case "claude-opus-4", "claude-opus-4-1": return Rates(input: 15, output: 75, read: 1.5)
        case "claude-opus-4-5", "claude-opus-4-6", "claude-opus-4-7", "claude-opus-4-8", "claude-opus-5": return Rates(input: 5, output: 25, read: 0.5)
        case "claude-haiku-4-5": return Rates(input: 1, output: 5, read: 0.1)
        case "claude-3-5-haiku": return Rates(input: 0.8, output: 4, read: 0.08)
        case "claude-opus-5-5": return Rates(input: 4, output: 20, read: 0.2)
        case "claude-sonnet-5-5": return Rates(input: 2, output: 10, read: 0.1)
        case "claude-sonnet-5": return Rates(input: 2, output: 10, read: 0.2)
        case "claude-fable-5-1", "claude-mythos-5-1": return Rates(input: 10, output: 50, read: 0.25)
        // Haiku 5.5 has per-request context tiers; leave unpriced until represented.
        default: return nil
        }
    }
}
