import Foundation

@main
struct ProviderSmoke {
    static func main() {
        guard let grok = ProviderID(rawValue: "grokBot"), grok.title == "Grok Bot" else {
            fatalError("Grok Bot must have its own provider identity, separate from Claude and Grok Build")
        }
        guard ProviderID(rawValue: "codex") == .codex, ProviderID(rawValue: "claude") == .claude else {
            fatalError("Existing cached provider identities must remain compatible")
        }
        guard grok.quotaTitles == ["每周"], !grok.hasTokenHistory, grok.iconName == "grok" else {
            fatalError("Grok Bot must expose only verified weekly quota and no fictional token history")
        }
        guard ProviderID.codex.quotaTitles == ["5 小时", "每周"], ProviderID.claude.quotaTitles == ["每周", "5 小时"] else {
            fatalError("Existing reference layout ordering must be preserved")
        }
        let previous = ProviderSnapshot(provider: .grokBot, plan: "Free", windows: [.init(id: "weekly", title: "每周", usedPercent: 0, resetsAt: nil)], updatedAt: Date(timeIntervalSince1970: 100))
        var failed = ProviderSnapshot(provider: .grokBot, message: "读取失败")
        failed.quotaReadFailed = true
        let merged = SnapshotMerge.preservingFailures(failed, previous: previous)
        guard merged.provider == .grokBot, merged.windows.first?.remaining == 100, merged.updatedAt == previous.updatedAt else {
            fatalError("A Grok refresh failure must preserve the last verified quota and its timestamp")
        }
        guard SnapshotMerge.preservingFailures(failed, previous: .init(provider: .claude)).windows.isEmpty else {
            fatalError("Grok must never inherit another provider's quota")
        }
        print("Provider: 6 checks passed")
    }
}
