import Foundation

@main
struct QuotaUsageSmoke {
    static func main() {
        var checks = 0
        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            precondition(condition(), message); checks += 1
        }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let week = LimitWindow(id: "weekly", title: "每周", usedPercent: 16, resetsAt: now.addingTimeInterval(3600))
        var snapshot = ProviderSnapshot(provider: .codex, plan: "pro", windows: [week], updatedAt: now)
        func rows(_ value: ProviderSnapshot, bridge: Bool = true, refreshing: Bool = false) -> [QuotaUsageWindow] {
            QuotaUsage.windows(for: value, bridgeInstalled: bridge, refreshing: refreshing, now: now)
        }
        let valid = rows(snapshot)
        check(valid.count == 2, "Keep missing expected windows")
        check(valid[0].title == "5 小时" && valid[0].state == .unavailable, "Missing window is unavailable")
        check(valid[0].usedPercent == nil && valid[0].remainingPercent == nil, "Unknown is not zero")
        check(valid[1].state == .current, "Fresh quota is available")
        check(valid[1].usedPercent == 16 && valid[1].remainingPercent == 84, "Show both complementary percentages")
        check(valid[1].window?.resetsAt == week.resetsAt, "Keep real reset date")
        check(rows(snapshot, refreshing: true)[1].state == .current, "Background refresh keeps known data")
        check(rows(snapshot, refreshing: true)[0].state == .loading, "Missing quota can be loading")

        snapshot.quotaReadFailed = true
        check(rows(snapshot)[1].state == .saved, "Failure preserves saved values")
        check(rows(snapshot)[1].remainingPercent == 84, "Saved quota remains inspectable")
        check(rows(snapshot)[0].state == .failed, "Failed missing quota is not unavailable")
        snapshot.quotaReadFailed = false
        snapshot.updatedAt = now.addingTimeInterval(-601)
        check(rows(snapshot)[1].state == .saved, "Old snapshots are explicit")
        snapshot.updatedAt = now.addingTimeInterval(-600)
        check(rows(snapshot)[1].state == .current, "Freshness boundary is deterministic")
        snapshot.updatedAt = nil
        check(rows(snapshot)[1].state == .saved, "Unknown sampling time cannot claim freshness")

        snapshot.windows[0].resetsAt = now
        check(rows(snapshot)[1].state == .expired, "Reset boundary invalidates quota")
        check(rows(snapshot)[1].usedPercent == nil && rows(snapshot)[1].remainingPercent == nil, "Expired values are not current allowance")
        snapshot.quotaReadFailed = true
        check(rows(snapshot)[1].state == .expired, "Expiry overrides saved fallback")

        let missingClaude = ProviderSnapshot(provider: .claude)
        check(rows(missingClaude, bridge: false).allSatisfy { $0.state == .disconnected }, "Claude missing bridge is explicit")
        check(rows(missingClaude, bridge: true).allSatisfy { $0.state == .unavailable }, "Installed bridge does not invent quota")
        var desktopClaude = missingClaude
        desktopClaude.quotaSource = .claudeDesktop
        desktopClaude.updatedAt = now
        check(rows(desktopClaude, bridge: false).allSatisfy { $0.state == .unavailable }, "Connected desktop accounts do not require a Code bridge")
        check(rows(desktopClaude, bridge: false, refreshing: true).allSatisfy { $0.state == .loading }, "Desktop missing quota can refresh independently of bridge")
        var oauthClaude = missingClaude
        oauthClaude.quotaSource = .claudeOAuth
        oauthClaude.updatedAt = now
        check(rows(oauthClaude, bridge: false).allSatisfy { $0.state == .unavailable }, "OAuth accounts do not require the status-line bridge and missing limits stay unknown")
        var claude = ProviderSnapshot(provider: .claude, windows: [week], updatedAt: now)
        check(rows(claude, bridge: false)[0].state == .current, "Valid Claude data takes priority over bridge installation flag")
        claude.updatedAt = now.addingTimeInterval(-601)
        check(rows(claude)[0].state == .saved, "Claude session snapshots age independently of logs")

        var grok = ProviderSnapshot(provider: .grokBot, windows: [week], updatedAt: now)
        check(rows(grok).count == 1, "Grok only has verified weekly slot")
        grok.windows[0].usedPercent = 0
        check(rows(grok)[0].usedPercent == 0 && rows(grok)[0].remainingPercent == 100, "Real zero is distinct from missing")
        grok.windows[0].usedPercent = 120
        check(rows(grok)[0].usedPercent == 100 && rows(grok)[0].remainingPercent == 0, "Bound display to percentage range")
        grok.windows[0].usedPercent = -3
        check(rows(grok)[0].usedPercent == 0 && rows(grok)[0].remainingPercent == 100, "Clamp lower bound")
        grok.windows[0].usedPercent = .nan
        check(rows(grok)[0].state == .unavailable && rows(grok)[0].usedPercent == nil, "Nonfinite percentages are unknown")
        grok.windows[0].usedPercent = .infinity
        check(rows(grok)[0].remainingPercent == nil, "Infinity cannot reach UI formatting")
        grok.windows[0] = week
        grok.windows[0].resetsAt = nil
        check(rows(grok)[0].state == .current && rows(grok)[0].window?.resetsAt == nil, "Unknown reset does not invent a date")

        let extra = LimitWindow(id: "model", title: "模型 A · 每周", usedPercent: 24, resetsAt: nil)
        snapshot = .init(provider: .codex, windows: [week, extra], updatedAt: now)
        check(rows(snapshot).map(\.title) == ["5 小时", "每周", "模型 A · 每周"], "Include additional real model windows")
        check(Set(rows(snapshot).map(\.id)).count == 3, "All slot IDs are stable and distinct")
        snapshot.historyReadFailed = true
        check(rows(snapshot)[1].state == .current, "Token-log errors do not turn fresh quota into failure")
        print("Quota usage: \(checks) checks passed")
    }
}
