import Foundation

@main enum OAuthQuotaSmoke {
    static func main() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        func parse(_ provider: ProviderID, _ json: String, status: Int = 200) throws -> ProviderSnapshot {
            try OAuthQuotaSource.parse(provider, data: Data(json.utf8), statusCode: status, now: now)
        }
        let codex = try parse(.codex, #"{"plan_type":"free","rate_limit":{"primary_window":{"used_percent":37,"limit_window_seconds":18000,"reset_at":1800003600},"secondary_window":{"used_percent":82,"limit_window_seconds":604800,"reset_at":1800604800}}}"#)
        precondition(codex.plan == "free" && codex.windows.count == 2)
        precondition(codex.windows[0].id == "primary" && codex.windows[0].remaining == 63)
        precondition(codex.windows[1].title == "每周" && codex.windows[1].resetsAt != nil)
        precondition(codex.quotaSource == .codexOAuth && codex.days.isEmpty)
        let claude = try parse(.claude, #"{"five_hour":{"utilization":26.5,"resets_at":"2027-01-15T09:00:00Z"},"seven_day":{"utilization":0,"resets_at":null},"seven_day_sonnet":{"utilization":61,"resets_at":"2027-01-20T09:00:00Z"}}"#)
        precondition(claude.windows.count == 3 && claude.windows[0].id == "claude.five_hour")
        precondition(claude.windows[0].remaining == 73.5 && claude.windows[1].resetsAt == nil)
        precondition(claude.quotaSource == .claudeOAuth)
        let missing = try parse(.claude, #"{"five_hour":null,"seven_day":null}"#)
        precondition(missing.windows.isEmpty && missing.message != nil && missing.quotaReadFailed != true)
        let empty = try parse(.codex, #"{"plan_type":"free","rate_limit":null}"#)
        precondition(empty.windows.isEmpty && empty.message != nil)
        for bad in [#"{"five_hour":{"utilization":true}}"#, #"{"five_hour":{"utilization":-1}}"#, #"{"five_hour":{"utilization":1000000}}"#, #"{}"#, #"{"five_hour":{"utilization":10,"resets_at":"not-date"}}"#] {
            do { _ = try parse(.claude, bad); preconditionFailure("Invalid usage must fail") }
            catch { precondition(!error.localizedDescription.contains("not-date")) }
        }
        for status in [301, 401, 403, 429, 500] {
            do { _ = try parse(.codex, #"{"error":"secret-sentinel"}"#, status: status); preconditionFailure("HTTP errors must fail") }
            catch { precondition(!error.localizedDescription.contains("secret-sentinel")) }
        }
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("NowBarOAuth-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".codex"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".claude"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        precondition(OAuthQuotaSource.credentialStatus(.codex, home: home) == .missing)
        let codexFile = home.appendingPathComponent(".codex/auth.json")
        try Data(#"{"tokens":{"access_token":"fixture-access-only","account_id":"fixture-account"}}"#.utf8).write(to: codexFile)
        precondition(OAuthQuotaSource.credentialStatus(.codex, home: home) == .available)
        try Data(#"{"OPENAI_API_KEY":"fixture-api-key"}"#.utf8).write(to: codexFile)
        precondition(OAuthQuotaSource.credentialStatus(.codex, home: home) == .missing, "API keys are not OAuth")
        let claudeFile = home.appendingPathComponent(".claude/.credentials.json")
        try Data(#"{"claudeAiOauth":{"accessToken":"fixture-claude","expiresAt":1900000000000,"scopes":["user:profile"]}}"#.utf8).write(to: claudeFile)
        precondition(OAuthQuotaSource.credentialStatus(.claude, home: home, now: now) == .available)
        try Data(#"{"claudeAiOauth":{"accessToken":"fixture-claude","expiresAt":1700000000000,"scopes":["user:profile"]}}"#.utf8).write(to: claudeFile)
        precondition(OAuthQuotaSource.credentialStatus(.claude, home: home, now: now) == .expired)
        try Data(#"{"claudeAiOauth":{"accessToken":"fixture-claude","expiresAt":1900000000000,"scopes":["user:inference"]}}"#.utf8).write(to: claudeFile)
        precondition(OAuthQuotaSource.credentialStatus(.claude, home: home, now: now) == .invalid)
        try Data(#"{"tokens":{"access_token":"bad\r\nheader"}}"#.utf8).write(to: codexFile)
        precondition(OAuthQuotaSource.credentialStatus(.codex, home: home) == .invalid)
        let override = home.appendingPathComponent("isolated")
        try FileManager.default.createDirectory(at: override, withIntermediateDirectories: true)
        precondition(OAuthQuotaSource.credentialStatus(.codex, home: home, codexHome: override) == .missing)
        try OAuthQuotaSource.prepareConnection(.codex, home: home)
        try OAuthQuotaSource.prepareConnection(.claude, home: home)
        try FileManager.default.removeItem(at: claudeFile)
        do {
            try OAuthQuotaSource.prepareConnection(.claude, home: home)
            preconditionFailure("Isolated homes must never access the real Keychain")
        } catch OAuthQuotaSource.ReadError.missing {}
        precondition(OAuthQuotaSource.ReadError.keychainAccess.localizedDescription.contains("钥匙串"))
        print("OAuth quota: parser, credential isolation, expiry, scope and redaction checks passed")
    }
}
