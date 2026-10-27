import Foundation

@main
enum GrokBotSmoke {
    static func main() throws {
        if let index = CommandLine.arguments.firstIndex(of: "--fake-keychain") {
            switch CommandLine.arguments[index + 1] {
            case "success":
                try FileHandle.standardOutput.write(contentsOf: Data("synthetic-password\n".utf8))
                exit(0)
            case "failure":
                try FileHandle.standardError.write(contentsOf: Data(repeating: 120, count: 262144))
                exit(23)
            default: Thread.sleep(forTimeInterval: 20); exit(0)
            }
        }
        let now = Date(timeIntervalSince1970: 1_793_000_000)
        let reset = "2026-10-29T11:22:16.814Z"
        let zero = GrokBotSource.parse([
            "usagePercent": 0,
            "nextResetTimestampUtc": reset,
            "hasNonZeroIncludedLimit": true,
            "isUnified": true,
            "cursorPlanName": "Free",
            "grokPlanLabel": "Grok Bot Plan"
        ], now: now)
        try check(zero.provider == .grokBot, "Quota must belong to Grok Bot")
        try check(zero.windows.count == 1 && zero.windows[0].remaining == 100,
                  "A confirmed zero is valid usage, not a missing value")
        try check(zero.windows[0].title == "每周", "Bot quota uses a weekly window")
        try check(zero.windows[0].resetsAt == MeterDate.parse(reset),
                  "The official protobuf JSON timestamp must preserve fractional seconds")
        try check(zero.updatedAt == now && zero.quotaReadFailed != true,
                  "A successful read records its capture time")
        try check(zero.plan == "Free" && zero.sourceNote.contains("共享"),
                  "Unified plans must use the backend plan and explain the shared allowance")
        try check(zero.days.isEmpty, "Quota must not invent token or cost history")

        let legacy = GrokBotSource.parse([
            "usagePercent": 37.5, "grokPlanLabel": "SuperGrok Plus", "cursorPlanName": "Pro",
            "nextResetTimestampUtc": "2026-10-29T11:22:16Z"
        ], now: now)
        try check(legacy.windows.first?.remaining == 62.5 && legacy.plan == "SuperGrok Plus",
                  "Legacy Bot quota must use its own grant label")
        try check(!legacy.sourceNote.contains("共享"), "Legacy grants must not be labeled as a unified pool")
        let fallback = GrokBotSource.parse(["usagePercent": 10, "isUnified": true,
                                           "cursorPlanName": "  ", "grokPlanLabel": "Grok Bot Plan"])
        try check(fallback.plan == "Grok Bot Plan", "A blank backend plan must use the official label")
        let unnamed = GrokBotSource.parse(["usagePercent": 10])
        try check(unnamed.plan == nil && unnamed.windows.first?.resetsAt == nil,
                  "Missing plan and reset must stay unknown")
        let invalidReset = GrokBotSource.parse(["usagePercent": 10, "nextResetTimestampUtc": "invalid"])
        try check(invalidReset.windows.first?.resetsAt == nil,
                  "An invalid reset must never turn into a synthetic countdown")
        let overshoot = GrokBotSource.parse(["usagePercent": 105])
        try check(overshoot.windows.first?.remaining == 0, "A backend usage overshoot has no remaining quota")

        let badValues: [Any] = [NSNull(), true, "0", -1, Double.nan, Double.infinity]
        for value in badValues {
            let failed = GrokBotSource.parse(["usagePercent": value], now: now)
            try check(failed.provider == .grokBot && failed.windows.isEmpty
                      && failed.quotaReadFailed == true && failed.updatedAt == nil,
                      "Absent or malformed quota must never become zero usage")
        }
        let missing = GrokBotSource.parse([:])
        try check(missing.quotaReadFailed == true && missing.windows.isEmpty,
                  "A missing usage percentage is a failed quota read")
        let pooled = GrokBotSource.parse(["usagePercent": 0, "usesPooledEnterpriseAllowance": true], now: now)
        try check(pooled.quotaReadFailed != true && pooled.windows.isEmpty && pooled.updatedAt == now
                  && pooled.message?.contains("团队") == true,
                  "A known enterprise pool is a successful unsupported state, not a transient read failure")
        for field in ["hasNonZeroIncludedLimit", "hasAvailableUsage"] {
            let unavailable = GrokBotSource.parse(["usagePercent": 0, field: false], now: now)
            try check(unavailable.windows.isEmpty && unavailable.quotaReadFailed != true && unavailable.updatedAt == now,
                      "A backend account without an allowance must not imply 100 percent remaining")
        }
        let freshTime = now.addingTimeInterval(60)
        for state: [String: Any] in [
            ["usagePercent": 0, "usesPooledEnterpriseAllowance": true],
            ["usagePercent": 0, "hasNonZeroIncludedLimit": false],
            ["hasNonZeroIncludedLimit": false],
            ["usagePercent": 0, "hasAvailableUsage": false]
        ] {
            let unsupported = GrokBotSource.parse(state, now: freshTime)
            let merged = SnapshotMerge.preservingFailures(unsupported, previous: zero)
            try check(merged.windows.isEmpty && merged.updatedAt == freshTime,
                      "A successful no-allowance state must clear a previous full quota after merge")
        }
        let transient = SnapshotMerge.preservingFailures(missing, previous: zero)
        try check(transient.windows == zero.windows && transient.updatedAt == zero.updatedAt,
                  "A malformed transient quota response must still preserve the last valid reading")
        let exhausted = GrokBotSource.parse(["usagePercent": 100, "hasNonZeroIncludedLimit": true,
                                             "hasAvailableUsage": false])
        try check(exhausted.windows.first?.remaining == 0 && exhausted.quotaReadFailed != true,
                  "An exhausted known allowance still has a valid zero remaining result")

        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let signedOut = GrokBotSource.load(home: home)
        try check(signedOut.provider == .grokBot && signedOut.windows.isEmpty
                  && signedOut.quotaReadFailed == true && signedOut.message?.contains("登录") == true,
                  "A missing login must fail locally without touching real credentials or the network")

        func fakeProcess(_ mode: String) -> Process {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
            process.arguments = ["--fake-keychain", mode]
            return process
        }
        let output = try GrokBotBoundedProcess.read(fakeProcess("success"), timeout: 2)
        try check(output == Data("synthetic-password\n".utf8), "Read the complete bounded child output before returning")
        var rejected = false
        do { _ = try GrokBotBoundedProcess.read(fakeProcess("failure"), timeout: 2) }
        catch { rejected = true }
        try check(rejected, "A failed keychain tool must not become a usable password or hang on stderr")
        let hung = fakeProcess("timeout")
        let started = Date()
        var timedOut = false
        do { _ = try GrokBotBoundedProcess.read(hung, timeout: 0.2) }
        catch { timedOut = true }
        try check(timedOut && Date().timeIntervalSince(started) < 2 && !hung.isRunning,
                  "An unresponsive keychain process must time out and be cleaned up")
        print("Grok Bot parser checks passed")
    }

    private static func check(_ passed: Bool, _ message: String) throws {
        if !passed { throw NSError(domain: "GrokBotSmoke", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    }
}
