import SwiftUI
import AgentMeterCore

struct MeterSettingsView: View {
    @ObservedObject var store: MeterStore
    @Binding var tab: Int

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                WorkspacePageHeader(title: L10n.text("通用与服务设置"), subtitle: L10n.text("AI 用量，抬眼可见。")) {
                    Text(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.6.9")
                        .font(.system(size: 11, weight: .medium)).monospacedDigit().foregroundStyle(.secondary)
                        .padding(.horizontal, 9).padding(.vertical, 5)
                        .background(Color.primary.opacity(0.045), in: Capsule())
                }
                Picker(L10n.text("设置分类"), selection: $tab) {
                    Text(L10n.text("通用")).tag(0)
                    Text(L10n.text("服务接入")).tag(1)
                    Text(L10n.text("菜单栏")).tag(2)
                }
                .id(L10n.locale.identifier).labelsHidden().accessibilityLabel(L10n.text("设置分类"))
                .pickerStyle(.segmented).frame(maxWidth: 380, alignment: .leading)
                if tab == 0 {
                    MeterGeneralSettings(store: store, services: store.systemServices)
                        // Recreate native popups so their selected titles refresh with the language.
                        .id(L10n.locale.identifier)
                } else if tab == 2 {
                    MenuBarSettingsView(store: store).id(L10n.locale.identifier)
                } else {
                    serviceSettings
                }
            }
            .frame(maxWidth: WorkspaceStyle.settingsWidth, alignment: .leading)
            .padding(28).frame(maxWidth: .infinity)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .environment(\.locale, L10n.locale)
        .onAppear { store.rescanInstalledProviders(); store.checkBridge(); store.systemServices.refreshStatus() }
    }

    private var serviceSettings: some View {
        VStack(alignment: .leading, spacing: 16) {
            if store.providers.contains(.codex) {
                WorkspaceCard {
                    VStack(alignment: .leading, spacing: 12) {
                        providerHeading(.codex)
                        serviceCaption("额度使用已登录的 Codex CLI。Token、模型和参考费用读取本机日志，按本地日期统计，包含子任务；自动模式约每 5 秒更新。无需复制密钥。")
                        Link(L10n.text("查看 Codex 用量"), destination: URL(string: "https://chatgpt.com/codex/settings/usage")!)
                    }
                }
            }
            if store.providers.contains(.claude) {
                WorkspaceCard {
                    VStack(alignment: .leading, spacing: 12) {
                        providerHeading(.claude)
                        serviceCaption("自动读取这台 Mac 已登录的 Claude 桌面版账户，显示已用、剩余和重置时间。Free 套餐的 5 小时额度读取桌面缓存，随正常聊天更新。")
                        serviceCaption("Token、模型和参考费用读取本机 Claude Code / Cowork 会话日志。普通桌面聊天未提供每日精确 Token，不会根据额度百分比估算。")
                        Link(L10n.text("查看 Claude 用量"), destination: URL(string: "https://claude.ai/settings/usage")!)
                        Divider().padding(.vertical, 2)
                        Text(L10n.text("可选：Claude Code 状态栏接入")).font(.system(size: 12, weight: .semibold))
                        serviceCaption("未使用桌面版时，可通过 Claude Code 状态栏读取订阅额度，在 Claude 响应后更新。桌面版接入无需安装此桥接。")
                        serviceCaption("接入会备份设置并保留你原有的状态栏命令。可随时移除。项目级 statusLine 配置可能优先于此接入。")
                        HStack(spacing: 10) {
                            Button(store.bridgeInstalled ? L10n.text("移除 Claude Code 额度接入") : L10n.text("接入 Claude Code 额度")) { store.setBridge(enabled: !store.bridgeInstalled) }
                                .disabled(store.bridgeBusy || store.demo)
                            if store.bridgeBusy { ProgressView().controlSize(.small) }
                            else if store.bridgeInstalled {
                                Label(L10n.text("已接入"), systemImage: "checkmark.circle.fill").foregroundStyle(.teal).font(.system(size: 11))
                            }
                        }
                        if let message = store.bridgeMessage { serviceCaption(message) }
                    }
                }
            }
            if store.providers.contains(.grokBot) {
                WorkspaceCard {
                    VStack(alignment: .leading, spacing: 12) {
                        providerHeading(.grokBot)
                        serviceCaption("自动读取这台 Mac 已登录的 Grok Bot 账户，显示每周剩余额度和重置时间。请先在 Grok Bot 完成登录。")
                        serviceCaption("只读使用本机登录状态向 Grok 官方查询，不修改 Grok Bot 设置，不发起对话。当前接口未提供 Token、费用和历史明细。")
                        Link(L10n.text("Grok Bot 官方说明"), destination: URL(string: "https://docs.x.ai/grok-bot/overview")!)
                    }
                }
            }
            WorkspaceCard {
                VStack(alignment: .leading, spacing: 12) {
                    Label(L10n.text("显示与数据"), systemImage: "externaldrive").font(.system(size: 13, weight: .semibold))
                    serviceCaption("点击用量条旁的眼睛图标，选择菜单栏常显的额度。刷新频率和显示方式可在「通用」中调整。缺失数据不会按零计算。")
                    serviceCaption("Codex 和 Claude 参考费用按支持模型的公开 API 单价估算，不代表订阅额外账单。未知模型或计价档位会标注费用未提供。")
                    serviceCaption("数据保存在本机，不上传到 NowBar 服务器。Codex、Claude 桌面版和 Grok Bot 通过各自的官方服务读取额度。")
                    Divider()
                    HStack {
                        Button(L10n.text("打开本地数据目录"), action: store.openSupport)
                        Spacer(minLength: 12)
                        if store.providers.contains(.claude) {
                            Link(L10n.text("Claude 接入说明"), destination: URL(string: "https://code.claude.com/docs/en/statusline")!)
                        }
                    }
                }
            }
        }.font(.system(size: 12)).controlSize(.small)
    }

    private func providerHeading(_ provider: ProviderID) -> some View {
        HStack(spacing: 10) {
            ProviderMark(name: provider.iconName, size: 22, color: .primary)
            Text(provider.title).font(.system(size: 15, weight: .semibold))
        }
    }

    private func serviceCaption(_ text: String) -> some View {
        Text(L10n.text(text)).font(.system(size: 12)).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true).lineSpacing(3)
    }
}

private struct MeterGeneralSettings: View {
    @ObservedObject var store: MeterStore
    @ObservedObject var services: MeterSystemServices

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            WorkspaceCard {
                VStack(alignment: .leading, spacing: 12) {
                    sectionHeading("语言", icon: "globe")
                    WorkspaceSettingRow(L10n.text("应用语言")) {
                        Picker(L10n.text("应用语言"), selection: $store.preferences.language) {
                            ForEach(AppLanguage.allCases) { language in Text(language.title).tag(language) }
                        }.labelsHidden().accessibilityLabel(L10n.text("应用语言"))
                    }
                    caption("默认跟随系统，也可单独选择中文或英文；切换后立即生效。")
                }
            }
            WorkspaceCard {
                VStack(alignment: .leading, spacing: 12) {
                    sectionHeading("外观", icon: "paintpalette")
                    WorkspaceSettingRow(L10n.text("应用外观")) {
                        Picker(L10n.text("应用外观"), selection: $store.preferences.theme) {
                            ForEach(AppTheme.allCases) { theme in Text(L10n.text(theme.title)).tag(theme) }
                        }.labelsHidden().accessibilityLabel(L10n.text("应用外观"))
                            .accessibilityIdentifier("NowBarAppTheme")
                    }
                    caption("默认跟随系统，也可独立选择浅色或深色；切换后立即生效。")
                }
            }
            WorkspaceCard { MeterUpdateSettings(updates: store.updates) }
            WorkspaceCard {
                VStack(alignment: .leading, spacing: 12) {
                    sectionHeading("显示与刷新", icon: "arrow.triangle.2.circlepath")
                    WorkspaceSettingRow(L10n.text("自动刷新")) {
                        Picker(L10n.text("自动刷新"), selection: $store.preferences.refreshInterval) {
                            ForEach(RefreshInterval.allCases, id: \.self) { Text(L10n.text($0.title)).tag($0) }
                        }.labelsHidden().accessibilityLabel(L10n.text("自动刷新"))
                    }
                    Divider()
                    WorkspaceSettingRow(L10n.text("额度口径")) {
                        Picker(L10n.text("额度口径"), selection: $store.preferences.quotaDisplay) {
                            ForEach(QuotaDisplayMode.allCases, id: \.self) { Text(L10n.text($0.title)).tag($0) }
                        }.labelsHidden().accessibilityLabel(L10n.text("额度口径"))
                    }
                    Divider()
                    WorkspaceSettingRow(L10n.text("重置时间")) {
                        Picker(L10n.text("重置时间"), selection: $store.preferences.resetTimeStyle) {
                            ForEach(ResetTimeStyle.allCases, id: \.self) { Text(L10n.text($0.title)).tag($0) }
                        }.labelsHidden().accessibilityLabel(L10n.text("重置时间"))
                    }
                    caption("本机 Codex 日志约每 5 秒更新，账户额度按上述频率刷新。手动模式停止周期读取，倒计时继续更新；启动和检测到新安装的服务时仍会读取一次。")
                }
            }
            WorkspaceCard {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        sectionHeading("自动检测服务", icon: "square.stack.3d.up")
                        Spacer()
                        Button(L10n.text("重新检测"), action: store.rescanInstalledProviders)
                            .disabled(store.demo)
                    }
                    if store.availableProviders.isEmpty { caption("未检测到支持的应用") }
                    ForEach(Array(store.availableProviders.enumerated()), id: \.element) { index, provider in
                        if index > 0 { Divider() }
                        HStack(spacing: 10) {
                            ProviderMark(name: provider.iconName, size: 18, color: .primary)
                            Text(provider.title).font(.system(size: 12, weight: .medium))
                            Spacer(minLength: 16)
                            Toggle(provider.title, isOn: Binding(get: { store.providers.contains(provider) }, set: {
                                store.setProvider(provider, enabled: $0)
                            })).labelsHidden().accessibilityLabel(provider.title)
                                .accessibilityIdentifier("NowBarEnable" + provider.rawValue).fixedSize()
                        }.frame(minHeight: 26)
                    }
                    caption("检测到 Codex、Claude 后默认启用；Grok Bot 等其他服务需手动开启。未安装的服务不会显示，也无法启用。")
                    caption("安装或卸载后会自动更新，也可点击重新检测。你的开关选择会保留，重新检测或重启不会重置。")
                }
            }
            WorkspaceCard {
                VStack(alignment: .leading, spacing: 12) {
                    sectionHeading("额度提醒", icon: "bell")
                    WorkspaceSettingRow(L10n.text("低额度提醒")) {
                        Toggle(L10n.text("低额度提醒"), isOn: Binding(get: { store.preferences.lowQuotaAlerts }, set: store.setLowQuotaAlerts))
                            .labelsHidden().accessibilityLabel(L10n.text("低额度提醒")).fixedSize()
                    }
                    Divider()
                    WorkspaceSettingRow(L10n.text("额度重置提醒")) {
                        Toggle(L10n.text("额度重置提醒"), isOn: Binding(get: { store.preferences.resetAlerts }, set: store.setResetAlerts))
                            .labelsHidden().accessibilityLabel(L10n.text("额度重置提醒")).fixedSize()
                    }
                    caption("剩余 20%、10% 和耗尽时各提醒一次。重置提醒需读取到新周期和用量恢复；过期或读取失败的数据不触发提醒。")
                    HStack(alignment: .center, spacing: 12) {
                        if services.notificationsBusy { ProgressView().controlSize(.small) }
                        caption(services.notificationStatusText)
                        Spacer(minLength: 8)
                        Button(L10n.text("系统通知设置"), action: services.openNotificationSettings)
                    }
                }.disabled(store.demo || services.notificationsBusy)
            }
            WorkspaceCard {
                VStack(alignment: .leading, spacing: 10) {
                    WorkspaceSettingRow(L10n.text("登录时启动")) {
                        Toggle(L10n.text("登录时启动"), isOn: Binding(get: { services.loginEnabled }, set: services.setLaunchAtLogin))
                            .labelsHidden().accessibilityLabel(L10n.text("登录时启动")).fixedSize()
                    }
                    if let message = services.loginMessage { caption(message) }
                    if services.loginRequiresApproval {
                        HStack(spacing: 10) {
                            Button(L10n.text("打开登录项设置"), action: services.openLoginSettings)
                            Button(L10n.text("取消登记")) { services.setLaunchAtLogin(false) }
                        }
                    }
                }.disabled(store.demo)
            }
        }.font(.system(size: 12)).toggleStyle(.switch).controlSize(.small)
    }

    private func sectionHeading(_ title: String, icon: String) -> some View {
        Label(L10n.text(title), systemImage: icon).font(.system(size: 13, weight: .semibold)).padding(.bottom, 2)
    }

    private func caption(_ text: String) -> some View {
        Text(L10n.text(text)).font(.system(size: 11)).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true).lineSpacing(2)
    }
}

private struct MeterUpdateSettings: View {
    @ObservedObject var updates: AppUpdateController

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Label(L10n.text("软件更新"), systemImage: "arrow.down.circle").font(.system(size: 13, weight: .semibold))
                    Text(L10n.format("当前版本 %@", updates.currentVersion)).font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 12)
                if updates.checking { ProgressView().controlSize(.small) }
                Button(L10n.text(updates.checking ? "正在检查更新…" : "检查更新…")) { updates.checkManually() }
                    .disabled(updates.checking || !updates.enabled).accessibilityIdentifier("NowBarCheckForUpdates")
            }
            if let result = updates.result {
                switch result {
                case .available(let release): caption(L10n.format("新版本 %@ 可供下载。", release.version))
                case .upToDate: caption(L10n.text("当前已是最新版本"))
                case .failed(let message): caption(L10n.text(message))
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
        Text(text).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).lineSpacing(2)
    }
}
