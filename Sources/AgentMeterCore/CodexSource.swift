import Foundation
import Darwin

public enum CodexSource {
    private static let readersLock = NSLock()
    private static var readers: [String: CodexLocalUsageReader] = [:]

    /// Quota is account-wide; Token history is exclusively this Mac's local logs.
    /// Neither read starts a turn or redeems a rate-limit reset.
    public static func load(executable: String? = nil, codexHome: URL? = nil, oauthEnabled: Bool = false) throws -> ProviderSnapshot {
        var quota = ProviderSnapshot(provider: .codex)
        do {
            quota = oauthEnabled ? try OAuthQuotaSource.load(.codex, codexHome: codexHome) : try loadQuota(executable: executable)
        } catch {
            if oauthEnabled { quota.quotaSource = .codexOAuth }
            quota.quotaReadFailed = true
            quota.message = error.localizedDescription
        }
        quota.quotaMessage = quota.message
        let local = localUsage(codexHome: codexHome)
        quota.days = local.days
        quota.sourceNote = local.sourceNote
        quota.historySource = local.historySource
        quota.historyUpdatedAt = local.historyUpdatedAt
        quota.historyReadFailed = local.historyReadFailed
        quota.historyIncomplete = local.historyIncomplete
        let notes = [quota.message, local.message].compactMap { $0 }
        quota.message = notes.isEmpty ? nil : notes.joined(separator: " ")
        return quota
    }

    public static func localUsage(codexHome: URL? = nil, now: Date = Date(), calendar: Calendar = .current) -> ProviderSnapshot {
        let root = codexHome ?? ProcessInfo.processInfo.environment["CODEX_HOME"].flatMap { path in
            path.isEmpty ? nil : URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        } ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex", isDirectory: true)
        readersLock.lock()
        let reader: CodexLocalUsageReader
        if let existing = readers[root.standardizedFileURL.path] { reader = existing }
        else {
            reader = CodexLocalUsageReader(root: root) { model, counts, rawInput, tier in
                CodexPricing.estimate(model: model, inputTokens: rawInput, cachedInputTokens: counts.cacheRead,
                                      cacheWriteInputTokens: counts.cacheWrite, outputTokens: counts.output,
                                      serviceTier: tier ?? "standard")
            }
            readers[root.standardizedFileURL.path] = reader
        }
        readersLock.unlock()
        let result = reader.scan(now: now, calendar: calendar)
        var snapshot = ProviderSnapshot(provider: .codex, days: result.days,
            sourceNote: "Token：本机 Codex 日志 · 本地日期；含子任务，按响应去重。费用按公开 API 单价估算，未记录服务档时按标准价；非订阅账单。推理已包含在输出中。",
            message: result.incomplete ? "部分本机日志尚未读完、损坏或无法读取，统计可能不完整。" : nil)
        snapshot.historySource = .codexLocal
        snapshot.historyUpdatedAt = now
        snapshot.historyIncomplete = result.incomplete
        snapshot.historyReadFailed = result.incomplete && result.days.isEmpty
        return snapshot
    }

    private static func loadQuota(executable: String?) throws -> ProviderSnapshot {
        let client = try CodexRPC(executable: executable ?? findExecutable())
        defer { client.close() }
        _ = try client.request("initialize", id: 1, params: [
            "clientInfo": ["name": "agent_meter", "title": "NowBar", "version": "0.6.3"]
        ])
        try client.notify("initialized")
        let limits = try client.request("account/rateLimits/read", id: 2)
        var snapshot = try parse(rateLimits: limits, usage: nil)
        snapshot.message = snapshot.windows.isEmpty ? "尚未获得订阅额度；请确认 Codex CLI 已使用 ChatGPT 账号登录。" : nil
        return snapshot
    }

    public static func parse(rateLimits: [String: Any], usage: [String: Any]?, now: Date = Date()) throws -> ProviderSnapshot {
        let buckets: [(String, [String: Any])]
        if let multiple = rateLimits["rateLimitsByLimitId"] as? [String: [String: Any]], !multiple.isEmpty {
            if let ordinary = multiple["codex"] { buckets = [("codex", ordinary)] }
            else { buckets = multiple.keys.sorted().compactMap { key in multiple[key].map { (key, $0) } } }
        } else if let legacy = rateLimits["rateLimits"] as? [String: Any] {
            buckets = [("codex", legacy)]
        } else { buckets = [] }

        var windows: [LimitWindow] = []
        for (bucketID, bucket) in buckets {
            let label = (bucket["limitName"] as? String) ?? (bucket["normalModelSlug"] as? String) ?? bucketID
            for field in ["primary", "secondary"] {
                guard let value = bucket[field] as? [String: Any], let used = number(value["usedPercent"]), used.isFinite else { continue }
                let duration = number(value["windowDurationMins"])
                let title = durationTitle(duration, fallback: field == "primary" ? "当前窗口" : "长期窗口")
                let reset = number(value["resetsAt"]).flatMap { $0.isFinite && $0 > 0 ? Date(timeIntervalSince1970: $0) : nil }
                windows.append(.init(id: bucketID == "codex" ? field : "\(bucketID):\(field)",
                                     title: bucketID == "codex" ? title : "\(label) · \(title)",
                                     usedPercent: used, resetsAt: reset))
            }
        }

        let rawDays = usage?["dailyUsageBuckets"] as? [[String: Any]]
        let days: [DayUsage] = (rawDays ?? []).compactMap { bucket in
            guard let day = bucket["startDate"] as? String, validDay(day),
                  let count = bucket["tokens"] as? NSNumber,
                  CFGetTypeID(count) != CFBooleanGetTypeID(), count.doubleValue.isFinite,
                  count.doubleValue >= 0, count.doubleValue < Double(Int64.max),
                  count.doubleValue.rounded() == count.doubleValue else { return nil }
            return DayUsage(day: day, totalTokens: count.int64Value)
        }.sorted { $0.day < $1.day }
        var notes: [String] = []
        if windows.isEmpty { notes.append("尚未获得订阅额度；请确认 Codex CLI 已使用 ChatGPT 账号登录。") }
        if rawDays == nil { notes.append("账户每日 Token 数据未提供。") }
        let plan = buckets.compactMap { $0.1["planType"] as? String }.first
        var snapshot = ProviderSnapshot(provider: .codex, plan: plan, windows: windows, updatedAt: now, days: days,
                                        sourceNote: "Codex 官方账户接口；Token 为账户范围，按服务端日期统计，不提供模型拆分或费用。",
                                        message: notes.isEmpty ? nil : notes.joined(separator: " "))
        snapshot.historyReadFailed = rawDays == nil
        snapshot.historySource = .codexAccount
        snapshot.historyUpdatedAt = now
        return snapshot
    }

    private static func number(_ value: Any?) -> Double? {
        guard let value = value as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID() else { return nil }
        return value.doubleValue
    }

    private static func validDay(_ value: String) -> Bool {
        guard value.count == 10 else { return false }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        return formatter.date(from: value).map { formatter.string(from: $0) == value } ?? false
    }

    private static func durationTitle(_ minutes: Double?, fallback: String) -> String {
        guard let minutes, minutes.isFinite, minutes > 0, minutes < Double(Int.max) else { return fallback }
        if minutes == 10080 { return "每周" }
        if minutes.truncatingRemainder(dividingBy: 1440) == 0 { return "\(Int(minutes / 1440)) 天" }
        if minutes.truncatingRemainder(dividingBy: 60) == 0 { return "\(Int(minutes / 60)) 小时" }
        return "\(Int(minutes)) 分钟"
    }

    private static func findExecutable() throws -> String {
        guard let path = ProviderInstallation.executable(named: "codex") else { throw CodexReadError.missingCLI }
        return path
    }
}

private enum CodexReadError: LocalizedError {
    case missingCLI, launchFailed, timedOut, disconnected, invalidResponse, requestFailed(Int)
    var errorDescription: String? {
        switch self {
        case .missingCLI: return "未找到 Codex CLI，请先安装并登录。"
        case .launchFailed: return "无法启动 Codex 用量读取程序。"
        case .timedOut: return "Codex 用量请求超时，请稍后刷新。"
        case .disconnected: return "Codex 用量读取连接已关闭。"
        case .invalidResponse: return "Codex 返回了无法识别的用量数据。"
        case .requestFailed(let code): return "Codex 用量请求失败（\(code)），请检查 CLI 登录状态。"
        }
    }
}

private final class CodexRPC {
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let errors = Pipe()
    private let inbox = CodexInbox()

    init(executable: String) throws {
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["app-server"]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        // Discard stderr as it arrives: diagnostics can contain private data and fill a pipe.
        errors.fileHandleForReading.readabilityHandler = { handle in
            if handle.availableData.isEmpty { handle.readabilityHandler = nil }
        }
        output.fileHandleForReading.readabilityHandler = { [inbox] handle in
            let data = handle.availableData
            inbox.receive(data)
            if data.isEmpty { handle.readabilityHandler = nil }
        }
        do { try process.run() }
        catch {
            output.fileHandleForReading.readabilityHandler = nil
            errors.fileHandleForReading.readabilityHandler = nil
            throw CodexReadError.launchFailed
        }
    }

    func request(_ method: String, id: Int, params: [String: Any] = [:]) throws -> [String: Any] {
        try send(["id": id, "method": method, "params": params])
        let response = try inbox.wait(for: id, timeout: 12)
        if let failure = response["error"] as? [String: Any] {
            throw CodexReadError.requestFailed((failure["code"] as? NSNumber)?.intValue ?? -1)
        }
        guard let result = response["result"] as? [String: Any] else { throw CodexReadError.invalidResponse }
        return result
    }

    func notify(_ method: String) throws { try send(["method": method, "params": [:]]) }

    private func send(_ value: [String: Any]) throws {
        guard process.isRunning else { throw CodexReadError.disconnected }
        var data = try JSONSerialization.data(withJSONObject: value)
        data.append(10)
        do { try input.fileHandleForWriting.write(contentsOf: data) }
        catch { throw CodexReadError.disconnected }
    }

    func close() {
        try? input.fileHandleForWriting.close()
        if process.isRunning { process.terminate() }
        let deadline = Date().addingTimeInterval(0.4)
        while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
        if process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) }
        output.fileHandleForReading.readabilityHandler = nil
        errors.fileHandleForReading.readabilityHandler = nil
        try? output.fileHandleForReading.close()
        try? errors.fileHandleForReading.close()
    }
}

private final class CodexInbox: @unchecked Sendable {
    private let condition = NSCondition()
    private var buffer = Data()
    private var responses: [Int: [String: Any]] = [:]
    private var closed = false

    func receive(_ data: Data) {
        condition.lock()
        defer { condition.broadcast(); condition.unlock() }
        guard !data.isEmpty else { closed = true; return }
        buffer.append(data)
        // A usage response should be small. Bound diagnostics or malformed streams.
        guard buffer.count <= 16 * 1024 * 1024 else { closed = true; buffer.removeAll(); return }
        while let newline = buffer.firstIndex(of: 10) {
            let line = buffer[..<newline]
            buffer.removeSubrange(...newline)
            guard let response = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
                  let id = response["id"] as? NSNumber,
                  response["result"] != nil || response["error"] != nil else { continue }
            // Ignore all server notifications and unrelated IDs; never retain account updates.
            if (1...3).contains(id.intValue) { responses[id.intValue] = response }
        }
    }

    func wait(for id: Int, timeout: TimeInterval) throws -> [String: Any] {
        condition.lock()
        defer { condition.unlock() }
        let deadline = Date().addingTimeInterval(timeout)
        while responses[id] == nil && !closed {
            if !condition.wait(until: deadline) { throw CodexReadError.timedOut }
        }
        guard let response = responses.removeValue(forKey: id) else { throw CodexReadError.disconnected }
        return response
    }
}
