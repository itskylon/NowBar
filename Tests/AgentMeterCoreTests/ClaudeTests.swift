import XCTest
@testable import AgentMeterCore

final class ClaudeTests: XCTestCase {
    func testBridgeKeepsIndependentWindowsAndDoesNotRestoreExpiredLimits() throws {
        let data = Data(#"{"updated_at":"2020-01-01T00:00:00Z","rate_limits":{"five_hour":{"used_percentage":100,"resets_at":1600000000},"seven_day":{"used_percentage":20,"resets_at":1900000000}}}"#.utf8)
        let result = try ClaudeSource.parseBridge(data, now: Date(timeIntervalSince1970: 1800000000))
        XCTAssertEqual(result.windows.count, 2)
        XCTAssertEqual(result.windows.first?.remaining, 0)
        XCTAssertTrue(result.windows.first!.expired(at: Date(timeIntervalSince1970: 1800000000)))
        XCTAssertEqual(result.windows.last?.remaining, 80)
    }

    func testMissingLimitsDoesNotCreateZeroUsage() throws {
        let result = try ClaudeSource.parseBridge(Data(#"{"updated_at":"2027-01-15T08:00:00Z","rate_limits":{}}"#.utf8))
        XCTAssertTrue(result.windows.isEmpty)
    }
}
