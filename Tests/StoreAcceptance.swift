import Foundation
import AgentMeterCore

@main
struct StoreAcceptance {
    @MainActor static func main() {
        var checks = 0
        func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
            guard condition() else { fatalError(message) }
            checks += 1
        }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let window = LimitWindow(id: "primary", title: "每周", usedPercent: 75, resetsAt: now.addingTimeInterval(3600))
        let store = MeterStore(previewSnapshots: [.init(provider: .codex, windows: [window])])
        store.preferences.language = .simplifiedChinese
        defer { L10n.language = .system }
        expect(store.providers == ProviderID.allCases, "Existing providers remain visible by default")
        expect(store.quotaPercent(window) == 25, "Default mode shows remaining")
        store.preferences.quotaDisplay = .used
        expect(store.quotaPercent(window) == 75, "The same raw sample can show used quota")
        expect(store.menuLabel.contains("75%"), "Menu summary follows the selected quota mode")
        store.setProvider(.codex, enabled: false)
        expect(!store.providers.contains(.codex) && store.selected == .claude, "Hiding the selected provider chooses a visible provider")
        expect(store.snapshot(.codex).windows.count == 1, "Hiding does not destroy cached quota")
        expect(store.pins.contains("codex:primary") && !store.menuLabel.contains("C "), "Hidden pins are retained but not displayed")
        store.setProvider(.claude, enabled: false)
        expect(store.providers == [.grokBot] && store.selected == .grokBot, "Selection continues to follow visibility")
        store.setProvider(.grokBot, enabled: false)
        expect(store.providers.isEmpty, "Users may turn off every installed service")
        store.setProvider(.codex, enabled: true)
        expect(store.providers == [.codex] && store.menuLabel.contains("75%"), "Re-enabling restores the existing pin and raw sample")
        expect(MeterFormat.reset(nil, style: .absolute, now: now) == "重置时间暂不可用", "Unknown reset remains unknown")
        expect(MeterFormat.reset(now, style: .absolute, now: now) == "窗口已到期，等待数据更新", "Absolute style does not claim expired quota reset")
        expect(MeterFormat.reset(now.addingTimeInterval(3600), style: .countdown, now: now) == "1小时0分钟后", "Countdown has deterministic time input")
        let absolute = MeterFormat.reset(window.resetsAt, style: .absolute, now: now)
        expect(absolute.contains("月") && absolute.contains(":"), "Absolute reset displays a local calendar date and clock time")
        expect(!store.systemServices.notificationsAllowed && !store.systemServices.loginEnabled, "Preview tests never query or enable system services")
        let demo = MeterStore(demo: true)
        demo.setProvider(.codex, enabled: false)
        demo.setProvider(.claude, enabled: false)
        expect(demo.providers.isEmpty, "Demo mode also supports all services switched off")
        let originalZone = NSTimeZone.default
        let utcHour = Calendar(identifier: .gregorian).dateComponents(in: TimeZone(secondsFromGMT: 0)!, from: Date()).hour!
        NSTimeZone.default = TimeZone(secondsFromGMT: utcHour < 12 ? -12 * 3600 : 14 * 3600)!
        store.selected = .codex
        let localDay = MeterDate.day()
        expect(store.todayKey == localDay, "Codex local logs must select today using the local calendar, including across UTC midnight")
        expect(store.lastSevenDays.last == localDay, "Codex local history must end on the same local day as the today card")
        NSTimeZone.default = originalZone
        var local = ProviderSnapshot(provider: .codex, days: [.init(day: MeterDate.day(), totalTokens: 123, tokens: .init(input: 100, output: 23))], sourceNote: "local")
        local.historySource = .codexLocal
        local.historyUpdatedAt = Date()
        let quotaBeforeLocal = store.snapshot(.codex)
        store.updateCodexLocalUsage(local)
        expect(store.today?.totalTokens == 123, "A local log tick must update today's card immediately")
        expect(store.snapshot(.codex).windows == quotaBeforeLocal.windows && store.snapshot(.codex).updatedAt == quotaBeforeLocal.updatedAt, "A local tick must preserve independent quota values and sample time")
        store.updateCodexLocalUsage(local)
        expect(store.today?.totalTokens == 123, "Repeated local ticks must replace totals, not add them")
        local.historyIncomplete = true
        local.days = [.init(day: MeterDate.day(), totalTokens: 200, tokens: .init(input: 150, output: 50))]
        local.historyUpdatedAt = Date()
        store.updateCodexLocalUsage(local)
        expect(store.today?.totalTokens == 200 && store.snapshot(.codex).historyIncomplete == true, "Valid partial logs must keep updating with an explicit incomplete flag")
        local.historyReadFailed = true
        local.days = []
        store.updateCodexLocalUsage(local)
        expect(store.today?.totalTokens == 200, "An empty log read failure must preserve the last usable local totals")
        var missingQuota = store.snapshot(.codex)
        missingQuota.windows = []
        missingQuota.quotaMessage = "当前账户未提供额度窗口"
        missingQuota.message = missingQuota.quotaMessage
        store.snapshots = [missingQuota]
        local.historyReadFailed = false
        local.historyIncomplete = false
        local.days = [.init(day: MeterDate.day(), totalTokens: 210)]
        store.updateCodexLocalUsage(local)
        expect(store.snapshot(.codex).message == missingQuota.quotaMessage, "Local ticks must retain successful-but-unavailable quota explanations")
        let menuStore = MeterStore(previewSnapshots: [
            .init(provider: .codex, windows: [window]),
            .init(provider: .claude, windows: [.init(id: "claude.five_hour", title: "5 小时", usedPercent: 24, resetsAt: nil)]),
            .init(provider: .grokBot, windows: [.init(id: "grokBot.weekly", title: "每周", usedPercent: 0, resetsAt: nil)])
        ])
        menuStore.pins = ["codex:primary", "grokBot:grokBot.weekly"]
        menuStore.togglePin(.claude, menuStore.snapshot(.claude).windows[0])
        expect(menuStore.pins.count == 3 && menuStore.pins.contains("codex:primary") && menuStore.pins.contains("grokBot:grokBot.weekly"),
               "Pinning a third service must not evict either existing service")
        expect(menuStore.menuLabel.contains("C ") && menuStore.menuLabel.contains("A ") && menuStore.menuLabel.contains("G "),
               "The menu summary must include every pinned service")
        menuStore.setProvider(.claude, enabled: false)
        expect(!menuStore.menuLabel.contains("A ") && menuStore.pins.count == 3, "Disabling a service hides its summary without losing its pin")
        menuStore.setProvider(.claude, enabled: true)
        expect(menuStore.menuLabel.contains("A "), "Re-enabling a service restores its menu quota")
        let otherWindow = LimitWindow(id: "secondary", title: "5 小时", usedPercent: 40, resetsAt: nil)
        menuStore.snapshots[0].windows.append(otherWindow)
        menuStore.togglePin(.codex, otherWindow)
        expect(!menuStore.pins.contains("codex:primary") && menuStore.pins.contains("codex:secondary") && menuStore.pins.count == 3,
               "Selecting another window replaces only that service's menu quota")
        expect(menuStore.menuQuotas.count == 3 && menuStore.menuQuotas.first?.window?.id == "secondary",
               "The single-line summary contains one chosen window per provider")
        menuStore.snapshots[0].windows = []
        expect(menuStore.menuQuotas.count == 3 && menuStore.menuQuotaValue(menuStore.menuQuotas[0].window) == "—",
               "A selected provider with unavailable data remains visible as a dash")
        let invalid = LimitWindow(id: "invalid", title: "每周", usedPercent: .nan, resetsAt: nil)
        expect(menuStore.menuQuotaValue(invalid) == "—", "Nonfinite percentages must not crash or invent a quota")
        let expired = LimitWindow(id: "expired", title: "每周", usedPercent: 10, resetsAt: .distantPast)
        expect(menuStore.menuQuotaValue(expired) == "—", "Expired quota is unavailable until refreshed")
        menuStore.snapshots[0].windows = [window, otherWindow]
        menuStore.pins.insert("codex:primary")
        expect(menuStore.menuQuotas.count == 3 && menuStore.isPinned(.codex, window) && !menuStore.isPinned(.codex, otherWindow),
               "Legacy multiple pins resolve to one visible choice and one selected eye")
        let detected = MeterStore(previewSnapshots: [.init(provider: .codex, windows: [window])])
        detected.applyDetectedProviders([.claude])
        expect(detected.providers == [.claude] && detected.selected == .claude, "Only installed providers are visible and selected")
        detected.setProvider(.codex, enabled: true)
        expect(detected.providers == [.claude] && detected.providerMessage != nil, "An uninstalled service cannot be enabled")
        detected.preferences.enabledProviders = Set(ProviderID.allCases)
        expect(detected.providers == [.claude], "Direct legacy preference writes cannot expose missing services")
        detected.applyDetectedProviders([])
        expect(detected.providers.isEmpty && detected.menuQuotas.isEmpty, "No installed apps is a valid empty state with no phantom Codex")
        expect(detected.snapshot(.codex).windows.count == 1, "Removing an installation preserves existing quota/history cache")
        detected.applyDetectedProviders([.grokBot, .codex])
        expect(detected.providers == [.codex] && detected.selected == .codex, "Optional services stay disabled after installation")
        expect(detected.preferences.enabledProviders == [.codex], "Only primary providers are enabled by default")
        expect(!detected.isMenuVisible(.grokBot), "An optional service does not receive a menu item until enabled")
        detected.setProvider(.grokBot, enabled: true)
        expect(detected.providers == [.codex, .grokBot] && detected.isMenuVisible(.grokBot), "Manually enabling an optional service shows its menu item")
        detected.applyDetectedProviders([.codex, .grokBot])
        expect(detected.providers.contains(.grokBot), "Rescanning preserves manual enablement")
        detected.setProvider(.grokBot, enabled: false)
        detected.applyDetectedProviders([.codex, .grokBot])
        expect(!detected.providers.contains(.grokBot), "Rescanning preserves manual disablement")
        detected.preferences.menuBar.size = .small
        detected.applyDetectedProviders([.codex])
        expect(detected.preferences.menuBar.size == .small && detected.isMenuVisible(.grokBot), "Detection preserves menu appearance and absent-provider pins")
        detected.setMenuVisible(.codex, visible: false)
        detected.applyDetectedProviders([.codex])
        expect(!detected.isMenuVisible(.codex), "An unchanged installation scan preserves a deliberate hidden menu item")
        let defaults = MeterStore(previewSnapshots: [])
        defaults.applyDetectedProviders(Set(ProviderID.allCases))
        expect(defaults.providers == [.codex, .claude], "All installed defaults to Codex and Claude only")
        expect(defaults.availableProviders == ProviderID.allCases, "Installed optional services remain available in settings")
        defaults.setProvider(.claude, enabled: false)
        defaults.applyDetectedProviders(Set(ProviderID.allCases))
        expect(defaults.providers == [.codex], "A manually disabled primary service remains disabled")
        defaults.applyDetectedProviders([.grokBot])
        expect(defaults.providers.isEmpty && defaults.availableProviders == [.grokBot], "Only Grok installed stays off until the user enables it")
        print("Store: \(checks) acceptance checks passed without preferences, network or system writes")
    }
}
