import Foundation
import AgentMeterCore

@main
struct HistoryWindowAcceptance {
    @MainActor static func main() async throws {
        var count = 0
        func expect(_ result: Bool, _ reason: String) {
            precondition(result, reason)
            count += 1
        }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let codex = UsageRecord(id: "same-id", date: now, provider: .codex, model: "model-a", tokens: .init(input: 10, output: 2), estimatedCostUSD: 0.2, projectPath: "/first/alpha", sessionID: "same-session", conversationID: "same-conversation")
        let claude = UsageRecord(id: "same-id", date: now, provider: .claude, model: "model-b", tokens: .init(input: 20), estimatedCostUSD: nil, projectPath: "/second/beta", sessionID: "same-session", conversationID: "same-conversation")
        let old = UsageRecord(id: "old", date: now.addingTimeInterval(-100 * 86400), provider: .codex, model: "model-a", tokens: .init(input: 5), estimatedCostUSD: 0.1, projectPath: "/first/alpha", sessionID: "old-session", conversationID: "old-conversation")
        let saved = UserDefaults.standard.object(forKey: UsageHistoryStore.timeZoneKey) as? String
        let history = UsageHistoryStore(previewRecords: [codex, claude, old], now: now)
        history.start(enabledProviders: [.codex], automatic: false)
        expect(history.records.count == 2, "Only enabled providers enter the history report")
        expect(history.report.summary.tokens.total == 17, "Full history includes records outside seven days")
        history.range = .sevenDays
        expect(history.report.summary.tokens.total == 12, "Changing range filters the same underlying history immediately")
        history.provider = .claude
        history.configure(enabledProviders: [.codex], automatic: false)
        expect(history.provider == nil, "Disabled selected providers return to the combined report")
        history.configure(enabledProviders: [.codex, .claude], automatic: true)
        expect(history.report.records.count == 2, "Re-enabling includes both providers without collapsing equal IDs")
        expect(history.report.summary.pricedCostUSD == 0.2 && history.report.summary.unpricedCount == 1, "Partial pricing remains explicit")
        history.search = "beta"
        expect(history.rankings.count == 1 && history.rankings.first?.title == "beta", "Search matches the project ranking")
        history.timeZoneID = "UTC"
        expect((UserDefaults.standard.object(forKey: UsageHistoryStore.timeZoneKey) as? String) == saved, "Preview history never persists preferences")
        history.stop()
        history.refresh()
        expect(!history.scanning, "A stopped preview cannot start background log reads")

        var clockNow = MeterDate.parse("2026-10-31T15:59:59Z")!
        func datedRecord(_ id: String, _ stamp: String, provider: ProviderID = .codex) -> UsageRecord {
            UsageRecord(id: id, date: MeterDate.parse(stamp)!, provider: provider, model: "model-a",
                        tokens: .init(input: 1), estimatedCostUSD: 0.1, projectPath: "/fixtures/\(id)",
                        sessionID: id, conversationID: id)
        }
        let clockHistory = UsageHistoryStore(previewRecords: [
            datedRecord("month-start", "2026-10-01T01:00:00Z"),
            datedRecord("seven-day-edge", "2026-10-24T16:30:00Z"),
            datedRecord("recent", "2026-10-31T08:00:00Z"),
            datedRecord("future", "2026-10-31T16:00:02Z", provider: .claude)
        ], clock: { clockNow })
        clockHistory.timeZoneID = "Asia/Shanghai"
        clockHistory.start(enabledProviders: [.codex, .claude], automatic: false)
        clockHistory.range = .sevenDays
        expect(clockHistory.report.summary.recordCount == 2 && clockHistory.conversationCount == 2 && clockHistory.sessionCount == 2,
               "Cached summary and identity counts use the selected seven-day range")
        _ = clockHistory.rankings
        _ = clockHistory.buckets
        clockNow = clockNow.addingTimeInterval(2)
        expect(clockHistory.rankings.reduce(0) { $0 + $1.summary.recordCount } == 1
               && clockHistory.buckets.reduce(0) { $0 + $1.summary.recordCount } == 1 && clockHistory.sessionCount == 1,
               "Crossing midnight in the selected timezone invalidates every derived cache without another log scan")
        clockHistory.range = .monthToDate
        expect(clockHistory.report.records.isEmpty && clockHistory.rankings.isEmpty && clockHistory.buckets.isEmpty,
               "The month-to-date cache advances into a new month and still excludes future records")
        clockNow = clockNow.addingTimeInterval(2)
        expect(clockHistory.report.summary.recordCount == 1 && clockHistory.buckets.first?.summary.recordCount == 1,
               "A future response becomes eligible within the same day without waiting for another midnight")
        clockHistory.timeZoneID = "UTC"
        expect(clockHistory.report.summary.recordCount == 4 && clockHistory.conversationCount == 4 && clockHistory.sessionCount == 4,
               "Changing timezone invalidates the report, rankings, buckets, and identity counts")
        clockHistory.grouping = .provider
        expect(Set(clockHistory.rankings.map(\.title)) == [ProviderID.codex.title, ProviderID.claude.title],
               "Changing grouping does not reuse stale project rankings")
        clockHistory.period = .hourly
        expect(clockHistory.buckets.allSatisfy { $0.end.timeIntervalSince($0.start) == 3600 },
               "Changing chart granularity replaces the cached overview buckets")
        clockHistory.provider = .claude
        expect(clockHistory.report.summary.recordCount == 1 && clockHistory.rankings.count == 1 && clockHistory.buckets.count == 1,
               "Changing provider invalidates every report projection")
        clockHistory.configure(enabledProviders: [.codex], automatic: false)
        expect(clockHistory.provider == nil && clockHistory.report.summary.recordCount == 3 && clockHistory.sessionCount == 3,
               "Replacing enabled records invalidates previously cached provider results")
        clockHistory.stop()

        let fixtureRoot = FileManager.default.temporaryDirectory.appendingPathComponent("HistoryWindow-\(UUID().uuidString)")
        let codexHome = fixtureRoot.appendingPathComponent("codex", isDirectory: true)
        let claudeProjects = fixtureRoot.appendingPathComponent("claude", isDirectory: true)
        try FileManager.default.createDirectory(at: codexHome.appendingPathComponent("sessions"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: claudeProjects.appendingPathComponent("project"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fixtureRoot) }
        let stamp = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-60))
        func jsonLine(_ fields: [String: Any]) throws -> Data {
            var data = try JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys])
            data.append(10)
            return data
        }
        func codexLine(_ type: String, _ payload: [String: Any]) throws -> Data {
            try jsonLine(["type": type, "timestamp": stamp, "payload": payload])
        }
        func response(_ id: String) throws -> Data {
            try codexLine("token_usage_record", ["response_id": id, "thread_id": "codex-session",
                "usage": ["input_tokens": 100, "cached_input_tokens": 20, "output_tokens": 10, "total_tokens": 110]])
        }
        let codexFile = codexHome.appendingPathComponent("sessions/history.jsonl")
        var codexData = try codexLine("session_meta", ["id": "codex-session", "cwd": "/fixtures/codex"])
        codexData.append(try codexLine("turn_context", ["model": "gpt-5-codex"]))
        codexData.append(try response("first"))
        try codexData.write(to: codexFile)
        let claudeData = try jsonLine(["type": "assistant", "sessionId": "claude-session", "timestamp": stamp,
            "cwd": "/fixtures/claude", "message": ["id": "first", "model": "claude-sonnet-4-6",
                "usage": ["input_tokens": 40, "output_tokens": 5, "cache_read_input_tokens": 10]]])
        try claudeData.write(to: claudeProjects.appendingPathComponent("project/history.jsonl"))

        func settle(_ store: UsageHistoryStore) async {
            for _ in 0..<500 {
                if !store.scanning { return }
                try? await Task.sleep(for: .milliseconds(10))
            }
            preconditionFailure("Local history scan did not settle")
        }
        let live = UsageHistoryStore(codexHome: codexHome, claudeProjects: claudeProjects)
        live.start(enabledProviders: [.codex], automatic: false)
        expect(live.scanning, "Opening a manual history window starts its local scan immediately")
        // No suspension here: the first batch captured Codex before Claude was enabled.
        live.configure(enabledProviders: [.codex, .claude], automatic: false)
        await settle(live)
        expect(Set(live.records.map(\.provider)) == [.codex, .claude], "Enabling a provider during an in-flight manual scan queues another scan")
        expect(live.report.summary.tokens.total == 165 && live.scannedFileCount == 2 && live.totalFileCount == 2,
               "Both fixture readers supply actual tokens and completed file progress")
        live.stop()

        let reopened = UsageHistoryStore(codexHome: codexHome, claudeProjects: claudeProjects)
        reopened.start(enabledProviders: [.codex], automatic: false)
        reopened.stop()
        reopened.start(enabledProviders: [.codex, .claude], automatic: false)
        await settle(reopened)
        expect(Set(reopened.records.map(\.provider)) == [.codex, .claude] && reopened.records.count == 2,
               "A closed generation cannot overwrite the immediately reopened history window")
        reopened.stop()
        let stoppedCount = reopened.records.count
        let handle = try FileHandle(forWritingTo: codexFile)
        try handle.seekToEnd()
        try handle.write(contentsOf: response("appended"))
        try handle.close()
        reopened.refresh()
        try await Task.sleep(for: .milliseconds(50))
        expect(!reopened.scanning && reopened.records.count == stoppedCount,
               "Refreshing a closed history window does not read appended logs")
        reopened.start(enabledProviders: [.codex, .claude], automatic: false)
        await settle(reopened)
        expect(reopened.records.count == stoppedCount + 1,
               "Reopening a history window resumes incremental reads without duplicating prior records")
        expect(reopened.report.summary.tokens.total == 275,
               "Appended local responses invalidate the prior cached token summary")
        reopened.stop()
        expect((UserDefaults.standard.object(forKey: UsageHistoryStore.timeZoneKey) as? String) == saved,
               "Local fixture acceptance checks do not change the real statistics timezone")
        print("History window: \(count) acceptance checks passed")
    }
}
