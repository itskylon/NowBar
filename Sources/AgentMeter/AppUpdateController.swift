import Foundation
import Combine
import AgentMeterCore

enum AppUpdateResult: Equatable {
    case available(AppRelease)
    case upToDate
    case failed(String)
}

typealias AppUpdatePresentation = AppUpdateResult

@MainActor
final class AppUpdateController: ObservableObject {
    let currentVersion: String
    let enabled: Bool
    @Published private(set) var checking = false
    @Published private(set) var lastChecked: Date?
    @Published private(set) var result: AppUpdateResult?
    var onPresentation: ((AppUpdatePresentation) -> Void)?

    private let defaults: UserDefaults
    private let now: () -> Date
    private let fetch: (String) async throws -> AppRelease?
    private var timer: Timer?
    private var started = false
    private var lastAttempt: Date?
    private var manualRequested = false
    private static let interval: TimeInterval = 24 * 3600
    private static let checkedKey = "nowbar.updates.lastChecked.v1"
    private static let notifiedKey = "nowbar.updates.lastNotifiedVersion.v1"

    init(currentVersion: String = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.6.9",
         enabled: Bool = true, defaults: UserDefaults = .standard, now: @escaping () -> Date = Date.init,
         fetch: @escaping (String) async throws -> AppRelease? = AppUpdates.fetch) {
        self.currentVersion = currentVersion
        self.enabled = enabled
        self.defaults = defaults
        self.now = now
        self.fetch = fetch
        if enabled { lastChecked = defaults.object(forKey: Self.checkedKey) as? Date }
    }

    var automaticCheckDue: Bool {
        enabled && !checking && (lastAttempt.map { now().timeIntervalSince($0) >= Self.interval } ?? true)
    }

    var nextCheckAt: Date? { timer?.fireDate }

    func start() {
        guard enabled, !started else { return }
        started = true
        checkAutomaticallyIfDue()
        if !automaticCheckDue { scheduleNextCheck() }
    }

    func stop() { started = false; timer?.invalidate(); timer = nil }

    private func scheduleNextCheck() {
        guard started else { return }
        timer?.invalidate()
        let deadline = max(now().addingTimeInterval(1), (lastAttempt ?? now()).addingTimeInterval(Self.interval))
        let next = Timer(fire: deadline, interval: 0, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.checkAutomaticallyIfDue() }
        }
        timer = next
        RunLoop.main.add(next, forMode: .common)
    }

    func checkAutomaticallyIfDue() {
        guard automaticCheckDue else { return }
        Task { await check(manual: false) }
    }

    func checkManually() { Task { await check(manual: true) } }

    func check(manual: Bool) async {
        guard enabled else { return }
        if checking {
            manualRequested = manualRequested || manual
            return
        }
        checking = true
        manualRequested = manual
        lastAttempt = now()
        let outcome: AppUpdateResult
        do {
            outcome = try await fetch(currentVersion).map(AppUpdateResult.available) ?? .upToDate
            lastChecked = now()
            defaults.set(lastChecked, forKey: Self.checkedKey)
        } catch {
            let message: String
            switch error {
            case AppUpdateError.rateLimited: message = "更新服务暂时限流，请稍后重试。"
            case AppUpdateError.invalidResponse: message = "更新信息无效，请稍后重试。"
            default: message = "无法连接更新服务，请检查网络后重试。"
            }
            outcome = .failed(message)
        }
        result = outcome
        let manualFeedback = manualRequested
        checking = false
        manualRequested = false
        scheduleNextCheck()
        guard let onPresentation else { return }
        if case .available(let release) = outcome {
            guard manualFeedback || defaults.string(forKey: Self.notifiedKey) != release.version else { return }
            defaults.set(release.version, forKey: Self.notifiedKey)
            onPresentation(outcome)
        } else if manualFeedback {
            onPresentation(outcome)
        }
    }
}
