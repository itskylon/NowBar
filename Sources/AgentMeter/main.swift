import AppKit
import SwiftUI
import Combine
import AgentMeterCore

private func requestedProvider() -> ProviderID? {
    guard let index = CommandLine.arguments.firstIndex(of: "--provider"), CommandLine.arguments.count > index + 1 else { return nil }
    return ProviderID(rawValue: CommandLine.arguments[index + 1])
}

@MainActor
final class MeterAppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var store: MeterStore!
    private var statusItem: NSStatusItem!
    private let summary = MeterStatusSummary(frame: .zero)
    private let panel = MeterPanel(contentRect: NSRect(x: 0, y: 0, width: 380, height: 600), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    private var usageWindow: NSWindow?
    private var changes: AnyCancellable?
    private var updateChanges: AnyCancellable?
    private var appliedTheme: AppTheme?
    private var wakeObserver: NSObjectProtocol?
    private var showingUpdateAlert = false
    private lazy var shortcuts = MeterShortcutMenu(
        refresh: { [weak self] in self?.store.refresh() },
        settings: { [weak self] in self?.openSettings() },
        usage: { [weak self] in self?.openUsage() },
        about: { [weak self] in self?.showAbout() },
        checkUpdates: { [weak self] in self?.store.updates.checkManually() },
        quit: { NSApp.terminate(nil) },
        openURL: { NSWorkspace.shared.open($0) })
    private var localMouseMonitor: Any?
    private var globalMouseMonitor: Any?
    private var resignObserver: NSObjectProtocol?
    private var screenObserver: NSObjectProtocol?
    private var openPanelObserver: NSObjectProtocol?
    private let inspectionMode = CommandLine.arguments.contains("--show")

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.applicationIconImage = AppBrand.icon
        store = MeterStore(demo: CommandLine.arguments.contains("--demo"))
        updateTheme()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.title = ""
            button.image = nil
            button.target = self
            button.action = #selector(statusButtonClicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.toolTip = AppBrand.name + " · " + L10n.text("AI 用量")
            button.addSubview(summary)
        }
        panel.title = L10n.format("%@ 用量", AppBrand.name)
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isFloatingPanel = true
        panel.level = .popUpMenu
        panel.hidesOnDeactivate = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        let hosting = NSHostingView(rootView: DashboardView(store: store, maxHeight: panelHeightLimit, onSizeChange: { [weak self] size in
            DispatchQueue.main.async { self?.resizePanel(size) }
        }, settings: { [weak self] in self?.openSettings() }, usage: { [weak self] in self?.openUsage() },
           about: { [weak self] in self?.showAbout() }))
        panel.contentView = hosting
        changes = store.objectWillChange.sink { [weak self] in
            DispatchQueue.main.async {
                self?.updateTheme()
                self?.updateStatusLabel()
            }
        }
        updateChanges = store.updates.objectWillChange.sink { [weak self] in
            DispatchQueue.main.async { self?.updateApplicationMenu() }
        }
        store.updates.onPresentation = { [weak self] result in
            DispatchQueue.main.async { self?.presentUpdate(result) }
        }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.store.updates.checkAutomaticallyIfDue() }
        }
        updateStatusLabel()
        installDismissalObservers()
        openPanelObserver = NotificationCenter.default.addObserver(forName: Notification.Name("AgentMeterOpenPanel"), object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.showPanel() }
        }
        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.panel.isVisible else { return }
                self.positionPanel()
            }
        }
        if CommandLine.arguments.contains("--settings") {
            DispatchQueue.main.async { [weak self] in self?.openSettings() }
        } else if CommandLine.arguments.contains("--usage") || CommandLine.arguments.contains("--quota") {
            DispatchQueue.main.async { [weak self] in self?.openUsage() }
        } else if inspectionMode || CommandLine.arguments.contains("--open") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in self?.togglePanel() }
        }
        store.updates.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        store?.updates.stop()
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
        if let localMouseMonitor { NSEvent.removeMonitor(localMouseMonitor) }
        if let globalMouseMonitor { NSEvent.removeMonitor(globalMouseMonitor) }
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        if let openPanelObserver { NotificationCenter.default.removeObserver(openPanelObserver) }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        store?.systemServices.refreshStatus()
        store?.updates.checkAutomaticallyIfDue()
    }

    private func updateTheme() {
        guard appliedTheme != store.preferences.theme else { return }
        appliedTheme = store.preferences.theme
        AppThemeController.apply(store.preferences.theme)
    }

    private func updateStatusLabel() {
        panel.title = L10n.format("%@ 用量", AppBrand.name)
        usageWindow?.title = AppBrand.name
        let entries = MenuBarPresentation.entries(for: store)
        statusItem.button?.toolTip = entries.isEmpty ? AppBrand.name + " · " + L10n.text("AI 用量") : entries.map(\.toolTip).joined(separator: "\n\n")
        statusItem.length = summary.update(entries: entries, fallback: NSImage(systemSymbolName: "chart.bar.xaxis", accessibilityDescription: AppBrand.name),
                                          appearance: MenuBarPresentation.appearance(store.preferences.menuBar))
        summary.frame.origin.y = max(0, ((statusItem.button?.bounds.height ?? 22) - 22) / 2)
        let accessibleSummary = entries.map(\.toolTip).joined(separator: "; ")
        statusItem.button?.setAccessibilityLabel(AppBrand.name + (accessibleSummary.isEmpty ? "" : ": " + accessibleSummary))
        statusItem.button?.setAccessibilityIdentifier("AgentMeterStatusItem")
        if panel.isVisible { positionPanel() }
        updateApplicationMenu()
    }

    private func updateApplicationMenu() {
        let menu = NSMenu()
        let appItem = NSMenuItem(title: AppBrand.name, action: nil, keyEquivalent: "")
        appItem.submenu = shortcuts.build(version: store.updates.currentVersion, checking: store.updates.checking, refreshing: store.refreshing)
        menu.addItem(appItem)
        NSApp.mainMenu = menu
    }

    @objc private func statusButtonClicked() {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            guard let button = statusItem.button else { return }
            panel.orderOut(nil)
            let menu = shortcuts.build(version: store.updates.currentVersion, checking: store.updates.checking, refreshing: store.refreshing)
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.minY - 3), in: button)
        } else {
            if let event, let entry = summary.entry(at: summary.convert(event.locationInWindow, from: nil)),
               let provider = ProviderID(rawValue: entry.id) { store.selected = provider }
            togglePanel()
        }
    }

    private func presentUpdate(_ result: AppUpdatePresentation) {
        guard !showingUpdateAlert else { return }
        showingUpdateAlert = true
        defer { showingUpdateAlert = false }
        panel.orderOut(nil)
        NSApp.activate(ignoringOtherApps: true)
        let response = MeterUpdateAlerts.make(result, currentVersion: store.updates.currentVersion).runModal()
        if case .available(let release) = result, response == .alertFirstButtonReturn {
            if !NSWorkspace.shared.open(release.url) {
                _ = MeterUpdateAlerts.make(.failed("下载页面未能打开，请稍后重试。"), currentVersion: store.updates.currentVersion).runModal()
            }
        }
    }

    private func showAbout() {
        panel.orderOut(nil)
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.icon = AppBrand.icon
        alert.messageText = L10n.text("关于 NowBar")
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "17"
        alert.informativeText = L10n.format("版本 %@（%@）", store.updates.currentVersion, build) + "\n\n" + L10n.text("AI 用量，抬眼可见。")
        alert.addButton(withTitle: L10n.text("好"))
        alert.addButton(withTitle: L10n.text("检查更新…"))
        alert.addButton(withTitle: L10n.text("项目主页"))
        switch alert.runModal() {
        case .alertSecondButtonReturn: store.updates.checkManually()
        case .alertThirdButtonReturn: NSWorkspace.shared.open(URL(string: "https://github.com/itskylon/NowBar")!)
        default: break
        }
    }

    private var visibleScreen: NSRect {
        statusItem.button?.window?.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
    }

    private func resizePanel(_ size: NSSize) {
        guard size.width > 0, size.height > 0, panel.frame.size != size else { return }
        let previous = panel.frame
        panel.setFrame(NSRect(x: previous.minX, y: previous.maxY - size.height, width: size.width, height: size.height), display: panel.isVisible)
        if panel.isVisible { positionPanel() }
    }

    private func positionPanel() {
        guard let button = statusItem.button, let statusWindow = button.window else { return }
        let anchor = statusWindow.convertToScreen(button.convert(button.bounds, to: nil))
        let screen = visibleScreen
        let size = panel.frame.size
        let x = min(max(screen.minX + 8, anchor.midX - size.width / 2), screen.maxX - size.width - 8)
        let top = min(anchor.minY - 6, screen.maxY - 6)
        panel.setFrameOrigin(NSPoint(x: x, y: max(screen.minY + 8, top - size.height)))
    }

    @objc private func togglePanel() {
        if panel.isVisible { panel.orderOut(nil); return }
        showPanel()
    }

    private func showPanel() {
        positionPanel()
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    private func installDismissalObservers() {
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor in self?.panel.orderOut(nil) }
        }
        localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self, self.panel.isVisible else { return event }
            // Preserve status-button toggling and popovers/menus attached to this panel.
            if let window = event.window,
               window !== self.panel, window !== self.statusItem.button?.window,
               window.parent !== self.panel, window.level.rawValue <= NSWindow.Level.normal.rawValue {
                self.panel.orderOut(nil)
            }
            return event
        }
        resignObserver = NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.panel.orderOut(nil) }
        }
    }

    private func openSettings() { openWorkspace(showSettings: true) }

    private func openUsage() { openWorkspace() }

    private func openWorkspace(showSettings: Bool = false) {
        panel.orderOut(nil)
        if usageWindow == nil {
            let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 1000)
            let size = NSSize(width: min(1240, screen.width - 40), height: min(880, screen.height - 40))
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            window.title = AppBrand.name
            window.isReleasedWhenClosed = false
            window.minSize = NSSize(width: 900, height: 650)
            window.contentView = NSHostingView(rootView: UsageHistoryView(store: store, showQuota: CommandLine.arguments.contains("--quota"), showSettings: showSettings))
            window.delegate = self
            window.center()
            usageWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        usageWindow?.deminiaturize(nil)
        usageWindow?.makeKeyAndOrderFront(nil)
        NotificationCenter.default.post(name: Notification.Name("AgentMeterWorkspaceNavigate"), object: showSettings ? "settings" : nil)
        NotificationCenter.default.post(name: Notification.Name("AgentMeterUsageOpened"), object: nil)
    }

    func windowWillClose(_ notification: Notification) {
        if let window = notification.object as? NSWindow, window === usageWindow {
            NotificationCenter.default.post(name: Notification.Name("AgentMeterUsageClosed"), object: nil)
        }
    }

    func windowDidMiniaturize(_ notification: Notification) { windowWillClose(notification) }

    func windowDidDeminiaturize(_ notification: Notification) {
        if let window = notification.object as? NSWindow, window === usageWindow {
            NotificationCenter.default.post(name: Notification.Name("AgentMeterUsageOpened"), object: nil)
        }
    }
}

@MainActor
var panelHeightLimit: CGFloat { max(300, (NSScreen.main?.visibleFrame.height ?? 900) - 24) }

@MainActor
func runDiagnostics() {
    for provider in requestedProvider().map({ [$0] }) ?? ProviderID.allCases {
        do {
            let result = try ProviderSource.load(provider)
            let totals = result.days.reduce(Int64(0)) { $0 + $1.totalTokens }
            print("\(provider.title): windows=\(result.windows.count), days=\(result.days.count), tokens=\(totals), lastUpdate=\(result.updatedAt?.ISO8601Format() ?? "none"), notice=\(result.message ?? "none")")
            for window in result.windows {
                print("  \(window.title): remaining=\(Int(window.remaining))%, expired=\(window.expired())")
            }
        } catch { print("\(provider.title): unavailable — \(error.localizedDescription)") }
    }
}

@MainActor
func renderPreview(path: String, dark: Bool) throws {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let reference = CommandLine.arguments.contains("--reference")
    let live = !reference && CommandLine.arguments.contains("--live")
    let empty = !reference && CommandLine.arguments.contains("--empty")
    var snapshots: [ProviderSnapshot]?
    if empty { snapshots = [] }
    else if live {
        snapshots = ProviderID.allCases.filter { ProviderInstallation.detect().contains($0) }.map { provider in
            do { return try ProviderSource.load(provider) }
            catch { return ProviderSnapshot(provider: provider, message: error.localizedDescription) }
        }
    }
    let store = MeterStore(demo: reference || (!live && !empty), previewSnapshots: snapshots)
    if live { store.applyDetectedProviders(ProviderInstallation.detect()) }
    if CommandLine.arguments.contains("--no-installed-apps") { store.applyDetectedProviders([]) }
    if let index = CommandLine.arguments.firstIndex(of: "--language"), CommandLine.arguments.count > index + 1,
       let language = AppLanguage(rawValue: CommandLine.arguments[index + 1]) {
        store.preferences.language = language
    }
    if CommandLine.arguments.contains("--claude") { store.selected = .claude }
    if let provider = requestedProvider(), store.providers.contains(provider) {
        store.selected = provider
    }
    let heightLimit: CGFloat = CommandLine.arguments.contains("--full") ? 1400 : panelHeightLimit
    let surfaceIndex = CommandLine.arguments.firstIndex(of: "--surface")
    let surface = surfaceIndex.flatMap { CommandLine.arguments.count > $0 + 1 ? CommandLine.arguments[$0 + 1] : nil } ?? "panel"
    var measured = NSSize(width: 380, height: heightLimit)
    var previewWindow: NSWindow?
    let content: AnyView
    switch surface {
    case "settings":
        measured = NSSize(width: 900, height: 880)
        content = AnyView(UsageHistoryView(store: store, showSettings: true, previewRecords: []))
    case "history", "quota":
        measured = NSSize(width: 900, height: 880)
        content = AnyView(UsageHistoryView(store: store, showQuota: surface == "quota", previewRecords: []))
    default:
        content = AnyView(DashboardView(store: store, maxHeight: heightLimit, referencePreview: reference, onSizeChange: { size in
            measured = size
            DispatchQueue.main.async { previewWindow?.setContentSize(size) }
        }))
    }
    let renderedContent = surface == "panel" ? content : AnyView(content.frame(width: measured.width, height: measured.height).background(Color(nsColor: .windowBackgroundColor)))
    let hosting = NSHostingView(rootView: renderedContent.environment(\.colorScheme, dark ? .dark : .light).environment(\.locale, L10n.locale))
    hosting.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    let window = NSWindow(contentRect: NSRect(origin: .zero, size: measured), styleMask: [.borderless], backing: .buffered, defer: false)
    window.isOpaque = false
    window.backgroundColor = .clear
    window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    window.contentView = hosting
    previewWindow = window
    window.orderFront(nil)
    window.display()
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
        hosting.layoutSubtreeIfNeeded()
        window.setContentSize(measured)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            app.stop(nil)
            // Wake AppKit's event fetch when a background export has no input events.
            if let wake = NSEvent.otherEvent(with: .applicationDefined, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, subtype: 0, data1: 0, data2: 0) {
                app.postEvent(wake, atStart: true)
            }
        }
    }
    app.run()
    hosting.layoutSubtreeIfNeeded()
    guard let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { throw CocoaError(.fileWriteUnknown) }
    hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
    let standardBitmap = bitmap.converting(to: .sRGB, renderingIntent: .default) ?? bitmap
    guard let data = standardBitmap.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
    try data.write(to: URL(fileURLWithPath: path))
    print("Rendered \(reference ? "reference demo" : live ? "live" : empty ? "empty" : "demo") native panel \(Int(measured.width))×\(Int(measured.height)): \(path)")
}

if CommandLine.arguments.contains("--diagnose") {
    MainActor.assumeIsolated { runDiagnostics() }
} else if let index = CommandLine.arguments.firstIndex(of: "--render"), CommandLine.arguments.count > index + 1 {
    do { try MainActor.assumeIsolated { try renderPreview(path: CommandLine.arguments[index + 1], dark: CommandLine.arguments.contains("--dark")) } }
    catch { fputs("Preview failed: \(error.localizedDescription)\n", stderr); exit(1) }
} else {
    MainActor.assumeIsolated {
        let app = NSApplication.shared
        app.setActivationPolicy(CommandLine.arguments.contains("--show") || CommandLine.arguments.contains("--usage") || CommandLine.arguments.contains("--quota") || CommandLine.arguments.contains("--settings") ? .regular : .accessory)
        let delegate = MeterAppDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
