import Foundation

/// Response metadata retained for local historical reports. No conversation text is stored.
public struct UsageRecord: Identifiable, Codable, Sendable {
    public var id: String
    public var date: Date
    public var provider: ProviderID
    public var model: String
    public var tokens: TokenCounts
    public var estimatedCostUSD: Double?
    public var projectPath: String?
    public var sessionID: String
    public var conversationID: String

    public init(id: String, date: Date, provider: ProviderID, model: String, tokens: TokenCounts,
                estimatedCostUSD: Double?, projectPath: String? = nil, sessionID: String, conversationID: String) {
        self.id = id; self.date = date; self.provider = provider; self.model = model; self.tokens = tokens
        self.estimatedCostUSD = estimatedCostUSD; self.projectPath = projectPath
        self.sessionID = sessionID; self.conversationID = conversationID
    }
}

public enum UsageRange: String, CaseIterable, Identifiable, Sendable {
    case sevenDays, thirtyDays, ninetyDays, monthToDate, all
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .sevenDays: "7 天"
        case .thirtyDays: "30 天"
        case .ninetyDays: "90 天"
        case .monthToDate: "本月至今"
        case .all: "全部"
        }
    }
}

public enum UsageGrouping: String, CaseIterable, Identifiable, Sendable {
    case provider, project, conversation, session
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .provider: "提供商"
        case .project: "项目"
        case .conversation: "独立聊天"
        case .session: "会话"
        }
    }
}

public enum UsagePeriod: String, CaseIterable, Identifiable, Sendable {
    case overview, hourly
    public var id: String { rawValue }
    public var title: String { self == .overview ? "概览" : "小时" }
}

public struct UsageSummary: Sendable {
    public var tokens = TokenCounts()
    public var recordCount = 0
    public var pricedCount = 0
    public var unpricedCount = 0
    public var pricedCostUSD: Double?
    public var completeCostUSD: Double?
    public var models: [ModelUsage] = []
    public init(records: [UsageRecord]) {
        let records = uniqueRecords(records)
        recordCount = records.count
        tokens = records.reduce(TokenCounts()) { $0 + $1.tokens }
        let priced = records.compactMap { validCost($0.estimatedCostUSD) }
        pricedCount = priced.count
        unpricedCount = recordCount - pricedCount
        let subtotal = priced.reduce(0, +)
        pricedCostUSD = !priced.isEmpty && subtotal.isFinite ? subtotal : nil
        completeCostUSD = unpricedCount == 0 ? pricedCostUSD : nil
        models = Dictionary(grouping: records, by: \.model).map { model, rows in
            let counts = rows.reduce(TokenCounts()) { $0 + $1.tokens }
            let fees = rows.compactMap { validCost($0.estimatedCostUSD) }
            let cost = fees.reduce(0, +)
            return ModelUsage(model: model, tokens: counts,
                              estimatedCostUSD: fees.count == rows.count && cost.isFinite ? cost : nil)
        }.sorted {
            $0.tokens.total == $1.tokens.total ? $0.model < $1.model : $0.tokens.total > $1.tokens.total
        }
    }
}

public struct UsageRanking: Identifiable, Sendable {
    public var id: String
    public var title: String
    public var subtitle: String
    public var records: [UsageRecord]
    public var summary: UsageSummary
    public init(id: String, title: String, subtitle: String, records: [UsageRecord]) {
        self.id = id; self.title = title; self.subtitle = subtitle; self.records = records
        summary = UsageSummary(records: records)
    }
}

public struct UsageBucket: Identifiable, Sendable {
    public var id: String
    public var start: Date
    public var end: Date
    public var records: [UsageRecord]
    public var summary: UsageSummary
    public init(id: String, start: Date, end: Date, records: [UsageRecord]) {
        self.id = id; self.start = start; self.end = end; self.records = records
        summary = UsageSummary(records: records)
    }
}

public struct UsageReport: Sendable {
    public var records: [UsageRecord] = []
    public var summary = UsageSummary(records: [])
    public var startDate: Date
    public var endDate: Date
    private var calendar: Calendar
    public init(records: [UsageRecord], range: UsageRange, timeZone: TimeZone, provider: ProviderID? = nil, now: Date = Date()) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        // A Monday-based calendar makes weekly buckets stable across user locales.
        calendar.firstWeekday = 2
        calendar.minimumDaysInFirstWeek = 4
        self.calendar = calendar
        let eligible = uniqueRecords(records).filter { $0.date <= now && (provider == nil || $0.provider == provider) }
        let today = calendar.startOfDay(for: now)
        switch range {
        case .sevenDays: startDate = calendar.date(byAdding: .day, value: -6, to: today) ?? today
        case .thirtyDays: startDate = calendar.date(byAdding: .day, value: -29, to: today) ?? today
        case .ninetyDays: startDate = calendar.date(byAdding: .day, value: -89, to: today) ?? today
        case .monthToDate: startDate = calendar.dateInterval(of: .month, for: now)?.start ?? today
        case .all: startDate = calendar.startOfDay(for: eligible.map(\.date).min() ?? now)
        }
        endDate = now
        self.records = eligible.filter { $0.date >= startDate }.sorted {
            if $0.date != $1.date { return $0.date < $1.date }
            if $0.provider != $1.provider { return $0.provider.rawValue < $1.provider.rawValue }
            return $0.id < $1.id
        }
        summary = UsageSummary(records: self.records)
    }

    public func rankings(_ grouping: UsageGrouping) -> [UsageRanking] {
        let grouped = Dictionary(grouping: records) { record -> String in
            switch grouping {
            case .provider: return record.provider.rawValue
            case .project: return projectPath(record.projectPath) ?? ""
            case .conversation: return record.provider.rawValue + ":" + record.conversationID
            case .session: return record.provider.rawValue + ":" + record.sessionID
            }
        }
        return grouped.map { key, rows in
            let first = rows[0]
            let title: String
            let subtitle: String
            switch grouping {
            case .provider:
                title = first.provider.title
                subtitle = "\(Set(rows.map(\.sessionID)).count) 个会话"
            case .project:
                title = key.isEmpty ? "未识别项目" : URL(fileURLWithPath: key).lastPathComponent
                subtitle = key.isEmpty ? "日志未提供工作目录" : key
            case .conversation:
                title = "聊天 " + String(first.conversationID.prefix(8))
                subtitle = first.provider.title + " · " + "\(Set(rows.map(\.sessionID)).count) 个会话"
            case .session:
                title = "会话 " + String(first.sessionID.prefix(8))
                subtitle = first.provider.title + " · 聊天 " + String(first.conversationID.prefix(8))
            }
            return UsageRanking(id: grouping.rawValue + ":" + key, title: title, subtitle: subtitle, records: rows)
        }.sorted {
            switch ($0.summary.pricedCostUSD, $1.summary.pricedCostUSD) {
            case let (.some(left), .some(right)) where left != right: return left > right
            case (.some, .none): return true
            case (.none, .some): return false
            default: break
            }
            if $0.summary.tokens.total != $1.summary.tokens.total { return $0.summary.tokens.total > $1.summary.tokens.total }
            return $0.id < $1.id
        }
    }

    public func buckets(_ mode: UsagePeriod) -> [UsageBucket] {
        let days = (calendar.dateComponents([.day], from: startDate, to: calendar.startOfDay(for: endDate)).day ?? 0) + 1
        let component: Calendar.Component = mode == .hourly ? .hour : days > 60 ? .weekOfYear : .day
        let groups = Dictionary(grouping: records) {
            calendar.dateInterval(of: component, for: $0.date)?.start ?? $0.date
        }
        return groups.map { start, rows in
            let end = calendar.dateInterval(of: component, for: start)?.end ?? start
            return UsageBucket(id: "\(component):\(start.timeIntervalSince1970)", start: start, end: end, records: rows)
        }.sorted { $0.start < $1.start }
    }
}

private struct UsageRecordIdentity: Hashable {
    var provider: ProviderID
    var id: String
}

private func uniqueRecords(_ records: [UsageRecord]) -> [UsageRecord] {
    var seen: Set<UsageRecordIdentity> = []
    return records.filter { seen.insert(.init(provider: $0.provider, id: $0.id)).inserted }
}

private func validCost(_ value: Double?) -> Double? {
    guard let value, value.isFinite, value >= 0 else { return nil }
    return value
}

private func projectPath(_ value: String?) -> String? {
    guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
    return URL(fileURLWithPath: value).standardizedFileURL.path
}
