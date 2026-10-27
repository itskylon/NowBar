import Foundation
import AgentMeterCore

@main
struct UpdateControllerAcceptance {
    @MainActor static func main() async {
        let suite = "NowBar.UpdateTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var count = 0
        func expect(_ value: Bool, _ reason: String) {
            precondition(value, reason)
            count += 1
        }
        var now = Date(timeIntervalSince1970: 1_800_000_000)
        let release = AppRelease(version: "0.6.5", notes: "Release notes", url: URL(string: "https://github.com/itskylon/NowBar/releases/tag/v0.6.5")!)
        var calls = 0
        var response: AppRelease? = release
        var failure: Error?
        var presentations: [AppUpdatePresentation] = []
        let updates = AppUpdateController(currentVersion: "0.6.4", defaults: defaults, now: { now }, fetch: { _ in
            calls += 1
            if let failure { throw failure }
            return response
        })
        updates.onPresentation = { presentations.append($0) }
        await updates.check(manual: false)
        expect(calls == 1 && presentations == [.available(release)], "Launch detects and presents a newer version")
        expect(updates.result == .available(release) && updates.lastChecked == now, "Successful check records its result and time")
        expect(!updates.automaticCheckDue, "A recent check is not due again")
        await updates.check(manual: false)
        expect(presentations.count == 1, "The same version is not automatically presented twice")
        await updates.check(manual: true)
        expect(presentations.count == 2, "Manual checks can present a postponed update again")
        let restarted = AppUpdateController(currentVersion: "0.6.4", defaults: defaults, now: { now }, fetch: { _ in release })
        restarted.onPresentation = { presentations.append($0) }
        await restarted.check(manual: false)
        expect(presentations.count == 2 && restarted.lastChecked == now, "Reminder deduplication survives restart")
        now.addTimeInterval(24 * 3600)
        expect(updates.automaticCheckDue, "Automatic check becomes due after 24 hours")
        response = nil
        await updates.check(manual: false)
        expect(updates.result == .upToDate && presentations.count == 2, "Background up-to-date checks stay quiet")
        await updates.check(manual: true)
        expect(presentations.last == .upToDate, "Manual up-to-date checks give feedback")
        let successTime = updates.lastChecked
        failure = AppUpdateError.rateLimited
        now.addTimeInterval(10)
        let previousCount = presentations.count
        await updates.check(manual: false)
        expect(presentations.count == previousCount && updates.lastChecked == successTime, "Background failures do not show dialogs or advance successful check time")
        await updates.check(manual: true)
        expect(presentations.last == .failed("更新服务暂时限流，请稍后重试。"), "Manual rate limits are explained")
        failure = AppUpdateError.invalidResponse
        await updates.check(manual: true)
        expect(presentations.last == .failed("更新信息无效，请稍后重试。"), "Invalid data is not reported as up to date")
        failure = URLError(.notConnectedToInternet)
        await updates.check(manual: true)
        expect(presentations.last == .failed("无法连接更新服务，请检查网络后重试。"), "Network errors have actionable feedback")
        let disabled = AppUpdateController(enabled: false, defaults: defaults, fetch: { _ in
            fatalError("Demo/preview must not access the network")
        })
        disabled.start()
        await disabled.check(manual: true)
        expect(disabled.result == nil && disabled.lastChecked == nil && !disabled.automaticCheckDue, "Preview has no update side effects")
        var resume: CheckedContinuation<AppRelease?, Error>?
        var concurrentCalls = 0
        let concurrent = AppUpdateController(defaults: defaults, fetch: { _ in
            concurrentCalls += 1
            return try await withCheckedThrowingContinuation { resume = $0 }
        })
        concurrent.onPresentation = { presentations.append($0) }
        let automatic = Task { await concurrent.check(manual: false) }
        while resume == nil { await Task.yield() }
        expect(concurrent.checking, "Network check exposes busy state")
        await concurrent.check(manual: true)
        resume?.resume(returning: nil)
        await automatic.value
        expect(concurrentCalls == 1 && !concurrent.checking && presentations.last == .upToDate, "Concurrent manual check reuses in-flight automatic request and receives feedback")
        let scheduled = AppUpdateController(defaults: defaults, now: { now }, fetch: { _ in nil })
        scheduled.start()
        while scheduled.result == nil { await Task.yield() }
        expect(scheduled.nextCheckAt == now.addingTimeInterval(24 * 3600), "Launch schedules its next daily check")
        now.addTimeInterval(3600)
        await scheduled.check(manual: true)
        expect(scheduled.nextCheckAt == now.addingTimeInterval(24 * 3600), "Manual check rearms the deadline instead of skipping a daily timer tick")
        scheduled.stop()
        expect(scheduled.nextCheckAt == nil, "Stopping cancels the scheduled check")
        print("Update controller acceptance: \(count) checks passed")
    }
}
