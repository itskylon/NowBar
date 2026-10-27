import AppKit
import AgentMeterCore

@main
struct ShortcutMenuAcceptance {
    @MainActor static func main() {
        _ = NSApplication.shared
        var checks = 0
        func expect(_ value: Bool, _ message: String) { precondition(value, message); checks += 1 }
        var actions: [String] = []
        var opened: URL?
        let shortcuts = MeterShortcutMenu(refresh: { actions.append("refresh") }, settings: { actions.append("settings") },
            usage: { actions.append("usage") }, about: { actions.append("about") }, checkUpdates: { actions.append("updates") },
            quit: { actions.append("quit") }, openURL: { opened = $0 })
        for language in [AppLanguage.english, .simplifiedChinese] {
            L10n.language = language
            let menu = shortcuts.build(version: "0.6.4")
            expect(menu.items.contains { $0.title == L10n.text("检查更新…") }, "Update action localizes")
            expect(menu.items.contains { $0.title.contains("NowBar") && $0.title.contains("0.6.4") }, "About includes real product version")
            for (key, name) in [("r", "refresh"), (",", "settings"), ("q", "quit")] {
                let item = menu.items.first { $0.keyEquivalent == key }!
                expect(item.keyEquivalentModifierMask == .command, "Native command shortcut")
                NSApp.sendAction(item.action!, to: item.target, from: item)
                expect(actions.last == name, "Shortcut invokes its action")
            }
            let status = menu.items.first { $0.submenu != nil }!.submenu!
            expect(status.items.count == 3, "All three supported services have status links")
            for item in status.items {
                NSApp.sendAction(item.action!, to: item.target, from: item)
                expect(opened?.scheme == "https", "Status opens official HTTPS page")
            }
            let busy = shortcuts.build(version: "0.6.4", checking: true, refreshing: true)
            expect(busy.items.first { $0.keyEquivalent == "r" }?.isEnabled == false, "Busy refresh is disabled")
            expect(busy.items.contains { $0.title == L10n.text("正在检查更新…") && !$0.isEnabled }, "Busy check is disabled")
            let release = AppRelease(version: "0.6.5", notes: "New release notes", url: URL(string: "https://github.com/itskylon/NowBar/releases/tag/v0.6.5")!)
            let alert = MeterUpdateAlerts.make(.available(release), currentVersion: "0.6.4")
            expect(alert.messageText == L10n.text("发现新版本"), "New-version dialog localizes")
            expect(alert.informativeText.contains("0.6.5") && alert.informativeText.contains("0.6.4"), "Dialog identifies new and installed versions")
            expect(alert.buttons.map(\.title) == [L10n.text("下载更新"), L10n.text("稍后")], "Dialog has download and later actions")
            expect(alert.accessoryView != nil, "Release notes are visible in the dialog")
            expect(alert.window.initialFirstResponder === alert.buttons.first, "Release notes do not steal focus and scroll past their beginning")
            let upToDate = MeterUpdateAlerts.make(.upToDate, currentVersion: "0.6.4")
            expect(upToDate.informativeText.contains("0.6.4"), "Up-to-date dialog includes version")
            let failed = MeterUpdateAlerts.make(.failed("无法连接更新服务，请检查网络后重试。"), currentVersion: "0.6.4")
            expect(failed.messageText == L10n.text("无法检查更新"), "Failure dialog does not imply no update")
        }
        L10n.language = .system
        print("Shortcut/menu/dialog acceptance: \(checks) checks passed")
    }
}
