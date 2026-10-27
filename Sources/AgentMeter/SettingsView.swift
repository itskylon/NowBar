import SwiftUI
import AgentMeterCore

struct MeterSettingsView: View {
    @ObservedObject var store: MeterStore
    @Binding var tab: Int
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(L10n.text("通用与服务设置")).font(.system(size: 22, weight: .semibold))
                        Text(L10n.text("AI 用量，抬眼可见。")).font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.6.5")
                        .font(.system(size: 11)).foregroundStyle(.tertiary)
                }
                Picker(L10n.text("设置分类"), selection: $tab) {
                    Text(L10n.text("通用")).tag(0)
                    Text(L10n.text("服务接入")).tag(1)
                }.id(L10n.locale.identifier).labelsHidden().accessibilityLabel(L10n.text("设置分类")).pickerStyle(.segmented).frame(maxWidth: 350)
                if tab == 0 {
                    MeterGeneralSettings(store: store, services: store.systemServices)
                        // Recreate native popups so their selected titles refresh with the language.
                        .id(L10n.locale.identifier)
                } else {
                    VStack(alignment: .leading, spacing: 9) {
                        Label("Codex", systemImage: "circle.hexagongrid").font(.headline)
                        Text(L10n.text("额度使用已登录的 Codex CLI。Token、模型和参考费用读取本机日志，按本地日期统计，包含子任务；自动模式约每 5 秒更新。无需复制密钥。"))
                            .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        Link(L10n.text("查看 Codex 用量"), destination: URL(string: "https://chatgpt.com/codex/settings/usage")!).font(.system(size: 11))
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        Label("Claude Code", systemImage: "asterisk").font(.headline)
                        Text(L10n.text("Token 自动从本机日志统计。订阅额度需接入 Claude Code 官方状态栏，在 Claude 响应后更新；未使用 Claude 时会显示上次采集时间。"))
                            .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        Text(L10n.text("接入会备份设置并保留你原有的状态栏命令。可随时移除。项目级 statusLine 配置可能优先于此接入。"))
                            .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        HStack {
                            Button(store.bridgeInstalled ? L10n.text("移除 Claude 额度接入") : L10n.text("接入 Claude 额度")) { store.setBridge(enabled: !store.bridgeInstalled) }
                                .disabled(store.bridgeBusy || store.demo)
                            if store.bridgeBusy { ProgressView().controlSize(.small) }
                            else if store.bridgeInstalled { Label(L10n.text("已接入"), systemImage: "checkmark.circle.fill").foregroundStyle(.teal).font(.system(size: 11)) }
                        }
                        if let message = store.bridgeMessage { Text(L10n.text(message)).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                    }
                    VStack(alignment: .leading, spacing: 9) {
                        HStack(spacing: 6) {
                            ProviderMark(name: ProviderID.grokBot.iconName, size: 16, color: .primary)
                            Text(ProviderID.grokBot.title)
                        }.font(.headline)
                        Text(L10n.text("自动读取这台 Mac 已登录的 Grok Bot 账户，显示每周剩余额度和重置时间。请先在 Grok Bot 完成登录。"))
                            .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        Text(L10n.text("只读使用本机登录状态向 Grok 官方查询，不修改 Grok Bot 设置，不发起对话。当前接口未提供 Token、费用和历史明细。"))
                            .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        Link(L10n.text("Grok Bot 官方说明"), destination: URL(string: "https://docs.x.ai/grok-bot/overview")!).font(.system(size: 11))
                    }
                    Divider()
                    VStack(alignment: .leading, spacing: 8) {
                        Text(L10n.text("显示与数据")).font(.headline)
                        Text(L10n.text("点击用量条旁的眼睛图标，选择菜单栏常显的额度。刷新频率和显示方式可在「通用」中调整。缺失数据不会按零计算。"))
                        Text(L10n.text("Codex 和 Claude 参考费用按支持模型的公开 API 单价估算，不代表订阅额外账单。未知模型或计价档位会标注费用未提供。"))
                        Text(L10n.text("数据保存在本机，不上传到NowBar服务器。Codex 和 Grok Bot 通过各自的官方服务读取额度。"))
                    }.font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Button(L10n.text("打开本地数据目录"), action: store.openSupport)
                        Spacer()
                        Link(L10n.text("Claude 接入说明"), destination: URL(string: "https://code.claude.com/docs/en/statusline")!)
                    }.font(.system(size: 11))
                }
            }.frame(maxWidth: 780, alignment: .leading).padding(28).frame(maxWidth: .infinity, alignment: .leading)
        }.background(Color(nsColor: .windowBackgroundColor)).environment(\.locale, L10n.locale).onAppear { store.checkBridge(); store.systemServices.refreshStatus() }
    }
}

private struct MeterGeneralSettings: View {
    @ObservedObject var store: MeterStore
    @ObservedObject var services: MeterSystemServices

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 12) {
                Text(L10n.text("语言")).font(.headline)
                Picker(L10n.text("应用语言"), selection: $store.preferences.language) {
                    ForEach(AppLanguage.allCases) { language in
                        Text(language.title).tag(language)
                    }
                }
                caption("默认跟随系统，也可单独选择中文或英文；切换后立即生效。")
            }
            Divider()
            MeterUpdateSettings(updates: store.updates)
            Divider()
            VStack(alignment: .leading, spacing: 12) {
                Text(L10n.text("显示与刷新")).font(.headline)
                Picker(L10n.text("自动刷新"), selection: $store.preferences.refreshInterval) {
                    ForEach(RefreshInterval.allCases, id: \.self) { Text(L10n.text($0.title)).tag($0) }
                }
                Picker(L10n.text("额度口径"), selection: $store.preferences.quotaDisplay) {
                    ForEach(QuotaDisplayMode.allCases, id: \.self) { Text(L10n.text($0.title)).tag($0) }
                }
                Picker(L10n.text("重置时间"), selection: $store.preferences.resetTimeStyle) {
                    ForEach(ResetTimeStyle.allCases, id: \.self) { Text(L10n.text($0.title)).tag($0) }
                }
                caption("本机 Codex 日志约每 5 秒更新，账户额度按上述频率刷新。手动模式停止周期读取，倒计时继续更新；启动和重新启用服务仍会读取一次。")
            }
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                Text(L10n.text("启用的服务")).font(.headline)
                ForEach(ProviderID.allCases) { provider in
                    Toggle(provider.title, isOn: Binding(get: { store.preferences.enabledProviders.contains(provider) },
                        set: { store.setProvider(provider, enabled: $0) }))
                }.toggleStyle(.switch)
                caption(store.providerMessage ?? L10n.text("关闭后隐藏该服务并停止读取，保留本机历史与菜单栏选择。至少保留一个服务。"))
            }
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                Text(L10n.text("额度提醒")).font(.headline)
                Toggle(L10n.text("低额度提醒"), isOn: Binding(get: { store.preferences.lowQuotaAlerts }, set: store.setLowQuotaAlerts))
                Toggle(L10n.text("额度重置提醒"), isOn: Binding(get: { store.preferences.resetAlerts }, set: store.setResetAlerts))
                caption("剩余 20%、10% 和耗尽时各提醒一次。重置提醒需读取到新周期和用量恢复；过期或读取失败的数据不触发提醒。")
                if services.notificationsBusy { ProgressView().controlSize(.small) }
                caption(services.notificationStatusText)
                Button(L10n.text("系统通知设置"), action: services.openNotificationSettings).font(.system(size: 11))
            }.toggleStyle(.switch).disabled(store.demo || services.notificationsBusy)
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                Toggle(L10n.text("登录时启动"), isOn: Binding(get: { services.loginEnabled }, set: services.setLaunchAtLogin))
                    .font(.headline).toggleStyle(.switch)
                if let message = services.loginMessage { caption(message) }
                if services.loginRequiresApproval {
                    HStack {
                        Button(L10n.text("打开登录项设置"), action: services.openLoginSettings)
                        Button(L10n.text("取消登记")) { services.setLaunchAtLogin(false) }
                    }.font(.system(size: 11))
                }
            }.disabled(store.demo)
        }.font(.system(size: 12))
    }

    private func caption(_ text: String) -> some View {
        Text(L10n.text(text)).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
}

private struct MeterUpdateSettings: View {
    @ObservedObject var updates: AppUpdateController

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L10n.text("软件更新")).font(.headline)
            HStack(spacing: 10) {
                Text(L10n.format("当前版本 %@", updates.currentVersion)).foregroundStyle(.secondary)
                Spacer()
                if updates.checking { ProgressView().controlSize(.small) }
                Button(L10n.text(updates.checking ? "正在检查更新…" : "检查更新…")) {
                    updates.checkManually()
                }
                .disabled(updates.checking || !updates.enabled)
                .accessibilityIdentifier("NowBarCheckForUpdates")
            }
            if let result = updates.result {
                switch result {
                case .available(let release):
                    caption(L10n.format("新版本 %@ 可供下载。", release.version))
                case .upToDate:
                    caption(L10n.text("当前已是最新版本"))
                case .failed(let message):
                    caption(L10n.text(message))
                }
            }
            if let checked = updates.lastChecked {
                HStack(spacing: 4) {
                    Text(L10n.text("上次检查"))
                    Text(checked, format: .dateTime.year().month().day().hour().minute())
                }.font(.system(size: 11)).foregroundStyle(.secondary)
            }
            caption(L10n.text("启动时和运行期间每天自动检查更新，有新版本时弹窗提醒。"))
            caption(L10n.text("下载后退出 NowBar，并用新版应用替换原应用。"))
        }
    }

    private func caption(_ text: String) -> some View {
        Text(text).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
}
