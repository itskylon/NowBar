import Foundation

public enum ProviderID: String, Codable, CaseIterable, Identifiable, Sendable {
    case codex, claude, grokBot
    public var id: String { rawValue }
    public var title: String {
        switch self { case .codex: "Codex"; case .claude: "Claude"; case .grokBot: "Grok Bot" }
    }
    public var usageTitle: String { self == .claude ? "Claude Code / Cowork" : title }
    public var iconName: String { self == .grokBot ? "grok" : rawValue }
    public var menuAbbreviation: String {
        switch self { case .codex: "C"; case .claude: "A"; case .grokBot: "G" }
    }
    public var quotaTitles: [String] {
        switch self { case .codex: ["5 小时", "每周"]; case .claude: ["每周", "5 小时"]; case .grokBot: ["每周"] }
    }
    public var hasTokenHistory: Bool { self != .grokBot }
}

public struct LimitWindow: Codable, Identifiable, Sendable, Equatable {
    public var id: String
    public var title: String
    public var usedPercent: Double
    public var resetsAt: Date?
    public var remaining: Double { max(0, min(100, 100 - usedPercent)) }
    public func expired(at now: Date = Date()) -> Bool { resetsAt.map { $0 <= now } ?? false }
    public init(id: String, title: String, usedPercent: Double, resetsAt: Date?) {
        self.id = id; self.title = title; self.usedPercent = usedPercent; self.resetsAt = resetsAt
    }
}

public struct TokenCounts: Codable, Sendable, Equatable {
    public var input: Int64 = 0
    public var output: Int64 = 0
    public var cacheRead: Int64 = 0
    public var cacheWrite: Int64 = 0
    public var reasoning: Int64 = 0
    public var total: Int64 { input + output + cacheRead + cacheWrite }
    public init(input: Int64 = 0, output: Int64 = 0, cacheRead: Int64 = 0, cacheWrite: Int64 = 0, reasoning: Int64 = 0) {
        self.input = input; self.output = output; self.cacheRead = cacheRead; self.cacheWrite = cacheWrite; self.reasoning = reasoning
    }
    public static func + (lhs: Self, rhs: Self) -> Self {
        .init(input: lhs.input + rhs.input, output: lhs.output + rhs.output, cacheRead: lhs.cacheRead + rhs.cacheRead,
              cacheWrite: lhs.cacheWrite + rhs.cacheWrite, reasoning: lhs.reasoning + rhs.reasoning)
    }
}

public struct ModelUsage: Codable, Identifiable, Sendable {
    public var model: String
    public var tokens: TokenCounts
    public var estimatedCostUSD: Double?
    public var id: String { model }
    public init(model: String, tokens: TokenCounts, estimatedCostUSD: Double?) {
        self.model = model; self.tokens = tokens; self.estimatedCostUSD = estimatedCostUSD
    }
}

public struct DayUsage: Codable, Identifiable, Sendable {
    public var day: String
    public var totalTokens: Int64
    public var tokens: TokenCounts?
    public var models: [ModelUsage]
    public var estimatedCostUSD: Double?
    public var unpricedModels: [String]
    public var id: String { day }
    public init(day: String, totalTokens: Int64, tokens: TokenCounts? = nil, models: [ModelUsage] = [], estimatedCostUSD: Double? = nil, unpricedModels: [String] = []) {
        self.day = day; self.totalTokens = totalTokens; self.tokens = tokens; self.models = models
        self.estimatedCostUSD = estimatedCostUSD; self.unpricedModels = unpricedModels
    }
}

public enum TokenHistorySource: String, Codable, Sendable {
    case codexAccount, codexLocal
}

public enum QuotaSource: String, Codable, Sendable {
    case claudeDesktop, claudeCode, codexOAuth, claudeOAuth

    public var isOAuth: Bool { self == .codexOAuth || self == .claudeOAuth }
}

public struct ProviderSnapshot: Codable, Sendable {
    public var provider: ProviderID
    public var plan: String?
    public var windows: [LimitWindow]
    public var updatedAt: Date?
    public var days: [DayUsage]
    public var sourceNote: String
    public var message: String?
    public var quotaReadFailed: Bool?
    public var quotaMessage: String?
    public var quotaSource: QuotaSource?
    public var quotaAccountID: String?
    public var quotaFromCache: Bool?
    public var historyReadFailed: Bool?
    public var historySource: TokenHistorySource?
    public var historyUpdatedAt: Date?
    public var historyIncomplete: Bool?
    public init(provider: ProviderID, plan: String? = nil, windows: [LimitWindow] = [], updatedAt: Date? = nil,
                days: [DayUsage] = [], sourceNote: String = "", message: String? = nil) {
        self.provider = provider; self.plan = plan; self.windows = windows; self.updatedAt = updatedAt
        self.days = days; self.sourceNote = sourceNote; self.message = message
    }
}

public enum SnapshotMerge {
    public static func preservingFailures(_ fresh: ProviderSnapshot, previous: ProviderSnapshot?) -> ProviderSnapshot {
        guard let previous, previous.provider == fresh.provider else { return fresh }
        var result = fresh
        let sameQuotaAccount = fresh.quotaSource == .claudeDesktop || previous.quotaSource == .claudeDesktop
            || fresh.quotaSource?.isOAuth == true || previous.quotaSource?.isOAuth == true
            ? fresh.quotaSource == previous.quotaSource && fresh.quotaAccountID != nil
                && fresh.quotaAccountID == previous.quotaAccountID : true
        if fresh.quotaReadFailed == true, sameQuotaAccount, !previous.windows.isEmpty {
            result.windows = previous.windows
            result.updatedAt = previous.updatedAt
            result.plan = previous.plan
            result.quotaFromCache = previous.quotaFromCache
        }
        let sameHistory = fresh.historySource == previous.historySource
        if fresh.historyReadFailed == true, sameHistory, !previous.days.isEmpty {
            result.days = previous.days
            result.historyUpdatedAt = previous.historyUpdatedAt
            result.sourceNote += " 历史显示上次成功读取的数据。"
        } else if sameHistory, fresh.historySource != nil,
                  let oldTime = previous.historyUpdatedAt, let newTime = fresh.historyUpdatedAt, oldTime > newTime {
            result.days = previous.days
            result.historyUpdatedAt = oldTime
            result.historyReadFailed = previous.historyReadFailed
            result.historyIncomplete = previous.historyIncomplete
        }
        return result
    }
}

public enum MeterDate {
    public static func day(_ date: Date = Date(), calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year!, parts.month!, parts.day!)
    }
    public static func parse(_ string: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: string) ?? ISO8601DateFormatter().date(from: string)
    }
}
