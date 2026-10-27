import XCTest
@testable import AgentMeterCore

final class CodexTests: XCTestCase {
    func testMultiBucketPrefersCodexAndDoesNotDuplicateLegacySnapshot() throws {
        let snapshot = try CodexSource.parse(rateLimits: [
            "rateLimits": ["primary": ["usedPercent": 99]],
            "rateLimitsByLimitId": [
                "codex": ["planType": "plus", "primary": ["usedPercent": 25, "windowDurationMins": 300]],
                "other": ["primary": ["usedPercent": 80]]
            ]
        ], usage: nil)
        XCTAssertEqual(snapshot.windows.count, 1)
        XCTAssertEqual(snapshot.windows.first?.remaining, 75)
        XCTAssertEqual(snapshot.windows.first?.title, "5 小时")
        XCTAssertEqual(snapshot.plan, "plus")
    }

    func testOtherBucketsStayDistinctAndMissingWindowsAreUnknown() throws {
        let snapshot = try CodexSource.parse(rateLimits: ["rateLimitsByLimitId": [
            "model-a": ["limitName": "Model A", "primary": ["usedPercent": 35, "windowDurationMins": 10080]],
            "model-b": ["limitName": "Model B", "secondary": ["usedPercent": 60]],
            "missing": ["primary": ["usedPercent": NSNull()]]
        ]], usage: ["dailyUsageBuckets": NSNull()])
        XCTAssertEqual(snapshot.windows.count, 2)
        XCTAssertEqual(Set(snapshot.windows.map(\.id)).count, 2)
        XCTAssertTrue(snapshot.windows[0].title.contains("Model A"))
        XCTAssertTrue(snapshot.windows[1].title.contains("Model B"))
        XCTAssertTrue(snapshot.days.isEmpty)
        XCTAssertNotNil(snapshot.message)
        XCTAssertEqual(snapshot.historyReadFailed, true)
    }

    func testDailyBucketsKeepServerDateAndDoNotInventPrices() throws {
        let snapshot = try CodexSource.parse(rateLimits: ["rateLimits": [:]], usage: [
            "dailyUsageBuckets": [
                ["startDate": "2026-10-27", "tokens": 1234],
                ["startDate": "2026-10-26", "tokens": NSNull()],
                ["startDate": "2026-10-25", "tokens": 0]
            ]
        ])
        XCTAssertEqual(snapshot.days.map(\.day), ["2026-10-25", "2026-10-27"])
        XCTAssertEqual(snapshot.days.last?.totalTokens, 1234)
        XCTAssertNil(snapshot.days.last?.estimatedCostUSD)
        XCTAssertNil(snapshot.days.last?.tokens)
        XCTAssertTrue(snapshot.sourceNote.contains("服务端日期"))
        XCTAssertNotEqual(snapshot.historyReadFailed, true)
    }

    func testMalformedTokenCountsDoNotTurnIntoValidUsage() throws {
        let snapshot = try CodexSource.parse(rateLimits: ["rateLimits": [:]], usage: ["dailyUsageBuckets": [
            ["startDate": "2026-10-27", "tokens": 1.5],
            ["startDate": "2026-10-27", "tokens": true],
            ["startDate": "2026-02-30", "tokens": 10]
        ]])
        XCTAssertTrue(snapshot.days.isEmpty)
    }

    func testSuccessfulEmptyHistoryIsNotAReadFailure() throws {
        let snapshot = try CodexSource.parse(rateLimits: ["rateLimits": [:]], usage: ["dailyUsageBuckets": []])
        XCTAssertTrue(snapshot.days.isEmpty)
        XCTAssertNotEqual(snapshot.historyReadFailed, true)
    }
}
