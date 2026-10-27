import AppKit
import Foundation
import SwiftUI
import AgentMeterCore

@MainActor
final class MeterStore: ObservableObject {
    @Published var snapshots: [ProviderSnapshot] = []
    @Published var refreshing = false
    @Published var selected: ProviderID = .codex {
        didSet { if !demo && !preview { UserDefaults.standard.set(selected.rawValue, forKey: "selectedProvider") } }
    }
    @Published var pins: Set<String> = ["codex:primary", "codex:secondary"]
    @Published var bridgeBusy = false
    @Published var bridgeInstalled = false
    @Published var bridgeMessage: String?
    @Published var providerMessage: String?
    @Published private(set) var displayNow = Date()
    @Published var preferences = MeterPreferences() {
        didSet {
            guard preferences != oldValue else { return }
            if preferences.language != oldValue.language { L10n.language = preferences.language }
            if !providers.contains(selected), let first = providers.first { selected = first }
            guard !demo, !preview else { return }
            if let data = try? JSONEncoder().encode(preferences) { UserDefaults.standard.set(data, forKey: "meterPreferences.v1") }
            if preferences.refreshInterval != oldValue.refreshInterval { scheduleRefresh() }
            if !preferences.enabledProviders.subtracting(oldValue.enabledProviders).isEmpty { refresh() }
        }
    }
    let systemServices: MeterSystemServices
    let demo: Bool
    private let preview: Bool
    private var timer: Timer?
    private var displayTimer: Timer?
    private var localUsageTimer: Timer?
    private var readingLocalUsage = false
    private var refreshPending = false
    private var alertTracker = QuotaAlertTracker()
    private let support = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/AgentMeter", isDirectory: true)

    init(demo: Bool = false, previewSnapshots: [ProviderSnapshot]? = nil) {
        self.demo = demo
        preview = previewSnapshots != nil
        systemServices = MeterSystemServices(active: !demo && previewSnapshots == nil)
        L10n.language = preferences.language
        if let previewSnapshots { snapshots = previewSnapshots; return }
        if demo { snapshots = Self.demoSnapshots(); selected = .claude; return }
        if let data = UserDefaults.standard.data(forKey: "meterPreferences.v1"), let value = try? JSONDecoder().decode(MeterPreferences.self, from: data) { preferences = value }
        L10n.language = preferences.language
        if let data = UserDefaults.standard.data(forKey: "quotaAlertTracker.v1"), let value = try? JSONDecoder().decode(QuotaAlertTracker.self, from: data) { alertTracker = value }
        if let value = UserDefaults.standard.string(forKey: "selectedProvider"), let id = ProviderID(rawValue: value) { selected = id }
        if !providers.contains(selected), let first = providers.first { selected = first }
        if let values = UserDefaults.standard.stringArray(forKey: "pinnedWindows") { pins = Set(values) }
        let file = support.appendingPathComponent("dashboard-cache.json")
        if let data = try? Data(contentsOf: file), let cached = try? JSONDecoder().decode([ProviderSnapshot].self, from: data) {
            snapshots = cached.map {
                var snapshot = $0
                if snapshot.provider == .codex, snapshot.historySource != .codexLocal {
                    snapshot.days = []
                    snapshot.historyUpdatedAt = nil
                }
                snapshot.message = "上次保存的数据，正在更新…"
                return snapshot
            }
        }
        scheduleRefresh()
        displayTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.displayNow = Date() }
        }
        localUsageTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshLocalUsage() }
        }
        refreshLocalUsage()
        refresh()
        checkBridge()
    }

    func snapshot(_ provider: ProviderID) -> ProviderSnapshot {
        snapshots.first { $0.provider == provider } ?? .init(provider: provider, message: refreshing ? "正在读取用量…" : "尚未接入")
    }
    var providers: [ProviderID] { (demo ? [.codex, .claude] : ProviderID.allCases).filter { preferences.enabledProviders.contains($0) } }
    func quotaPercent(_ window: LimitWindow) -> Double { preferences.quotaDisplay.percent(for: window) }
    var current: ProviderSnapshot { snapshot(selected) }
    var todayKey: String {
        MeterDate.day(displayNow)
    }
    var today: DayUsage? { current.days.first { $0.day == todayKey } }
    var lastSevenDays: [String] {
        let calendar = Calendar.current
        return (0..<7).reversed().compactMap { calendar.date(byAdding: .day, value: -$0, to: displayNow) }.map { MeterDate.day($0, calendar: calendar) }
    }
    var menuLabel: String {
        let pieces = providers.flatMap { provider in
            snapshot(provider).windows.filter { pins.contains("\(provider.rawValue):\($0.id)") }.map { window in
                let amount = window.expired(at: displayNow) ? L10n.text("待更新") : "\(Int(quotaPercent(window).rounded()))%"
                let label = L10n.text(window.title == "每周" ? "周" : window.title)
                return "\(provider.menuAbbreviation) \(label) \(amount)"
            }
        }
        return pieces.joined(separator: "  ")
    }
    func isPinned(_ provider: ProviderID, _ window: LimitWindow) -> Bool { pins.contains("\(provider.rawValue):\(window.id)") }
    func togglePin(_ provider: ProviderID, _ window: LimitWindow) {
        let key = "\(provider.rawValue):\(window.id)"
        if pins.contains(key) { pins.remove(key) }
        else {
            // The menu bar fits two rows. A newly selected quota must be visible.
            let available = Set(providers.flatMap { id in snapshot(id).windows.map { "\(id.rawValue):\($0.id)" } })
            pins.formIntersection(available)
            while pins.count >= 2, let displaced = pins.sorted().first { pins.remove(displaced) }
            pins.insert(key)
        }
        if !demo && !preview { UserDefaults.standard.set(Array(pins).sorted(), forKey: "pinnedWindows") }
    }

    func setProvider(_ provider: ProviderID, enabled: Bool) {
        guard enabled || providers != [provider] else { providerMessage = "至少保留一个服务。"; return }
        var value = preferences
        guard value.setProvider(provider, enabled: enabled) else { providerMessage = "至少保留一个服务。"; return }
        providerMessage = nil
        preferences = value
    }

    func setLowQuotaAlerts(_ enabled: Bool) { setAlerts(enabled, reset: false) }
    func setResetAlerts(_ enabled: Bool) { setAlerts(enabled, reset: true) }
    private func setAlerts(_ enabled: Bool, reset: Bool) {
        guard !demo, !preview else { return }
        if !enabled {
            if reset { preferences.resetAlerts = false } else { preferences.lowQuotaAlerts = false }
            return
        }
        Task {
            guard await systemServices.requestNotifications() else { return }
            if reset { preferences.resetAlerts = true } else { preferences.lowQuotaAlerts = true }
            refresh()
        }
    }

    private func scheduleRefresh() {
        timer?.invalidate()
        timer = nil
        guard !demo, !preview, preferences.refreshInterval != .manual else { return }
        timer = Timer.scheduledTimer(withTimeInterval: Double(preferences.refreshInterval.rawValue), repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func refresh() {
        guard !demo, !preview else { return }
        if refreshing { refreshPending = true; return }
        refreshing = true
        let previous = snapshots
        let requestedProviders = providers
        Task {
            let result = await Task.detached(priority: .utility) {
                var merged: [ProviderSnapshot] = []
                var fresh: [ProviderSnapshot] = []
                for provider in requestedProviders {
                    guard await MainActor.run(body: { self.providers.contains(provider) }) else { continue }
                    do {
                        let value = try ProviderSource.load(provider)
                        fresh.append(value)
                        merged.append(value)
                    }
                    catch {
                        var fallback = previous.first { $0.provider == provider } ?? ProviderSnapshot(provider: provider)
                        fallback.message = error.localizedDescription
                        fallback.quotaReadFailed = true
                        fallback.quotaMessage = error.localizedDescription
                        merged.append(fallback)
                    }
                }
                return (merged: merged, fresh: fresh)
            }.value
            // A service disabled during a read cannot update the visible result or send alerts.
            snapshots = ProviderID.allCases.compactMap { id in
                (providers.contains(id) ? result.merged.first { $0.provider == id }.map {
                    SnapshotMerge.preservingFailures($0, previous: snapshots.first { $0.provider == id })
                } : nil)
                    ?? snapshots.first { $0.provider == id }
            }
            displayNow = Date()
            if let data = try? JSONEncoder().encode(snapshots) {
                try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                let file = support.appendingPathComponent("dashboard-cache.json")
                try? data.write(to: file, options: .atomic)
                try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            }
            await recordAlerts(result.fresh)
            refreshing = false
            if refreshPending { refreshPending = false; refresh() }
        }
    }

    private func refreshLocalUsage() {
        guard !demo, !preview, providers.contains(.codex), preferences.refreshInterval != .manual, !readingLocalUsage else { return }
        readingLocalUsage = true
        Task {
            let local = await Task.detached(priority: .utility) { CodexSource.localUsage() }.value
            if providers.contains(.codex), preferences.refreshInterval != .manual { updateCodexLocalUsage(local) }
            readingLocalUsage = false
        }
    }

    func updateCodexLocalUsage(_ local: ProviderSnapshot) {
        guard local.provider == .codex, local.historySource == .codexLocal else { return }
        let current = snapshot(.codex)
        let history = SnapshotMerge.preservingFailures(local, previous: current)
        var next = current
        next.days = history.days
        next.sourceNote = history.sourceNote
        next.historySource = history.historySource
        next.historyUpdatedAt = history.historyUpdatedAt
        next.historyReadFailed = history.historyReadFailed
        next.historyIncomplete = history.historyIncomplete
        // A fast log update cannot replace the independent quota status or sample time.
        let quotaNotice = current.quotaMessage ?? (current.quotaReadFailed == true ? current.message : nil)
        let notes = [quotaNotice, local.message].compactMap { $0 }
        next.message = notes.isEmpty ? nil : notes.joined(separator: " ")
        if let index = snapshots.firstIndex(where: { $0.provider == .codex }) { snapshots[index] = next }
        else { snapshots.append(next) }
        displayNow = Date()
    }

    private func recordAlerts(_ fresh: [ProviderSnapshot]) async {
        for snapshot in fresh {
            for window in snapshot.windows {
                guard providers.contains(snapshot.provider) else { break }
                var observation = snapshot
                observation.windows = [window]
                var nextTracker = alertTracker
                let alerts = nextTracker.evaluate([observation],
                    lowEnabled: preferences.lowQuotaAlerts && systemServices.notificationsAllowed,
                    resetEnabled: preferences.resetAlerts && systemServices.notificationsAllowed)
                if let alert = alerts.first {
                    let delivered = await systemServices.deliver(alert, shouldSend: { [self] in
                        providers.contains(snapshot.provider)
                            && (alert.kind == .low ? preferences.lowQuotaAlerts : preferences.resetAlerts)
                    })
                    guard delivered else { continue }
                }
                // Commit each window independently so another window's send failure cannot replay it.
                alertTracker = nextTracker
                if let data = try? JSONEncoder().encode(alertTracker) { UserDefaults.standard.set(data, forKey: "quotaAlertTracker.v1") }
            }
        }
    }

    private func runBridge(_ argument: String) async -> (Int32, String) {
        guard let script = Bundle.main.path(forResource: "claude_bridge", ofType: "py") else { return (1, "未找到 Claude 接入脚本，请使用构建好的应用。") }
        return await Task.detached(priority: .utility) {
            let process = Process(), output = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            process.arguments = [script, argument]
            process.standardOutput = output; process.standardError = output
            do {
                try process.run()
                let data = output.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
            } catch { return (1, error.localizedDescription) }
        }.value
    }
    func checkBridge() {
        guard !demo, !preview else { return }
        Task {
            let (status, text) = await runBridge("--status")
            if status == 0, let data = text.data(using: .utf8), let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                bridgeInstalled = value["installed"] as? Bool ?? false
            }
        }
    }
    func setBridge(enabled: Bool) {
        guard !bridgeBusy, !demo, !preview else { return }
        bridgeBusy = true
        Task {
            let (status, text) = await runBridge(enabled ? "--install" : "--uninstall")
            bridgeBusy = false
            let json = text.data(using: .utf8).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            bridgeMessage = status == 0 ? (json?["message"] as? String ?? "操作已完成。") : "操作未完成：\((json?["error"] as? String ?? text).prefix(500))"
            checkBridge()
            refresh()
        }
    }
    func openSupport() {
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        NSWorkspace.shared.open(support)
    }

    static func demoSnapshots() -> [ProviderSnapshot] {
        let now = Date()
        let windows: (ProviderID) -> [LimitWindow] = { id in
            [.init(id: id == .codex ? "primary" : "five_hour", title: "5 小时", usedPercent: id == .codex ? 64 : 83, resetsAt: now.addingTimeInterval(8040)),
             .init(id: id == .codex ? "secondary" : "seven_day", title: "每周", usedPercent: id == .codex ? 38 : 42, resetsAt: now.addingTimeInterval(273600))]
        }
        return [ProviderID.codex, .claude].map { id in
            let days = (0..<7).reversed().map { offset -> DayUsage in
                let day = MeterDate.day(Calendar.current.date(byAdding: .day, value: -offset, to: now)!)
                let scale = [0.32, 0.85, 1.21, 1.03, 0.76, 0.45, 0.52][6 - offset]
                let counts = TokenCounts(input: Int64(670700 * scale), output: Int64(574100 * scale), cacheRead: Int64(12840000 * scale), cacheWrite: Int64(256900 * scale))
                return .init(day: day, totalTokens: counts.total, tokens: id == .claude ? counts : nil,
                    models: id == .claude ? [.init(model: "claude-sonnet-4-6", tokens: counts, estimatedCostUSD: 12.84 * scale)] : [], estimatedCostUSD: id == .claude ? 12.84 * scale : nil)
            }
            return .init(provider: id, plan: id == .codex ? "PLUS" : "CLAUDE CODE", windows: windows(id), updatedAt: now, days: days,
                         sourceNote: id == .codex ? "本机 Codex 日志 · 本地日期 · 标准 API 参考费用" : "本机 Claude Code · 本地日期 · 参考费用")
        }
    }
}

enum MeterFormat {
    static func tokens(_ count: Int64) -> String {
        if L10n.isEnglish {
            if count >= 1_000_000_000 { return significant(Double(count) / 1_000_000_000) + "B" }
            if count >= 1_000_000 { return significant(Double(count) / 1_000_000) + "M" }
            if count >= 1_000 { return significant(Double(count) / 1_000) + "K" }
        }
        if count >= 100_000_000 { return significant(Double(count) / 100_000_000) + "亿" }
        if count >= 10_000 { return significant(Double(count) / 10_000) + "万" }
        return count.formatted(.number.locale(L10n.locale))
    }
    private static func significant(_ value: Double) -> String {
        let digits = max(0, 3 - Int(floor(log10(max(1, value)))))
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = digits
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }
    static func cost(_ value: Double?) -> String { value.map { String(format: "$%.2f", $0) } ?? "—" }
    static func reset(_ date: Date?, style: ResetTimeStyle = .countdown, now: Date = Date()) -> String {
        guard let date else { return L10n.text("重置时间暂不可用") }
        let minutes = Int(ceil(date.timeIntervalSince(now) / 60))
        if minutes <= 0 { return L10n.text("窗口已到期，等待数据更新") }
        if style == .absolute {
            let formatter = DateFormatter()
            formatter.locale = L10n.locale
            formatter.dateFormat = L10n.isEnglish ? "MMM d, HH:mm" : "M月d日 HH:mm"
            return formatter.string(from: date)
        }
        if minutes < 60 { return L10n.format("%@分钟后", String(minutes)) }
        if minutes < 1440 { return L10n.format("%@小时%@分钟后", String(minutes / 60), String(minutes % 60)) }
        let time = DateFormatter()
        time.locale = L10n.locale
        time.dateFormat = "HH:mm"
        return L10n.format("%@天后 %@", String(minutes / 1440), time.string(from: date))
    }
    static func updated(_ date: Date?) -> String {
        guard let date else { return L10n.text("未更新") }
        let minutes = max(0, Int(Date().timeIntervalSince(date) / 60))
        if minutes < 1 { return L10n.text("刚刚更新") }
        if minutes < 60 { return L10n.format("%@ 分钟前更新", String(minutes)) }
        if minutes < 1440 { return L10n.format("%@ 小时前更新", String(minutes / 60)) }
        return L10n.format("%@ 天前更新", String(minutes / 1440))
    }
}
