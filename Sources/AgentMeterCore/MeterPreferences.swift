import Foundation

public enum RefreshInterval: Int, Codable, CaseIterable, Sendable {
    case manual = 0
    case thirtySeconds = 30
    case oneMinute = 60
    case twoMinutes = 120
    case fiveMinutes = 300

    public var title: String {
        switch self {
        case .manual: "手动"
        case .thirtySeconds: "30 秒"
        case .oneMinute: "1 分钟"
        case .twoMinutes: "2 分钟"
        case .fiveMinutes: "5 分钟"
        }
    }
}

public enum QuotaDisplayMode: String, Codable, CaseIterable, Sendable {
    case remaining, used

    public var title: String { self == .remaining ? "剩余" : "已用" }

    public func percent(for window: LimitWindow) -> Double {
        guard window.usedPercent.isFinite else { return 0 }
        let used = max(0, min(100, window.usedPercent))
        return self == .remaining ? 100 - used : used
    }
}

public enum ResetTimeStyle: String, Codable, CaseIterable, Sendable {
    case countdown, absolute

    public var title: String { self == .countdown ? "倒计时" : "绝对时间" }
}

public struct MeterPreferences: Codable, Equatable, Sendable {
    public var language: AppLanguage = .system
    public var refreshInterval: RefreshInterval = .oneMinute
    public var quotaDisplay: QuotaDisplayMode = .remaining
    public var resetTimeStyle: ResetTimeStyle = .countdown
    public var enabledProviders: Set<ProviderID> = Set(ProviderID.allCases)
    public var lowQuotaAlerts = false
    public var resetAlerts = false
    public var menuBar = MenuBarPreferences()

    public init() {}

    @discardableResult
    public mutating func setProvider(_ id: ProviderID, enabled: Bool) -> Bool {
        if enabled {
            enabledProviders.insert(id)
        } else {
            guard enabledProviders.count > 1 || !enabledProviders.contains(id) else { return false }
            enabledProviders.remove(id)
        }
        return true
    }

    private enum CodingKeys: String, CodingKey {
        case language, refreshInterval, quotaDisplay, resetTimeStyle, enabledProviders, lowQuotaAlerts, resetAlerts, menuBar
    }

    public init(from decoder: Decoder) throws {
        self.init()
        let values = try decoder.container(keyedBy: CodingKeys.self)
        language = (try? values.decode(AppLanguage.self, forKey: .language)) ?? language
        refreshInterval = (try? values.decode(RefreshInterval.self, forKey: .refreshInterval)) ?? refreshInterval
        quotaDisplay = (try? values.decode(QuotaDisplayMode.self, forKey: .quotaDisplay)) ?? quotaDisplay
        resetTimeStyle = (try? values.decode(ResetTimeStyle.self, forKey: .resetTimeStyle)) ?? resetTimeStyle
        lowQuotaAlerts = (try? values.decode(Bool.self, forKey: .lowQuotaAlerts)) ?? lowQuotaAlerts
        resetAlerts = (try? values.decode(Bool.self, forKey: .resetAlerts)) ?? resetAlerts
        menuBar = (try? values.decode(MenuBarPreferences.self, forKey: .menuBar)) ?? menuBar
        if let entries = try? values.decode([ProviderEntry].self, forKey: .enabledProviders) {
            let providers = Set(entries.compactMap(\.id))
            if !providers.isEmpty { enabledProviders = providers }
        }
    }

    private struct ProviderEntry: Decodable {
        let id: ProviderID?

        init(from decoder: Decoder) throws {
            id = (try? decoder.singleValueContainer().decode(String.self)).flatMap(ProviderID.init(rawValue:))
        }
    }
}
