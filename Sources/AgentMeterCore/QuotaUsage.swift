import Foundation

public enum QuotaUsageState: String, Sendable {
    case current, saved, expired, unavailable, disconnected, loading, failed

    public var title: String {
        switch self {
        case .current: return "已获取"
        case .saved: return "上次数据"
        case .expired: return "已到期 · 待更新"
        case .unavailable: return "未提供"
        case .disconnected: return "未接入"
        case .loading: return "读取中"
        case .failed: return "读取失败"
        }
    }
}

public struct QuotaUsageWindow: Identifiable, Sendable {
    public let id: String
    public let title: String
    public let window: LimitWindow?
    public let state: QuotaUsageState

    public var usedPercent: Double? {
        guard state == .current || state == .saved, let window, window.usedPercent.isFinite else { return nil }
        return min(100, max(0, window.usedPercent))
    }
    public var remainingPercent: Double? { usedPercent.map { 100 - $0 } }
}

/// Presents account quota independently of local Token history and its read status.
public enum QuotaUsage {
    public static func windows(for snapshot: ProviderSnapshot, bridgeInstalled: Bool, refreshing: Bool, now: Date) -> [QuotaUsageWindow] {
        let expected = snapshot.provider.quotaTitles
        let slots: [(String, LimitWindow?)] = expected.map { title in
            (title, snapshot.windows.first { $0.title == title })
        } + snapshot.windows.filter { !expected.contains($0.title) }.map { ($0.title, Optional($0)) }

        return slots.map { title, window in
            let state: QuotaUsageState
            if let window, window.usedPercent.isFinite {
                if window.expired(at: now) { state = .expired }
                else if snapshot.quotaReadFailed == true || snapshot.updatedAt.map({ now.timeIntervalSince($0) > 600 }) != false {
                    state = .saved
                } else { state = .current }
            } else if snapshot.quotaReadFailed == true { state = .failed }
            else if snapshot.provider == .claude && !bridgeInstalled { state = .disconnected }
            else if refreshing { state = .loading }
            else { state = .unavailable }
            return .init(id: window?.id ?? "\(snapshot.provider.rawValue).missing.\(title)", title: title, window: window, state: state)
        }
    }
}
