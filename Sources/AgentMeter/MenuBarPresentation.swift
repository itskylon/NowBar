import AppKit
import SwiftUI
import AgentMeterCore

@MainActor
enum MenuBarPresentation {
    static func appearance(_ preferences: MenuBarPreferences) -> MeterStatusAppearance {
        .init(fontSize: preferences.size == .small ? 10 : preferences.size == .large ? 13 : 12,
              iconSize: preferences.size == .small ? 12 : preferences.size == .large ? 15 : 14,
              spacing: preferences.spacing == .compact ? 6 : preferences.spacing == .wide ? 18 : 12,
              verticalOffset: CGFloat(preferences.verticalOffset), monospacedDigits: preferences.monospacedDigits)
    }

    static func entries(for store: MeterStore) -> [MeterStatusEntry] {
        let preferences = store.preferences.menuBar
        return store.menuQuotas.map { provider, window in
            let snapshot = store.snapshot(provider)
            let quotas = QuotaUsage.windows(for: snapshot, bridgeInstalled: store.bridgeInstalled, refreshing: store.refreshing, now: store.displayNow)
            let quota = quotas.first { $0.window?.id == window?.id }
            let value = store.menuQuotaValue(window)
            let mode = L10n.text(store.preferences.quotaDisplay == .used ? "已用" : "剩余")
            var detail = provider.title + " · " + (window.map { L10n.text($0.title) } ?? L10n.text("未提供")) + " · " + mode + " " + value
            if let quota { detail += " · " + L10n.text(quota.state.title) }
            if let window { detail += "\n" + L10n.format("重置时间  %@", MeterFormat.reset(window.resetsAt, style: store.preferences.resetTimeStyle, now: store.displayNow)) }
            let today = snapshot.days.first { $0.day == store.todayKey }
            let parts: [MeterStatusPart] = preferences.layout(for: provider).effectiveComponents.map { component in
                switch component {
                case .icon: return .icon
                case .providerName: return .text(provider.title)
                case .quotaPercent: return percentPart(window, store: store)
                case .sessionPercent: return percentPart(snapshot.windows.first { $0.title == "5 小时" }, store: store, period: "5h")
                case .weeklyPercent: return percentPart(snapshot.windows.first { $0.title == "每周" }, store: store, period: "7d")
                case .usageBar:
                    return .meter(value == "—" ? nil : window.map(store.quotaPercent))
                case .resetCountdown:
                    guard let date = window?.resetsAt, date > store.displayNow else { return .text("—") }
                    let minutes = max(1, Int(ceil(date.timeIntervalSince(store.displayNow) / 60)))
                    let text = minutes >= 1440 ? "\(minutes / 1440)d \(minutes % 1440 / 60)h" : minutes >= 60 ? "\(minutes / 60)h \(minutes % 60)m" : "\(minutes)m"
                    return .text(text)
                case .resetTime:
                    guard let date = window?.resetsAt, date > store.displayNow else { return .text("—") }
                    let formatter = DateFormatter()
                    formatter.locale = L10n.locale
                    formatter.dateFormat = "HH:mm"
                    return .text(formatter.string(from: date))
                case .todayTokens:
                    return .text(provider.hasTokenHistory ? today.map { MeterFormat.tokens($0.totalTokens) } ?? "—" : "—")
                case .todayCost:
                    let cost = provider.hasTokenHistory ? today?.estimatedCostUSD : nil
                    return .text(cost.flatMap { $0.isFinite && $0 >= 0 ? MeterFormat.cost($0) : nil } ?? "—")
                case .separator: return .text("·")
                case .space: return .space
                case .lineBreak: return .lineBreak
                }
            }
            var color: NSColor?
            if preferences.colorByProvider {
                color = provider == .codex ? .systemBlue : provider == .claude ? .systemOrange : .labelColor
            }
            if preferences.lowQuotaColor, let window, value != "—", window.remaining <= 20 { color = .systemRed }
            return MeterStatusEntry(id: provider.rawValue, image: image(provider), value: value, toolTip: detail, parts: parts, color: color)
        }
    }

    private static func percentPart(_ window: LimitWindow?, store: MeterStore, period: String? = nil) -> MeterStatusPart {
        let value = store.menuQuotaValue(window)
        guard store.preferences.menuBar.showPeriodLabels else { return .text(value, widthSample: "100%") }
        let title = period ?? (window?.title == "每周" ? "7d" : window?.title == "5 小时" ? "5h" : "")
        return .text(title.isEmpty ? value : title + " " + value, widthSample: title.isEmpty ? "100%" : title + " 100%")
    }

    private static func image(_ provider: ProviderID) -> NSImage? {
        let image = Bundle.main.url(forResource: provider.iconName, withExtension: "svg", subdirectory: "providers")
            .flatMap { NSImage(contentsOf: $0) }
            ?? NSImage(systemSymbolName: "chart.bar.xaxis", accessibilityDescription: provider.title)
        image?.isTemplate = true
        return image
    }
}

struct MenuBarPreview: NSViewRepresentable {
    @ObservedObject var store: MeterStore
    func makeNSView(context: Context) -> MeterStatusSummary { MeterStatusSummary(frame: .zero) }
    func updateNSView(_ view: MeterStatusSummary, context: Context) {
        _ = view.update(entries: MenuBarPresentation.entries(for: store),
                        fallback: NSImage(systemSymbolName: "chart.bar.xaxis", accessibilityDescription: "NowBar"),
                        appearance: MenuBarPresentation.appearance(store.preferences.menuBar))
        view.setAccessibilityLabel(store.menuLabel)
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: MeterStatusSummary, context: Context) -> CGSize? { nsView.frame.size }
}
