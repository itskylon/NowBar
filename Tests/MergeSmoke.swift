import Foundation

@main
struct MergeSmoke {
    static func main() {
        let oldTime = Date(timeIntervalSince1970: 100)
        let old = ProviderSnapshot(provider: .codex, plan: "plus", windows: [.init(id: "secondary", title: "每周", usedPercent: 20, resetsAt: nil)], updatedAt: oldTime,
                                   days: [.init(day: "2026-10-26", totalTokens: 1000)])
        var partial = ProviderSnapshot(provider: .codex, windows: [.init(id: "secondary", title: "每周", usedPercent: 30, resetsAt: nil)], updatedAt: Date(timeIntervalSince1970: 200), message: "历史读取失败")
        partial.historyReadFailed = true
        let merged = SnapshotMerge.preservingFailures(partial, previous: old)
        guard merged.days.count == 1, merged.days[0].totalTokens == 1000 else { fatalError("Historical failure must preserve the last valid daily totals") }
        guard merged.windows[0].usedPercent == 30, merged.updatedAt != oldTime else { fatalError("A history error must not roll back fresh quota") }
        var broken = ProviderSnapshot(provider: .codex, days: [.init(day: "2026-10-27", totalTokens: 1200)], message: "额度读取失败")
        broken.quotaReadFailed = true
        let quota = SnapshotMerge.preservingFailures(broken, previous: old)
        guard quota.windows == old.windows, quota.updatedAt == oldTime, quota.plan == "plus" else { fatalError("Quota failure must preserve its original sample time") }
        guard quota.days.first?.totalTokens == 1200 else { fatalError("Quota error must not roll back fresh history") }
        let validEmpty = SnapshotMerge.preservingFailures(ProviderSnapshot(provider: .codex), previous: old)
        guard validEmpty.windows.isEmpty, validEmpty.days.isEmpty else { fatalError("Successful empty responses must not resurrect stale data") }
        guard SnapshotMerge.preservingFailures(partial, previous: nil).days.isEmpty else { fatalError("No previous data must remain unavailable") }
        var local = partial
        local.historySource = .codexLocal
        local.days = [.init(day: "2026-10-27", totalTokens: 50)]
        let migrated = SnapshotMerge.preservingFailures(local, previous: old)
        guard migrated.days.first?.totalTokens == 50 else { fatalError("Account history cannot be restored into a local-log snapshot") }
        var newer = local
        newer.historyReadFailed = false
        newer.historyUpdatedAt = Date(timeIntervalSince1970: 300)
        newer.days = [.init(day: "2026-10-27", totalTokens: 70)]
        local.historyReadFailed = false
        local.historyUpdatedAt = Date(timeIntervalSince1970: 200)
        let raced = SnapshotMerge.preservingFailures(local, previous: newer)
        guard raced.days.first?.totalTokens == 70 && raced.historyUpdatedAt == newer.historyUpdatedAt else { fatalError("Slow quota refresh cannot overwrite newer local history") }
        var oauthOld = old
        oauthOld.quotaSource = .codexOAuth
        oauthOld.quotaAccountID = "account-one"
        var oauthFailure = broken
        oauthFailure.quotaSource = .codexOAuth
        oauthFailure.quotaAccountID = "account-two"
        guard SnapshotMerge.preservingFailures(oauthFailure, previous: oauthOld).windows.isEmpty else {
            fatalError("An OAuth account change must not restore another account's quota")
        }
        oauthFailure.quotaAccountID = nil
        guard SnapshotMerge.preservingFailures(oauthFailure, previous: oauthOld).windows.isEmpty else {
            fatalError("An unreadable OAuth identity must not restore a cached account's quota")
        }
        oauthFailure.quotaAccountID = "account-one"
        guard SnapshotMerge.preservingFailures(oauthFailure, previous: oauthOld).windows == oauthOld.windows else {
            fatalError("Transient same-account failure can preserve the last quota sample")
        }
        oauthFailure.quotaSource = nil
        guard SnapshotMerge.preservingFailures(oauthFailure, previous: oauthOld).windows.isEmpty else {
            fatalError("Disconnecting OAuth must not carry its quota into the CLI source")
        }
        print("Merge: 12 checks passed")
    }
}
