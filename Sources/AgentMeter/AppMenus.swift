import AppKit
import AgentMeterCore

@MainActor
final class MeterShortcutMenu: NSObject {
    static let statusPages = [
        (name: "Codex", address: "https://status.openai.com/"),
        (name: "Claude", address: "https://status.claude.com/"),
        (name: "Grok", address: "https://status.x.ai/")
    ]
    private let refresh: () -> Void
    private let settings: () -> Void
    private let usage: () -> Void
    private let about: () -> Void
    private let checkUpdates: () -> Void
    private let quit: () -> Void
    private let openURL: (URL) -> Void

    init(refresh: @escaping () -> Void, settings: @escaping () -> Void, usage: @escaping () -> Void,
         about: @escaping () -> Void, checkUpdates: @escaping () -> Void, quit: @escaping () -> Void,
         openURL: @escaping (URL) -> Void) {
        self.refresh = refresh
        self.settings = settings
        self.usage = usage
        self.about = about
        self.checkUpdates = checkUpdates
        self.quit = quit
        self.openURL = openURL
    }

    func build(version: String, checking: Bool = false, refreshing: Bool = false) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        func add(_ title: String, _ action: Selector?, key: String = "") -> NSMenuItem {
            let item = NSMenuItem(title: L10n.text(title), action: action, keyEquivalent: key)
            item.target = self
            if !key.isEmpty { item.keyEquivalentModifierMask = .command }
            menu.addItem(item)
            return item
        }
        _ = add("用量与支出", #selector(showUsage))
        let status = add("状态页", nil)
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        for (name, address) in Self.statusPages {
            let item = NSMenuItem(title: name, action: #selector(showStatus(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = URL(string: address)!
            submenu.addItem(item)
        }
        status.submenu = submenu
        menu.addItem(.separator())
        add("刷新", #selector(refreshUsage), key: "r").isEnabled = !refreshing
        _ = add("设置…", #selector(showSettings), key: ",")
        add(checking ? "正在检查更新…" : "检查更新…", #selector(checkForUpdates)).isEnabled = !checking
        _ = add(L10n.text("关于 NowBar") + " (v\(version))", #selector(showAbout))
        menu.addItem(.separator())
        _ = add("退出 NowBar", #selector(quitApp), key: "q")
        return menu
    }

    @objc private func refreshUsage() { refresh() }
    @objc private func showSettings() { settings() }
    @objc private func showUsage() { usage() }
    @objc private func showAbout() { about() }
    @objc private func checkForUpdates() { checkUpdates() }
    @objc private func quitApp() { quit() }
    @objc private func showStatus(_ sender: NSMenuItem) {
        if let url = sender.representedObject as? URL { openURL(url) }
    }
}

@MainActor
enum MeterUpdateAlerts {
    static func make(_ presentation: AppUpdatePresentation, currentVersion: String) -> NSAlert {
        let alert = NSAlert()
        alert.alertStyle = .informational
        switch presentation {
        case .available(let release):
            alert.messageText = L10n.text("发现新版本")
            alert.informativeText = L10n.format("NowBar %@ 现已推出，当前版本为 %@。", release.version, currentVersion)
                + "\n\n" + L10n.text("下载后解压并替换应用，不会自动安装。")
            alert.addButton(withTitle: L10n.text("下载更新"))
            alert.addButton(withTitle: L10n.text("稍后"))
            if !release.notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 390, height: 160))
                scroll.hasVerticalScroller = true
                scroll.borderType = .bezelBorder
                let text = NSTextView(frame: scroll.contentView.bounds)
                text.isEditable = false
                text.isSelectable = false
                text.font = .systemFont(ofSize: 12)
                text.textColor = .labelColor
                text.textContainerInset = NSSize(width: 8, height: 8)
                text.isHorizontallyResizable = false
                text.isVerticallyResizable = true
                text.autoresizingMask = [.width]
                text.textContainer?.widthTracksTextView = true
                // GitHub release notes are displayed as plain text, never executed.
                text.string = String(release.notes.prefix(20_000))
                scroll.documentView = text
                alert.accessoryView = scroll
            }
        case .upToDate:
            alert.messageText = L10n.text("当前已是最新版本")
            alert.informativeText = L10n.format("NowBar %@ 已是最新版本。", currentVersion)
            alert.addButton(withTitle: L10n.text("好"))
        case .failed(let message):
            alert.alertStyle = .warning
            alert.messageText = L10n.text("无法检查更新")
            alert.informativeText = L10n.text(message)
            alert.addButton(withTitle: L10n.text("好"))
        }
        alert.layout()
        alert.window.initialFirstResponder = alert.buttons.first
        if let scroll = alert.accessoryView as? NSScrollView, let text = scroll.documentView as? NSTextView {
            text.setSelectedRange(NSRange(location: 0, length: 0))
            text.scrollRangeToVisible(NSRange(location: 0, length: 0))
        }
        return alert
    }
}
