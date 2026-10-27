import AppKit
import Combine
import ServiceManagement
import UserNotifications
import AgentMeterCore

@MainActor
final class MeterSystemServices: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    @Published private(set) var notificationsAllowed = false
    @Published private(set) var notificationsBusy = false
    @Published private(set) var notificationStatusText = "正在检查通知设置…"
    @Published private(set) var loginEnabled = false
    @Published private(set) var loginRequiresApproval = false
    @Published private(set) var loginMessage: String?

    private let active: Bool
    private var notificationCenter: UNUserNotificationCenter?
    private var notificationStatusRevision = 0

    private var isApplicationBundle: Bool {
        Bundle.main.bundleURL.pathExtension.lowercased() == "app"
            && !(Bundle.main.bundleIdentifier ?? "").isEmpty
    }

    init(active: Bool = true) {
        self.active = active
        super.init()
        guard active, isApplicationBundle else {
            showUnavailableStatus()
            return
        }
        let center = UNUserNotificationCenter.current()
        notificationCenter = center
        center.delegate = self
        refreshStatus()
    }

    /// Queries the system only; authorization and login-item changes require explicit actions.
    func refreshStatus() {
        guard active, isApplicationBundle, let center = notificationCenter else {
            showUnavailableStatus()
            return
        }
        refreshLoginStatus()
        guard !notificationsBusy else { return }
        notificationStatusRevision += 1
        let revision = notificationStatusRevision
        Task { [weak self] in
            let settings = await center.notificationSettings()
            guard let self, revision == notificationStatusRevision, !notificationsBusy else { return }
            applyNotificationSettings(settings)
        }
    }

    /// Call only after the person explicitly enables reminders in settings.
    func requestNotifications() async -> Bool {
        guard active, isApplicationBundle, let center = notificationCenter else {
            showUnavailableStatus()
            return false
        }
        guard !notificationsBusy else { return false }
        notificationsBusy = true
        notificationStatusRevision += 1
        defer { notificationsBusy = false }

        let existing = await center.notificationSettings()
        if existing.authorizationStatus == .denied {
            applyNotificationSettings(existing)
            return false
        }
        do {
            // Banners are the only interaction used; no badge, sound, or remote registration.
            _ = try await center.requestAuthorization(options: [.alert])
            applyNotificationSettings(await center.notificationSettings())
            return notificationsAllowed
        } catch {
            applyNotificationSettings(await center.notificationSettings())
            notificationStatusText += " 无法申请通知权限：\(error.localizedDescription)"
            return false
        }
    }

    /// Success means the system accepted the request, not that a banner was displayed.
    func deliver(_ alert: QuotaAlert, shouldSend: @MainActor () -> Bool = { true }) async -> Bool {
        guard active, notificationsAllowed, let center = notificationCenter else { return false }
        guard !notificationsBusy else { return false }
        notificationsBusy = true
        notificationStatusRevision += 1
        defer { notificationsBusy = false }

        applyNotificationSettings(await center.notificationSettings())
        guard notificationsAllowed, shouldSend() else { return false }
        let content = UNMutableNotificationContent()
        content.title = L10n.text(alert.title)
        content.body = L10n.text(alert.body)
        let request = UNNotificationRequest(identifier: alert.identifier, content: content, trigger: nil)
        do {
            try await center.add(request)
            return true
        } catch {
            notificationStatusText = "提醒未能提交：\(error.localizedDescription)"
            return false
        }
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        guard active, isApplicationBundle else {
            showUnavailableStatus()
            return
        }
        let service = SMAppService.mainApp
        var operationError: String?
        do {
            if enabled {
                // A pending approval must be resolved by the person in System Settings.
                if service.status != .enabled && service.status != .requiresApproval {
                    try service.register()
                }
            } else if service.status != .notRegistered {
                try service.unregister()
            }
        } catch {
            operationError = "无法更改登录时启动：\(error.localizedDescription)"
        }
        refreshLoginStatus(operationError: operationError)
    }

    func openLoginSettings() {
        guard active, isApplicationBundle else {
            showUnavailableStatus()
            return
        }
        SMAppService.openSystemSettingsLoginItems()
    }

    func openNotificationSettings() {
        guard active, isApplicationBundle else {
            showUnavailableStatus()
            return
        }
        // macOS has no public app-specific equivalent of iOS's settings URL constant.
        // Treat the pane URL as best effort and retain a general System Settings fallback.
        let pane = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!
        if !NSWorkspace.shared.open(pane) {
            let settings = URL(fileURLWithPath: "/System/Applications/System Settings.app", isDirectory: true)
            guard NSWorkspace.shared.open(settings) else {
                notificationStatusText = "无法打开系统设置，请手动前往「通知」→「NowBar」。"
                return
            }
        }
        notificationStatusText = "请在系统设置的「通知」中选择NowBar，检查允许通知和提醒样式。"
    }

    private func refreshLoginStatus(operationError: String? = nil) {
        let status = SMAppService.mainApp.status
        loginEnabled = status == .enabled
        loginRequiresApproval = status == .requiresApproval
        let message: String
        switch status {
        case .enabled: message = "已启用登录时启动。"
        case .notRegistered: message = "登录时启动未启用。"
        case .requiresApproval: message = "需要在系统设置的「登录项」中允许NowBar，当前尚未启用。"
        case .notFound: message = "当前没有可用的登录项登记，开启后会尝试向系统登记。"
        @unknown default: message = "系统返回了未知的登录项状态。"
        }
        loginMessage = operationError.map { "\($0)\n\(message)" } ?? message
    }

    private func applyNotificationSettings(_ settings: UNNotificationSettings) {
        notificationsAllowed = false
        switch settings.authorizationStatus {
        case .notDetermined:
            notificationStatusText = "尚未申请通知权限，开启提醒时才会询问。"
        case .denied:
            notificationStatusText = "系统已拒绝通知，请在系统设置的「通知」中允许NowBar。"
        case .authorized:
            notificationsAllowed = settings.alertSetting == .enabled && settings.alertStyle != .none
            notificationStatusText = notificationsAllowed
                ? "系统通知已允许；提醒显示仍受专注模式等系统设置影响。"
                : "系统已授权通知，但提醒样式已关闭。请在系统设置中开启横幅或提醒。"
        case .provisional:
            notificationStatusText = "系统仅允许静默通知，请在系统设置中允许横幅提醒。"
        @unknown default:
            notificationStatusText = "系统返回了未知的通知权限状态，暂不发送提醒。"
        }
    }

    private func showUnavailableStatus() {
        notificationsAllowed = false
        loginEnabled = false
        loginRequiresApproval = false
        if !active {
            notificationStatusText = "演示和预览模式不使用系统通知。"
            loginMessage = "演示和预览模式不更改登录项。"
        } else {
            notificationStatusText = "系统通知不可用，请打开构建好的NowBar.app。"
            loginMessage = "登录时启动不可用，请打开构建好的NowBar.app。"
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                           willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        await MainActor.run { active && notificationsAllowed ? [.banner] : [] }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                           didReceive response: UNNotificationResponse) async {
        guard response.actionIdentifier == UNNotificationDefaultActionIdentifier else { return }
        await MainActor.run {
            guard active else { return }
            NSApplication.shared.activate(ignoringOtherApps: true)
            NotificationCenter.default.post(name: Notification.Name("AgentMeterOpenPanel"), object: nil)
        }
    }
}
