import Foundation

public enum MenuBarStyle: String, Codable, CaseIterable, Sendable {
    case iconAndPercent, iconOnly, percentOnly, nameAndPercent, usageBar, custom
    public var title: String {
        switch self {
        case .iconAndPercent: "图标和百分比"
        case .iconOnly: "仅图标"
        case .percentOnly: "仅百分比"
        case .nameAndPercent: "名称和百分比"
        case .usageBar: "图标和用量条"
        case .custom: "自定义"
        }
    }
}

public enum MenuBarComponent: String, Codable, CaseIterable, Sendable {
    case icon, providerName, quotaPercent, sessionPercent, weeklyPercent, usageBar
    case resetCountdown, resetTime, todayTokens, todayCost, separator, space, lineBreak
    public var title: String {
        switch self {
        case .icon: "图标"
        case .providerName: "服务名称"
        case .quotaPercent: "所选额度 %"
        case .sessionPercent: "5 小时 %"
        case .weeklyPercent: "每周 %"
        case .usageBar: "用量条"
        case .resetCountdown: "重置倒计时"
        case .resetTime: "重置时间"
        case .todayTokens: "今日 Token"
        case .todayCost: "今日参考费用"
        case .separator: "分隔点"
        case .space: "空格"
        case .lineBreak: "换行"
        }
    }
}

public struct MenuBarLayout: Codable, Equatable, Sendable {
    public var style: MenuBarStyle
    public var components: [MenuBarComponent]
    public init(style: MenuBarStyle = .iconAndPercent, components: [MenuBarComponent] = [.icon, .quotaPercent]) {
        self.style = style; self.components = components
    }
    public var effectiveComponents: [MenuBarComponent] {
        switch style {
        case .iconAndPercent: return [.icon, .quotaPercent]
        case .iconOnly: return [.icon]
        case .percentOnly: return [.quotaPercent]
        case .nameAndPercent: return [.providerName, .quotaPercent]
        case .usageBar: return [.icon, .usageBar, .quotaPercent]
        case .custom:
            var result: [MenuBarComponent] = []
            for component in components.prefix(12) {
                if component == .lineBreak && (result.isEmpty || result.contains(.lineBreak)) { continue }
                result.append(component)
            }
            while result.last == .lineBreak { result.removeLast() }
            return result.contains(where: { ![.space, .separator, .lineBreak].contains($0) }) ? result : [.icon]
        }
    }
    private enum CodingKeys: String, CodingKey { case style, components }
    public init(from decoder: Decoder) throws {
        self.init()
        let values = try decoder.container(keyedBy: CodingKeys.self)
        style = (try? values.decode(MenuBarStyle.self, forKey: .style)) ?? style
        if let strings = try? values.decode([String].self, forKey: .components) {
            components = Array(strings.compactMap(MenuBarComponent.init(rawValue:)).prefix(12))
        }
    }
}

public enum MenuBarSize: String, Codable, CaseIterable, Sendable {
    case small, regular, large
    public var title: String { switch self { case .small: "小"; case .regular: "常规"; case .large: "大" } }
}
public enum MenuBarSpacing: String, Codable, CaseIterable, Sendable {
    case compact, regular, wide
    public var title: String { switch self { case .compact: "紧凑"; case .regular: "常规"; case .wide: "宽松" } }
}
public enum MenuBarDisplayScope: String, Codable, CaseIterable, Sendable {
    case all, selected
    public var title: String { self == .all ? "所有常显服务" : "当前选中的服务" }
}

public struct MenuBarPreferences: Codable, Equatable, Sendable {
    public var layout = MenuBarLayout()
    public var providerLayouts: [String: MenuBarLayout] = [:]
    public var providerOrder = ProviderID.allCases
    public var size: MenuBarSize = .regular
    public var spacing: MenuBarSpacing = .regular
    public var verticalOffset = 0
    public var monospacedDigits = true
    public var showPeriodLabels = false
    public var colorByProvider = false
    public var lowQuotaColor = false
    public var displayScope: MenuBarDisplayScope = .all
    public init() {}

    public var orderedProviders: [ProviderID] {
        (providerOrder + ProviderID.allCases).reduce(into: []) { if !$0.contains($1) { $0.append($1) } }
    }
    public func layout(for provider: ProviderID) -> MenuBarLayout { providerLayouts[provider.rawValue] ?? layout }

    private enum CodingKeys: String, CodingKey {
        case layout, providerLayouts, providerOrder, size, spacing, verticalOffset, monospacedDigits
        case showPeriodLabels, colorByProvider, lowQuotaColor, displayScope
    }
    public init(from decoder: Decoder) throws {
        self.init()
        let values = try decoder.container(keyedBy: CodingKeys.self)
        layout = (try? values.decode(MenuBarLayout.self, forKey: .layout)) ?? layout
        providerLayouts = (try? values.decode([String: MenuBarLayout].self, forKey: .providerLayouts)) ?? providerLayouts
        if let raw = try? values.decode([String].self, forKey: .providerOrder) { providerOrder = raw.compactMap(ProviderID.init(rawValue:)) }
        size = (try? values.decode(MenuBarSize.self, forKey: .size)) ?? size
        spacing = (try? values.decode(MenuBarSpacing.self, forKey: .spacing)) ?? spacing
        verticalOffset = min(3, max(-3, (try? values.decode(Int.self, forKey: .verticalOffset)) ?? 0))
        monospacedDigits = (try? values.decode(Bool.self, forKey: .monospacedDigits)) ?? monospacedDigits
        showPeriodLabels = (try? values.decode(Bool.self, forKey: .showPeriodLabels)) ?? showPeriodLabels
        colorByProvider = (try? values.decode(Bool.self, forKey: .colorByProvider)) ?? colorByProvider
        lowQuotaColor = (try? values.decode(Bool.self, forKey: .lowQuotaColor)) ?? lowQuotaColor
        displayScope = (try? values.decode(MenuBarDisplayScope.self, forKey: .displayScope)) ?? displayScope
    }
}
