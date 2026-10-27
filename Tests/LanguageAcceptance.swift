import Foundation
import AgentMeterCore

@main
struct LanguageAcceptance {
    @MainActor static func main() {
        var count = 0
        func expect(_ result: Bool, _ reason: String) {
            precondition(result, reason)
            count += 1
        }
        let saved = UserDefaults.standard.data(forKey: "meterPreferences.v1")
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let window = LimitWindow(id: "primary", title: "每周", usedPercent: 17, resetsAt: now.addingTimeInterval(3600))
        let store = MeterStore(previewSnapshots: [.init(provider: .codex, windows: [window])])
        defer { L10n.language = .system }
        expect(store.preferences.language == .system, "Default preview follows system")
        let pins = store.pins
        store.preferences.language = .english
        expect(L10n.isEnglish && store.menuLabel.contains("Week"), "A language change updates menu presentation immediately")
        expect(store.current.windows.first?.title == "每周", "Internal quota titles remain stable")
        expect(store.current.windows.first?.usedPercent == 17 && store.pins == pins, "Language does not change values or pins")
        expect(MeterFormat.tokens(123_400_000) == "123.4M", "English compact token units")
        expect(MeterFormat.reset(nil, now: now) == "Reset time unavailable", "English unknown reset")
        expect(!MeterFormat.reset(now.addingTimeInterval(3600), style: .absolute, now: now).contains("月"), "English date format")
        expect(L10n.text("每周剩余 83%") == "Weekly: 83% remaining", "Cached alert body translates quota title")
        expect(L10n.text("额度为上次 Claude Code 会话快照，等待会话更新。 部分额度窗口已过期，等待 Claude Code 刷新。").range(of: "\\p{Han}", options: .regularExpression) == nil, "Combined cached source messages translate")
        expect(L10n.text("无法更改登录时启动：Permission denied\n登录时启动未启用。") == "Unable to change launch at login: Permission denied\nLaunch at login is disabled.", "Combined login error preserves details and translates status")
        expect(L10n.text("Claude 桥接未安装。") == "Claude connection is not installed.", "Absent bridge status translates")
        let record = UsageRecord(id: "one", date: now, provider: .codex, model: "my-model", tokens: .init(input: 10), estimatedCostUSD: 0.01, projectPath: "/projects/每周", sessionID: "abcdefghijk", conversationID: "123456789")
        let history = UsageHistoryStore(previewRecords: [record], now: now)
        history.grouping = .session
        history.search = "Session abcdefgh"
        expect(history.rankings.count == 1, "English generated labels can be searched")
        history.grouping = .project
        history.search = "Weekly"
        expect(history.rankings.isEmpty, "Real Chinese project names are not translated")
        history.search = "每周"
        expect(history.rankings.first?.title == "每周", "Real Chinese project names remain searchable")
        store.preferences.language = .simplifiedChinese
        expect(!L10n.isEnglish && store.menuLabel.contains("周"), "Switching back updates menu without restarting")
        expect(MeterFormat.tokens(123_400_000) == "1.234亿", "Chinese token units restored")
        expect(MeterFormat.reset(now.addingTimeInterval(3600), now: now) == "1小时0分钟后", "Chinese countdown restored")
        expect(UserDefaults.standard.data(forKey: "meterPreferences.v1") == saved, "Preview switching never writes real preferences")
        print("Language acceptance: \(count) checks passed")
    }
}
