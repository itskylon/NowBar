import Foundation

public struct QuotaAlert: Sendable {
    public enum Kind: String, Codable, Sendable { case low, reset }
    public var kind: Kind
    public var identifier: String
    public var title: String
    public var body: String
    public init(kind: Kind, identifier: String, title: String, body: String) {
        self.kind = kind; self.identifier = identifier; self.title = title; self.body = body
    }
}

public struct QuotaAlertTracker: Codable, Sendable {
    private struct WindowState: Codable, Sendable {
        var updatedAt: Date
        var usedPercent: Double
        var resetAt: Date?
        var cycle = 0
        var notifiedThresholds: Set<Int> = []
    }
    private var windows: [String: WindowState] = [:]
    private static let maximumWindows = 64

    public init() {}

    /// Disabled alerts still record fresh observations, but do not consume low thresholds.
    /// Reenabling can notify on the next newer sample; it never replays an old observation.
    public mutating func evaluate(_ snapshots: [ProviderSnapshot], lowEnabled: Bool, resetEnabled: Bool, now: Date = Date()) -> [QuotaAlert] {
        guard now.timeIntervalSince1970.isFinite else { return [] }
        var alerts: [QuotaAlert] = []
        for snapshot in snapshots {
            guard snapshot.quotaReadFailed != true, let updatedAt = snapshot.updatedAt,
                  updatedAt.timeIntervalSince1970.isFinite else { continue }
            let age = now.timeIntervalSince(updatedAt)
            guard age <= 300, age >= -60 else { continue }

            for window in snapshot.windows {
                guard window.usedPercent.isFinite, (0...100).contains(window.usedPercent) else { continue }
                if let reset = window.resetsAt {
                    guard reset.timeIntervalSince1970.isFinite, reset > now else { continue }
                }
                let key = snapshot.provider.rawValue + ":" + window.id
                let previous = windows[key]
                guard previous.map({ updatedAt > $0.updatedAt }) ?? true else { continue }
                var state = previous ?? WindowState(updatedAt: updatedAt, usedPercent: window.usedPercent, resetAt: window.resetsAt)
                var confirmedReset = false
                if let previous, let oldReset = previous.resetAt, let newReset = window.resetsAt,
                   oldReset <= now, oldReset <= updatedAt, newReset > oldReset {
                    // A later server period is independent. Usage must also fall substantially
                    // before we tell the user that an actual reset has been observed.
                    state.cycle += 1
                    state.notifiedThresholds.removeAll()
                    state.resetAt = newReset
                    confirmedReset = previous.usedPercent - window.usedPercent >= 5
                } else if state.resetAt == nil {
                    // A first timestamp establishes the baseline; it cannot prove a reset.
                    state.resetAt = window.resetsAt
                }
                let identifier = "agentmeter.quota.\(key).\(state.cycle)"
                let amount = percentage(window.remaining)
                if resetEnabled, confirmedReset {
                    alerts.append(.init(kind: .reset, identifier: identifier + ".reset",
                                        title: snapshot.provider.title + " 额度已重置",
                                        body: "\(window.title)额度已重置，当前剩余 \(amount)"))
                } else if lowEnabled {
                    // Deliver at most one event for this observation. A reset takes priority;
                    // the next newer sample can report a still-low, unconsumed threshold.
                    let crossed = [20, 10, 0].filter { window.remaining <= Double($0) }
                    if let threshold = crossed.filter({ !state.notifiedThresholds.contains($0) }).min() {
                        alerts.append(.init(kind: .low, identifier: identifier + ".low.\(threshold)",
                                            title: snapshot.provider.title + " 额度不足",
                                            body: "\(window.title)剩余 \(amount)"))
                        // A jump to 5% consumes both 20% and 10%, while sending one alert.
                        state.notifiedThresholds.formUnion(crossed)
                    }
                }
                state.updatedAt = updatedAt
                state.usedPercent = window.usedPercent
                if previous == nil, windows.count >= Self.maximumWindows,
                   let oldest = windows.keys.min(by: {
                       let lhs = windows[$0]!.updatedAt, rhs = windows[$1]!.updatedAt
                       return lhs == rhs ? $0 < $1 : lhs < rhs
                   }) {
                    windows.removeValue(forKey: oldest)
                }
                windows[key] = state
            }
        }
        return alerts
    }

    private func percentage(_ remaining: Double) -> String {
        if remaining > 0 && remaining < 1 { return "不足 1%" }
        return String(format: "%.0f%%", remaining)
    }
}
