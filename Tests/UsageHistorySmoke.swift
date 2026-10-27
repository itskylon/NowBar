import Foundation

@main
struct UsageHistorySmoke {
    static func main() throws {
        var checks = 0
        func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
            guard condition() else { fatalError(message) }
            checks += 1
        }
        func date(_ stamp: String) -> Date { MeterDate.parse(stamp)! }
        func record(_ id: String, _ stamp: String, provider: ProviderID = .codex, model: String = "model-a", input: Int64 = 10,
                    cost: Double? = 1, project: String? = "/workspace/a", session: String = "root", conversation: String = "root") -> UsageRecord {
            UsageRecord(id: id, date: date(stamp), provider: provider, model: model, tokens: .init(input: input, output: 2, cacheRead: 3, reasoning: 1),
                        estimatedCostUSD: cost, projectPath: project, sessionID: session, conversationID: conversation)
        }
        let now = date("2026-10-27T10:00:00Z")
        let utc = TimeZone(secondsFromGMT: 0)!
        let rows = [record("a", "2026-10-26T17:00:00Z"), record("b", "2026-10-27T01:00:00Z", model: "model-b", input: 20, cost: nil, session: "child", conversation: "root")]
        let report = UsageReport(records: rows, range: .sevenDays, timeZone: utc, now: now)
        expect(report.records.count == 2 && report.summary.tokens.total == 40, "Report must include and sum actual records")
        expect(report.summary.tokens.reasoning == 2 && report.summary.tokens.total == 40, "Reasoning is an output subset, not an extra total")
        expect(report.summary.recordCount == 2 && report.summary.pricedCount == 1 && report.summary.unpricedCount == 1, "Unknown prices keep their Token and status")
        expect(report.summary.pricedCostUSD == 1 && report.summary.completeCostUSD == nil, "Partial priced subtotal cannot claim a complete fee")
        expect(report.summary.models.count == 2 && report.summary.models.first?.model == "model-b", "Model rows sort by tokens")
        expect(report.rankings(.session).count == 2 && report.rankings(.conversation).count == 1, "Subtasks have separate sessions but share an independent chat")
        expect(report.rankings(.conversation).first?.summary.tokens.total == report.summary.tokens.total, "Chat grouping must reconcile with total")
        expect(report.rankings(.provider).first?.title == "Codex", "Provider ranking uses user-facing provider names")
        let duplicate = UsageReport(records: rows + [rows[0]], range: .all, timeZone: utc, now: now)
        expect(duplicate.records.count == 2 && duplicate.summary.tokens.total == 40, "One response ID is counted once per provider")
        let otherProvider = record("a", "2026-10-27T02:00:00Z", provider: .claude, cost: 0)
        let mixed = UsageReport(records: rows + [otherProvider], range: .all, timeZone: utc, now: now)
        expect(mixed.records.count == 3 && mixed.rankings(.provider).count == 2, "Same response ID in distinct providers remains independent")
        expect(mixed.rankings(.session).count == 3 && mixed.rankings(.conversation).count == 2, "Conversation and session IDs are provider-scoped")
        let providerOnly = UsageReport(records: mixed.records, range: .all, timeZone: utc, provider: .claude, now: now)
        expect(providerOnly.records.count == 1 && providerOnly.summary.completeCostUSD == 0, "Provider filter keeps observed zero fees as zero")
        let unpriced = UsageSummary(records: [record("unknown", "2026-10-27T00:00:00Z", cost: nil)])
        expect(unpriced.pricedCostUSD == nil && unpriced.completeCostUSD == nil && unpriced.tokens.total == 15, "All unknown prices stay unavailable")
        let empty = UsageSummary(records: [])
        expect(empty.recordCount == 0 && empty.pricedCostUSD == nil && empty.completeCostUSD == nil, "No records must not imply a measured zero fee")
        let invalidPrice = UsageSummary(records: [record("nan", "2026-10-27T00:00:00Z", cost: .nan), record("neg", "2026-10-27T00:00:00Z", cost: -1)])
        expect(invalidPrice.pricedCount == 0 && invalidPrice.pricedCostUSD == nil, "Invalid estimates are unpriced")
        let sameModelPartial = UsageSummary(records: [record("p", "2026-10-27T00:00:00Z"), record("u", "2026-10-27T01:00:00Z", cost: nil)])
        expect(sameModelPartial.models.count == 1 && sameModelPartial.models[0].estimatedCostUSD == nil, "A model with unknown-price responses cannot claim a complete model fee")
        let projects = UsageReport(records: [rows[0], record("c", "2026-10-27T02:00:00Z", project: "/other/a"), record("d", "2026-10-27T02:00:00Z", project: nil)], range: .all, timeZone: utc, now: now).rankings(.project)
        expect(projects.count == 3 && projects.filter { $0.title == "a" }.count == 2, "Identically named project directories remain separate")
        expect(Set(projects.filter { $0.title == "a" }.map(\.subtitle)) == Set(["/workspace/a", "/other/a"]), "Project paths remain available for disambiguation")
        expect(projects.contains { $0.title == "未识别项目" }, "Missing project metadata stays explicit")
        expect(projects.reduce(Int64(0)) { $0 + $1.summary.tokens.total } == 45, "Project ranking reconciles with all records")
        let ranked = UsageReport(records: [record("cost0", "2026-10-27T00:00:00Z", input: 200, cost: 0, project: "/p/zero"), record("cost1", "2026-10-27T00:00:00Z", cost: 1, project: "/p/paid"), record("unknown", "2026-10-27T00:00:00Z", input: 999, cost: nil, project: "/p/unknown")], range: .all, timeZone: utc, now: now).rankings(.project)
        expect(ranked.map(\.title) == ["paid", "zero", "unknown"], "Rank known fees first, then amount, without treating unknown as zero")
        expect(UsageRange.allCases.count == 5 && UsageGrouping.allCases.count == 4 && UsagePeriod.allCases.count == 2, "All requested filter modes are represented")
        let sevenBoundary = [record("before", "2026-10-20T23:59:59Z"), record("edge", "2026-10-21T00:00:00Z"), record("future", "2026-10-27T10:00:01Z")]
        let seven = UsageReport(records: sevenBoundary, range: .sevenDays, timeZone: utc, now: now)
        expect(seven.records.map(\.id) == ["edge"] && seven.startDate == date("2026-10-21T00:00:00Z"), "Seven days includes today and excludes the prior midnight and future")
        let thirty = UsageReport(records: [], range: .thirtyDays, timeZone: utc, now: now)
        let ninety = UsageReport(records: [], range: .ninetyDays, timeZone: utc, now: now)
        expect(thirty.startDate == date("2026-09-28T00:00:00Z") && ninety.startDate == date("2026-07-30T00:00:00Z"), "Thirty and ninety day ranges include today")
        let month = UsageReport(records: [record("old", "2026-09-30T23:59:59Z"), record("month", "2026-10-01T00:00:00Z")], range: .monthToDate, timeZone: utc, now: now)
        expect(month.records.map(\.id) == ["month"] && month.startDate == date("2026-10-01T00:00:00Z"), "Month to date starts at the selected calendar's month")
        let all = UsageReport(records: [record("june", "2026-06-02T15:00:00Z"), rows[0]], range: .all, timeZone: utc, now: now)
        expect(all.records.count == 2 && all.startDate == date("2026-06-02T00:00:00Z"), "All history extends to the earliest observed local day")
        expect(all.endDate == now, "Range ends at the current instant without future estimates")
        let shanghai = TimeZone(identifier: "Asia/Shanghai")!
        let shifted = UsageReport(records: [record("outside", "2026-10-20T15:59:59Z"), record("inside", "2026-10-20T16:00:00Z")], range: .sevenDays, timeZone: shanghai, now: now)
        expect(shifted.records.map(\.id) == ["inside"] && shifted.startDate == date("2026-10-20T16:00:00Z"), "Time zone changes the midnight boundary, not the response timestamp")
        let losAngeles = TimeZone(identifier: "America/Los_Angeles")!
        let dstNow = date("2026-03-10T18:00:00Z")
        let dst = UsageReport(records: [record("dst", "2026-03-04T08:00:00Z")], range: .sevenDays, timeZone: losAngeles, now: dstNow)
        expect(dst.startDate == date("2026-03-04T08:00:00Z"), "DST ranges use calendar days rather than fixed 24-hour subtraction")
        let daily = report.buckets(.overview)
        expect(daily.count == 2 && daily[0].start == date("2026-10-26T00:00:00Z"), "Short overview groups by selected-zone day")
        expect(daily.reduce(Int64(0)) { $0 + $1.summary.tokens.total } == report.summary.tokens.total, "Daily bars reconcile with report")
        expect(report.buckets(.hourly).count == 2 && report.buckets(.hourly)[0].end.timeIntervalSince(report.buckets(.hourly)[0].start) == 3600, "Hourly mode groups into actual calendar hours")
        expect(all.buckets(.overview).allSatisfy { $0.end.timeIntervalSince($0.start) == 7 * 86400 }, "Long overview uses calendar weeks")
        expect(all.buckets(.overview).reduce(Int64(0)) { $0 + $1.summary.tokens.total } == all.summary.tokens.total, "Weekly bars reconcile with all-history total")
        expect(UsageReport(records: [], range: .all, timeZone: utc, now: now).buckets(.overview).isEmpty, "Missing dates do not become invented zero-usage bars")
        let fall = UsageReport(records: [record("fall-a", "2026-11-01T08:30:00Z"), record("fall-b", "2026-11-01T09:30:00Z")], range: .sevenDays, timeZone: losAngeles, now: date("2026-11-02T18:00:00Z"))
        expect(fall.buckets(.hourly).count == 2 && Set(fall.buckets(.hourly).map(\.start)).count == 2, "Repeated local DST hours must remain distinct instants")
        let roundTrip = try JSONDecoder().decode(UsageRecord.self, from: JSONEncoder().encode(rows[0]))
        expect(roundTrip.id == rows[0].id && roundTrip.tokens == rows[0].tokens && roundTrip.projectPath == rows[0].projectPath, "Usage metadata retains its public Codable contract")
        print("Usage history: \(checks) checks passed")
    }
}
