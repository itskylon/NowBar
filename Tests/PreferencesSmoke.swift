import Foundation

@main
enum PreferencesSmoke {
    private static var checks = 0

    static func main() throws {
        let defaults = MeterPreferences()
        try check(defaults.theme == .system, "default theme follows the system")
        try check(try decode(#"{"theme":"light"}"#).theme == .light, "light theme restores from preferences")
        try check(try decode(#"{"theme":"invalid"}"#).theme == .system, "unknown theme falls back to the system")
        try check(defaults.refreshInterval == .oneMinute, "default refresh is one minute")
        try check(defaults.quotaDisplay == .remaining, "default quota display is remaining")
        try check(defaults.resetTimeStyle == .countdown, "default reset display is countdown")
        try check(defaults.enabledProviders == Set(ProviderID.allCases), "all providers are enabled by default")
        try check(!defaults.lowQuotaAlerts && !defaults.resetAlerts, "alerts require an explicit opt-in")
        try check(try decode("{}") == defaults, "old preferences without new fields retain defaults")

        let migrated = try decode(#"{"quotaDisplay":"used","unknownFutureSetting":true}"#)
        try check(migrated.quotaDisplay == .used, "an existing valid field survives migration")
        try check(migrated.refreshInterval == defaults.refreshInterval && migrated.enabledProviders == defaults.enabledProviders,
                  "missing fields migrate independently")

        let corrupted = try decode(#"{"refreshInterval":15,"quotaDisplay":"invalid","resetTimeStyle":[],"enabledProviders":false,"lowQuotaAlerts":"true","resetAlerts":1}"#)
        try check(corrupted == defaults, "invalid individual fields fall back to their own defaults")

        let mixed = try decode(#"{"refreshInterval":300,"quotaDisplay":false,"resetTimeStyle":"absolute","enabledProviders":["grokBot","unknown","codex","codex"],"lowQuotaAlerts":true,"resetAlerts":"false"}"#)
        try check(mixed.refreshInterval == .fiveMinutes && mixed.resetTimeStyle == .absolute, "valid display settings survive a bad sibling field")
        try check(mixed.quotaDisplay == .remaining, "an invalid quota display falls back independently")
        try check(mixed.enabledProviders == [.codex, .grokBot], "unknown provider names are ignored and duplicates collapse")
        try check(mixed.lowQuotaAlerts && !mixed.resetAlerts, "valid alert settings survive an invalid sibling")

        let lossyProviders = try decode(#"{"enabledProviders":["claude",17,null,{"provider":"codex"},"unknown"]}"#)
        try check(lossyProviders.enabledProviders == [.claude], "invalid provider entries do not discard valid provider names")
        try check(try decode(#"{"enabledProviders":[]}"#).enabledProviders == defaults.enabledProviders,
                  "an empty provider list falls back to all providers")
        try check(try decode(#"{"enabledProviders":["unknown"]}"#).enabledProviders == defaults.enabledProviders,
                  "a list containing only unsupported providers falls back to all providers")
        try check(try decode(#"{"refreshInterval":null,"quotaDisplay":null,"resetTimeStyle":null,"enabledProviders":null,"lowQuotaAlerts":null,"resetAlerts":null}"#) == defaults,
                  "null fields retain safe defaults")

        var selection = defaults
        for provider in ProviderID.allCases where provider != .codex {
            try check(selection.setProvider(provider, enabled: false), "providers may be hidden while another remains")
        }
        try check(selection.enabledProviders == [.codex], "hiding providers preserves the remaining provider")
        try check(!selection.setProvider(.codex, enabled: false) && selection.enabledProviders == [.codex],
                  "the last enabled provider cannot be hidden")
        try check(selection.setProvider(.claude, enabled: false) && selection.enabledProviders == [.codex],
                  "hiding an already hidden provider is harmless")
        try check(selection.setProvider(.claude, enabled: true) && selection.enabledProviders == [.codex, .claude],
                  "a hidden provider can be enabled again")

        var saved = defaults
        saved.theme = .dark
        saved.refreshInterval = .manual
        saved.quotaDisplay = .used
        saved.resetTimeStyle = .absolute
        saved.enabledProviders = [.claude]
        saved.lowQuotaAlerts = true
        saved.resetAlerts = true
        try check(try JSONDecoder().decode(MeterPreferences.self, from: JSONEncoder().encode(saved)) == saved,
                  "every preference survives an encode/decode round trip")
        try check(RefreshInterval.allCases.map(\.rawValue) == [0, 30, 60, 120, 300], "refresh intervals use the agreed seconds")
        try check(RefreshInterval.allCases.allSatisfy { !$0.title.isEmpty }, "refresh choices have visible labels")
        try check(QuotaDisplayMode.remaining.title == "剩余" && QuotaDisplayMode.used.title == "已用", "quota mode labels explain the number")
        try check(ResetTimeStyle.allCases.allSatisfy { !$0.title.isEmpty }, "reset display choices have visible labels")

        for (used, remaining) in [(37.5, 62.5), (0.0, 100.0), (100.0, 0.0), (-10.0, 100.0), (140.0, 0.0)] {
            let window = LimitWindow(id: "test", title: "测试窗口", usedPercent: used, resetsAt: nil)
            try check(QuotaDisplayMode.remaining.percent(for: window) == remaining, "remaining display preserves zero and clamps valid numeric input")
            try check(QuotaDisplayMode.used.percent(for: window) == 100 - remaining, "used display preserves zero and clamps valid numeric input")
        }
        for invalid in [Double.nan, Double.infinity, -Double.infinity] {
            let window = LimitWindow(id: "test", title: "测试窗口", usedPercent: invalid, resetsAt: nil)
            for mode in QuotaDisplayMode.allCases {
                try check(mode.percent(for: window) == 0, "non-finite input cannot reach a percentage renderer")
            }
        }
        let unknown: LimitWindow? = nil
        for mode in QuotaDisplayMode.allCases {
            try check(unknown.map(mode.percent(for:)) == nil, "a missing window remains unknown instead of becoming a zero quota")
        }
        print("Preferences: \(checks) checks passed")
    }

    private static func decode(_ json: String) throws -> MeterPreferences {
        try JSONDecoder().decode(MeterPreferences.self, from: Data(json.utf8))
    }

    private static func check(_ passed: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try passed() else { throw NSError(domain: "PreferencesSmoke", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
        checks += 1
    }
}
