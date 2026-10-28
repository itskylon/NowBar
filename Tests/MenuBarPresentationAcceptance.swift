import AppKit
import AgentMeterCore

@main
enum MenuBarPresentationAcceptance {
    @MainActor static func main() {
        var checks = 0
        func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
            precondition(condition(), message); checks += 1
        }
        let now = Date()
        let weekly = LimitWindow(id: "primary", title: "每周", usedPercent: 27, resetsAt: now.addingTimeInterval(7200))
        let session = LimitWindow(id: "session", title: "5 小时", usedPercent: 40, resetsAt: now.addingTimeInterval(3600))
        let store = MeterStore(previewSnapshots: [
            .init(provider: .codex, windows: [weekly, session], updatedAt: now,
                  days: [.init(day: MeterDate.day(), totalTokens: 12345, estimatedCostUSD: 1.25)]),
            .init(provider: .claude, windows: [.init(id: "five_hour", title: "5 小时", usedPercent: 24, resetsAt: now.addingTimeInterval(3600))]),
            .init(provider: .grokBot, windows: [.init(id: "weekly", title: "每周", usedPercent: 0, resetsAt: now.addingTimeInterval(3600))])
        ])
        store.preferences.language = .english
        defer { L10n.language = .system }
        store.pins = ["codex:primary", "claude:five_hour", "grokBot:weekly"]
        func text(_ entry: MeterStatusEntry) -> [String] {
            entry.parts.compactMap { if case .text(let text, _) = $0 { return text }; return nil }
        }
        expect(MenuBarPresentation.entries(for: store).map(\.value) == ["73%", "76%", "100%"], "Defaults keep the approved three-service summary")
        store.preferences.menuBar.providerOrder = [.grokBot, .claude, .codex]
        expect(MenuBarPresentation.entries(for: store).map(\.id) == ["grokBot", "claude", "codex"], "User order controls actual rendered entries")
        store.preferences.menuBar.providerLayouts["codex"] = .init(style: .custom, components: [.providerName, .sessionPercent, .weeklyPercent, .todayTokens, .todayCost, .resetCountdown])
        var codex = MenuBarPresentation.entries(for: store).first { $0.id == "codex" }!
        expect(text(codex).prefix(3) == ["Codex", "60%", "73%"], "Custom periods use their own real windows")
        expect(text(codex).contains("12.35K") || text(codex).contains("12.34K") || text(codex).contains("12.3K"), "Today's tokens come from today's local history")
        expect(text(codex).contains("$1.25"), "Today's cost is the recorded estimate")
        store.preferences.menuBar.showPeriodLabels = true
        codex = MenuBarPresentation.entries(for: store).first { $0.id == "codex" }!
        expect(text(codex).contains("5h 60%") && text(codex).contains("7d 73%"), "Period labels use real window identities")
        store.preferences.quotaDisplay = .used
        codex = MenuBarPresentation.entries(for: store).first { $0.id == "codex" }!
        expect(text(codex).contains("5h 40%") && text(codex).contains("7d 27%"), "Custom percentages respect used/remaining mode")
        store.preferences.menuBar.layout = .init(style: .custom, components: [.todayTokens, .todayCost, .sessionPercent])
        let grok = MenuBarPresentation.entries(for: store).first { $0.id == "grokBot" }!
        expect(text(grok) == ["—", "—", "5h —"], "Unsupported Grok tokens, cost and session limits stay unavailable")
        store.preferences.menuBar.displayScope = .selected
        store.selected = .claude
        expect(MenuBarPresentation.entries(for: store).map(\.id) == ["claude"], "Selected-service mode renders one provider")
        expect(store.isPinned(.codex, weekly), "Selected-service mode must not erase another service's eye selection")
        store.preferences.menuBar.displayScope = .all
        store.setMenuVisible(.codex, visible: false)
        expect(!MenuBarPresentation.entries(for: store).contains { $0.id == "codex" }, "Hiding menu content does not disable collection")
        expect(store.providers.contains(.codex), "Menu visibility is independent of enabled providers")
        store.setMenuVisible(.codex, visible: true)
        expect(MenuBarPresentation.entries(for: store).contains { $0.id == "codex" }, "Showing a provider chooses a usable quota again")
        store.preferences.menuBar.colorByProvider = true
        expect(MenuBarPresentation.entries(for: store).first { $0.id == "codex" }?.color == .systemBlue, "Provider colors reach the actual renderer")
        store.snapshots[0].windows[0].usedPercent = 95
        store.preferences.menuBar.lowQuotaColor = true
        expect(MenuBarPresentation.entries(for: store).first { $0.id == "codex" }?.color == .systemRed, "Low quota overrides decorative provider color")
        store.snapshots[0].windows[0].resetsAt = .distantPast
        codex = MenuBarPresentation.entries(for: store).first { $0.id == "codex" }!
        expect(codex.value != "5%", "An automatic visible quota can pick the other live window after expiry")
        print("Menu presentation: \(checks) checks passed")
    }
}
