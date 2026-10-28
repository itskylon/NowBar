import Foundation

@main
enum ClaudeDesktopSmoke {
    static func main() throws {
        let now = Date(timeIntervalSince1970: 1_793_000_000)
        let reset = "2026-10-29T11:22:16.814Z"
        let value = ClaudeDesktopSource.parseUsage([
            "five_hour": ["utilization": 26.5, "resets_at": reset],
            "seven_day": ["utilization": 0, "resets_at": NSNull()],
            "seven_day_opus": ["utilization": 100, "resets_at": reset]
        ], plan: "Pro", accountID: "account-a", now: now)
        precondition(value.windows.count == 3, "Desktop quota windows must be read independently")
        precondition(value.windows[0].remaining == 73.5)
        precondition(value.windows[0].resetsAt == MeterDate.parse(reset))
        precondition(value.windows[1].usedPercent == 0 && value.windows[1].resetsAt == nil,
                     "Explicit zero is known; a missing reset must remain unknown")
        precondition(value.days.isEmpty, "Subscription percentages must never generate Token or cost history")
        precondition(value.quotaSource == .claudeDesktop && value.quotaAccountID == "account-a")
        precondition(value.plan == "Pro" && value.updatedAt == now)
        let empty = ClaudeDesktopSource.parseUsage(["five_hour": NSNull(), "seven_day": NSNull(), "limits": []], now: now)
        precondition(empty.windows.isEmpty && empty.quotaReadFailed != true && empty.quotaMessage != nil,
                     "A successful empty response must explain unavailability, never imply 100%")
        let free = ClaudeDesktopSource.parseUsage(["five_hour": NSNull(), "seven_day": NSNull(), "limits": []], plan: "Free", now: now)
        precondition(free.quotaMessage?.contains("正常聊天") == true,
                     "Free accounts have limits; empty API data must explain how desktop chat updates them")
        let sample = ClaudeDesktopQuotaCache.Sample(window: .init(id: "claude.five_hour", title: "5 小时", usedPercent: 24,
                                                                   resetsAt: now.addingTimeInterval(3600)),
                                                    observedAt: now.addingTimeInterval(-900))
        let cached = ClaudeDesktopSource.applyingCache(sample, to: free)
        precondition(cached.windows.count == 1 && cached.windows[0].usedPercent == 24 && cached.plan == "Free")
        precondition(cached.updatedAt == sample.observedAt && cached.quotaFromCache == true && cached.quotaMessage == nil,
                     "A refresh must not turn a cached observation into a new measurement")
        precondition(cached.days.isEmpty, "Cached quota must not create chat Token or cost history")
        precondition(ClaudeDesktopSource.applyingCache(sample, to: value).windows[0].usedPercent == 26.5,
                     "An authoritative API window takes priority over a cached one")
        precondition(ClaudeDesktopSource.planName(["billing_type": "none", "rate_limit_tier": "default_claude_ai"]) == "Free")
        precondition(ClaudeDesktopSource.planName(["billing_type": "none"]) == nil,
                     "A missing plan must not be guessed from absent quota")
        let cachedState = QuotaUsage.windows(for: cached, bridgeInstalled: false, refreshing: false, now: now)
        precondition(cachedState.first(where: { $0.title == "5 小时" })?.state == .saved)
        precondition(cachedState.first(where: { $0.title == "每周" })?.state == .unavailable,
                     "Free five-hour data must never invent a weekly budget")
        let scopedEntry: [String: Any] = ["kind": "weekly_scoped", "group": "weekly", "percent": 32,
            "resets_at": reset, "scope": ["model": ["id": "claude-fable", "display_name": "Fable"]]]
        let scoped = ClaudeDesktopSource.parseUsage(["limits": [scopedEntry, scopedEntry]], now: now)
        precondition(scoped.windows.count == 1 && scoped.windows.first?.usedPercent == 32,
                     "Model-scoped weekly quotas must be shown once even without aggregate windows")
        L10n.language = .english
        precondition(L10n.text(scoped.windows[0].title) == "Fable weekly")
        let historyNote = "Token：本机 Claude Code / Cowork 日志 · 本地日期；普通聊天 Token 未提供，参考费用非订阅账单。"
        precondition(L10n.text(ClaudeDesktopSource.note + " " + historyNote).range(of: "\\p{Han}", options: .regularExpression) == nil)
        precondition(L10n.text(ClaudeDesktopSource.cacheNote + " " + historyNote).range(of: "\\p{Han}", options: .regularExpression) == nil)
        L10n.language = .system
        let partial = ClaudeDesktopSource.parseUsage([
            "five_hour": ["utilization": true], "seven_day": ["utilization": 61],
            "seven_day_opus": ["utilization": -1], "seven_day_sonnet": ["utilization": "14"]
        ], now: now)
        precondition(partial.windows.count == 1 && partial.windows[0].usedPercent == 61,
                     "Boolean, negative and string values must not become quota percentages")
        let invalid = ClaudeDesktopSource.parseUsage(["unrecognized": 1], now: now)
        precondition(invalid.quotaReadFailed == true, "An unknown schema is a read failure")
        let over = ClaudeDesktopSource.parseUsage(["five_hour": ["utilization": 115]], now: now)
        precondition(over.windows.first?.remaining == 0, "Over-limit accounts cannot imply available allowance")
        let identity = ClaudeDesktopSource.quotaIdentity(sessionKey: "session-a", organizationID: "team")
        precondition(identity == ClaudeDesktopSource.quotaIdentity(sessionKey: "session-a", organizationID: "team"))
        precondition(identity != ClaudeDesktopSource.quotaIdentity(sessionKey: "session-b", organizationID: "team"),
                     "Different users in the same organization cannot share cached quota identity")
        precondition(identity != ClaudeDesktopSource.quotaIdentity(sessionKey: "session-a", organizationID: "other-team"))
        precondition(identity.count == 64 && !identity.contains("session-a"), "Persist only a one-way session fingerprint")
        let orgs: [[String: Any]] = [
            ["uuid": "api", "capabilities": ["api"]],
            ["uuid": "first", "capabilities": ["chat"]],
            ["uuid": "active", "capabilities": ["chat", "api"]]
        ]
        let active = try ClaudeDesktopSource.selectOrganization(orgs, preferredID: "active")
        let only = try ClaudeDesktopSource.selectOrganization([orgs[0], orgs[1]], preferredID: nil)
        precondition(active["uuid"] as? String == "active")
        precondition(only["uuid"] as? String == "first")
        do { _ = try ClaudeDesktopSource.selectOrganization(orgs, preferredID: nil); preconditionFailure("Ambiguous accounts must not pick the first") } catch {}
        do { _ = try ClaudeDesktopSource.selectOrganization(orgs, preferredID: "missing"); preconditionFailure("A missing active organization must not select another account") } catch {}
        var failed = value
        failed.windows = []; failed.quotaReadFailed = true
        precondition(SnapshotMerge.preservingFailures(failed, previous: value).windows.count == 3)
        failed.quotaAccountID = "account-b"
        precondition(SnapshotMerge.preservingFailures(failed, previous: value).windows.isEmpty,
                     "A switched desktop account must not inherit the previous account's limits")
        failed.quotaAccountID = nil
        precondition(SnapshotMerge.preservingFailures(failed, previous: value).windows.isEmpty,
                     "An unknown desktop account cannot retain old-account limits")
        var bridge = failed; bridge.quotaSource = .claudeCode
        precondition(SnapshotMerge.preservingFailures(bridge, previous: value).windows.isEmpty)
        precondition(SnapshotMerge.preservingFailures(empty, previous: value).windows.isEmpty)
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let absent = ClaudeDesktopSource.load(home: home)
        precondition(absent.windows.isEmpty && absent.quotaReadFailed == true && absent.message?.contains("登录") == true)
        let cookie = Data(base64Encoded: "djEwy6jYs7gT94Sq5G3qkli1iz0Z9feJ3Ed43wFSev1z6T7edfEdhy2CUVKgUOuLoSso5rowp3yfwHF7YuO5dJFjlA==")!
        let decoded = try ClaudeDesktopSource.decodeCookie(cookie, host: ".claude.ai", password: Data("test-password".utf8))
        precondition(decoded == "sk-ant-sid-test-only", "Read Chromium domain-bound cookies")
        do { _ = try ClaudeDesktopSource.decodeCookie(cookie, host: "claude.ai", password: Data("test-password".utf8)); preconditionFailure("A cookie bound to a different host must be rejected") } catch {}
        do { _ = try ClaudeDesktopSource.decodeCookie(cookie, host: ".claude.ai", password: Data("wrong".utf8)); preconditionFailure("Wrong keys must never yield a session") } catch {}
        let request = try ClaudeDesktopSource.request(path: "/api/organizations", sessionKey: "synthetic-session")
        precondition(request.url?.absoluteString == "https://claude.ai/api/organizations" && request.httpMethod == "GET")
        precondition(request.value(forHTTPHeaderField: "Cookie") == "sessionKey=synthetic-session")
        do { _ = try ClaudeDesktopSource.request(path: "https://example.com/usage", sessionKey: "synthetic-session"); preconditionFailure("Never send cookies to an alternate host") } catch {}
        do { _ = try ClaudeDesktopSource.request(path: "/api/organizations", sessionKey: "x\r\nInjected: value"); preconditionFailure("Reject header injection") } catch {}
        print("Claude desktop parser, identity and cookie security checks passed")
    }
}
