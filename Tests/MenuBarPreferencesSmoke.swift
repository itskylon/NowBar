import Foundation

@main
enum MenuBarPreferencesSmoke {
    private static var checks = 0

    static func main() throws {
        let defaults = MenuBarPreferences()
        try check(defaults.layout.style == .iconAndPercent, "existing single-line icon and percentage remains the default")
        try check(defaults.layout.effectiveComponents == [.icon, .quotaPercent], "default content preserves the approved menu")
        try check(defaults.monospacedDigits, "changing percentages use stable digit widths by default")
        try check(!defaults.showPeriodLabels && !defaults.colorByProvider && !defaults.lowQuotaColor,
                  "period labels and optional colors remain opt-in")
        try check(defaults.size == .regular && defaults.spacing == .regular && defaults.verticalOffset == 0,
                  "existing menu geometry is retained by default")
        try check(defaults.displayScope == .all, "all selected services remain visible by default")
        try check(defaults.orderedProviders == ProviderID.allCases, "default provider ordering stays deterministic")
        try check(try decodePreferences("{}").menuBar == defaults, "old preference files migrate without changing their menu")
        try check(try decodeMenu("{}") == defaults, "missing menu-specific settings receive safe defaults")
        try check(try decodePreferences(#"{"menuBar":false,"quotaDisplay":"used"}"#).menuBar == defaults,
                  "corrupt menu preferences do not prevent loading the application")
        try check(try decodePreferences(#"{"menuBar":false,"quotaDisplay":"used"}"#).quotaDisplay == .used,
                  "a corrupt menu configuration does not discard valid sibling preferences")

        let partial = try decodeMenu(#"{"layout":false,"providerLayouts":[],"providerOrder":"bad","size":"unknown","spacing":"wide","verticalOffset":99,"monospacedDigits":false,"showPeriodLabels":true,"colorByProvider":null,"lowQuotaColor":true,"displayScope":"selected"}"#)
        try check(partial.layout == defaults.layout && partial.providerLayouts.isEmpty,
                  "invalid layouts fall back independently")
        try check(partial.orderedProviders == ProviderID.allCases && partial.size == .regular,
                  "invalid ordering and size retain defaults")
        try check(partial.spacing == .wide && !partial.monospacedDigits && partial.showPeriodLabels,
                  "valid display choices survive adjacent corrupt fields")
        try check(!partial.colorByProvider && partial.lowQuotaColor && partial.displayScope == .selected,
                  "valid color and scope settings are restored independently")
        try check(partial.verticalOffset == 3, "a stored vertical offset cannot move content outside the menu")
        try check(try decodeMenu(#"{"verticalOffset":-99}"#).verticalOffset == -3,
                  "negative offsets are also constrained to the supported range")
        try check(try decodeMenu(#"{"layout":null,"size":null,"spacing":null,"verticalOffset":null,"monospacedDigits":null,"showPeriodLabels":null,"colorByProvider":null,"lowQuotaColor":null,"displayScope":null}"#) == defaults,
                  "null menu settings retain defaults rather than failing the whole object")

        var custom = defaults
        custom.layout = .init(style: .custom, components: [.icon, .providerName, .quotaPercent, .separator, .resetCountdown])
        custom.providerLayouts[ProviderID.claude.rawValue] = .init(style: .percentOnly)
        custom.providerOrder = [.grokBot, .claude, .grokBot]
        custom.size = .large
        custom.spacing = .compact
        custom.verticalOffset = -2
        custom.monospacedDigits = false
        custom.showPeriodLabels = true
        custom.colorByProvider = true
        custom.lowQuotaColor = true
        custom.displayScope = .selected
        try check(custom.orderedProviders == [.grokBot, .claude, .codex],
                  "provider ordering removes duplicates and appends omitted services")
        try check(custom.layout(for: .claude).style == .percentOnly,
                  "a provider-specific format overrides the global format")
        try check(custom.layout(for: .codex) == custom.layout,
                  "providers without an override follow the global format")
        try check(try JSONDecoder().decode(MenuBarPreferences.self, from: JSONEncoder().encode(custom)) == custom,
                  "every configurable menu choice survives persistence")
        var application = MeterPreferences()
        application.menuBar = custom
        application.language = .english
        try check(try JSONDecoder().decode(MeterPreferences.self, from: JSONEncoder().encode(application)) == application,
                  "menu settings persist alongside existing application preferences")

        let presets: [(MenuBarStyle, [MenuBarComponent])] = [
            (.iconAndPercent, [.icon, .quotaPercent]),
            (.iconOnly, [.icon]),
            (.percentOnly, [.quotaPercent]),
            (.nameAndPercent, [.providerName, .quotaPercent])
        ]
        for (style, expected) in presets {
            try check(MenuBarLayout(style: style, components: [.todayCost]).effectiveComponents == expected,
                      "preset \(style.rawValue) cannot accidentally retain custom content")
        }
        try check(MenuBarLayout(style: .usageBar).effectiveComponents.contains(.usageBar),
                  "the usage-bar preset actually renders a usage meter")
        let chosen: [MenuBarComponent] = [.providerName, .space, .todayTokens, .separator, .todayCost]
        try check(MenuBarLayout(style: .custom, components: chosen).effectiveComponents == chosen,
                  "custom layouts preserve the user's content ordering")
        for invisible: [MenuBarComponent] in [[], [.space], [.separator, .space, .lineBreak]] {
            try check(MenuBarLayout(style: .custom, components: invisible).effectiveComponents == [.icon],
                      "an empty or structure-only layout cannot make NowBar inaccessible")
        }
        let many = MenuBarLayout(style: .custom, components: Array(repeating: .quotaPercent, count: 30)).effectiveComponents
        try check(many.count <= 12 && !many.isEmpty, "custom layouts remain within the supported content limit")
        let breaks = MenuBarLayout(style: .custom, components: [.icon, .lineBreak, .quotaPercent, .lineBreak, .resetTime]).effectiveComponents
        try check(breaks.filter { $0 == .lineBreak }.count <= 1,
                  "menu content cannot create more than two rows")

        try check(MenuBarStyle.allCases.allSatisfy { !$0.title.isEmpty }, "all menu styles have visible labels")
        try check(MenuBarComponent.allCases.allSatisfy { !$0.title.isEmpty }, "all content choices have visible labels")
        try check(MenuBarSize.allCases.allSatisfy { !$0.title.isEmpty }, "font size choices have visible labels")
        try check(MenuBarSpacing.allCases.allSatisfy { !$0.title.isEmpty }, "spacing choices have visible labels")
        try check(MenuBarDisplayScope.allCases.allSatisfy { !$0.title.isEmpty }, "service scope choices have visible labels")
        print("Menu bar preferences: \(checks) migration, persistence, overrides and layout safety checks passed")
    }

    private static func decodeMenu(_ json: String) throws -> MenuBarPreferences {
        try JSONDecoder().decode(MenuBarPreferences.self, from: Data(json.utf8))
    }

    private static func decodePreferences(_ json: String) throws -> MeterPreferences {
        try JSONDecoder().decode(MeterPreferences.self, from: Data(json.utf8))
    }

    private static func check(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try condition() else {
            throw NSError(domain: "MenuBarPreferencesSmoke", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
        }
        checks += 1
    }
}
