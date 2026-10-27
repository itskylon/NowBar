import Foundation

@main
struct ClaudeHistorySmoke {
    static func main() throws {
        var checks = 0
        func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
            precondition(condition(), message)
            checks += 1
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ClaudeHistory-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let now = MeterDate.parse("2026-10-27T12:00:00Z")!
        func row(_ id: String, session: String = "main", stamp: String = "2026-10-27T10:00:00Z",
                 model: String = "claude-sonnet-4-6", output: Int = 20, cwd: String? = "/work/a/project",
                 agent: String? = nil, ttl: Bool = true) throws -> Data {
            var usage: [String: Any] = ["input_tokens": 100, "output_tokens": output,
                "cache_read_input_tokens": 1000, "cache_creation_input_tokens": 200]
            if ttl { usage["cache_creation"] = ["ephemeral_5m_input_tokens": 100, "ephemeral_1h_input_tokens": 100] }
            var object: [String: Any] = ["type": "assistant", "sessionId": session, "timestamp": stamp,
                "message": ["id": id, "model": model, "content": [["type": "text", "text": "private body"]], "usage": usage]]
            if let cwd { object["cwd"] = cwd }
            if let agent { object["agentId"] = agent }
            return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        }
        func write(_ name: String, _ lines: [Data], newline: Bool = true) throws -> URL {
            let file = root.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            var data = Data()
            for (index, line) in lines.enumerated() {
                data.append(line)
                if newline || index < lines.count - 1 { data.append(10) }
            }
            try data.write(to: file)
            return file
        }
        func append(_ file: URL, _ data: Data) throws {
            let handle = try FileHandle(forWritingTo: file)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        }
        let old = try row("old", stamp: "2020-01-02T10:00:00Z")
        let file = try write("project/main.jsonl", [old, try row("same", output: 10, ttl: false), try row("same"), try row("same", ttl: false)])
        let reader = ClaudeUsageHistoryReader(root: root)
        var result = reader.scan(now: now)
        expect(result.records.count == 2, "All history includes old sessions and deduplicates streamed blocks")
        expect(result.records.reduce(Int64(0)) { $0 + $1.tokens.total } == 2640, "Tokens count cache reads/writes once, not once per streamed block")
        let streamed = result.records.first { $0.date > MeterDate.parse("2026-01-01T00:00:00Z")! }!
        expect(abs(streamed.estimatedCostUSD! - 0.001875) < 1e-12, "Late TTL details reclassify existing writes without double charging")
        expect(streamed.projectPath == "/work/a/project" && streamed.sessionID == "main" && streamed.conversationID == "main", "Assistant metadata supplies project and root session")
        expect(!result.incomplete && result.scannedFileCount == 1 && result.totalFileCount == 1, "Finished files report complete progress")
        result = reader.scan(now: now)
        expect(result.records.count == 2 && result.records.reduce(Int64(0)) { $0 + $1.tokens.total } == 2640, "An unchanged scan must not accumulate totals")
        var next = try row("new", cwd: "/work/b/project"); next.append(10)
        try append(file, next)
        result = reader.scan(now: now)
        expect(result.records.count == 3, "An appended complete response appears incrementally")
        expect(Set(result.records.compactMap(\.projectPath)).count == 2, "Same-name projects retain their full paths")
        _ = try write("project/main/subagents/agent-child.jsonl", [try row("child", agent: "child")])
        _ = try write("project/main/subagents/agent-other.jsonl", [try row("other")])
        result = reader.scan(now: now)
        let children = result.records.filter { $0.sessionID != "main" }
        expect(children.count == 2 && Set(children.map(\.sessionID)).count == 2, "Explicit and file-derived agent IDs remain distinct sessions")
        expect(Set(children.map(\.conversationID)) == ["main"], "Subagents belong to their independent root conversation")
        _ = try write("project/unknown.jsonl", [try row("unknown", model: "future-model", cwd: nil), try row("synthetic", model: "<synthetic>")])
        result = reader.scan(now: now)
        expect(result.records.count == 6, "Synthetic context records are not billed")
        let unknown = result.records.first { $0.model == "future-model" }!
        expect(unknown.estimatedCostUSD == nil && unknown.projectPath == nil, "Unknown prices and projects stay unknown")
        _ = try write("project/future.jsonl", [try row("future", stamp: "2026-10-28T10:00:00Z")])
        result = reader.scan(now: now)
        expect(result.records.count == 6, "Future usage cannot appear before its timestamp")
        result = reader.scan(now: now.addingTimeInterval(86400))
        expect(result.records.count == 7, "Cached future metadata becomes visible as time advances")
        let partial = try row("partial")
        let partialFile = try write("project/partial.jsonl", [Data(partial.prefix(partial.count / 2))], newline: false)
        result = reader.scan(now: now)
        expect(result.records.count == 6 && result.incomplete, "An incomplete line is not reported as completed usage")
        expect(result.scannedFileCount == result.totalFileCount, "A partial EOF does not advertise unread scan-budget backlog")
        var remainder = Data(partial.suffix(partial.count - partial.count / 2)); remainder.append(10)
        try append(partialFile, remainder)
        result = reader.scan(now: now)
        expect(result.records.count == 7 && !result.incomplete, "A completed half-line is read on the next scan without retaining body text")
        try Data().write(to: partialFile)
        result = reader.scan(now: now)
        expect(result.records.count == 6, "Truncating a file removes its old records")
        let slicedRoot = root.appendingPathComponent("budget")
        try FileManager.default.createDirectory(at: slicedRoot, withIntermediateDirectories: true)
        var budgetData = Data()
        for i in 0..<8 { budgetData.append(try row("budget-\(i)")); budgetData.append(10) }
        try budgetData.write(to: slicedRoot.appendingPathComponent("one.jsonl"))
        let limited = ClaudeUsageHistoryReader(root: slicedRoot, limits: .init(fileBytes: 1024, scanBytes: 1024, lineBytes: 1024))
        var batch = limited.scan(now: now)
        expect(batch.incomplete && batch.scannedFileCount == 0 && batch.totalFileCount == 1, "Budget limits expose unread progress")
        for _ in 0..<8 { batch = limited.scan(now: now) }
        expect(batch.records.count == 8 && !batch.incomplete && batch.scannedFileCount == 1, "Budget-limited scans resume until all old records have been read")
        let prefixRoot = root.appendingPathComponent("prefix-progress")
        try FileManager.default.createDirectory(at: prefixRoot, withIntermediateDirectories: true)
        var prefixData = Data()
        for _ in 0..<100 { prefixData.append(Data("{\"type\":\"user\",\"message\":\"private prefix\"}\n".utf8)) }
        prefixData.append(try row("after-prefix")); prefixData.append(10)
        try prefixData.write(to: prefixRoot.appendingPathComponent("large.jsonl"))
        let prefixed = ClaudeUsageHistoryReader(root: prefixRoot, limits: .init(fileBytes: 1024, scanBytes: 1024, lineBytes: 1024))
        let firstPrefix = prefixed.scan(now: now)
        let secondPrefix = prefixed.scan(now: now)
        expect(firstPrefix.records.isEmpty && firstPrefix.scannedFileCount == 0 && firstPrefix.readBytes > 0,
               "Reading a non-usage prefix must expose byte progress before any response or file completes")
        expect(secondPrefix.records.isEmpty && secondPrefix.scannedFileCount == 0 && secondPrefix.readBytes > firstPrefix.readBytes,
               "A second prefix-only batch must report increasing bytes so manual continuation does not stop")
        var prefixBatch = secondPrefix
        for _ in 0..<10 { prefixBatch = prefixed.scan(now: now) }
        expect(prefixBatch.records.count == 1 && !prefixBatch.incomplete && prefixBatch.readBytes == UInt64(prefixData.count),
               "Continuation reaches usage after a long prefix and byte progress ends at the file size")
        let empty = ClaudeUsageHistoryReader(root: root.appendingPathComponent("absent")).scan(now: now)
        expect(empty.records.isEmpty && !empty.incomplete && empty.totalFileCount == 0, "An absent log directory is a known empty source")
        print("Claude history: \(checks) checks passed")
    }
}
