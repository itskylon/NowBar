import AppKit
import Charts
import SwiftUI
import AgentMeterCore

struct UsageHistoryView: View {
    @ObservedObject var store: MeterStore
    @StateObject private var history: UsageHistoryStore
    @State private var settingsTab = 0
    @State private var showingSettings: Bool
    @State private var showingQuota: Bool
    @State private var showAllRankings = false
    @State private var expandedRankings: Set<String> = []
    @State private var selectedBucketID: String?
    @State private var selectedChartDate: Date?

    init(store: MeterStore, showQuota: Bool = false, showSettings: Bool = false, previewRecords: [UsageRecord]? = nil, now: Date? = nil) {
        self.store = store
        _showingSettings = State(initialValue: showSettings)
        _showingQuota = State(initialValue: showQuota)
        _history = StateObject(wrappedValue: UsageHistoryStore(previewRecords: previewRecords ?? (store.demo ? [] : nil), now: now))
    }

    private var buckets: [UsageBucket] { history.buckets }
    private var timeZoneIdentifiers: [String] {
        let identifiers = TimeZone.knownTimeZoneIdentifiers
        return identifiers.contains(history.timeZoneID) ? identifiers : [history.timeZoneID] + identifiers
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            if showingSettings {
                MeterSettingsView(store: store, tab: $settingsTab)
            } else if showingQuota {
                QuotaUsageView(store: store, provider: history.provider, settings: { showingSettings = true })
                    .environment(\.timeZone, .current)
            } else {
                historyContent
            }
        }
        .frame(minWidth: 900, minHeight: 650)
        .environment(\.timeZone, history.timeZone)
        .environment(\.locale, L10n.locale)
        .onAppear(perform: start)
        .onDisappear { history.stop() }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("AgentMeterUsageOpened"))) { _ in start() }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("AgentMeterUsageClosed"))) { _ in history.stop() }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("AgentMeterWorkspaceNavigate"))) { notification in
            showingSettings = notification.object as? String == "settings"
        }
        .onChange(of: showingSettings) { _, settings in
            if settings { history.stop() } else { start() }
        }
        .onChange(of: showingQuota) { _, quota in
            if quota { history.stop() } else { start() }
        }
        .onChange(of: store.preferences.enabledProviders) { _, enabled in
            if showingQuota {
                if let provider = history.provider, !enabled.contains(provider) { history.provider = nil }
            } else { configure() }
        }
        .onChange(of: store.preferences.refreshInterval) { _, _ in configure() }
        .onChange(of: history.range) { _, _ in clearSelection() }
        .onChange(of: history.timeZoneID) { _, _ in clearSelection() }
        .onChange(of: history.provider) { _, _ in clearSelection() }
        .onChange(of: history.grouping) { _, _ in expandedRankings.removeAll(); showAllRankings = false }
        .onChange(of: history.period) { _, _ in selectedBucketID = nil }
        .onChange(of: selectedChartDate) { _, date in
            guard !showingSettings, !showingQuota, let date else { return }
            selectedBucketID = buckets.first { $0.start <= date && date < $0.end }?.id
                ?? buckets.min(by: { abs($0.start.timeIntervalSince(date)) < abs($1.start.timeIntervalSince(date)) })?.id
        }
    }

    private var historyContent: some View {
        ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    header
                    filters
                    summary
                    rankingCard
                    chartCard
                    Text(L10n.text("本机日志中的参考费用，按公开 API 单价估算，不代表订阅账单。缓存属于输入、推理属于输出，总 Token 不重复累加。"))
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }.padding(28).frame(maxWidth: .infinity, alignment: .leading)
        }.background(Color(nsColor: .windowBackgroundColor))
    }

    private func start() {
        guard !showingSettings, !showingQuota else { return }
        history.start(enabledProviders: store.preferences.enabledProviders, automatic: store.preferences.refreshInterval != .manual)
    }
    private func configure() {
        guard !showingSettings, !showingQuota else { return }
        history.configure(enabledProviders: store.preferences.enabledProviders, automatic: store.preferences.refreshInterval != .manual)
    }
    private func clearSelection() {
        selectedBucketID = nil
        selectedChartDate = nil
        expandedRankings.removeAll()
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                AppBrandMark(size: 30)
                Text(AppBrand.name).font(.system(size: 17, weight: .semibold, design: .rounded))
            }.padding(.horizontal, 10).padding(.bottom, 22)
            sidebarButton(L10n.text("通用与服务设置"), icon: "gearshape", selected: showingSettings) { showingSettings = true }
            sidebarButton(L10n.text("额度用量"), icon: "gauge.with.dots.needle.33percent", selected: !showingSettings && showingQuota && history.provider == nil) {
                showingSettings = false
                showingQuota = true
                history.provider = nil
            }
            sidebarButton(L10n.text("用量与支出"), icon: "chart.bar.fill", selected: !showingSettings && !showingQuota && history.provider == nil) {
                showingSettings = false
                showingQuota = false
                history.provider = nil
            }
            Text(L10n.text("已启用的服务")).font(.system(size: 11)).foregroundStyle(.secondary).padding(.horizontal, 10).padding(.top, 22)
            ForEach(store.providers) { provider in
                Button { showingSettings = false; history.provider = provider } label: {
                    HStack(spacing: 8) {
                        ProviderMark(name: provider.iconName, size: 15, color: !showingSettings && history.provider == provider ? .white : .primary)
                        Text(provider.title).font(.system(size: 12, weight: .medium))
                        Spacer(minLength: 0)
                        if !showingQuota {
                            Circle().fill(provider.hasTokenHistory ? Color.green : Color.secondary.opacity(0.5)).frame(width: 5, height: 5)
                        }
                    }.padding(.horizontal, 10).padding(.vertical, 8).contentShape(Rectangle())
                }.buttonStyle(.plain).foregroundStyle(!showingSettings && history.provider == provider ? .white : .primary)
                    .background(!showingSettings && history.provider == provider ? Color.accentColor : .clear, in: RoundedRectangle(cornerRadius: 6))
                    .accessibilityLabel(L10n.text("筛选 ") + provider.title)
            }
            Spacer()
            Text(L10n.text("仅统计这台 Mac\n跟随系统外观")).font(.system(size: 11)).foregroundStyle(.secondary).lineSpacing(4).padding(10)
        }.padding(.horizontal, 12).padding(.top, 26).padding(.bottom, 12).frame(width: 190)
            .background(Color(nsColor: .underPageBackgroundColor))
    }

    private func sidebarButton(_ title: String, icon: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon).font(.system(size: 12, weight: .medium)).frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10).padding(.vertical, 9).contentShape(Rectangle())
        }.buttonStyle(.plain).foregroundStyle(selected ? .white : .primary)
            .background(selected ? Color.accentColor : .clear, in: RoundedRectangle(cornerRadius: 6))
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 5) {
                Text(L10n.text("用量与支出")).font(.system(size: 22, weight: .semibold))
                Text(L10n.text("已启用服务在本机留下的历史用量与参考费用。")).font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Spacer()
            Button(action: history.refresh) {
                HStack(spacing: 5) {
                    if history.scanning { ProgressView().controlSize(.small) }
                    else { Image(systemName: "arrow.clockwise") }
                    Text(history.scanning ? L10n.text("读取中") : L10n.text("刷新"))
                }
            }.disabled(history.scanning).accessibilityLabel(L10n.text("刷新本机历史用量"))
        }
    }

    private var filters: some View {
        VStack(alignment: .leading, spacing: 15) {
            Picker(L10n.text("统计范围"), selection: $history.range) {
                ForEach(UsageRange.allCases) { Text(L10n.text($0.title)).tag($0) }
            }.id(L10n.locale.identifier).labelsHidden().accessibilityLabel(L10n.text("统计范围")).pickerStyle(.segmented).frame(maxWidth: 490)
            VStack(alignment: .leading, spacing: 6) {
                Text(L10n.text("统计时区")).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                HStack(spacing: 10) {
                    Picker(L10n.text("统计时区"), selection: $history.timeZoneID) {
                        ForEach(timeZoneIdentifiers, id: \.self) { Text($0).tag($0) }
                    }.id(L10n.locale.identifier).labelsHidden().frame(maxWidth: 330)
                    Button(L10n.text("使用电脑当前时区"), action: history.useCurrentTimeZone)
                }
                Text(L10n.text("按所选时区的日期汇总；更改时区可能让部分用量归入不同日期。")).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            if history.provider == .grokBot {
                Label(L10n.text("Grok Bot 当前只提供订阅额度，没有本机 Token 与费用历史。"), systemImage: "info.circle")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }
    }

    private var summary: some View {
        let report = history.report
        let summary = report.summary
        return VStack(alignment: .leading, spacing: 17) {
            VStack(alignment: .leading, spacing: 5) {
                Text(L10n.text("USD · 本地参考费用")).font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    if history.scanning { ProgressView().controlSize(.mini) }
                    Text(L10n.format("日志读取：%@ / %@ 个文件", String(history.scannedFileCount), String(history.totalFileCount)) + (history.incomplete ? L10n.text(" · 部分统计") : ""))
                    if let updated = history.lastUpdated { Text("· " + MeterFormat.updated(updated)) }
                }.font(.system(size: 11)).foregroundStyle(.secondary)
            }
            HStack(alignment: .top, spacing: 42) {
                metric(summary.unpricedCount > 0 ? L10n.text("已计价部分") : L10n.text("参考支出"), value: cost(summary.pricedCostUSD))
                metric(L10n.text("已记录 Token"), value: report.records.isEmpty ? "—" : MeterFormat.tokens(summary.tokens.total))
                metric(L10n.text("独立聊天"), value: String(history.conversationCount))
                metric(L10n.text("会话"), value: String(history.sessionCount))
                Spacer(minLength: 0)
            }
            Divider()
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), alignment: .leading), count: 5), alignment: .leading, spacing: 14) {
                tokenMetric(L10n.text("普通输入"), value: summary.tokens.input)
                tokenMetric(L10n.text("输出"), value: summary.tokens.output)
                tokenMetric(L10n.text("缓存读取"), value: summary.tokens.cacheRead)
                tokenMetric(L10n.text("缓存写入"), value: summary.tokens.cacheWrite)
                tokenMetric(L10n.text("推理（已含在输出）"), value: summary.tokens.reasoning)
            }
            Text(L10n.format("已计价 %@ · 未计价 %@ · 记录 %@", String(summary.pricedCount), String(summary.unpricedCount), String(summary.recordCount)))
                .font(.system(size: 11)).foregroundStyle(.secondary)
            if history.incomplete {
                Label(history.hasUnreadFiles ? L10n.text("还有日志未读完，以上为已读取部分；可刷新继续检查。") : L10n.text("部分日志损坏或无法读取，统计可能不完整。"), systemImage: "info.circle")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
    }

    private func metric(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 11)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 23, weight: .semibold, design: .rounded)).monospacedDigit()
        }
    }
    private func tokenMetric(_ title: String, value: Int64) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.system(size: 10)).foregroundStyle(.secondary)
            Text(MeterFormat.tokens(value)).font(.system(size: 13, weight: .medium)).monospacedDigit()
        }
    }

    private var rankingCard: some View {
        VStack(alignment: .leading, spacing: 15) {
            let rankings = history.rankings
            HStack(spacing: 20) {
                Picker(L10n.text("排行分组"), selection: $history.grouping) {
                    ForEach(UsageGrouping.allCases) { Text(L10n.text($0.title)).tag($0) }
                }.id(L10n.locale.identifier).labelsHidden().accessibilityLabel(L10n.text("排行分组")).pickerStyle(.segmented).frame(maxWidth: 350)
                Spacer(minLength: 0)
                TextField(L10n.text("搜索排行"), text: $history.search).textFieldStyle(.roundedBorder).frame(width: 180)
            }
            if rankings.isEmpty {
                emptyMessage(history.search.isEmpty ? L10n.text("所选范围没有本机用量记录") : L10n.text("没有匹配的结果"), detail: L10n.text("可以切换时间范围、服务或搜索条件。"))
            } else {
                let visible = showAllRankings ? rankings : Array(rankings.prefix(8))
                VStack(spacing: 0) {
                    ForEach(Array(visible.enumerated()), id: \.element.id) { index, row in
                        if index > 0 { Divider() }
                        rankingRow(row, index: index)
                    }
                }
                if rankings.count > 8 {
                    Button(showAllRankings ? L10n.text("收起排行") : L10n.format("显示全部（%@）", String(rankings.count))) { showAllRankings.toggle() }
                        .font(.system(size: 11))
                }
            }
        }.padding(18).historyCard()
    }

    private func rankingRow(_ row: UsageRanking, index: Int) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                if expandedRankings.contains(row.id) { expandedRankings.remove(row.id) }
                else { expandedRankings.insert(row.id) }
            } label: {
                HStack(spacing: 12) {
                    Text("#\(index + 1)").font(.system(size: 10)).foregroundStyle(.secondary).frame(width: 24, alignment: .leading)
                    Image(systemName: history.grouping == .project ? "folder" : history.grouping == .provider ? "square.stack.3d.up" : "bubble.left.and.bubble.right")
                        .font(.system(size: 13)).foregroundStyle(.secondary).frame(width: 18)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(rankingTitle(row)).font(.system(size: 13, weight: .medium)).lineLimit(1)
                        Text(rankingSubtitle(row)).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                    }.help(rankingTitle(row) + "\n" + rankingSubtitle(row))
                    Spacer(minLength: 12)
                    VStack(alignment: .trailing, spacing: 3) {
                        Text(cost(row.summary.pricedCostUSD) + (row.summary.unpricedCount > 0 ? L10n.text(" + 未计价") : "")).font(.system(size: 12, weight: .medium)).monospacedDigit()
                        Text(MeterFormat.tokens(row.summary.tokens.total) + " Token").font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
                    }
                    Image(systemName: expandedRankings.contains(row.id) ? "chevron.up" : "chevron.down").font(.system(size: 9)).foregroundStyle(.secondary)
                }.padding(.vertical, 12).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityLabel((expandedRankings.contains(row.id) ? L10n.text("收起排行明细 ") : L10n.text("展开排行明细 ")) + rankingTitle(row))
            if expandedRankings.contains(row.id) {
                VStack(alignment: .leading, spacing: 12) {
                    if let first = row.records.map(\.date).min(), let last = row.records.map(\.date).max() {
                        Text(date(first, format: "yyyy年M月d日 HH:mm") + " — " + date(last, format: "yyyy年M月d日 HH:mm") + L10n.format(" · %@ 条用量记录", String(row.summary.recordCount)))
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    modelRows(row.summary.models)
                }.padding(.leading, 54).padding(.bottom, 16)
            }
        }
    }

    private var chartCard: some View {
        let report = history.report
        let buckets = history.buckets
        let selectedBucket = buckets.first { $0.id == selectedBucketID } ?? buckets.last
        let selectedID = selectedBucket?.id
        let priced = buckets.compactMap { bucket -> HistoryCostBar? in
            guard let value = bucket.summary.pricedCostUSD else { return nil }
            let start = max(bucket.start, report.startDate)
            let end = min(bucket.end, report.endDate)
            guard end > start else { return nil }
            return HistoryCostBar(id: bucket.id, start: start, end: end, cost: value,
                                  label: bucketLabel(bucket), costLabel: cost(value))
        }
        return VStack(alignment: .leading, spacing: 17) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(L10n.text("参考支出")).font(.system(size: 15, weight: .semibold))
                    Text(date(report.startDate, format: "yyyy年M月d日") + " — " + date(report.endDate, format: "yyyy年M月d日"))
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                Picker(L10n.text("图表粒度"), selection: $history.period) {
                    ForEach(UsagePeriod.allCases) { Text(L10n.text($0.title)).tag($0) }
                }.id(L10n.locale.identifier).labelsHidden().accessibilityLabel(L10n.text("图表粒度")).pickerStyle(.segmented).frame(width: 140)
            }
            Text(L10n.text("点击柱形或在下方选择期间，查看模型明细。无日志的日期留空；未计价记录不按零费用绘图。"))
                .font(.system(size: 11)).foregroundStyle(.secondary)
            if priced.isEmpty {
                emptyMessage(report.records.isEmpty ? L10n.text("所选范围没有用量记录") : L10n.text("这些记录尚未计价"), detail: L10n.text("有已知价格的记录后显示参考费用趋势。"))
                    .frame(height: 210)
            } else {
                Chart(priced) { bar in
                    RectangleMark(xStart: .value(L10n.text("开始"), bar.start), xEnd: .value(L10n.text("结束"), bar.end),
                                  yStart: .value(L10n.text("基线"), 0.0), yEnd: .value(L10n.text("参考费用"), bar.cost))
                        .foregroundStyle(selectedID == bar.id ? Color.teal : Color.teal.opacity(0.7))
                        .cornerRadius(3)
                        .accessibilityLabel(bar.label)
                        .accessibilityValue(bar.costLabel)
                }
                .chartXScale(domain: report.startDate...max(report.endDate, report.startDate.addingTimeInterval(1)))
                .chartPlotStyle { $0.clipped() }
                .chartXSelection(value: $selectedChartDate)
                .chartGesture { proxy in
                    SpatialTapGesture().onEnded { proxy.selectXValue(at: $0.location.x) }
                }
                .chartYAxis {
                    AxisMarks(position: .leading) { value in
                        AxisGridLine()
                        AxisValueLabel { if let number = value.as(Double.self) { Text("$" + number.formatted(.number.precision(.fractionLength(0...2)).locale(L10n.locale))) } }
                    }
                }
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: 5)) { value in
                        AxisGridLine()
                        AxisValueLabel {
                            if let stamp = value.as(Date.self) { Text(date(stamp, format: history.period == .hourly ? "M/d HH:mm" : "M/d")) }
                        }
                    }
                }
                .frame(height: 240)
                .accessibilityLabel(L10n.text("本机参考费用历史图"))
            }
            if let selectedBucket {
                Divider()
                HStack {
                    Picker(L10n.text("查看期间"), selection: Binding(get: { selectedBucket.id }, set: { selectedBucketID = $0 })) {
                        ForEach(buckets) { Text(bucketLabel($0)).tag($0.id) }
                    }.id(L10n.locale.identifier).labelsHidden().frame(maxWidth: 360)
                    Text(L10n.format("%@ 条记录", String(selectedBucket.summary.recordCount))).font(.system(size: 11)).foregroundStyle(.secondary)
                    Spacer()
                    Text(cost(selectedBucket.summary.pricedCostUSD) + (selectedBucket.summary.unpricedCount > 0 ? L10n.text(" + 未计价") : ""))
                        .font(.system(size: 14, weight: .semibold)).monospacedDigit()
                }
                modelRows(selectedBucket.summary.models)
            }
        }.padding(18).historyCard()
    }

    private func modelRows(_ models: [ModelUsage]) -> some View {
        VStack(spacing: 9) {
            ForEach(models) { model in
                HStack(spacing: 12) {
                    Text(model.model).font(.system(size: 12, design: .monospaced)).lineLimit(1).help(model.model)
                    Spacer(minLength: 8)
                    Text(MeterFormat.tokens(model.tokens.total) + " Token").font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
                    Text(cost(model.estimatedCostUSD)).font(.system(size: 12, weight: .medium)).monospacedDigit().frame(minWidth: 66, alignment: .trailing)
                }
            }
        }
    }
    private func emptyMessage(_ title: String, detail: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "chart.bar.xaxis").font(.system(size: 22)).foregroundStyle(.tertiary)
            Text(title).font(.system(size: 13, weight: .medium))
            Text(detail).font(.system(size: 11)).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity).padding(.vertical, 35)
    }
    private func cost(_ value: Double?) -> String { value.map { MeterFormat.cost($0) } ?? L10n.text("未计价") }
    private func rankingTitle(_ row: UsageRanking) -> String {
        if history.grouping == .project {
            return row.id == "project:" ? L10n.text(row.title) : row.title
        }
        return L10n.text(row.title)
    }
    private func rankingSubtitle(_ row: UsageRanking) -> String {
        if history.grouping == .project, row.id != "project:" { return row.subtitle }
        return L10n.text(row.subtitle)
    }
    private func date(_ value: Date, format: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = L10n.locale
        formatter.timeZone = history.timeZone
        if L10n.isEnglish {
            switch format {
            case "yyyy年M月d日 HH:mm": formatter.dateFormat = "MMM d, yyyy HH:mm"
            case "yyyy年M月d日": formatter.dateFormat = "MMM d, yyyy"
            case "M月d日 HH:mm": formatter.dateFormat = "MMM d HH:mm"
            case "M月d日": formatter.dateFormat = "MMM d"
            default: formatter.dateFormat = format
            }
        } else { formatter.dateFormat = format }
        return formatter.string(from: value)
    }
    private func bucketLabel(_ bucket: UsageBucket) -> String {
        if history.period == .hourly { return date(bucket.start, format: "M月d日 HH:mm") }
        if bucket.end.timeIntervalSince(bucket.start) > 36 * 3600 {
            return date(bucket.start, format: "yyyy年M月d日") + " — " + date(bucket.end.addingTimeInterval(-1), format: "M月d日")
        }
        return date(bucket.start, format: "yyyy年M月d日")
    }
}

private struct HistoryCostBar: Identifiable {
    var id: String
    var start: Date
    var end: Date
    var cost: Double
    var label: String
    var costLabel: String
}

private extension View {
    func historyCard() -> some View {
        background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.05), lineWidth: 1))
    }
}
