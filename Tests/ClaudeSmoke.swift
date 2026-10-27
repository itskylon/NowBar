import Foundation

@main struct ClaudeSmoke {
    static func main() throws {
        let now = Date(timeIntervalSince1970: 1800000000)
        let valid = Data(#"{"updated_at":"2027-01-15T08:00:00Z","rate_limits":{"five_hour":{"used_percentage":26,"resets_at":1900000000},"seven_day":{"used_percentage":70,"resets_at":1900100000}}}"#.utf8)
        let snapshot = try ClaudeSource.parseBridge(valid, now: now)
        precondition(snapshot.windows.count == 2)
        precondition(snapshot.windows[0].remaining == 74)
        precondition(snapshot.updatedAt != nil)
        let expired = try ClaudeSource.parseBridge(Data(#"{"updated_at":"2020-01-01T00:00:00Z","rate_limits":{"five_hour":{"used_percentage":100,"resets_at":1600000000}}}"#.utf8), now: now)
        precondition(expired.windows[0].expired(at: now))
        precondition(expired.windows[0].remaining == 0, "Expired data must never imply full quota")
        let missing = try ClaudeSource.parseBridge(Data(#"{"updated_at":"2020-01-01T00:00:00Z","rate_limits":{}}"#.utf8), now: now)
        precondition(missing.windows.isEmpty)

        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let dir = home.appendingPathComponent(".claude/projects/project")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let stamp = ISO8601DateFormatter().string(from: Date())
        func row(_ id: String, _ model: String, _ output: Int) -> String {
            """
            {"type":"assistant","sessionId":"s1","timestamp":"\(stamp)","requestId":"r-\(id)","message":{"id":"\(id)","model":"\(model)","usage":{"input_tokens":100,"output_tokens":\(output),"cache_read_input_tokens":1000,"cache_creation_input_tokens":200,"cache_creation":{"ephemeral_5m_input_tokens":100,"ephemeral_1h_input_tokens":100}}}}
            """
        }
        let lines = [row("m1", "claude-sonnet-4-6", 10), row("m1", "claude-sonnet-4-6", 20), row("m2", "unknown-model", 4)]
        try (lines.joined(separator: "\n") + "\n").write(to: dir.appendingPathComponent("s1.jsonl"), atomically: true, encoding: .utf8)
        let local = try ClaudeSource.load(home: home)
        precondition(local.days.count == 1)
        precondition(local.days[0].totalTokens == 2624, "Streamed blocks must not duplicate requests; cache components counted once")
        precondition(local.days[0].unpricedModels == ["unknown-model"])
        precondition(local.days[0].estimatedCostUSD == nil, "Partial costs cannot be represented as full totals")
        precondition(local.days[0].models.first(where: { $0.model == "claude-sonnet-4-6" })!.estimatedCostUSD! > 0)
        precondition(abs(local.days[0].models.first(where: { $0.model == "claude-sonnet-4-6" })!.estimatedCostUSD! - 0.001875) < 0.000000001,
                     "5-minute and 1-hour cache writes must be priced separately")

        let second = row("m1", "claude-sonnet-4-6", 20).replacingOccurrences(of: "\"sessionId\":\"s1\"", with: "\"sessionId\":\"s2\"")
        try (second + "\n{\"usage\": broken}\n").write(to: dir.appendingPathComponent("s2.jsonl"), atomically: true, encoding: .utf8)
        let separate = try ClaudeSource.load(home: home)
        precondition(separate.days[0].totalTokens == 3944, "Different sessions sharing a message id are independent")
        precondition(separate.message?.contains("不完整") == true)

        let totalOnly = row("late-ttl", "claude-sonnet-4-6", 20)
            .replacingOccurrences(of: ",\"cache_creation\":{\"ephemeral_5m_input_tokens\":100,\"ephemeral_1h_input_tokens\":100}", with: "")
        let detailed = row("late-ttl", "claude-sonnet-4-6", 20)
        try (totalOnly + "\n" + detailed + "\n" + totalOnly + "\n").write(to: dir.appendingPathComponent("late.jsonl"), atomically: true, encoding: .utf8)
        let late = try ClaudeSource.load(home: home)
        precondition(late.days[0].totalTokens == 5264, "Late cache metadata must not add a second set of cache tokens")
        let model = late.days[0].models.first(where: { $0.model == "claude-sonnet-4-6" })!
        precondition(abs(model.estimatedCostUSD! - 3 * 0.001875) < 0.000000001,
                     "Late TTL details must replace inferred 5m allocation and survive later total-only blocks")
        precondition(separate.historyReadFailed == true)
        precondition(separate.quotaReadFailed != true, "Missing bridge means not connected, not failed")
        precondition(separate.quotaMessage?.contains("接入 Claude") == true, "Keep quota connection notice separate from log warnings")
        precondition(separate.quotaMessage?.contains("不完整") != true, "History warnings must not become quota warnings")

        let bridge = home.appendingPathComponent("Library/Application Support/AgentMeter/claude-usage.json")
        try FileManager.default.createDirectory(at: bridge.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("broken".utf8).write(to: bridge)
        let broken = try ClaudeSource.load(home: home)
        precondition(broken.quotaReadFailed == true)
        try Data(#"{"updated_at":"2027-01-15T08:00:00Z","rate_limits":{}}"#.utf8).write(to: bridge)
        let empty = try ClaudeSource.load(home: home)
        precondition(empty.quotaReadFailed != true, "Successful empty quota windows must remain distinguishable from failure")
        precondition(empty.quotaMessage?.contains("未提供订阅额度") == true, "Keep missing-quota notice separate from logs")
        let healthyData = try JSONSerialization.data(withJSONObject: [
            "updated_at": stamp,
            "rate_limits": ["five_hour": ["used_percentage": 26, "resets_at": Date().addingTimeInterval(3600).timeIntervalSince1970]]
        ])
        try healthyData.write(to: bridge)
        let healthy = try ClaudeSource.load(home: home)
        precondition(healthy.quotaMessage == nil && healthy.message?.contains("不完整") == true, "Valid quota and incomplete local history are independent")
        print("Claude: 24 checks passed")
    }
}
