import Foundation

@main
enum CodexSmoke {
    static func main() throws {
        if CommandLine.arguments.dropFirst().first == "app-server" { fakeRPC(); return }
        if CommandLine.arguments.contains("--live") {
            let snapshot = try CodexSource.load()
            print("Codex live: windows=\(snapshot.windows.count), days=\(snapshot.days.count), hasMessage=\(snapshot.message != nil)")
            for window in snapshot.windows {
                print("remaining=\(window.remaining), hasReset=\(window.resetsAt != nil)")
            }
            return
        }
        let now = Date(timeIntervalSince1970: 1000)
        let snapshot = try CodexSource.parse(rateLimits: [
            "rateLimits": ["primary": ["usedPercent": 99]],
            "rateLimitsByLimitId": [
                "codex": ["planType": "plus", "primary": ["usedPercent": 25, "windowDurationMins": 300, "resetsAt": 2000]],
                "other": ["primary": ["usedPercent": 80]]
            ]
        ], usage: ["dailyUsageBuckets": [["startDate": "2026-10-27", "tokens": 1234]]], now: now)
        try check(snapshot.windows.count == 1, "Multi-bucket must not duplicate legacy or unrelated buckets")
        try check(snapshot.windows[0].remaining == 75, "Used percent must convert to remaining")
        try check(snapshot.windows[0].title == "5 小时", "Duration must set window title")
        try check(snapshot.plan == "plus", "Plan comes from selected bucket")
        try check(snapshot.updatedAt == now, "Capture time must be recorded")
        try check(snapshot.days.count == 1 && snapshot.days[0].totalTokens == 1234, "Server daily usage must be parsed")
        try check(snapshot.historyReadFailed != true, "Successful history must not be marked failed")
        try check(snapshot.days[0].tokens == nil && snapshot.days[0].estimatedCostUSD == nil, "Missing breakdown and prices must stay unknown")
        try check(snapshot.sourceNote.contains("服务端日期"), "Date scope must be explicit")

        let separate = try CodexSource.parse(rateLimits: ["rateLimitsByLimitId": [
            "model-a": ["limitName": "Model A", "primary": ["usedPercent": 35, "windowDurationMins": 10080]],
            "model-b": ["normalModelSlug": "Model B", "secondary": ["usedPercent": 60]],
            "missing": ["primary": ["usedPercent": NSNull()]]
        ]], usage: ["dailyUsageBuckets": NSNull()])
        try check(separate.windows.count == 2 && Set(separate.windows.map(\.id)).count == 2, "Distinct model buckets need distinct windows")
        try check(separate.windows[0].title.contains("Model A") && separate.windows[1].title.contains("Model B"), "Model labels must remain visible")
        try check(separate.days.isEmpty && separate.message != nil, "Missing daily usage must remain unknown")
        try check(separate.historyReadFailed == true, "Null history must preserve a previous valid history")
        let emptyHistory = try CodexSource.parse(rateLimits: ["rateLimits": [:]], usage: ["dailyUsageBuckets": []])
        try check(emptyHistory.days.isEmpty && emptyHistory.historyReadFailed != true, "A successful empty history must clear previous data")
        let legacy = try CodexSource.parse(rateLimits: ["rateLimits": ["secondary": ["usedPercent": 140]]], usage: nil)
        try check(legacy.windows.count == 1 && legacy.windows[0].remaining == 0, "Legacy fallback and percentage clamp")
        let missing = try CodexSource.parse(rateLimits: ["rateLimits": ["primary": ["usedPercent": NSNull()], "secondary": NSNull()]], usage: nil)
        try check(missing.windows.isEmpty, "Missing quota must not become zero usage")
        let invalid = try CodexSource.parse(rateLimits: ["rateLimits": [:]], usage: ["dailyUsageBuckets": [
            ["startDate": "2026-10-27", "tokens": 1.5],
            ["startDate": "2026-10-27", "tokens": true],
            ["startDate": "2026-02-30", "tokens": 10]
        ]])
        try check(invalid.days.isEmpty, "Malformed fractional, boolean and invalid-date buckets must not become real token usage")
        let path = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.path
        let logs = FileManager.default.temporaryDirectory.appendingPathComponent("AgentMeterCodexSource-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: logs.appendingPathComponent("sessions"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: logs) }
        let stamp = Date().ISO8601Format()
        let records: [[String: Any]] = [
            ["type": "session_meta", "timestamp": stamp, "payload": ["id": "local-test"]],
            ["type": "turn_context", "timestamp": stamp, "payload": ["model": "gpt-6.1-sol"]],
            ["type": "token_usage_record", "timestamp": stamp, "payload": ["thread_id": "local-test", "response_id": "one-response", "usage": ["input_tokens": 100, "cached_input_tokens": 40, "output_tokens": 20, "reasoning_output_tokens": 10, "total_tokens": 120]]]
        ]
        var log = Data()
        for record in records { log.append(try JSONSerialization.data(withJSONObject: record)); log.append(10) }
        try log.write(to: logs.appendingPathComponent("sessions/local.jsonl"))
        let loaded = try CodexSource.load(executable: path, codexHome: logs)
        try check(loaded.windows.count == 1 && loaded.windows[0].remaining == 75, "RPC must ignore notifications and match response IDs")
        try check(loaded.days.first?.totalTokens == 120 && loaded.days.first?.models.first?.model == "gpt-6.1-sol", "Local logs must supply the day and model without account daily usage")
        try check(loaded.days.first?.tokens?.input == 60 && loaded.days.first?.tokens?.reasoning == 10, "Local cache and reasoning must not be counted twice")
        try check(loaded.historySource == .codexLocal && loaded.historyReadFailed != true, "Local history has an explicit scope independent of quota")
        try check(loaded.days.first?.estimatedCostUSD != nil, "Known local models must have standard API reference cost")
        setenv("AGENTMETER_TEST_QUOTA_FAIL", "1", 1)
        let offline = try CodexSource.load(executable: path, codexHome: logs)
        unsetenv("AGENTMETER_TEST_QUOTA_FAIL")
        try check(offline.quotaReadFailed == true && offline.days.first?.totalTokens == 120, "Quota failure must not block independent local statistics")
        if CommandLine.arguments.contains("--timeout") {
            setenv("AGENTMETER_TEST_RPC_TIMEOUT", "1", 1)
            defer { unsetenv("AGENTMETER_TEST_RPC_TIMEOUT") }
            let started = Date()
            let timedOut = try CodexSource.load(executable: path, codexHome: logs)
            try check(timedOut.quotaReadFailed == true && timedOut.days.first?.totalTokens == 120 && Date().timeIntervalSince(started) < 15, "Unresponsive quota child must time out while keeping local usage available")
        }
        print("Codex parser checks passed")
    }
    private static func check(_ passed: Bool, _ message: String) throws {
        if !passed { throw NSError(domain: "CodexSmoke", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    }

    private static func fakeRPC() {
        if ProcessInfo.processInfo.environment["AGENTMETER_TEST_RPC_TIMEOUT"] != nil { Thread.sleep(forTimeInterval: 30); return }
        func send(_ value: [String: Any]) {
            var data = try! JSONSerialization.data(withJSONObject: value)
            data.append(10)
            try! FileHandle.standardOutput.write(contentsOf: data)
        }
        while let line = readLine(), let data = line.data(using: .utf8),
              let request = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let method = request["method"] as? String {
            switch method {
            case "initialize":
                send(["method": "account/updated", "params": ["private": "must-not-retain"]])
                send(["id": request["id"]!, "result": [:]])
            case "initialized": break
            case "account/rateLimits/read":
                if ProcessInfo.processInfo.environment["AGENTMETER_TEST_QUOTA_FAIL"] != nil {
                    send(["id": request["id"]!, "error": ["code": -1]])
                    continue
                }
                send(["id": 999, "result": ["rateLimits": ["primary": ["usedPercent": 99]]]])
                send(["id": request["id"]!, "result": ["rateLimits": ["primary": ["usedPercent": 25, "windowDurationMins": 300]]]])
            case "account/usage/read":
                try! FileHandle.standardError.write(contentsOf: Data(repeating: 120, count: 262144))
                send(["id": request["id"]!, "error": ["code": -32601, "message": "private error detail must not be retained"]])
            default: exit(2)
            }
        }
    }
}
