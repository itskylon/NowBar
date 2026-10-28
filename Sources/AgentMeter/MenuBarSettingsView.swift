import SwiftUI
import AgentMeterCore

struct MenuBarSettingsView: View {
    @ObservedObject var store: MeterStore
    @State private var editingProvider = "all"

    private var visibleProviderOrder: [ProviderID] { store.preferences.menuBar.orderedProviders.filter { store.providers.contains($0) } }
    private var provider: ProviderID? { ProviderID(rawValue: editingProvider) }
    private var editedLayout: MenuBarLayout {
        provider.map { store.preferences.menuBar.layout(for: $0) } ?? store.preferences.menuBar.layout
    }
    private var usesGlobalLayout: Bool {
        guard let provider else { return false }
        return store.preferences.menuBar.providerLayouts[provider.rawValue] == nil
    }
    private var layout: Binding<MenuBarLayout> {
        Binding(get: { editedLayout }, set: { value in
            if let provider { store.preferences.menuBar.providerLayouts[provider.rawValue] = value }
            else { store.preferences.menuBar.layout = value }
        })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            preview
            layoutEditor
            providers
            appearance
            HStack(alignment: .center, spacing: 16) {
                caption("所有修改立即生效，并保存在这台 Mac。")
                Spacer(minLength: 8)
                Button(L10n.text("恢复默认菜单栏")) { store.preferences.menuBar = MenuBarPreferences() }
                    .accessibilityIdentifier("NowBarResetMenuLayout")
            }.padding(.horizontal, 2)
        }.font(.system(size: 12)).controlSize(.regular)
            .onChange(of: store.providers) { _, providers in
                if let provider, !providers.contains(provider) { editingProvider = "all" }
            }
    }

    private var preview: some View {
        WorkspaceCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    Label(L10n.text("实时预览"), systemImage: "menubar.rectangle")
                        .font(.system(size: 13, weight: .semibold))
                    Spacer(minLength: 8)
                    Text(L10n.text("使用本机真实数据")).font(.system(size: 11)).foregroundStyle(.secondary)
                }
                ScrollView(.horizontal) {
                    MenuBarPreview(store: store).fixedSize().padding(.horizontal, 12).padding(.vertical, 12)
                }
                .scrollIndicators(.automatic)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
                caption("预览与实际菜单栏使用相同的显示方式。未提供或已过期的数据以 — 显示。")
            }
        }
    }

    private var layoutEditor: some View {
        VStack(alignment: .leading, spacing: 9) {
            sectionTitle("显示内容")
            WorkspaceCard {
                VStack(alignment: .leading, spacing: 14) {
                    WorkspaceSettingRow(L10n.text("应用到")) {
                        Picker(L10n.text("应用到"), selection: $editingProvider) {
                            Text(L10n.text("所有服务的默认布局")).tag("all")
                            ForEach(store.providers) { Text($0.title).tag($0.rawValue) }
                        }.labelsHidden().accessibilityLabel(L10n.text("应用到"))
                    }
                    if let provider {
                        Divider()
                        WorkspaceSettingRow(L10n.text("跟随默认布局")) {
                            Toggle(L10n.text("跟随默认布局"), isOn: Binding(get: { usesGlobalLayout }, set: { follow in
                                if follow { store.preferences.menuBar.providerLayouts.removeValue(forKey: provider.rawValue) }
                                else { store.preferences.menuBar.providerLayouts[provider.rawValue] = store.preferences.menuBar.layout }
                            })).labelsHidden().accessibilityLabel(L10n.text("跟随默认布局")).toggleStyle(.switch).controlSize(.small)
                        }
                    }
                    Divider()
                    VStack(alignment: .leading, spacing: 14) {
                        WorkspaceSettingRow(L10n.text("菜单栏样式")) {
                            Picker(L10n.text("菜单栏样式"), selection: Binding(get: { editedLayout.style }, set: setStyle)) {
                                ForEach(MenuBarStyle.allCases, id: \.self) { Text(L10n.text($0.title)).tag($0) }
                            }.labelsHidden().accessibilityLabel(L10n.text("菜单栏样式"))
                                .accessibilityIdentifier("NowBarMenuStyle")
                        }
                        if editedLayout.style == .custom {
                            Divider()
                            componentEditor
                        } else {
                            VStack(alignment: .leading, spacing: 12) {
                                LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), alignment: .leading)], alignment: .leading, spacing: 8) {
                                    ForEach(Array(editedLayout.effectiveComponents.enumerated()), id: \.offset) { _, component in
                                        Label(L10n.text(component.title), systemImage: icon(component))
                                            .font(.system(size: 11)).foregroundStyle(.secondary)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                    }
                                }
                                HStack {
                                    Spacer(minLength: 0)
                                    Button(L10n.text("在此基础上自定义")) { setStyle(.custom) }
                                }
                            }
                        }
                    }.disabled(usesGlobalLayout)
                }
            }
            caption("可统一设置，也可为某一家服务单独选择布局。")
        }
    }

    private var componentEditor: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(L10n.text("菜单栏显示项")).font(.system(size: 12, weight: .medium))
                Spacer()
                Text("\(editedLayout.components.count) / 12")
                    .font(.system(size: 11)).monospacedDigit().foregroundStyle(.secondary)
            }
            VStack(spacing: 0) {
                ForEach(Array(editedLayout.components.enumerated()), id: \.offset) { index, component in
                    HStack(spacing: 10) {
                        Image(systemName: "line.3.horizontal").font(.system(size: 11)).foregroundStyle(.tertiary)
                        Label(L10n.text(component.title), systemImage: icon(component))
                            .frame(maxWidth: .infinity, alignment: .leading)
                        HStack(spacing: 8) {
                            Button { moveComponent(from: index, to: index - 1) } label: {
                                Image(systemName: "chevron.up").frame(width: 22, height: 24)
                            }.disabled(index == 0).help(L10n.text("上移"))
                                .accessibilityLabel(L10n.format("上移 %@", L10n.text(component.title)))
                            Button { moveComponent(from: index, to: index + 1) } label: {
                                Image(systemName: "chevron.down").frame(width: 22, height: 24)
                            }.disabled(index == editedLayout.components.count - 1).help(L10n.text("下移"))
                                .accessibilityLabel(L10n.format("下移 %@", L10n.text(component.title)))
                            Button { removeComponent(at: index) } label: {
                                Image(systemName: "minus.circle").frame(width: 22, height: 24)
                            }.help(L10n.text("移除显示项"))
                                .accessibilityLabel(L10n.format("移除 %@", L10n.text(component.title)))
                        }.buttonStyle(.borderless).foregroundStyle(.secondary)
                    }.padding(.horizontal, 12).padding(.vertical, 5)
                        .contentShape(Rectangle())
                        .draggable("NowBarComponent:\(index)")
                        .dropDestination(for: String.self) { values, _ in
                            guard let value = values.first, value.hasPrefix("NowBarComponent:"),
                                  let source = Int(value.dropFirst("NowBarComponent:".count)) else { return false }
                            moveComponent(from: source, to: index)
                            return true
                        }
                    if index < editedLayout.components.count - 1 { Divider().padding(.horizontal, 12) }
                }
                if editedLayout.components.isEmpty {
                    Text(L10n.text("点击下方项目添加显示内容")).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(12)
                }
            }.background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
            caption("拖动项目调整顺序，或使用右侧箭头。最多 12 项，换行最多一次。")
            Divider()
            ForEach(["身份", "用量", "时间", "费用", "结构"], id: \.self) { group in
                VStack(alignment: .leading, spacing: 8) {
                    Text(L10n.text(group)).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 145), alignment: .leading)], alignment: .leading, spacing: 8) {
                        ForEach(MenuBarComponent.allCases.filter { componentGroup($0) == group }, id: \.self) { component in
                            Button { addComponent(component) } label: {
                                Label(L10n.text(component.title), systemImage: icon(component))
                                    .font(.system(size: 11)).frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 2)
                            }.buttonStyle(.bordered).controlSize(.small)
                                .disabled(editedLayout.components.count >= 12 || (component == .lineBreak && editedLayout.components.contains(.lineBreak)))
                        }
                    }
                }
            }
            caption("Token 与参考费用来自本机日志；服务未提供的数据会显示 —，不会按零计算。")
        }
    }

    private var providers: some View {
        VStack(alignment: .leading, spacing: 9) {
            sectionTitle("服务与顺序")
            WorkspaceCard {
                VStack(alignment: .leading, spacing: 12) {
                    WorkspaceSettingRow(L10n.text("常显服务")) {
                        Picker(L10n.text("常显服务"), selection: $store.preferences.menuBar.displayScope) {
                            ForEach(MenuBarDisplayScope.allCases, id: \.self) { Text(L10n.text($0.title)).tag($0) }
                        }.labelsHidden().accessibilityLabel(L10n.text("常显服务"))
                    }
                    Divider()
                    ForEach(Array(visibleProviderOrder.enumerated()), id: \.element) { index, provider in
                        HStack(spacing: 12) {
                            ProviderMark(name: provider.iconName, size: 17, color: .primary).frame(width: 20)
                            Text(provider.title).font(.system(size: 12, weight: .medium))
                                .frame(maxWidth: .infinity, alignment: .leading)
                            if !store.snapshot(provider).windows.isEmpty {
                                Picker(L10n.text("常显额度"), selection: quotaSelection(provider)) {
                                    Text(L10n.text("不显示")).tag("")
                                    if selectedQuotaMissing(provider) {
                                        Text(L10n.text("所选额度暂未提供")).tag("__nowbar_unavailable_quota__")
                                    }
                                    ForEach(store.snapshot(provider).windows) { Text(L10n.text($0.title)).tag($0.id) }
                                }.labelsHidden().accessibilityLabel(provider.title + " " + L10n.text("常显额度"))
                                    .frame(width: 155)
                                    .disabled(!store.providers.contains(provider))
                            } else {
                                Text(L10n.text("额度暂未提供")).font(.system(size: 11)).foregroundStyle(.secondary)
                                    .frame(width: 155, alignment: .trailing)
                            }
                            Toggle(provider.title, isOn: Binding(get: { store.isMenuVisible(provider) }, set: {
                                store.setMenuVisible(provider, visible: $0)
                            })).labelsHidden().accessibilityLabel(provider.title).toggleStyle(.switch).controlSize(.small)
                                .disabled(!store.providers.contains(provider))
                            HStack(spacing: 4) {
                                Button { moveProvider(from: index, to: index - 1) } label: {
                                    Image(systemName: "chevron.up").frame(width: 20, height: 24)
                                }.disabled(index == 0).accessibilityLabel(L10n.format("上移 %@", provider.title))
                                Button { moveProvider(from: index, to: index + 1) } label: {
                                    Image(systemName: "chevron.down").frame(width: 20, height: 24)
                                }.disabled(index == visibleProviderOrder.count - 1)
                                    .accessibilityLabel(L10n.format("下移 %@", provider.title))
                            }.buttonStyle(.borderless).foregroundStyle(.secondary)
                        }.padding(.vertical, 4).contentShape(Rectangle())
                            .draggable("NowBarProvider:\(provider.rawValue)")
                            .dropDestination(for: String.self) { values, _ in
                                guard let value = values.first, value.hasPrefix("NowBarProvider:"),
                                      let id = ProviderID(rawValue: String(value.dropFirst("NowBarProvider:".count))),
                                      let source = visibleProviderOrder.firstIndex(of: id) else { return false }
                                moveProvider(from: source, to: index)
                                return true
                            }
                        if index < visibleProviderOrder.count - 1 { Divider() }
                    }
                }
            }
            caption("顺序可拖动调整。关闭这里只隐藏菜单栏显示，不会停止服务的数据读取。")
        }
    }

    private var appearance: some View {
        VStack(alignment: .leading, spacing: 9) {
            sectionTitle("外观与排版")
            WorkspaceCard {
                VStack(alignment: .leading, spacing: 12) {
                    WorkspaceSettingRow(L10n.text("大小")) {
                        Picker(L10n.text("大小"), selection: $store.preferences.menuBar.size) {
                            ForEach(MenuBarSize.allCases, id: \.self) { Text(L10n.text($0.title)).tag($0) }
                        }.labelsHidden().accessibilityLabel(L10n.text("大小"))
                    }
                    Divider()
                    WorkspaceSettingRow(L10n.text("间距")) {
                        Picker(L10n.text("间距"), selection: $store.preferences.menuBar.spacing) {
                            ForEach(MenuBarSpacing.allCases, id: \.self) { Text(L10n.text($0.title)).tag($0) }
                        }.labelsHidden().accessibilityLabel(L10n.text("间距"))
                    }
                    Divider()
                    WorkspaceSettingRow(L10n.text("垂直微调"), subtitle: L10n.text("双行布局会自动缩小字号；垂直微调仅用于单行。")) {
                        HStack(spacing: 10) {
                            Text("\(store.preferences.menuBar.verticalOffset) pt").monospacedDigit().foregroundStyle(.secondary)
                            Stepper(L10n.text("垂直微调"), value: $store.preferences.menuBar.verticalOffset, in: -3...3)
                                .labelsHidden().accessibilityLabel(L10n.text("垂直微调"))
                        }.fixedSize()
                    }
                    Divider()
                    appearanceToggle("等宽数字", selection: $store.preferences.menuBar.monospacedDigits)
                    Divider()
                    appearanceToggle("显示额度周期标签", selection: $store.preferences.menuBar.showPeriodLabels)
                    Divider()
                    appearanceToggle("按服务着色", selection: $store.preferences.menuBar.colorByProvider)
                    Divider()
                    appearanceToggle("低额度时使用提醒色", selection: $store.preferences.menuBar.lowQuotaColor)
                    caption("剩余不超过 20% 时显示提醒色，优先于服务颜色。其他时候跟随系统外观。")
                }
            }
        }
    }

    private func appearanceToggle(_ title: String, selection: Binding<Bool>) -> some View {
        WorkspaceSettingRow(L10n.text(title)) {
            Toggle(L10n.text(title), isOn: selection).labelsHidden().accessibilityLabel(L10n.text(title))
                .toggleStyle(.switch).controlSize(.small)
        }
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(L10n.text(title)).font(.system(size: 13, weight: .semibold)).padding(.horizontal, 2)
    }

    private func setStyle(_ style: MenuBarStyle) {
        var value = editedLayout
        if style == .custom { value.components = value.effectiveComponents }
        value.style = style
        layout.wrappedValue = value
    }
    private func addComponent(_ component: MenuBarComponent) {
        guard editedLayout.components.count < 12 else { return }
        var value = editedLayout
        value.components.append(component)
        layout.wrappedValue = value
    }
    private func removeComponent(at index: Int) {
        var value = editedLayout
        guard value.components.indices.contains(index) else { return }
        value.components.remove(at: index)
        layout.wrappedValue = value
    }
    private func moveComponent(from source: Int, to destination: Int) {
        var value = editedLayout
        guard value.components.indices.contains(source), value.components.indices.contains(destination), source != destination else { return }
        let component = value.components.remove(at: source)
        value.components.insert(component, at: destination)
        layout.wrappedValue = value
    }
    private func moveProvider(from source: Int, to destination: Int) {
        var order = visibleProviderOrder
        guard order.indices.contains(source), order.indices.contains(destination), source != destination else { return }
        let provider = order.remove(at: source)
        order.insert(provider, at: destination)
        var next = order.makeIterator()
        store.preferences.menuBar.providerOrder = store.preferences.menuBar.orderedProviders.map {
            store.providers.contains($0) ? next.next()! : $0
        }
    }
    private func quotaSelection(_ provider: ProviderID) -> Binding<String> {
        Binding(get: {
            store.snapshot(provider).windows.first { store.isPinned(provider, $0) }?.id
                ?? (store.isMenuVisible(provider) ? "__nowbar_unavailable_quota__" : "")
        }, set: { id in
            guard id != "__nowbar_unavailable_quota__" else { return }
            if id.isEmpty { store.setMenuVisible(provider, visible: false) }
            else if let window = store.snapshot(provider).windows.first(where: { $0.id == id }), !store.isPinned(provider, window) {
                store.togglePin(provider, window)
            }
        })
    }
    private func selectedQuotaMissing(_ provider: ProviderID) -> Bool {
        store.isMenuVisible(provider) && !store.snapshot(provider).windows.contains { store.isPinned(provider, $0) }
    }
    private func componentGroup(_ component: MenuBarComponent) -> String {
        switch component {
        case .icon, .providerName: return "身份"
        case .quotaPercent, .sessionPercent, .weeklyPercent, .usageBar, .todayTokens: return "用量"
        case .todayCost: return "费用"
        case .resetCountdown, .resetTime: return "时间"
        case .separator, .space, .lineBreak: return "结构"
        }
    }
    private func icon(_ component: MenuBarComponent) -> String {
        switch component {
        case .icon: return "app.dashed"
        case .providerName: return "textformat"
        case .quotaPercent, .sessionPercent, .weeklyPercent: return "percent"
        case .usageBar: return "chart.bar.fill"
        case .resetCountdown: return "timer"
        case .resetTime: return "clock"
        case .todayTokens: return "number"
        case .todayCost: return "dollarsign.circle"
        case .separator: return "circle.fill"
        case .space: return "space"
        case .lineBreak: return "return"
        }
    }
    private func caption(_ text: String) -> some View {
        Text(L10n.text(text)).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
}
