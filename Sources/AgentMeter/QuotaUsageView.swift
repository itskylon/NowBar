import AppKit
import SwiftUI
import AgentMeterCore

struct QuotaUsageView: View {
    @ObservedObject var store: MeterStore
    var provider: ProviderID?
    var settings: () -> Void

    private var providers: [ProviderID] {
        store.providers.filter { provider == nil || $0 == provider }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "info.circle").foregroundStyle(Color.accentColor)
                    Text(L10n.text("服务提供使用比例与重置时间，未提供可换算的总 Token 额度或剩余 Token 数。Token 明细与参考费用请查看“用量与支出”。"))
                        .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }.padding(15).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.accentColor.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
                if providers.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "gauge.with.dots.needle.33percent").font(.system(size: 28)).foregroundStyle(.tertiary)
                        Text(L10n.text("所选服务尚未启用")).font(.system(size: 14, weight: .medium))
                        Button(L10n.text("前往服务设置"), action: settings)
                    }.frame(maxWidth: .infinity).padding(.vertical, 60)
                } else {
                    ForEach(providers) { provider in providerCard(provider) }
                }
                Text(L10n.format("重置时间按电脑当前时区显示：%@。刷新读取已启用服务的最新额度；Claude 快照随 Claude Code 会话活动更新。", TimeZone.current.identifier))
                    .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }.padding(28).frame(maxWidth: .infinity, alignment: .leading)
        }.background(Color(nsColor: .windowBackgroundColor)).environment(\.locale, L10n.locale)
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 5) {
                Text(L10n.text("额度用量")).font(.system(size: 22, weight: .semibold))
                Text(L10n.text("同时查看各个额度窗口的已用、剩余和重置时间。"))
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Spacer()
            Button(action: store.refresh) {
                HStack(spacing: 5) {
                    if store.refreshing { ProgressView().controlSize(.small) }
                    else { Image(systemName: "arrow.clockwise") }
                    Text(store.refreshing ? L10n.text("刷新中") : L10n.text("刷新"))
                }
            }.disabled(store.refreshing).accessibilityLabel(L10n.text("刷新订阅额度"))
        }
    }

    private func providerCard(_ provider: ProviderID) -> some View {
        let snapshot = store.snapshot(provider)
        let windows = QuotaUsage.windows(for: snapshot, bridgeInstalled: store.bridgeInstalled,
                                         refreshing: store.refreshing, now: store.displayNow)
        let note = provider == .grokBot ? snapshot.quotaMessage ?? snapshot.message : snapshot.quotaMessage
        return VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 11) {
                ProviderMark(name: provider.iconName, size: 25, color: .primary)
                VStack(alignment: .leading, spacing: 7) {
                    HStack(spacing: 9) {
                        Text(provider.title).font(.system(size: 17, weight: .semibold))
                        if let plan = snapshot.plan, !plan.isEmpty {
                            Text(plan.uppercased()).font(.system(size: 10, weight: .semibold)).tracking(0.4)
                                .foregroundStyle(.secondary).padding(.horizontal, 7).padding(.vertical, 3)
                                .background(Color.primary.opacity(0.06), in: Capsule())
                        } else {
                            Text(L10n.text("套餐暂未提供")).font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                    }
                    Text(L10n.text("数据来源：") + source(provider)).font(.system(size: 11)).foregroundStyle(.secondary)
                    Text(snapshot.updatedAt.map { L10n.text("采样时间：") + absolute($0) } ?? L10n.text("采样时间暂未提供"))
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                if provider == .claude, !store.bridgeInstalled || snapshot.windows.isEmpty {
                    Button(store.bridgeInstalled ? L10n.text("查看接入设置") : L10n.text("接入 Claude 额度"), action: settings)
                        .font(.system(size: 11)).accessibilityLabel(L10n.text("打开 Claude 额度接入设置"))
                }
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 16, alignment: .top), count: min(2, windows.count)), spacing: 16) {
                ForEach(windows) { window in quotaWindow(window, provider: provider) }
            }
            if let note, !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Label(L10n.text(note), systemImage: "info.circle").font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if windows.contains(where: { $0.state == .saved }) {
                Label(L10n.text("以上保留了上次获取的额度，刷新后可确认最新数值。"), systemImage: "clock.arrow.circlepath")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            if provider == .claude, windows.contains(where: { $0.state == .disconnected }) {
                Text(L10n.text("在设置中接入后，Claude Code 完成回复时会更新额度快照。"))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            if provider == .grokBot, !snapshot.sourceNote.isEmpty {
                Text(L10n.text(snapshot.sourceNote)).font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }.padding(20)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.05), lineWidth: 1))
    }

    private func quotaWindow(_ quota: QuotaUsageWindow, provider: ProviderID) -> some View {
        let color = (quota.remainingPercent ?? 100) < 20 ? Color.orange : providerColor(provider)
        let displayMode = store.preferences.quotaDisplay
        let meterValue = displayMode == .remaining ? quota.remainingPercent : quota.usedPercent
        return VStack(alignment: .leading, spacing: 17) {
            HStack(spacing: 8) {
                Text(L10n.text(quota.title)).font(.system(size: 13, weight: .semibold))
                Text(L10n.text(quota.state.title)).font(.system(size: 10, weight: .medium))
                    .foregroundStyle(stateColor(quota.state)).padding(.horizontal, 7).padding(.vertical, 3)
                    .background(stateColor(quota.state).opacity(0.1), in: Capsule())
                Spacer(minLength: 0)
                if let window = quota.window {
                    let pinned = store.isPinned(provider, window)
                    Button { store.togglePin(provider, window) } label: {
                        Image(systemName: pinned ? "pin.fill" : "pin")
                            .font(.system(size: 12)).frame(width: 28, height: 28).contentShape(Rectangle())
                    }.buttonStyle(.plain).foregroundStyle(pinned ? Color.accentColor : Color.secondary)
                        .help(pinned ? L10n.text("从菜单栏取消固定") : L10n.text("固定到菜单栏"))
                        .accessibilityLabel("\(pinned ? L10n.text("取消固定") : L10n.text("固定到菜单栏")) \(provider.title) \(L10n.text(quota.title))")
                }
            }.frame(minHeight: 28)
            HStack(alignment: .firstTextBaseline, spacing: 30) {
                quotaMetric(L10n.text("已用"), value: quota.usedPercent, color: .primary)
                quotaMetric(L10n.text("剩余"), value: quota.remainingPercent, color: quota.remainingPercent == nil ? .secondary : color)
                Spacer(minLength: 0)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(L10n.text(displayMode.title) + L10n.text("比例")).font(.system(size: 10)).foregroundStyle(.secondary)
                if let meterValue {
                    quotaMeter(value: meterValue, color: color).opacity(quota.state == .saved ? 0.7 : 1)
                } else {
                    RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(0.05)).frame(height: 16)
                        .overlay(Text(L10n.text("暂无可显示的额度比例")).font(.system(size: 9)).foregroundStyle(.tertiary))
                        .accessibilityHidden(true)
                }
            }
            Divider()
            VStack(alignment: .leading, spacing: 6) {
                Label(MeterFormat.reset(quota.window?.resetsAt, style: .countdown, now: store.displayNow), systemImage: "arrow.counterclockwise")
                    .font(.system(size: 11, weight: .medium))
                if let reset = quota.window?.resetsAt {
                    Text(absolute(reset) + L10n.text(" · 电脑时区")).font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }.fixedSize(horizontal: false, vertical: true)
        }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 9))
            .accessibilityElement(children: .contain)
    }

    private func quotaMeter(value: Double, color: Color) -> some View {
        GeometryReader { geometry in
            let count = max(1, Int(geometry.size.width / 5))
            let width = max(1, (geometry.size.width - CGFloat(count - 1) * 2) / CGFloat(count))
            HStack(spacing: 2) {
                ForEach(0..<count, id: \.self) { index in
                    Capsule().fill(color.opacity(Double(index) < (value / 100 * Double(count)).rounded() ? 1 : 0.2))
                        .frame(width: width)
                }
            }
        }.frame(height: 16).accessibilityHidden(true)
    }

    private func quotaMetric(_ title: String, value: Double?, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 11)).foregroundStyle(.secondary)
            Text(value.map { "\(Int($0.rounded()))%" } ?? "—")
                .font(.system(size: 26, weight: .semibold, design: .rounded)).monospacedDigit().foregroundStyle(color)
                .accessibilityLabel(title + (value.map { " \(Int($0.rounded()))%" } ?? L10n.text("暂不可用")))
        }
    }

    private func source(_ provider: ProviderID) -> String {
        switch provider {
        case .codex: L10n.text("Codex 账户额度")
        case .claude: L10n.text("Claude Code 官方状态栏快照")
        case .grokBot: L10n.text("Grok Bot 账户用量")
        }
    }
    private func providerColor(_ provider: ProviderID) -> Color {
        switch provider {
        case .codex: Color(red: 51/255, green: 156/255, blue: 1)
        case .claude: Color(red: 217/255, green: 120/255, blue: 87/255)
        case .grokBot: .teal
        }
    }
    private func stateColor(_ state: QuotaUsageState) -> Color {
        switch state {
        case .current: .green
        case .saved, .expired: .orange
        case .failed: .red
        case .loading: .accentColor
        case .unavailable, .disconnected: .secondary
        }
    }
    private func absolute(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = L10n.locale
        formatter.timeZone = .current
        formatter.dateFormat = L10n.isEnglish ? "MMM d, yyyy HH:mm" : "yyyy年M月d日 HH:mm"
        return formatter.string(from: date)
    }
}
