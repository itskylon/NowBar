import Foundation

public enum ProviderSource {
    public static func load(_ provider: ProviderID) throws -> ProviderSnapshot {
        switch provider {
        case .codex: return try CodexSource.load()
        case .claude: return try ClaudeSource.load()
        case .grokBot: return GrokBotSource.load()
        }
    }
}
