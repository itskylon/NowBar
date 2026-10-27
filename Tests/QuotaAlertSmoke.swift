import Foundation

@main
enum QuotaAlertSmoke {
    static let origin = Date(timeIntervalSince1970: 1_800_000_000)
    static var checks = 0

    static func main() throws {
        var tracker = QuotaAlertTracker()
        let first = tracker.evaluate([sample(used: 85)], lowEnabled: true, resetEnabled: true, now: origin)
        try check(first.count == 1 && first[0].kind == .low && first[0].body.contains("15%"), "A first reported low value must notify")
        try check(!first[0].identifier.isEmpty && first[0].title.contains("Codex"), "Notifications need a stable identity and service name")
        tracker = try JSONDecoder().decode(QuotaAlertTracker.self, from: JSONEncoder().encode(tracker))
        try check(tracker.evaluate([sample(used: 86, at: 30)], lowEnabled: true, resetEnabled: true, now: time(30)).isEmpty, "Restart must preserve threshold deduplication")

        var thresholds = QuotaAlertTracker()
        let expectedCounts = [0, 1, 0, 0, 1, 0, 1, 0, 0]
        for (index, used) in [79.0, 80, 79, 81, 90, 91, 100, 99, 100].enumerated() {
            let offset = Double(index * 10)
            let events = thresholds.evaluate([sample(used: used, at: offset)], lowEnabled: true, resetEnabled: true, now: time(offset))
            try check(events.count == expectedCounts[index], "20/10/0 thresholds must each fire once despite oscillation")
        }

        var jump = QuotaAlertTracker()
        let severe = jump.evaluate([sample(used: 95)], lowEnabled: true, resetEnabled: false, now: origin)
        try check(severe.count == 1 && severe[0].body.contains("5%"), "A threshold jump must emit only the current most severe alert")
        try check(jump.evaluate([sample(used: 85, at: 10)], lowEnabled: true, resetEnabled: false, now: time(10)).isEmpty, "A jump must also consume the skipped 20 percent threshold")
        try check(jump.evaluate([sample(used: 100, at: 20)], lowEnabled: true, resetEnabled: false, now: time(20)).count == 1, "Exhaustion remains a separate threshold")

        var switches = QuotaAlertTracker()
        try check(switches.evaluate([sample(used: 95)], lowEnabled: false, resetEnabled: false, now: origin).isEmpty, "Disabled reminders still accept baseline samples without sending")
        try check(switches.evaluate([sample(used: 95)], lowEnabled: true, resetEnabled: false, now: time(10)).isEmpty, "Enabling a reminder must not replay an identical sample")
        try check(switches.evaluate([sample(used: 95, at: 20)], lowEnabled: true, resetEnabled: false, now: time(20)).count == 1, "A fresh low sample after enabling should notify once")
        _ = switches.evaluate([sample(used: 100, at: 30)], lowEnabled: false, resetEnabled: false, now: time(30))
        try check(switches.evaluate([sample(used: 100, at: 40)], lowEnabled: true, resetEnabled: false, now: time(40)).count == 1, "A disabled threshold must remain available when reenabled")

        var reset = QuotaAlertTracker()
        _ = reset.evaluate([sample(used: 95, reset: 60)], lowEnabled: false, resetEnabled: true, now: origin)
        try check(reset.evaluate([], lowEnabled: false, resetEnabled: true, now: time(61)).isEmpty, "A countdown reaching zero cannot prove a reset")
        let resetEvents = reset.evaluate([sample(used: 5, at: 61, reset: 604_860)], lowEnabled: false, resetEnabled: true, now: time(61))
        try check(resetEvents.count == 1 && resetEvents[0].kind == .reset && resetEvents[0].body.contains("95%"), "A later reset plus a clear usage fall confirms a reset")
        reset = try JSONDecoder().decode(QuotaAlertTracker.self, from: JSONEncoder().encode(reset))
        try check(reset.evaluate([sample(used: 5, at: 62, reset: 604_860)], lowEnabled: false, resetEnabled: true, now: time(62)).isEmpty, "Confirmed reset must not repeat after restart")

        var combined = QuotaAlertTracker()
        _ = combined.evaluate([sample(used: 100, reset: 60)], lowEnabled: true, resetEnabled: true, now: origin)
        let combinedEvents = combined.evaluate([sample(used: 90, at: 61, reset: 604_860)], lowEnabled: true, resetEnabled: true, now: time(61))
        try check(combinedEvents.count == 1 && combinedEvents[0].kind == .reset, "A confirmed reset must take priority over a simultaneous low alert")
        combined = try JSONDecoder().decode(QuotaAlertTracker.self, from: JSONEncoder().encode(combined))
        try check(combined.evaluate([sample(used: 90, at: 61, reset: 604_860)], lowEnabled: true, resetEnabled: true, now: time(62)).isEmpty, "A deferred low alert still requires a newer sample")
        let deferred = combined.evaluate([sample(used: 90, at: 62, reset: 604_860)], lowEnabled: true, resetEnabled: true, now: time(62))
        try check(deferred.count == 1 && deferred[0].kind == .low, "The next fresh sample must emit the unconsumed low threshold without repeating reset")
        try check(combined.evaluate([sample(used: 90, at: 63, reset: 604_860)], lowEnabled: true, resetEnabled: true, now: time(63)).isEmpty, "The delivered deferred low alert must remain deduplicated")
        var resetDisabled = QuotaAlertTracker()
        _ = resetDisabled.evaluate([sample(used: 100, reset: 60)], lowEnabled: true, resetEnabled: false, now: origin)
        let lowOnly = resetDisabled.evaluate([sample(used: 90, at: 61, reset: 604_860)], lowEnabled: true, resetEnabled: false, now: time(61))
        try check(lowOnly.count == 1 && lowOnly[0].kind == .low, "A disabled reset reminder must not defer an enabled low alert")

        var noDrop = QuotaAlertTracker()
        let oldLow = noDrop.evaluate([sample(used: 95, reset: 60)], lowEnabled: true, resetEnabled: true, now: origin)
        let nextLow = noDrop.evaluate([sample(used: 94, at: 61, reset: 604_860)], lowEnabled: true, resetEnabled: true, now: time(61))
        try check(nextLow.count == 1 && nextLow[0].kind == .low && nextLow[0].identifier != oldLow[0].identifier, "A new period has independent low thresholds but a tiny fall cannot prove reset")

        var premature = QuotaAlertTracker()
        _ = premature.evaluate([sample(used: 95, reset: 60)], lowEnabled: false, resetEnabled: true, now: origin)
        try check(premature.evaluate([sample(used: 0, at: 30, reset: 604_860)], lowEnabled: false, resetEnabled: true, now: time(61)).isEmpty, "A sample observed before the old deadline cannot confirm a reset")
        var noReset = QuotaAlertTracker()
        _ = noReset.evaluate([sample(used: 95, reset: nil)], lowEnabled: false, resetEnabled: true, now: origin)
        try check(noReset.evaluate([sample(used: 0, at: 61, reset: nil)], lowEnabled: false, resetEnabled: true, now: time(61)).isEmpty, "Missing reset timestamps must never invent a reset")
        try check(noReset.evaluate([sample(used: 0, at: 62, reset: 600)], lowEnabled: false, resetEnabled: true, now: time(62)).isEmpty, "A first known reset is baseline only")

        var failed = QuotaAlertTracker()
        _ = failed.evaluate([sample(used: 95, reset: 60)], lowEnabled: false, resetEnabled: true, now: origin)
        var broken = sample(used: 0, at: 61, reset: 604_860)
        broken.quotaReadFailed = true
        try check(failed.evaluate([broken], lowEnabled: false, resetEnabled: true, now: time(61)).isEmpty, "Failed quota reads must not notify")
        try check(failed.evaluate([sample(used: 5, at: 62, reset: 604_860)], lowEnabled: false, resetEnabled: true, now: time(62)).first?.kind == .reset, "Failed samples must not overwrite the valid reset baseline")

        var stale = QuotaAlertTracker()
        try check(stale.evaluate([sample(used: 100, reset: 900)], lowEnabled: true, resetEnabled: true, now: time(301)).isEmpty, "A sample older than five minutes is stale")
        var absent = sample(used: 100, reset: 900)
        absent.updatedAt = nil
        try check(stale.evaluate([absent], lowEnabled: true, resetEnabled: true, now: time(301)).isEmpty, "Unknown capture time cannot notify")
        try check(stale.evaluate([sample(used: 90, at: 301, reset: 900)], lowEnabled: true, resetEnabled: true, now: time(301)).count == 1, "Rejected samples must not consume the threshold")

        for badUsed in [-1.0, 101, Double.nan, Double.infinity] {
            var invalid = QuotaAlertTracker()
            try check(invalid.evaluate([sample(used: badUsed)], lowEnabled: true, resetEnabled: true, now: origin).isEmpty, "Invalid percentages must not notify")
            try check(invalid.evaluate([sample(used: 90)], lowEnabled: true, resetEnabled: true, now: origin).count == 1, "An invalid percentage must not advance sample time")
        }
        var future = QuotaAlertTracker()
        try check(future.evaluate([sample(used: 100, at: 61)], lowEnabled: true, resetEnabled: true, now: origin).isEmpty, "A timestamp over a minute into the future is invalid")
        try check(future.evaluate([sample(used: 90, at: 60)], lowEnabled: true, resetEnabled: true, now: origin).count == 1, "One minute of clock skew is allowed")
        var expired = QuotaAlertTracker()
        try check(expired.evaluate([sample(used: 100, reset: 0)], lowEnabled: true, resetEnabled: true, now: origin).isEmpty, "Expired windows cannot notify")
        try check(expired.evaluate([sample(used: 90)], lowEnabled: true, resetEnabled: true, now: origin).count == 1, "Expired windows must not consume valid future thresholds")

        var ordered = QuotaAlertTracker()
        _ = ordered.evaluate([sample(used: 85)], lowEnabled: true, resetEnabled: true, now: origin)
        try check(ordered.evaluate([sample(used: 100)], lowEnabled: true, resetEnabled: true, now: time(1)).isEmpty, "Duplicate timestamps cannot consume further thresholds")
        try check(ordered.evaluate([sample(used: 100, at: -1)], lowEnabled: true, resetEnabled: true, now: time(1)).isEmpty, "Out of order samples cannot overwrite baseline")
        try check(ordered.evaluate([sample(used: 90, at: 1)], lowEnabled: true, resetEnabled: true, now: time(1)).count == 1, "A later real threshold must still notify")

        var separate = QuotaAlertTracker()
        let multiple = separate.evaluate([sample(used: 90), sample(provider: .grokBot, used: 90)], lowEnabled: true, resetEnabled: true, now: origin)
        try check(multiple.count == 2 && Set(multiple.map(\.identifier)).count == 2, "Identical window names on different services must remain independent")
        var huge = QuotaAlertTracker()
        var many = sample(used: 50)
        many.windows = (0..<1000).map { .init(id: "window-\($0)", title: "窗口", usedPercent: 50, resetsAt: time(900)) }
        _ = huge.evaluate([many], lowEnabled: false, resetEnabled: false, now: origin)
        try check(try JSONEncoder().encode(huge).count < 50_000, "Persistent tracking must remain bounded even if upstream window identifiers change")
        print("Quota alerts: \(checks) checks passed")
    }

    static func sample(provider: ProviderID = .codex, used: Double, at offset: Double = 0, reset: Double? = 900) -> ProviderSnapshot {
        .init(provider: provider, windows: [.init(id: "weekly", title: "每周", usedPercent: used, resetsAt: reset.map(time))], updatedAt: time(offset))
    }
    static func time(_ offset: Double) -> Date { origin.addingTimeInterval(offset) }
    static func check(_ value: Bool, _ message: String) throws {
        checks += 1
        if !value { throw NSError(domain: "QuotaAlertSmoke", code: checks, userInfo: [NSLocalizedDescriptionKey: message]) }
    }
}
