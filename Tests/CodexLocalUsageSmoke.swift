import Foundation

@main
enum CodexLocalUsageSmoke {
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("meter-codex-local-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("sessions"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let now = MeterDate.parse("2026-10-27T08:00:00Z")!
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 8 * 3600)!
        var checks = 0
        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            guard condition() else { fatalError(message) }; checks += 1
        }
        func line(_ type: String, _ payload: [String: Any], _ timestamp: String = "2026-10-27T01:00:00Z") -> String {
            var fields = payload
            let subtype = fields.removeValue(forKey: "type") as? String
            let data = try! JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys])
            var body = String(decoding: data, as: UTF8.self)
            if let subtype {
                body = "{\"type\":\"\(subtype)\"" + (body == "{}" ? "}" : "," + body.dropFirst())
            }
            return "{\"timestamp\":\"\(timestamp)\",\"type\":\"\(type)\",\"payload\":\(body)}\n"
        }
        func usage(_ input: Int = 100, _ read: Int = 60, _ output: Int = 20, _ reasoning: Int = 5, _ write: Int = 0) -> [String: Any] {
            ["input_tokens": input, "cached_input_tokens": read, "cache_write_input_tokens": write,
             "output_tokens": output, "reasoning_output_tokens": min(reasoning, output), "total_tokens": input + output]
        }
        func context(_ model: String) -> String { line("turn_context", ["model": model]) }
        func record(_ id: String, _ count: [String: Any], _ stamp: String = "2026-10-27T01:00:00Z", cumulative: [String: Any]? = nil) -> String {
            var payload: [String: Any] = ["response_id": id, "thread_id": "parent", "usage": count]
            if let cumulative { payload["thread_token_usage"] = cumulative }
            return line("token_usage_record", payload, stamp)
        }
        func legacy(_ count: [String: Any], _ total: [String: Any], _ stamp: String = "2026-10-27T01:00:00.002Z") -> String {
            line("event_msg", ["type": "token_count", "info": ["last_token_usage": count, "total_token_usage": total]], stamp)
        }
        func write(_ name: String, _ text: String) throws -> URL {
            let url = root.appendingPathComponent("sessions/\(name).jsonl")
            try Data(text.utf8).write(to: url)
            return url
        }
        let sample = usage()
        let initial = line("session_meta", ["id": "parent"]) + context("known") + record("r1", sample) + legacy(sample, sample)
        let file = try write("parent", initial)
        let reader = CodexLocalUsageReader(root: root, estimateCost: { model, counts, rawInput, _ in
            model == "known" ? Double(rawInput + counts.output) / 1_000_000 : nil
        })
        var result = reader.scan(now: now, calendar: calendar)
        check(result.days.count == 1 && result.days[0].totalTokens == 120, "Paired record/token_count (+2ms) must count once")
        check(result.days[0].tokens == TokenCounts(input: 40, output: 20, cacheRead: 60, reasoning: 5), "Cache is an input subset and reasoning an output subset")
        check(result.days[0].estimatedCostUSD == 0.00012, "Costs are evaluated per request with raw input")
        check(!result.incomplete, "Valid logs are complete")
        result = reader.scan(now: now, calendar: calendar)
        check(result.days[0].totalTokens == 120, "Repeated scans must not add usage")
        _ = try write("fork", line("session_meta", ["id": "child", "forked_from_id": "parent"]) + initial)
        result = reader.scan(now: now, calendar: calendar)
        check(result.days[0].totalTokens == 120, "Inherited parent records are deduplicated across files")
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        let next = context("other") + record("r2", usage(50, 10, 10), "2026-10-27T01:01:00Z")
        try handle.write(contentsOf: Data(next.utf8)); try handle.close()
        result = reader.scan(now: now, calendar: calendar)
        check(result.days[0].totalTokens == 180 && result.days[0].models.count == 2, "Appended model changes appear incrementally")
        check(result.days[0].estimatedCostUSD == nil && result.days[0].unpricedModels == ["other"], "Unknown prices preserve tokens but do not fabricate cost")
        check(result.latestUsageAt == MeterDate.parse("2026-10-27T01:01:00Z"), "Latest usage timestamp is reported")

        // Legacy-only sessions use the last sample, never their lifetime cumulative total.
        _ = try write("legacy", context("known") + legacy(usage(10, 2, 3), usage(1000, 500, 100), "2026-10-27T02:00:00Z")
            + legacy(usage(10, 2, 3), usage(1000, 500, 100), "2026-10-27T02:01:00Z"))
        result = reader.scan(now: now, calendar: calendar)
        check(result.days[0].totalTokens == 193, "Repeated cumulative notifications and historical totals are not new requests")
        _ = try write("legacy-fork", context("known") + legacy(usage(10, 2, 3), usage(1000, 500, 100), "2026-10-27T02:00:00Z"))
        check(reader.scan(now: now, calendar: calendar).days[0].totalTokens == 193, "Legacy fork copies use timestamp and cumulative identity")
        _ = try write("reverse", context("known") + legacy(usage(7, 1, 2), usage(7, 1, 2), "2026-10-27T03:00:00Z")
            + record("reverse", usage(7, 1, 2), "2026-10-27T03:00:00.001Z"))
        check(reader.scan(now: now, calendar: calendar).days[0].totalTokens == 202, "Reverse-order paired event types count once")
        _ = try write("same-counts", context("known") + record("same-1", usage(3, 0, 2), "2026-10-27T03:01:00Z")
            + record("same-2", usage(3, 0, 2), "2026-10-27T03:01:00.010Z"))
        check(reader.scan(now: now, calendar: calendar).days[0].totalTokens == 212, "Distinct response IDs with identical token counts remain distinct")
        _ = try write("midnight", context("known") + record("before", usage(1, 0, 1), "2026-10-26T15:59:59Z")
            + record("after", usage(2, 0, 1), "2026-10-26T16:00:00Z")
            + record("old", usage(10000, 0, 1), "2026-10-19T00:00:00Z"))
        result = reader.scan(now: now, calendar: calendar)
        check(result.days.map(\.day) == ["2026-10-26", "2026-10-27"], "Use local midnight and retain seven local dates only")
        check(result.days[0].totalTokens == 2 && result.days[1].totalTokens == 215, "Each request belongs to its local calendar date")

        let partial = record("partial", usage(5, 0, 2), "2026-10-27T04:00:00Z")
        let partialFile = try write("partial", context("known") + String(partial.dropLast(12)))
        result = reader.scan(now: now, calendar: calendar)
        check(result.days.last!.totalTokens == 215 && result.incomplete, "Incomplete JSONL tails are not counted")
        let append = try FileHandle(forWritingTo: partialFile); try append.seekToEnd()
        try append.write(contentsOf: Data(partial.suffix(12).utf8)); try append.close()
        result = reader.scan(now: now, calendar: calendar)
        check(result.days.last!.totalTokens == 222 && !result.incomplete, "Half-line append completes exactly one request")
        try Data((context("known") + record("replacement", usage(1, 0, 1), "2026-10-27T04:01:00Z")).utf8).write(to: partialFile, options: .atomic)
        result = reader.scan(now: now, calendar: calendar)
        check(result.days.last!.totalTokens == 217, "Atomic replacement removes prior file events and reparses")
        _ = try write("invalid", context("known") + "{\"type\":\"token_usage_record\",broken}\n"
            + record("bad-count", ["input_tokens": true, "output_tokens": 2], "2026-10-27T04:02:00Z"))
        result = reader.scan(now: now, calendar: calendar)
        check(result.incomplete && result.days.last!.totalTokens == 217, "Malformed or boolean usage cannot become billable tokens")
        let missing = CodexLocalUsageReader(root: root.appendingPathComponent("absent")).scan(now: now, calendar: calendar)
        check(missing.days.isEmpty && !missing.incomplete, "A missing logs directory is empty, not a read failure")
        let cleanRoot = root.appendingPathComponent("clean")
        try FileManager.default.createDirectory(at: cleanRoot.appendingPathComponent("sessions"), withIntermediateDirectories: true)
        var estimate = usage(0, 0, 0, 0)
        estimate["total_tokens"] = 99_999
        let small = usage(4, 1, 2)
        let synthetic = context("known") + record("synthetic-base", small, "2026-10-27T05:00:00Z")
            + legacy(small, small, "2026-10-27T05:00:00.001Z")
            + legacy(small, estimate, "2026-10-27T05:01:00Z")
            + legacy(small, small, "2026-10-27T05:02:00Z")
        try Data(synthetic.utf8).write(to: cleanRoot.appendingPathComponent("sessions/clean.jsonl"))
        let cleanReader = CodexLocalUsageReader(root: cleanRoot)
        let clean = cleanReader.scan(now: now, calendar: calendar)
        check(clean.days.first?.totalTokens == 6 && !clean.incomplete, "Context-size estimates and quota-only resends are not new consumption or damaged logs")
        try Data((context("known") + record("truncated", usage(1, 0, 1), "2026-10-27T05:03:00Z")).utf8)
            .write(to: cleanRoot.appendingPathComponent("sessions/clean.jsonl"))
        check(cleanReader.scan(now: now, calendar: calendar).days.first?.totalTokens == 2, "A truncated file resets its old offsets and contributions")
        try FileManager.default.createDirectory(at: cleanRoot.appendingPathComponent("archived_sessions"), withIntermediateDirectories: true)
        try Data((context("known") + record("archived", usage(8, 0, 2), "2026-10-27T05:04:00Z")).utf8)
            .write(to: cleanRoot.appendingPathComponent("archived_sessions/archive.jsonl"))
        check(cleanReader.scan(now: now, calendar: calendar).days.first?.totalTokens == 12, "Archived sessions contribute to the same local date")
        let userMessage = line("event_msg", ["type": "user_message", "message": String(repeating: "private-body", count: 100)])
        try Data(userMessage.dropLast(40).utf8).write(to: cleanRoot.appendingPathComponent("sessions/user-message.jsonl"))
        let privateTail = cleanReader.scan(now: now, calendar: calendar)
        check(privateTail.days.first?.totalTokens == 12 && !privateTail.incomplete, "An unfinished user_message is ignored rather than treated as incomplete usage")
        let states = Mirror(reflecting: cleanReader).children.first { $0.label == "files" }!.value
        let pendingSizes = Mirror(reflecting: states).children.map { item -> Int in
            let tuple = Array(Mirror(reflecting: item.value).children)
            let state = tuple[1].value
            return (Mirror(reflecting: state).children.first { $0.label == "pending" }?.value as? Data)?.count ?? 0
        }
        check(pendingSizes.allSatisfy { $0 == 0 }, "Conversation tails are not retained between scans")
        let delayedRoot = root.appendingPathComponent("delayed")
        try FileManager.default.createDirectory(at: delayedRoot.appendingPathComponent("sessions"), withIntermediateDirectories: true)
        let delayedFile = delayedRoot.appendingPathComponent("sessions/delayed.jsonl")
        let cumulative = usage(400, 100, 200)
        try Data((context("known") + record("delayed", small, "2026-10-27T05:00:00Z", cumulative: cumulative)
            + legacy(small, cumulative, "2026-10-27T05:00:20Z")).utf8).write(to: delayedFile)
        let delayedReader = CodexLocalUsageReader(root: delayedRoot)
        check(delayedReader.scan(now: now, calendar: calendar).days.first?.totalTokens == 6, "Delayed events pair by matching cumulative request identity, not a one-second timer")
        let delayedHandle = try FileHandle(forWritingTo: delayedFile); try delayedHandle.seekToEnd()
        try delayedHandle.write(contentsOf: Data((record("distinct", small, "2026-10-27T05:01:00Z", cumulative: usage(404, 101, 202))
            + legacy(small, usage(408, 102, 204), "2026-10-27T05:01:00.001Z")
            + record("future", usage(2, 0, 2), "2026-10-27T08:00:01Z")).utf8)); try delayedHandle.close()
        check(delayedReader.scan(now: now, calendar: calendar).days.first?.totalTokens == 12, "Adjacent paired forms can have different cumulative bases after inherited history or compaction")
        check(delayedReader.scan(now: now.addingTimeInterval(2), calendar: calendar).days.first?.totalTokens == 16, "Future samples wait for their timestamp and remain available without rewriting the file")
        let priorityRoot = root.appendingPathComponent("priority")
        try FileManager.default.createDirectory(at: priorityRoot.appendingPathComponent("sessions"), withIntermediateDirectories: true)
        try Data((context("known")
            + record("priority-a", small, "2026-10-27T05:00:00Z", cumulative: cumulative)
            + record("priority-b", small, "2026-10-27T05:00:01Z")
            + legacy(small, cumulative, "2026-10-27T05:00:02Z")
            + legacy(small, usage(404, 101, 202), "2026-10-27T05:00:03Z")).utf8)
            .write(to: priorityRoot.appendingPathComponent("sessions/priority.jsonl"))
        check(CodexLocalUsageReader(root: priorityRoot).scan(now: now, calendar: calendar).days.first?.totalTokens == 12,
              "Exact cumulative matches take priority over a newer record without cumulative metadata")
        try Data((context("known")
            + record("barrier-a", small, "2026-10-27T05:10:00Z")
            + record("barrier-b", usage(7, 1, 2), "2026-10-27T05:10:01Z")
            + legacy(small, cumulative, "2026-10-27T05:10:02Z")).utf8)
            .write(to: priorityRoot.appendingPathComponent("sessions/barrier.jsonl"))
        check(CodexLocalUsageReader(root: priorityRoot).scan(now: now, calendar: calendar).days.first?.totalTokens == 33,
              "Heuristic pairing cannot jump over another unpaired request with different usage")
        try Data((context("known") + record("segment", small, "2026-10-27T05:20:00Z")
            + line("session_meta", ["id": "separate-session"])
            + legacy(small, cumulative, "2026-10-27T05:20:01Z")).utf8)
            .write(to: priorityRoot.appendingPathComponent("sessions/segment.jsonl"))
        check(CodexLocalUsageReader(root: priorityRoot).scan(now: now, calendar: calendar).days.first?.totalTokens == 45,
              "Pairing remains inside a session metadata segment")
        try Data((context("known") + record("long-tool", small, "2026-10-27T05:30:00Z")
            + legacy(small, cumulative, "2026-10-27T05:32:00Z")).utf8)
            .write(to: priorityRoot.appendingPathComponent("sessions/long-tool.jsonl"))
        check(CodexLocalUsageReader(root: priorityRoot).scan(now: now, calendar: calendar).days.first?.totalTokens == 51,
              "Waiting for tools can delay the adjacent token_count by more than a minute")
        let bounded = CodexLocalUsageReader(root: root, estimateCost: { _, _, _, _ in nil }, readLimits: .init(fileBytes: 100, scanBytes: 180, lineBytes: 4096))
        var boundedResult = bounded.scan(now: now, calendar: calendar)
        check(boundedResult.incomplete, "Read budgets are explicit partial results")
        for _ in 0..<100 { boundedResult = bounded.scan(now: now, calendar: calendar) }
        check(boundedResult.days.last!.totalTokens == 217, "Budget-limited scans continue from saved offsets instead of rereading the same prefix")

        let historyRoot = root.appendingPathComponent("history")
        try FileManager.default.createDirectory(at: historyRoot.appendingPathComponent("sessions"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: historyRoot.appendingPathComponent("archived_sessions"), withIntermediateDirectories: true)
        func fullRecord(_ id: String, thread: String? = nil, conversation: String? = nil, turn: String? = nil,
                        stamp: String = "2026-10-27T06:00:00Z", tier: String? = nil) -> String {
            var payload: [String: Any] = ["response_id": id, "usage": sample]
            payload["thread_id"] = thread; payload["session_id"] = conversation
            payload["turn_id"] = turn; payload["service_tier"] = tier
            return line("token_usage_record", payload, stamp)
        }
        func historyFile(_ name: String, _ text: String) throws -> URL {
            let url = historyRoot.appendingPathComponent(name)
            try Data(text.utf8).write(to: url)
            return url
        }
        let parentMeta = line("session_meta", ["id": "root-thread", "session_id": "root-meta-chat", "cwd": "/projects/parent"])
        let parentContext = line("turn_context", ["turn_id": "parent-turn", "model": "known", "cwd": "/projects/parent-active", "service_tier": "priority"])
        let parentUsage = fullRecord("history-parent", thread: "root-thread", conversation: "explicit-parent-chat", turn: "parent-turn", tier: "flex")
        _ = try historyFile("sessions/z-parent.jsonl", parentMeta + parentContext + parentUsage)
        let childMeta = line("session_meta", ["id": "child-thread", "cwd": "/projects/child",
            "source": ["subagent": ["thread_spawn": ["parent_thread_id": "middle-thread"]]]])
        let childContext = line("turn_context", ["turn_id": "child-turn", "model": "child-model", "cwd": "/projects/child-active", "service_tier": "priority"])
        _ = try historyFile("sessions/a-child.jsonl", childMeta + parentMeta + parentContext + parentUsage + childContext
            + line("turn_context", ["turn_id": "other-turn", "model": "wrong-model", "cwd": "/projects/wrong", "service_tier": "flex"])
            + fullRecord("history-explicit", thread: "override-thread", conversation: "explicit-child-chat", turn: "child-turn")
            + fullRecord("history-child", thread: "child-thread", turn: "child-turn")
            + fullRecord("history-fallback", turn: "child-turn")
            + fullRecord("history-threadmeta", thread: "middle-thread", turn: "missing-turn"))
        _ = try historyFile("sessions/m-middle.jsonl", line("session_meta", ["id": "middle-thread", "parent_thread_id": "root-thread", "cwd": "/projects/middle"]))
        _ = try historyFile("sessions/manual-fork.jsonl", line("session_meta", ["id": "manual-fork", "forked_from_id": "root-thread", "cwd": "/projects/fork"])
            + context("known") + fullRecord("history-manual"))
        _ = try historyFile("sessions/orphan.jsonl", fullRecord("history-orphan", thread: "orphan-thread"))
        _ = try historyFile("sessions/unlabelled.jsonl", fullRecord("history-unlabelled"))
        _ = try historyFile("sessions/meta-session.jsonl", line("session_meta", ["id": "meta-thread", "session_id": "meta-chat"])
            + fullRecord("history-meta"))
        let oldFile = try historyFile("archived_sessions/old.jsonl", context("known")
            + fullRecord("history-old", stamp: "2026-10-19T06:00:00Z"))
        try FileManager.default.setAttributes([.modificationDate: MeterDate.parse("2026-10-19T06:01:00Z")!], ofItemAtPath: oldFile.path)
        let recentHistory = CodexLocalUsageReader(root: historyRoot).scan(now: now, calendar: calendar)
        check(!recentHistory.days.contains { $0.day == "2026-10-19" } && recentHistory.records.count == 9,
              "The default reader still excludes dates older than seven local days")
        let allReader = CodexLocalUsageReader(root: historyRoot, includeAllHistory: true, estimateCost: { model, _, _, tier in
            ["known", "child-model"].contains(model) ? (tier == "priority" ? 7 : 2) : nil
        })
        let allHistory = allReader.scan(now: now, calendar: calendar)
        check(allHistory.days.map(\.day) == ["2026-10-19", "2026-10-27"] && allHistory.records.count == 10,
              "All-history mode includes archived records and files with old modification dates")
        check(allHistory.scannedFileCount == 8 && allHistory.totalFileCount == 8 && !allHistory.incomplete,
              "File progress counts every discovered file that has been read to EOF")
        func historyRecord(_ id: String) -> UsageRecord { allHistory.records.first { $0.id == "response:\(id)" }! }
        let explicit = historyRecord("history-explicit")
        check(explicit.sessionID == "override-thread" && explicit.conversationID == "explicit-child-chat",
              "Record thread and session identifiers take priority over file metadata")
        check(explicit.projectPath == "/projects/child-active" && explicit.model == "child-model" && explicit.estimatedCostUSD == 7,
              "The matching turn supplies project, model and service tier even after another turn context")
        let original = historyRecord("history-parent")
        check(original.projectPath == "/projects/parent-active" && original.sessionID == "root-thread"
              && original.conversationID == "explicit-parent-chat" && original.estimatedCostUSD == 2,
              "Copied parent records are globally deduplicated and retain record-level pricing tier")
        let child = historyRecord("history-child")
        check(child.conversationID == "root-thread", "Subagent parents resolve recursively through metadata in other files")
        let fallback = historyRecord("history-fallback")
        check(fallback.sessionID == "child-thread" && fallback.conversationID == "root-thread",
              "The first child metadata remains the fallback identity after copied parent metadata")
        check(historyRecord("history-threadmeta").projectPath == "/projects/middle",
              "An unknown turn cannot borrow another turn's cwd ahead of the matching thread metadata")
        let manual = historyRecord("history-manual")
        check(manual.sessionID == "manual-fork" && manual.conversationID == "manual-fork" && manual.projectPath == "/projects/fork",
              "Manual forks stay independent and use their thread metadata project when no turn cwd exists")
        check(historyRecord("history-meta").conversationID == "meta-chat", "The first metadata session_id supplies a conversation fallback")
        let orphan = historyRecord("history-orphan")
        check(orphan.projectPath == nil && orphan.conversationID == "orphan-thread" && orphan.estimatedCostUSD == nil,
              "Missing projects and unknown prices remain unknown")
        let anonymous = historyRecord("history-unlabelled")
        check(!anonymous.sessionID.isEmpty && anonymous.sessionID == anonymous.conversationID,
              "Metadata-free files receive a stable nonempty session identity")
        check(allHistory.days.reduce(Int64(0)) { $0 + $1.totalTokens } == allHistory.records.reduce(Int64(0)) { $0 + $1.tokens.total },
              "Deduplicated response records and daily history have identical token totals")
        check(allReader.scan(now: now, calendar: calendar).records.map(\.id) == allHistory.records.map(\.id),
              "Repeated all-history scans retain stable record order and identities")
        let allBounded = CodexLocalUsageReader(root: historyRoot, estimateCost: { _, _, _, _ in nil },
            readLimits: .init(fileBytes: 80, scanBytes: 120, lineBytes: 4096), includeAllHistory: true)
        var allPartial = allBounded.scan(now: now, calendar: calendar)
        check(allPartial.incomplete && allPartial.scannedFileCount < allPartial.totalFileCount && allPartial.totalFileCount == 8,
              "All-history scans expose unfinished file progress when a read budget is exhausted")
        var progressNeverDecreased = true
        for _ in 0..<200 {
            let previous = allPartial.scannedFileCount
            allPartial = allBounded.scan(now: now, calendar: calendar)
            progressNeverDecreased = progressNeverDecreased && allPartial.scannedFileCount >= previous
        }
        check(progressNeverDecreased && allPartial.scannedFileCount == allPartial.totalFileCount
              && !allPartial.incomplete && allPartial.records.count == 10,
              "Budget-limited all-history scans continue across batches until every file reaches EOF")
        let modelFallbackRoot = root.appendingPathComponent("model-fallback")
        try FileManager.default.createDirectory(at: modelFallbackRoot.appendingPathComponent("sessions"), withIntermediateDirectories: true)
        let missingContext = fullRecord("missing-context", thread: "primary-thread")
        try Data((line("session_meta", ["id": "primary-thread", "cwd": "/projects/primary"]) + missingContext).utf8)
            .write(to: modelFallbackRoot.appendingPathComponent("sessions/primary.jsonl"))
        try Data((line("session_meta", ["id": "copy-thread", "cwd": "/projects/copy"]) + context("known") + missingContext).utf8)
            .write(to: modelFallbackRoot.appendingPathComponent("sessions/copy.jsonl"))
        let modelFallback = CodexLocalUsageReader(root: modelFallbackRoot).scan(now: now, calendar: calendar)
        check(modelFallback.records.count == 1 && modelFallback.records[0].model == "known"
              && modelFallback.records[0].projectPath == "/projects/primary",
              "Response deduplication can recover a known model from a copy while preserving the owning thread's project")
        let byteProgressRoot = root.appendingPathComponent("byte-progress")
        try FileManager.default.createDirectory(at: byteProgressRoot.appendingPathComponent("sessions"), withIntermediateDirectories: true)
        let conversationPrefix = line("response_item", ["type": "message", "content": String(repeating: "private-body", count: 120)])
        let byteProgressLog = conversationPrefix + fullRecord("after-long-prefix")
        try Data(byteProgressLog.utf8).write(to: byteProgressRoot.appendingPathComponent("sessions/prefix.jsonl"))
        let byteProgressReader = CodexLocalUsageReader(root: byteProgressRoot, estimateCost: { _, _, _, _ in nil },
            readLimits: .init(fileBytes: 64, scanBytes: 64, lineBytes: 4096), includeAllHistory: true)
        let firstBytes = byteProgressReader.scan(now: now, calendar: calendar)
        let secondBytes = byteProgressReader.scan(now: now, calendar: calendar)
        var byteProgress = byteProgressReader.scan(now: now, calendar: calendar)
        check(firstBytes.records.isEmpty && secondBytes.records.isEmpty && byteProgress.records.isEmpty
              && byteProgress.scannedFileCount == 0 && firstBytes.readBytes == 64
              && secondBytes.readBytes == 128 && byteProgress.readBytes == 192,
              "Consumed byte progress increases through multiple batches without usage records or completed files")
        let byteStates = Mirror(reflecting: byteProgressReader).children.first { $0.label == "files" }!.value
        let privateBytesRetained = Mirror(reflecting: byteStates).children.contains { item in
            let state = Array(Mirror(reflecting: item.value).children)[1].value
            return ((Mirror(reflecting: state).children.first { $0.label == "pending" }?.value as? Data)?.count ?? 0) > 0
        }
        check(!privateBytesRetained, "Discarded conversation continuations are not cached by small-budget scans")
        for _ in 0..<100 where byteProgress.scannedFileCount < byteProgress.totalFileCount {
            byteProgress = byteProgressReader.scan(now: now, calendar: calendar)
        }
        check(byteProgress.records.count == 1 && !byteProgress.incomplete && byteProgress.readBytes == UInt64(byteProgressLog.utf8.count),
              "Byte progress reaches the consumed file length after the long prefix")
        check(byteProgressReader.scan(now: now, calendar: calendar).readBytes == byteProgress.readBytes && missing.readBytes == 0,
              "Unchanged scans and missing files do not invent consumed bytes")
        print("Codex local logs: \(checks) checks passed")
    }
}
