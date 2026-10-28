import Foundation

@main
struct ClaudeDesktopHistorySmoke {
    static func main() throws {
        var checks = 0
        func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
            precondition(condition(), message)
            checks += 1
        }
        let manager = FileManager.default
        let home = manager.temporaryDirectory.appendingPathComponent("ClaudeDesktopHistory-\(UUID().uuidString)")
        try manager.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: home) }
        let desktop = home.appendingPathComponent("Library/Application Support/Claude")
        let code = desktop.appendingPathComponent("claude-code-sessions/account/session/.claude/projects")
        let cowork = desktop.appendingPathComponent("local-agent-mode-sessions/account/session/.claude/projects")
        let cli = home.appendingPathComponent(".claude/projects")
        expect(ClaudeDesktopProjects.roots(home: home).isEmpty, "Missing desktop data is empty, not a fabricated usage source")
        for root in [code, cowork, cli] { try manager.createDirectory(at: root, withIntermediateDirectories: true) }
        expect(Set(ClaudeDesktopProjects.roots(home: home).map(\.path)) == Set([code.path, cowork.path]),
               "Only real desktop Code and Cowork projects directories are discovered")

        let ignored = desktop.appendingPathComponent("local-agent-mode-sessions/account/session/plugins/plugin/.claude/projects")
        try manager.createDirectory(at: ignored, withIntermediateDirectories: true)
        let external = home.appendingPathComponent("outside/.claude/projects")
        try manager.createDirectory(at: external, withIntermediateDirectories: true)
        let linked = desktop.appendingPathComponent("claude-code-sessions/linked")
        try manager.createSymbolicLink(at: linked, withDestinationURL: home.appendingPathComponent("outside"))
        let linkedClaude = desktop.appendingPathComponent("local-agent-mode-sessions/account/linked-claude")
        try manager.createDirectory(at: linkedClaude, withIntermediateDirectories: true)
        try manager.createSymbolicLink(at: linkedClaude.appendingPathComponent(".claude"), withDestinationURL: home.appendingPathComponent("outside/.claude"))
        expect(Set(ClaudeDesktopProjects.roots(home: home).map(\.path)) == Set([code.path, cowork.path]),
               "Plugin payloads and linked directories must not extend the scan outside real session roots")
        let deep = desktop.appendingPathComponent("claude-code-sessions/a/b/c/d/e/f/g/h/i/.claude/projects")
        try manager.createDirectory(at: deep, withIntermediateDirectories: true)
        expect(ClaudeDesktopProjects.roots(home: home).count == 2, "Discovery is depth-bounded")

        let now = MeterDate.parse("2026-10-27T12:00:00Z")!
        func line(id: String, output: Int = 20, project: String = "/work/project") throws -> Data {
            let object: [String: Any] = ["type": "assistant", "timestamp": "2026-10-27T10:00:00Z",
                "sessionId": "same-session", "cwd": project,
                "message": ["id": id, "model": "claude-sonnet-4-6", "usage": ["input_tokens": 100, "output_tokens": output]]]
            var data = try JSONSerialization.data(withJSONObject: object)
            data.append(10)
            return data
        }
        try line(id: "same-message", output: 10).write(to: cli.appendingPathComponent("session.jsonl"))
        try line(id: "same-message").write(to: code.appendingPathComponent("session.jsonl"))
        try line(id: "cowork-message", project: "/work/cowork").write(to: cowork.appendingPathComponent("session.jsonl"))
        let roots = [cli] + ClaudeDesktopProjects.roots(home: home)
        let reader = ClaudeUsageHistoryReader(roots: roots + [code])
        var result = reader.scan(now: now)
        expect(result.records.count == 2 && result.records.reduce(Int64(0)) { $0 + $1.tokens.total } == 240,
               "The same session/message copied across roots is billed once using its final usage")
        expect(result.totalFileCount == 3 && result.scannedFileCount == 3 && !result.incomplete,
               "Repeated roots do not inflate file progress")
        expect(Set(result.records.compactMap(\.projectPath)) == ["/work/project", "/work/cowork"],
               "Desktop usage retains real project paths")
        result = reader.scan(now: now)
        expect(result.records.count == 2 && result.records.reduce(Int64(0)) { $0 + $1.tokens.total } == 240,
               "An unchanged multi-root scan remains stable")
        let missing = ClaudeUsageHistoryReader(roots: [home.appendingPathComponent("missing")]).scan(now: now)
        expect(missing.records.isEmpty && !missing.incomplete && missing.totalFileCount == 0,
               "Absent optional roots do not mark history as damaged")
        try line(id: "external").write(to: external.appendingPathComponent("external.jsonl"))
        let linkFile = code.appendingPathComponent("linked-file.jsonl")
        try manager.createSymbolicLink(at: linkFile, withDestinationURL: external.appendingPathComponent("external.jsonl"))
        try manager.createSymbolicLink(at: code.appendingPathComponent("linked-folder"), withDestinationURL: external)
        let links = ClaudeUsageHistoryReader(roots: [code, linked]).scan(now: now)
        expect(links.records.count == 1 && links.totalFileCount == 1,
               "History never follows symlinked files, descendants or supplied roots")

        let dynamic = ClaudeUsageHistoryReader(roots: [cli])
        expect(dynamic.scan(now: now).records.count == 1, "A reader starts with the configured roots only")
        dynamic.updateRoots(roots)
        expect(dynamic.scan(now: now).records.count == 2, "New desktop session roots appear without restarting the reader")
        dynamic.updateRoots([cli, code])
        let removed = dynamic.scan(now: now)
        expect(removed.records.count == 1 && removed.records.allSatisfy { $0.projectPath != "/work/cowork" },
               "Removing a root cannot leave its cached records visible")
        dynamic.updateRoots([code])
        expect(dynamic.scan(now: now).records.first?.tokens.output == 20,
               "Surviving roots retain their final usage when another root is removed")

        let later = desktop.appendingPathComponent("claude-code-sessions/account/new-session/.claude/projects")
        try manager.createDirectory(at: later, withIntermediateDirectories: true)
        try line(id: "new-desktop-session").write(to: later.appendingPathComponent("later.jsonl"))
        dynamic.updateRoots([cli] + ClaudeDesktopProjects.roots(home: home))
        expect(dynamic.scan(now: now).records.count == 3,
               "Rediscovery includes a desktop session created after the first scan")
        try manager.removeItem(at: later)
        dynamic.updateRoots([cli] + ClaudeDesktopProjects.roots(home: home))
        expect(dynamic.scan(now: now).records.count == 2,
               "Rediscovery removes deleted desktop sessions without retaining their cached usage")

        func requestLine(snakeCase: Bool, output: Int) throws -> Data {
            var object = try JSONSerialization.jsonObject(with: line(id: "placeholder", output: output)) as! [String: Any]
            var message = object["message"] as! [String: Any]
            message.removeValue(forKey: "id")
            object["message"] = message
            object.removeValue(forKey: "sessionId")
            object[snakeCase ? "session_id" : "sessionId"] = "request-session"
            object[snakeCase ? "request_id" : "requestId"] = "same-request"
            var data = try JSONSerialization.data(withJSONObject: object)
            data.append(10)
            return data
        }
        let aliasRoot = home.appendingPathComponent("aliases")
        try manager.createDirectory(at: aliasRoot, withIntermediateDirectories: true)
        try requestLine(snakeCase: false, output: 10).write(to: aliasRoot.appendingPathComponent("camel.jsonl"))
        try requestLine(snakeCase: true, output: 30).write(to: aliasRoot.appendingPathComponent("snake.jsonl"))
        let aliases = ClaudeUsageHistoryReader(roots: [aliasRoot]).scan(now: now)
        expect(aliases.records.count == 1 && aliases.records.first?.tokens.total == 130,
               "Desktop snake_case session and request identifiers deduplicate against CLI camelCase identifiers")
        expect(aliases.records.first?.sessionID == "request-session" && !aliases.incomplete,
               "Desktop session identifier aliases retain stable session attribution")
        print("Claude desktop history: \(checks) checks passed")
    }
}
