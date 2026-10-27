import SwiftUI
import AgentMeterCore

// Measured from the approved 380pt reference, rather than scaled from a mockup.
enum ReferenceStyle {
    static let width: CGFloat = 380
    static let panel = adaptive(0xF5F5F5, 0x202022)
    static let card = adaptive(0xFBFAFB, 0x2B2B2E)
    static let text = adaptive(0x202020, 0xF2F2F4)
    static let secondary = adaptive(0x646464, 0xB0B0B5)
    static let statistic = adaptive(0x292D30, 0xEEEEF0)
    static let caption = adaptive(0x686974, 0xB4B4BD)
    static let divider = adaptive(0xDFE3E1, 0x46464A)
    static let green = adaptive(0x07836B, 0x35C6A0)
    static let blue = adaptive(0x3B82F6, 0x60A5FA)
    static let teal = adaptive(0x14B8A6, 0x2DD4BF)
    static let orange = adaptive(0xF59E0B, 0xFBBF24)
    static let purple = adaptive(0xA855F7, 0xC084FC)
    static let reasoning = adaptive(0x22C55E, 0x4ADE80)
    static let control = adaptive(0xFFFFFF, 0x404043)
    static let border = adaptive(0x000000, 0xFFFFFF)

    private static func adaptive(_ light: UInt32, _ dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let rgb = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: Double((rgb >> 16) & 0xFF) / 255,
                           green: Double((rgb >> 8) & 0xFF) / 255,
                           blue: Double(rgb & 0xFF) / 255, alpha: 1)
        })
    }
}

struct ProviderMark: View {
    var name: String
    var size: CGFloat = 20
    var color: Color = ReferenceStyle.text
    var body: some View {
        Group {
            if let path = Bundle.main.url(forResource: name, withExtension: "svg", subdirectory: "providers"), let icon = NSImage(contentsOf: path) {
                Image(nsImage: icon).resizable().renderingMode(.template).scaledToFit()
            } else { Image(systemName: "circle.hexagongrid").resizable().scaledToFit() }
        }.foregroundStyle(color).frame(width: size, height: size).accessibilityHidden(true)
    }
}

private struct ReferenceIcon: View {
    @Environment(\.colorScheme) private var colorScheme
    let name: String
    var size: CGFloat = 13
    var body: some View {
        if let path = Bundle.main.url(forResource: name, withExtension: "svg", subdirectory: "interface"), let icon = image(at: path) {
            Image(nsImage: icon).resizable().scaledToFit()
                .frame(width: size, height: size).accessibilityHidden(true)
        }
    }

    private func image(at path: URL) -> NSImage? {
        guard colorScheme == .dark, let svg = try? String(contentsOf: path, encoding: .utf8) else {
            return NSImage(contentsOf: path)
        }
        // Preserve the eye's contrasting pupil; template rendering would fill it in.
        let darkSVG = svg.replacingOccurrences(of: "#fff", with: "#2B2B2E")
            .replacingOccurrences(of: "#202020", with: "#F2F2F4")
            .replacingOccurrences(of: "#646464", with: "#B0B0B5")
        return NSImage(data: Data(darkSVG.utf8))
    }
}

struct DashboardView: View {
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject var store: MeterStore
    var maxHeight: CGFloat = 800
    var referencePreview = false
    var onSizeChange: (CGSize) -> Void = { _ in }
    var settings: () -> Void = {}
    var usage: () -> Void = {}
    @State private var contentHeight: CGFloat = 680
    @State private var showUsage = true
    @State private var showTrend = true
    @State private var chartCost: Bool?
    @State private var showInfo = false
    private var panelHeight: CGFloat { 52 + min(contentHeight, maxHeight - 52) }
    private var supportsTokenHistory: Bool { referencePreview || store.selected.hasTokenHistory }
    private var today: DayUsage? { referencePreview ? ReferenceSample.today : supportsTokenHistory ? store.today : nil }
    private var costMetric: Bool { supportsTokenHistory && (chartCost ?? (referencePreview || store.current.days.contains { $0.estimatedCostUSD != nil })) }

    var body: some View {
        VStack(spacing: 0) {
            header.padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 12).frame(height: 52)
            ScrollView {
                VStack(spacing: 12) {
                    quotaCard
                    usageCard
                    trendCard
                }.padding(.horizontal, 12).padding(.bottom, 12)
                    .fixedSize(horizontal: false, vertical: true)
                    .onGeometryChange(for: CGFloat.self) { ceil($0.size.height) } action: { value in
                        if value > 0, abs(contentHeight - value) > 0.5 { contentHeight = value }
                    }
            }.scrollIndicators(.hidden)
        }
        .frame(width: ReferenceStyle.width, height: panelHeight)
        .foregroundStyle(ReferenceStyle.text)
        .background(ReferenceStyle.panel)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(ReferenceStyle.border.opacity(0.14), lineWidth: 0.5))
        .environment(\.legibilityWeight, .regular)
        .environment(\.locale, L10n.locale)
        .buttonStyle(.plain)
        .onChange(of: panelHeight, initial: true) { _, height in onSizeChange(CGSize(width: ReferenceStyle.width, height: height)) }
    }

    private var header: some View {
        HStack(spacing: 0) {
            Button { showInfo.toggle() } label: {
                HStack(spacing: 6) {
                    AppBrandMark(size: 20)
                    Text(AppBrand.name).font(.system(size: 12, weight: .medium))
                    ReferenceIcon(name: "external")
                }.contentShape(Rectangle())
            }.help(L10n.text("数据来源、更新时间与统计服务"))
                .accessibilityLabel(L10n.text("数据来源与统计服务"))
                .popover(isPresented: $showInfo, arrowEdge: .bottom) { sourceInfo }
            if store.demo {
                Text(L10n.text("示例")).font(.system(size: 8, weight: .light)).foregroundStyle(ReferenceStyle.caption).padding(.leading, 6)
                    .help(L10n.text("演示模式；显示的用量与额度均为示例"))
            }
            Spacer()
            HStack(spacing: 8) {
                iconButton("chart", label: "用量与支出", action: usage)
                if store.refreshing { ProgressView().controlSize(.small).frame(width: 28, height: 28) }
                else { iconButton("refresh", label: "刷新用量", action: store.refresh) }
                iconButton("power", label: "退出应用") { NSApplication.shared.terminate(nil) }
            }
        }
    }

    private var sourceInfo: some View {
        VStack(alignment: .leading, spacing: 14) {
            Picker(L10n.text("统计服务"), selection: $store.selected) {
                ForEach(store.providers) { Text($0.title).tag($0) }
            }.pickerStyle(.segmented)
            ForEach(store.providers) { provider in
                let value = store.snapshot(provider)
                VStack(alignment: .leading, spacing: 5) {
                    Text(provider.title + " · " + MeterFormat.updated(value.updatedAt)).fontWeight(.medium)
                    Text(L10n.text(value.sourceNote.isEmpty ? "尚无数据来源" : value.sourceNote))
                    if provider == .codex, let checked = value.historyUpdatedAt {
                        Text(L10n.format("本机日志检查：%@", MeterFormat.updated(checked)))
                    }
                    if let message = value.message { Text(L10n.text(message)) }
                }
            }
            Text(L10n.text("Codex 和 Claude 的 Token 为本机日志，按本地日期统计。Grok Bot 当前仅提供订阅额度。参考费用按公开 API 单价估算，Codex 未记录服务档时按标准价；未知模型或计价档位不计价。"))
            Button(L10n.text("用量与支出")) { showInfo = false; usage() }
            Button(L10n.text("打开设置"), action: settings)
        }.font(.system(size: 11, weight: .light)).foregroundStyle(ReferenceStyle.secondary).padding(18).frame(width: 300)
    }

    private var quotaCard: some View {
        VStack(spacing: 0) {
            ForEach(Array(store.providers.enumerated()), id: \.element) { index, provider in
                if index > 0 { Rectangle().fill(ReferenceStyle.divider).frame(height: 1).padding(.horizontal, 12) }
                providerQuota(provider)
            }
        }.referenceCard()
    }

    private func providerQuota(_ provider: ProviderID) -> some View {
        let value = referencePreview ? ReferenceSample.snapshot(provider) : store.snapshot(provider)
        let titles = provider.quotaTitles
        let extraWindows = value.windows.filter { !titles.contains($0.title) }
        return VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                ProviderMark(name: provider.iconName)
                Text(provider.title).font(.system(size: 13, weight: .semibold))
                if let plan = value.plan {
                    Text(plan.uppercased()).font(.system(size: 9, weight: .semibold)).tracking(0.4)
                        .foregroundStyle(ReferenceStyle.secondary).padding(.horizontal, 6).padding(.vertical, 2)
                        .background(ReferenceStyle.text.opacity(0.08), in: Capsule())
                }
                Spacer()
                if value.windows.isEmpty, provider == .claude {
                    Button(L10n.text("连接"), action: settings).font(.system(size: 11, weight: .light)).foregroundStyle(ReferenceStyle.secondary)
                        .accessibilityLabel(L10n.text("连接 Claude Code"))
                }
            }.frame(height: 20).padding(.trailing, value.windows.isEmpty ? 16 : 56)
                .help([MeterFormat.updated(value.updatedAt), value.message.map(L10n.text)].compactMap { $0 }.joined(separator: " · "))
            VStack(spacing: 10) {
                ForEach(titles, id: \.self) { title in
                    if let window = value.windows.first(where: { $0.title == title }) {
                        quotaRow(provider, window)
                    } else {
                        unavailableQuotaRow(provider, title: title, snapshot: value)
                    }
                }
                ForEach(extraWindows) { window in quotaRow(provider, window) }
            }
        }.padding(.leading, 12).padding(.vertical, 14)
    }

    private func unavailableQuotaRow(_ provider: ProviderID, title: String, snapshot: ProviderSnapshot) -> some View {
        let disconnected = provider == .claude && !store.bridgeInstalled
        let state = disconnected ? "未接入" : store.refreshing ? "读取中" : snapshot.quotaReadFailed == true ? "待更新" : "未提供"
        let note = disconnected ? "连接后显示额度与重置时间" : "暂无重置时间"
        return HStack(spacing: 12) {
            VStack(spacing: 4) {
                HStack {
                    Text(L10n.text(title))
                    Spacer()
                    Text(L10n.text(state))
                }.frame(height: 16.5)
                SegmentedMeter(value: 0, color: ReferenceStyle.secondary)
                HStack(spacing: 4) {
                    ReferenceIcon(name: "reset", size: 11)
                    Text(L10n.text(note))
                    Spacer(minLength: 0)
                }.frame(height: 16.5)
            }.font(.system(size: 11, weight: .light)).foregroundStyle(ReferenceStyle.secondary)
            ReferenceIcon(name: "eye-slash", size: 14).opacity(0.3).frame(width: 44, height: 44)
        }.accessibilityElement(children: .ignore)
            .accessibilityLabel(L10n.format("%@ %@，%@，没有可显示的额度数值", provider.title, L10n.text(title), L10n.text(state)))
    }

    private func quotaRow(_ provider: ProviderID, _ window: LimitWindow) -> some View {
        let expired = !referencePreview && window.expired(at: store.displayNow)
        let remaining = Int(window.remaining.rounded())
        let amount = referencePreview ? window.remaining : store.quotaPercent(window)
        let displayTitle = referencePreview ? "剩余" : store.preferences.quotaDisplay.title
        let providerColor = provider == .codex ? Color(red: 51/255, green: 156/255, blue: 1) : provider == .claude ? Color(red: 217/255, green: 120/255, blue: 87/255) : ReferenceStyle.text
        let color = expired ? Color.gray : remaining < 20 ? Color(red: 1, green: 149/255, blue: 0) : providerColor
        let pinned = store.isPinned(provider, window)
        return HStack(spacing: 12) {
            VStack(spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text(L10n.text(window.title)).foregroundStyle(ReferenceStyle.secondary)
                    Spacer()
                    if expired { Text(L10n.text("待更新")).foregroundStyle(ReferenceStyle.secondary) }
                    else {
                        Text(L10n.text(displayTitle)).foregroundStyle(ReferenceStyle.secondary)
                        Text("\(Int(amount.rounded()))%").fontWeight(.semibold).monospacedDigit()
                    }
                }.font(.system(size: 11, weight: .light)).frame(height: 16.5)
                SegmentedMeter(value: amount, color: color).opacity(expired ? 0.45 : 1)
                    .accessibilityLabel(L10n.format("%@ %@，%@", provider.title, L10n.text(window.title), expired ? L10n.text("待更新") : "\(L10n.text(displayTitle)) \(Int(amount.rounded()))%"))
                HStack(spacing: 4) {
                    ReferenceIcon(name: "reset", size: 11)
                    Text(L10n.format("重置时间  %@", referencePreview ? ReferenceSample.reset(provider, window) : MeterFormat.reset(window.resetsAt, style: store.preferences.resetTimeStyle, now: store.displayNow)))
                    Spacer(minLength: 0)
                    if referencePreview, provider == .codex, window.title == "每周" {
                        ReferenceIcon(name: "counter", size: 11)
                        Text("2")
                    }
                }.font(.system(size: 11, weight: .light)).foregroundStyle(ReferenceStyle.secondary).frame(height: 16.5)
            }
            Button { store.togglePin(provider, window) } label: {
                ReferenceIcon(name: pinned ? "eye-fill" : "eye-slash", size: 14)
                    .opacity(pinned || colorScheme == .dark ? 1 : 0.5)
                    .frame(width: 44, height: 44).contentShape(Rectangle())
            }.help(L10n.format("在菜单栏显示或隐藏 %@ %@", provider.title, L10n.text(window.title)))
                .accessibilityLabel(L10n.format("切换菜单栏显示 %@ %@", provider.title, L10n.text(window.title)))
        }
    }

    private var usageCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(L10n.text("今天")).font(.system(size: 14, weight: .semibold))
                Text(displayDate(referencePreview ? "2026-10-19" : store.todayKey)).font(.system(size: 12, weight: .light)).foregroundStyle(ReferenceStyle.caption)
                Spacer()
                if showUsage {
                    Button(action: printUsage) { ReferenceIcon(name: "printer", size: 15).frame(width: 24, height: 20) }
                        .help(L10n.text("打印今日用量")).accessibilityLabel(L10n.text("打印今日用量"))
                } else if let today {
                    Text(MeterFormat.tokens(today.totalTokens)).font(.system(size: 13, weight: .medium, design: .rounded))
                }
                disclosure(expanded: $showUsage, label: "今日用量")
            }.frame(height: 20)
            if showUsage { usageDetails.padding(.top, 14) }
        }.padding(16).frame(minHeight: showUsage ? 361 : nil, alignment: .topLeading)
            .foregroundStyle(ReferenceStyle.statistic).referenceCard()
    }

    private var usageDetails: some View {
        let counts = today?.tokens
        return
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(today.map { MeterFormat.tokens($0.totalTokens) } ?? "—").font(.system(size: 28, weight: .semibold)).monospacedDigit().frame(height: 28)
                        Text(L10n.text("总 token")).font(.system(size: 12, weight: .light)).foregroundStyle(ReferenceStyle.caption).frame(height: 18)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 6) {
                        if let cost = today?.estimatedCostUSD {
                            Text(MeterFormat.cost(cost)).font(.system(size: 20, weight: .regular, design: .rounded)).monospacedDigit().frame(height: 20)
                            Text(L10n.text(!referencePreview && store.selected == .codex ? "参考费用" : "费用")).font(.system(size: 12, weight: .light)).foregroundStyle(ReferenceStyle.caption).frame(height: 18)
                        } else {
                            Text("—").font(.system(size: 20, weight: .regular, design: .rounded)).frame(height: 20)
                            Text(L10n.text("费用未提供")).font(.system(size: 12, weight: .light)).foregroundStyle(ReferenceStyle.caption).frame(height: 18)
                        }
                    }.help(L10n.text("参考费用按公开模型单价估算，非订阅账单"))
                }
                if let counts, counts.total > 0 {
                    TokenMix(counts: counts, referencePreview: referencePreview)
                } else {
                    Capsule().fill(ReferenceStyle.divider).frame(height: 8)
                        .accessibilityLabel(L10n.text(counts == nil ? "分类明细未提供" : "本日分类用量为零"))
                }
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 12, alignment: .leading), GridItem(.flexible(), alignment: .leading)], alignment: .leading, spacing: 12) {
                    legend("输入", value: counts?.input, color: ReferenceStyle.blue)
                    legend("输出", value: counts?.output, color: ReferenceStyle.teal)
                    legend("缓存读取", value: counts?.cacheRead, color: ReferenceStyle.orange)
                    legend("缓存写入", value: counts?.cacheWrite, color: ReferenceStyle.purple)
                    legend("推理", value: counts?.reasoning, color: ReferenceStyle.reasoning)
                }
                Rectangle().fill(ReferenceStyle.divider).frame(height: 1)
                if !usageGroups.isEmpty {
                    VStack(spacing: 12) {
                        ForEach(usageGroups) { group in
                            VStack(spacing: 6) {
                                HStack(spacing: 8) {
                                    ProviderMark(name: group.mark, size: 16, color: ReferenceStyle.statistic)
                                    Text(group.title).font(.system(size: 13, weight: .semibold))
                                    Spacer(minLength: 0)
                                    Text(MeterFormat.tokens(group.tokens) + (group.cost.map { " · " + MeterFormat.cost($0) } ?? ""))
                                        .font(.system(size: 12, weight: .light)).foregroundStyle(ReferenceStyle.caption).monospacedDigit()
                                }.frame(height: 20)
                                ForEach(group.models) { model in
                                    HStack(spacing: 8) {
                                        ProviderMark(name: group.mark, size: 12, color: ReferenceStyle.caption)
                                        Text(model.model).font(.system(size: 12, weight: .light, design: .monospaced)).lineLimit(1).help(model.model)
                                        Spacer(minLength: 0)
                                        Text(MeterFormat.tokens(model.tokens.total) + (!referencePreview && store.selected == .codex ? model.estimatedCostUSD.map { " · " + MeterFormat.cost($0) } ?? "" : ""))
                                            .font(.system(size: 12, weight: .light)).foregroundStyle(ReferenceStyle.caption).monospacedDigit()
                                    }.padding(.leading, 24).frame(height: 18)
                                }
                                if group.models.isEmpty {
                                    Text(L10n.text("当前数据源未提供模型明细"))
                                        .font(.system(size: 12, weight: .light)).foregroundStyle(ReferenceStyle.caption)
                                        .frame(maxWidth: .infinity, alignment: .leading).padding(.leading, 24).frame(height: 18)
                                }
                            }
                        }
                    }
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 8) {
                            ProviderMark(name: store.selected.iconName, size: 16, color: ReferenceStyle.statistic)
                            Text(store.selected.usageTitle).font(.system(size: 13, weight: .semibold))
                            Spacer()
                            Text(L10n.text(!supportsTokenHistory ? "未提供" : store.current.historyReadFailed == true ? "等待更新" : "今日暂无上报"))
                                .font(.system(size: 12, weight: .light)).foregroundStyle(ReferenceStyle.caption)
                        }.frame(height: 20)
                        Text(L10n.text(supportsTokenHistory ? "收到当日记录后显示用量和模型明细" : "当前接口未提供 Token、费用和模型明细"))
                            .font(.system(size: 12, weight: .light)).foregroundStyle(ReferenceStyle.caption)
                            .padding(.leading, 24).frame(height: 18)
                    }
                }
                if let today, !today.unpricedModels.isEmpty {
                    Text(L10n.text("部分模型或计价档位未知，费用未汇总")).font(.system(size: 11, weight: .light)).foregroundStyle(ReferenceStyle.caption)
                }
                if store.selected == .codex, store.current.historyIncomplete == true, !referencePreview {
                    Text(L10n.text("部分日志未读完整，以上为已读取的用量")).font(.system(size: 11, weight: .light)).foregroundStyle(ReferenceStyle.caption)
                }
            }
    }

    private var trendCard: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text(L10n.text("最近 7 天")).font(.system(size: 14, weight: .semibold))
                Spacer()
                Button { chartCost = !costMetric } label: {
                    Text(L10n.text(costMetric ? "费用（美元）" : "Token")).font(.system(size: 12, weight: .light)).foregroundStyle(ReferenceStyle.caption)
                }.disabled(!supportsTokenHistory)
                    .help(L10n.text(supportsTokenHistory ? "切换 Token 与参考费用" : "当前接口未提供 Token 和费用历史"))
                    .accessibilityLabel(L10n.text(supportsTokenHistory ? "切换趋势指标" : "Token 和费用历史未提供"))
                disclosure(expanded: $showTrend, label: "七天趋势")
            }.frame(height: 21)
            if showTrend {
                if trendPoints.isEmpty {
                    VStack(spacing: 0) {
                        ForEach(0..<4) { _ in
                            Spacer(minLength: 0)
                            Rectangle().fill(ReferenceStyle.divider).frame(height: 0.6)
                        }
                        Spacer(minLength: 0)
                    }.overlay {
                        Text(L10n.text(!supportsTokenHistory ? "当前接口未提供 Token 和费用历史" : costMetric ? "当前数据源未提供费用" : "有用量记录后显示趋势"))
                            .font(.system(size: 11, weight: .light)).foregroundStyle(ReferenceStyle.caption)
                            .padding(6).background(ReferenceStyle.card)
                    }.frame(height: 110).padding(.top, 12)
                } else {
                    ReferenceTrend(points: trendPoints, cost: costMetric, exactReference: referencePreview)
                        .frame(height: 110).padding(.top, 12)
                        .help(L10n.format("%@ / 7 天有记录；缺失日期留空，不按零计算", String(trendPoints.count)))
                }
            }
        }.padding(16).foregroundStyle(ReferenceStyle.statistic).referenceCard()
    }

    private var usageGroups: [UsageGroup] {
        if referencePreview { return ReferenceSample.groups }
        guard supportsTokenHistory, let today else { return [] }
        return [UsageGroup(mark: store.selected.iconName, title: store.selected.usageTitle, tokens: today.totalTokens, cost: today.estimatedCostUSD, models: today.models)]
    }
    private var trendPoints: [TrendDatum] {
        if referencePreview { return ReferenceSample.trend(cost: costMetric) }
        guard supportsTokenHistory else { return [] }
        var series = 0
        return store.lastSevenDays.enumerated().compactMap { index, date in
            guard let day = store.current.days.first(where: { $0.day == date }),
                  let amount = costMetric ? day.estimatedCostUSD : Double(day.totalTokens) else { series += 1; return nil }
            return TrendDatum(index: index, date: displayDate(date), amount: amount, series: series)
        }
    }
    private func displayDate(_ day: String) -> String {
        let parts = day.split(separator: "-")
        guard parts.count == 3, let month = Int(parts[1]), let date = Int(parts[2]) else { return day }
        return L10n.isEnglish ? "\(month)/\(date)" : "\(month)月\(date)日"
    }
    private func legend(_ title: String, value: Int64?, color: Color) -> some View {
        HStack(spacing: 7) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(L10n.text(title)).foregroundStyle(ReferenceStyle.caption)
            Text(value.map(MeterFormat.tokens) ?? "—").monospacedDigit()
        }.font(.system(size: 12, weight: .light)).frame(height: 18)
    }
    private func disclosure(expanded: Binding<Bool>, label: String) -> some View {
        Button { expanded.wrappedValue.toggle() } label: {
            Image(systemName: expanded.wrappedValue ? "chevron.up" : "chevron.down").font(.system(size: 8, weight: .medium))
                .foregroundStyle(ReferenceStyle.caption.opacity(0.8)).frame(width: 15, height: 20).contentShape(Rectangle())
        }.help(L10n.format(expanded.wrappedValue ? "收起%@" : "展开%@", L10n.text(label)))
            .accessibilityLabel(L10n.format(expanded.wrappedValue ? "收起%@" : "展开%@", L10n.text(label)))
    }
    private func iconButton(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            ReferenceIcon(name: symbol)
                .frame(width: 28, height: 28).background(ReferenceStyle.control.opacity(0.95), in: Circle())
                .overlay(Circle().stroke(ReferenceStyle.secondary.opacity(0.14), lineWidth: 0.5)).contentShape(Circle())
        }.help(L10n.text(label)).accessibilityLabel(L10n.text(label))
    }
    private func printUsage() {
        let view = NSHostingView(rootView: usageCard.frame(width: 356).padding(12).environment(\.colorScheme, .light))
        view.appearance = NSAppearance(named: .aqua)
        view.setFrameSize(view.fittingSize)
        let operation = NSPrintOperation(view: view)
        operation.showsPrintPanel = true
        operation.run()
    }
}

private struct UsageGroup: Identifiable {
    let mark: String
    let title: String
    let tokens: Int64
    let cost: Double?
    let models: [ModelUsage]
    var id: String { title }
}

struct SegmentedMeter: View {
    let value: Double
    let color: Color
    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 2) {
                ForEach(0..<58, id: \.self) { index in
                    Capsule().fill(color.opacity(Double(index) < (value / 100 * 58).rounded() ? 1 : 0.2))
                        .frame(width: max(1, (geometry.size.width - 114) / 58))
                }
            }
        }.frame(height: 16).accessibilityHidden(true)
    }
}

struct TokenMix: View {
    let counts: TokenCounts
    var referencePreview = false
    var body: some View {
        GeometryReader { geometry in
            let reasoning = referencePreview ? counts.reasoning : min(counts.output, counts.reasoning)
            let output = referencePreview ? counts.output : counts.output - reasoning
            let values: [(Int64, Color)] = [(counts.input, ReferenceStyle.blue), (output, ReferenceStyle.teal), (counts.cacheRead, ReferenceStyle.orange), (counts.cacheWrite, ReferenceStyle.purple), (reasoning, ReferenceStyle.reasoning)]
            let active = values.filter { $0.0 > 0 }
            let total = max(1, active.reduce(Int64(0)) { $0 + $1.0 })
            let available = geometry.size.width - CGFloat(max(0, active.count - 1))
            let raw = active.map { available * Double($0.0) / Double(total) }
            let minimum = min(3, available / CGFloat(max(1, active.count)))
            let shortfall = raw.reduce(CGFloat(0)) { $0 + max(0, minimum - $1) }
            let flexible = raw.reduce(CGFloat(0)) { $0 + max(0, $1 - minimum) }
            HStack(spacing: 1) {
                ForEach(0..<active.count, id: \.self) { index in
                    Rectangle().fill(active[index].1)
                        .frame(width: raw[index] < minimum ? minimum : raw[index] - shortfall * max(0, raw[index] - minimum) / max(1, flexible))
                }
            }.clipShape(Capsule())
        }.frame(height: 8).accessibilityHidden(true)
    }
}

private extension View {
    func referenceCard() -> some View {
        frame(maxWidth: .infinity, alignment: .leading).background(ReferenceStyle.card, in: RoundedRectangle(cornerRadius: 10))
    }
}

// Explicit screenshot-only fixture. Never used by the normal application or source readers.
private enum ReferenceSample {
    static let today = DayUsage(day: "2026-10-19", totalTokens: 132_284_210,
        tokens: TokenCounts(input: 670_700, output: 574_100, cacheRead: 128_400_000, cacheWrite: 2_569_000, reasoning: 70_410), estimatedCostUSD: 55)
    static let groups = [
        UsageGroup(mark: "claude", title: "Claude Code", tokens: 121_400_000, cost: 47.65, models: [.init(model: "claude-opus-5-5", tokens: .init(input: 121_400_000), estimatedCostUSD: 47.65)]),
        UsageGroup(mark: "grok", title: "Grok Build", tokens: 10_910_000, cost: 7.35, models: [.init(model: "grok-4.7-build-fast", tokens: .init(input: 10_910_000), estimatedCostUSD: 7.35)])
    ]
    static func snapshot(_ provider: ProviderID) -> ProviderSnapshot {
        guard provider == .codex || provider == .claude else { return .init(provider: provider) }
        return .init(provider: provider, plan: provider == .codex ? "PLUS" : "MAX", windows: [
            .init(id: provider == .codex ? "primary" : "five_hour", title: "5 小时", usedPercent: provider == .codex ? 64 : 83, resetsAt: nil),
            .init(id: provider == .codex ? "secondary" : "seven_day", title: "每周", usedPercent: provider == .codex ? 38 : 42, resetsAt: nil)
        ])
    }
    static func reset(_ provider: ProviderID, _ window: LimitWindow) -> String {
        L10n.text(window.title == "每周" ? (provider == .codex ? "3天后 18:30" : "4天后 09:00") : (provider == .codex ? "2小时14分钟后" : "1小时6分钟后"))
    }
    static func trend(cost: Bool) -> [TrendDatum] {
        [71.75, 67.91, 169.87, 200.25, 149.47, 125.26, 55].enumerated().map { index, amount in
            TrendDatum(index: index, date: L10n.isEnglish ? "10/\(13 + index)" : "10月\(13 + index)日", amount: cost ? amount : amount * 1_000_000, series: 0)
        }
    }
}
