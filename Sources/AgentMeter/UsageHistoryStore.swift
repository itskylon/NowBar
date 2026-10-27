import Foundation
import SwiftUI
import AgentMeterCore

/// Window-scoped local history. Account quota refreshes remain in MeterStore.
@MainActor
final class UsageHistoryStore: ObservableObject {
    @Published private(set) var records: [UsageRecord] = [] {
        didSet { invalidateReport() }
    }
    @Published private(set) var scanning = false
    @Published private(set) var incomplete = false
    @Published private(set) var scannedFileCount = 0
    @Published private(set) var totalFileCount = 0
    @Published private(set) var lastUpdated: Date?
    @Published var range: UsageRange = .all {
        didSet { if range != oldValue { invalidateReport() } }
    }
    @Published var grouping: UsageGrouping = .project {
        didSet { if grouping != oldValue { cachedRankings = nil } }
    }
    @Published var period: UsagePeriod = .overview {
        didSet { if period != oldValue { cachedBuckets = nil } }
    }
    @Published var provider: ProviderID? {
        didSet { if provider != oldValue { invalidateReport() } }
    }
    @Published var search = ""
    @Published var timeZoneID: String {
        didSet {
            if timeZoneID != oldValue { invalidateReport(); scheduleDayBoundary() }
            guard !isPreview, TimeZone(identifier: timeZoneID) != nil else { return }
            UserDefaults.standard.set(timeZoneID, forKey: Self.timeZoneKey)
        }
    }

    static let timeZoneKey = "usageHistory.timeZone.v1"
    private let isPreview: Bool
    private let currentDate: () -> Date
    private let codexReader: CodexLocalUsageReader
    private let claudeReader: ClaudeUsageHistoryReader
    private var timer: Timer?
    private var dayTimer: Timer?
    private var active = false
    private var enabled: Set<ProviderID> = []
    private var byProvider: [ProviderID: [UsageRecord]] = [:]
    private var noProgressPasses = 0
    private var lastReadBytes: UInt64 = 0
    private var pendingRefresh = false
    private var generation = 0
    private var cachedReport: UsageReport?
    private var cachedRankings: [UsageRanking]?
    private var cachedBuckets: [UsageBucket]?
    private var cachedIdentityCounts: (conversations: Int, sessions: Int)?
    private var cachedReportDate: Date?
    private var cachedReportValidUntil = Date.distantPast

    init(previewRecords: [UsageRecord]? = nil, now: Date? = nil,
         codexHome: URL? = nil, claudeProjects: URL? = nil, clock: @escaping () -> Date = Date.init) {
        isPreview = previewRecords != nil
        currentDate = { now ?? clock() }
        let savedZone = previewRecords == nil ? UserDefaults.standard.string(forKey: Self.timeZoneKey) : nil
        timeZoneID = savedZone.flatMap { TimeZone(identifier: $0)?.identifier } ?? TimeZone.current.identifier
        let root = codexHome ?? ProcessInfo.processInfo.environment["CODEX_HOME"].flatMap { path in
            path.isEmpty ? nil : URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        } ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex", isDirectory: true)
        codexReader = CodexLocalUsageReader(root: root, includeAllHistory: true, estimateCost: { model, counts, rawInput, tier in
            CodexPricing.estimate(model: model, inputTokens: rawInput, cachedInputTokens: counts.cacheRead,
                                 cacheWriteInputTokens: counts.cacheWrite, outputTokens: counts.output,
                                 serviceTier: tier ?? "standard")
        })
        claudeReader = ClaudeUsageHistoryReader(root: claudeProjects ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects", isDirectory: true))
        if let previewRecords {
            records = previewRecords
            byProvider = Dictionary(grouping: previewRecords, by: \.provider)
            lastUpdated = now ?? Date()
        }
    }

    var timeZone: TimeZone { TimeZone(identifier: timeZoneID) ?? .current }
    var report: UsageReport {
        let now = currentDate()
        if let cachedReport, let cachedReportDate, now >= cachedReportDate, now < cachedReportValidUntil { return cachedReport }
        invalidateReport()
        let value = UsageReport(records: records, range: range, timeZone: timeZone, provider: provider, now: now)
        cachedReport = value
        cachedReportDate = now
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let nextDay = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) ?? now.addingTimeInterval(86400)
        // A future record must become eligible at its timestamp, even within the same date.
        cachedReportValidUntil = min(nextDay, records.lazy.filter { $0.date > now }.map(\.date).min() ?? .distantFuture)
        return value
    }
    var rankings: [UsageRanking] {
        let report = self.report
        let values: [UsageRanking]
        if let cachedRankings { values = cachedRankings }
        else {
            values = report.rankings(grouping)
            cachedRankings = values
        }
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return values }
        return values.filter { row in
            let raw = row.title + " " + row.subtitle
            // Real project names and paths are user data, not localization keys.
            let presented = grouping == .project && row.id != "project:"
                ? raw : L10n.text(row.title) + " " + L10n.text(row.subtitle)
            return (raw + " " + presented).localizedCaseInsensitiveContains(query)
        }
    }
    var buckets: [UsageBucket] {
        let report = self.report
        if let cachedBuckets { return cachedBuckets }
        let values = report.buckets(period)
        cachedBuckets = values
        return values
    }
    var conversationCount: Int { identityCounts.conversations }
    var sessionCount: Int { identityCounts.sessions }
    var hasUnreadFiles: Bool { incomplete && scannedFileCount < totalFileCount }

    private var identityCounts: (conversations: Int, sessions: Int) {
        let report = self.report
        if let cachedIdentityCounts { return cachedIdentityCounts }
        let rows = report.records
        let values = (conversations: Set(rows.map { $0.provider.rawValue + ":" + $0.conversationID }).count,
                      sessions: Set(rows.map { $0.provider.rawValue + ":" + $0.sessionID }).count)
        cachedIdentityCounts = values
        return values
    }

    private func invalidateReport() {
        cachedReport = nil
        cachedRankings = nil
        cachedBuckets = nil
        cachedIdentityCounts = nil
        cachedReportDate = nil
        cachedReportValidUntil = .distantPast
    }

    private func scheduleDayBoundary() {
        dayTimer?.invalidate()
        dayTimer = nil
        guard active, !isPreview else { return }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let now = currentDate()
        guard let nextDay = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) else { return }
        // Redraw rolling date ranges at midnight without scanning logs in manual mode.
        dayTimer = Timer.scheduledTimer(withTimeInterval: max(0.1, nextDay.timeIntervalSince(now)), repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.active else { return }
                self.invalidateReport()
                self.objectWillChange.send()
                self.scheduleDayBoundary()
            }
        }
    }

    func useCurrentTimeZone() { timeZoneID = TimeZone.current.identifier }

    func start(enabledProviders: Set<ProviderID>, automatic: Bool) {
        let wasActive = active
        let configurationWillRefresh = !enabledProviders.subtracting(enabled).isEmpty
        if !wasActive { generation += 1 }
        active = true
        configure(enabledProviders: enabledProviders, automatic: automatic)
        if !wasActive, !configurationWillRefresh { refresh() }
    }

    func configure(enabledProviders: Set<ProviderID>, automatic: Bool) {
        let newlyEnabled = enabledProviders.subtracting(enabled)
        enabled = enabledProviders
        if let provider, !enabled.contains(provider) { self.provider = nil }
        records = byProvider.filter { enabled.contains($0.key) }.values.flatMap { $0 }
        timer?.invalidate()
        timer = nil
        scheduleDayBoundary()
        if active, automatic, !isPreview {
            timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.scan() }
            }
        }
        if active, !newlyEnabled.isEmpty { refresh() }
    }

    func stop() {
        active = false
        generation += 1
        pendingRefresh = false
        timer?.invalidate()
        timer = nil
        dayTimer?.invalidate()
        dayTimer = nil
    }

    func refresh() {
        guard active, !isPreview else { return }
        noProgressPasses = 0
        if scanning { pendingRefresh = true; return }
        scan()
    }

    private func scan() {
        guard active, !isPreview, !scanning else { return }
        let requested = enabled
        let codex = codexReader
        let claude = claudeReader
        let scanGeneration = generation
        scanning = true
        Task {
            let result = await Task.detached(priority: .utility) { [weak self] in
                var batches: [HistoryBatch] = []
                if requested.contains(.codex), await self?.mayRead(.codex, generation: scanGeneration) == true {
                    let result = codex.scan()
                    batches.append(.init(provider: .codex, records: result.records, incomplete: result.incomplete,
                                         scanned: result.scannedFileCount, total: result.totalFileCount, readBytes: result.readBytes))
                }
                if requested.contains(.claude), await self?.mayRead(.claude, generation: scanGeneration) == true {
                    let result = claude.scan()
                    batches.append(.init(provider: .claude, records: result.records, incomplete: result.incomplete,
                                         scanned: result.scannedFileCount, total: result.totalFileCount, readBytes: result.readBytes))
                }
                return batches
            }.value
            guard active, generation == scanGeneration else {
                scanning = false
                let shouldRefresh = active && pendingRefresh
                pendingRefresh = false
                if shouldRefresh { scan() }
                return
            }
            let current = result.filter { enabled.contains($0.provider) }
            let previousCount = records.count
            let previousScanned = scannedFileCount
            let previousTotal = totalFileCount
            let previousReadBytes = lastReadBytes
            for batch in current where !batch.incomplete || !batch.records.isEmpty || byProvider[batch.provider]?.isEmpty != false {
                byProvider[batch.provider] = batch.records
            }
            records = byProvider.filter { enabled.contains($0.key) }.values.flatMap { $0 }
            incomplete = current.contains { $0.incomplete }
            scannedFileCount = current.reduce(0) { $0 + $1.scanned }
            totalFileCount = current.reduce(0) { $0 + $1.total }
            lastReadBytes = current.reduce(0) { $0 + $1.readBytes }
            lastUpdated = Date()
            scanning = false
            noProgressPasses = records.count == previousCount && scannedFileCount == previousScanned && totalFileCount == previousTotal && lastReadBytes == previousReadBytes
                ? noProgressPasses + 1 : 0
            if pendingRefresh {
                pendingRefresh = false
                noProgressPasses = 0
                scan()
                return
            }
            if hasUnreadFiles, noProgressPasses < 3 {
                // Continue bounded reads even in manual mode; damaged files at EOF do not loop.
                try? await Task.sleep(for: .milliseconds(150))
                if active, generation == scanGeneration { scan() }
            }
        }
    }

    private func mayRead(_ provider: ProviderID, generation expectedGeneration: Int) -> Bool {
        active && generation == expectedGeneration && enabled.contains(provider)
    }

    private struct HistoryBatch: Sendable {
        var provider: ProviderID
        var records: [UsageRecord]
        var incomplete: Bool
        var scanned: Int
        var total: Int
        var readBytes: UInt64
    }
}
