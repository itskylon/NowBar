import Foundation

public enum ProviderSource {
    public static func load(_ provider: ProviderID, oauthEnabled: Bool = false) throws -> ProviderSnapshot {
        switch provider {
        case .codex: return try CodexSource.load(oauthEnabled: oauthEnabled)
        case .claude: return try ClaudeSource.load(oauthEnabled: oauthEnabled)
        case .grokBot: return GrokBotSource.load()
        }
    }
}
