import Foundation
import Security
import LocalAuthentication
import CryptoKit

/// Read-only quota requests using credentials owned by the provider's local login flow.
/// Call only after explicit consent, on a background queue. Never renews or rewrites credentials.
public enum OAuthQuotaSource {
    public enum CredentialStatus: Equatable, Sendable { case available, missing, expired, invalid }

    public enum ReadError: Error, LocalizedError {
        case missing, expired, invalidCredential, scope, keychainAccess, unavailable, invalidResponse, denied, rateLimited, timedOut, redirect
        public var errorDescription: String? {
            switch self {
            case .missing: return "未找到 OAuth 登录凭证，请先连接账户。"
            case .expired: return "OAuth 登录已过期，请重新连接账户。"
            case .invalidCredential: return "OAuth 登录凭证不可用，请重新连接账户。"
            case .scope: return "当前登录未授予读取用量的权限，请重新连接账户。"
            case .keychainAccess: return "无法读取 Claude 登录钥匙串，请解锁钥匙串并在连接账户时允许 NowBar 访问。"
            case .unavailable: return "OAuth 用量服务暂时不可用，请稍后刷新。"
            case .invalidResponse: return "OAuth 用量数据格式无效，请稍后刷新。"
            case .denied: return "OAuth 用量访问被拒绝，请重新连接账户。"
            case .rateLimited: return "OAuth 用量服务暂时限流，请稍后刷新。"
            case .timedOut: return "OAuth 用量请求超时，请稍后刷新。"
            case .redirect: return "OAuth 用量请求被重定向，已停止发送登录凭证。"
            }
        }
    }

    private struct Credentials {
        var accessToken: String
        var accountID: String?
        var identity: String
        var plan: String?
    }

    public static func credentialStatus(_ provider: ProviderID,
                                        home: URL = FileManager.default.homeDirectoryForCurrentUser,
                                        codexHome: URL? = nil, now: Date = Date()) -> CredentialStatus {
        do { _ = try credentials(provider, home: home, codexHome: codexHome, now: now); return .available }
        catch ReadError.missing { return .missing }
        catch ReadError.expired { return .expired }
        catch { return .invalid }
    }

    /// Explicit Connect action only. May show one macOS credential-access prompt; never invoke at startup.
    /// The credential payload is discarded and provider-owned login entries are never modified.
    public static func prepareConnection(_ provider: ProviderID) throws {
        try prepareConnection(provider, home: FileManager.default.homeDirectoryForCurrentUser)
    }

    public static func prepareConnection(_ provider: ProviderID, home: URL) throws {
        guard provider == .claude else { return }
        let file = home.appendingPathComponent(".claude/.credentials.json")
        if FileManager.default.fileExists(atPath: file.path) {
            _ = try credentialFile(file)
        } else if home.standardizedFileURL == FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL {
            _ = try claudeKeychain(allowInteraction: true)
        } else {
            throw ReadError.missing
        }
    }

    public static func load(_ provider: ProviderID,
                            home: URL = FileManager.default.homeDirectoryForCurrentUser,
                            codexHome: URL? = nil) throws -> ProviderSnapshot {
        let credential = try credentials(provider, home: home, codexHome: codexHome, now: Date())
        let endpoint: String
        switch provider {
        case .codex: endpoint = "https://chatgpt.com/backend-api/wham/usage"
        case .claude: endpoint = "https://api.anthropic.com/api/oauth/usage"
        case .grokBot: throw ReadError.unavailable
        }
        var request = URLRequest(url: URL(string: endpoint)!, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 8)
        request.setValue("Bearer " + credential.accessToken, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if provider == .codex, let account = credential.accountID {
            request.setValue(account, forHTTPHeaderField: "ChatGPT-Account-Id")
        }
        if provider == .claude {
            request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        }
        let response = try QuotaFetch.fetch(request)
        var value = try parse(provider, data: response.data, statusCode: response.status, now: Date())
        value.quotaAccountID = credential.identity
        if value.plan == nil { value.plan = credential.plan }
        return value
    }

    /// Parses only quota fields. HTTP error payloads are never decoded or surfaced.
    public static func parse(_ provider: ProviderID, data: Data, statusCode: Int,
                             now: Date = Date()) throws -> ProviderSnapshot {
        try validateStatus(statusCode)
        guard data.count <= 2 * 1024 * 1024,
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw ReadError.invalidResponse
        }
        var windows: [LimitWindow] = []
        var plan: String?
        switch provider {
        case .codex:
            guard object.keys.contains("rate_limit") else { throw ReadError.invalidResponse }
            plan = safeLabel(object["plan_type"])
            if let raw = object["rate_limit"], !(raw is NSNull) {
                guard let rateLimit = raw as? [String: Any] else { throw ReadError.invalidResponse }
                windows = try codexWindows(rateLimit, prefix: "", label: nil)
            }
            if let extras = object["additional_rate_limits"] as? [[String: Any]] {
                for (index, item) in extras.enumerated() {
                    guard let rateLimit = item["rate_limit"] as? [String: Any] else { continue }
                    let name = safeLabel(item["limit_name"]) ?? safeLabel(item["metered_feature"])
                    windows += try codexWindows(rateLimit, prefix: "extra.\(index).", label: name)
                }
            }
        case .claude:
            let fields = [("five_hour", "5 小时"), ("seven_day", "每周"),
                          ("seven_day_opus", "Opus 每周"), ("seven_day_sonnet", "Sonnet 每周"),
                          ("seven_day_cowork", "Cowork 每周")]
            guard fields.contains(where: { object.keys.contains($0.0) }) else { throw ReadError.invalidResponse }
            for (field, title) in fields {
                guard let raw = object[field], !(raw is NSNull) else { continue }
                guard let item = raw as? [String: Any], let used = percent(item["utilization"]) else {
                    throw ReadError.invalidResponse
                }
                let reset = try isoReset(item["resets_at"])
                windows.append(.init(id: "claude." + field, title: title, usedPercent: used, resetsAt: reset))
            }
        case .grokBot: throw ReadError.unavailable
        }
        let message = windows.isEmpty ? "账户已连接，但服务未提供可读取的额度。" : nil
        var value = ProviderSnapshot(provider: provider, plan: plan, windows: windows, updatedAt: now,
                                     sourceNote: "OAuth 账户额度接口；Token 和参考费用由本机日志单独统计。", message: message)
        value.quotaSource = provider == .codex ? .codexOAuth : .claudeOAuth
        value.quotaMessage = message
        return value
    }

    fileprivate static func validateStatus(_ status: Int) throws {
        switch status {
        case 200...299: return
        case 300...399: throw ReadError.redirect
        case 401: throw ReadError.expired
        case 403: throw ReadError.denied
        case 429: throw ReadError.rateLimited
        default: throw ReadError.unavailable
        }
    }

    private static func codexWindows(_ object: [String: Any], prefix: String, label: String?) throws -> [LimitWindow] {
        var windows: [LimitWindow] = []
        for (field, id) in [("primary_window", "primary"), ("secondary_window", "secondary")] {
            guard let raw = object[field], !(raw is NSNull) else { continue }
            guard let item = raw as? [String: Any], let used = percent(item["used_percent"]) else {
                throw ReadError.invalidResponse
            }
            let seconds = number(item["limit_window_seconds"])
            let title: String
            switch seconds {
            case 18_000: title = "5 小时"
            case 604_800: title = "每周"
            case let seconds? where seconds > 0 && seconds < 31_536_000 && seconds.truncatingRemainder(dividingBy: 86_400) == 0:
                title = "\(Int(seconds / 86_400)) 天"
            default: title = id == "primary" ? "当前窗口" : "长期窗口"
            }
            var reset: Date?
            if let rawReset = item["reset_at"], !(rawReset is NSNull) {
                guard let stamp = number(rawReset), stamp > 0 && stamp < 253_402_300_800 else { throw ReadError.invalidResponse }
                reset = Date(timeIntervalSince1970: stamp)
            }
            windows.append(.init(id: prefix + id, title: label.map { $0 + " · " + title } ?? title,
                                 usedPercent: used, resetsAt: reset))
        }
        return windows
    }

    private static func credentials(_ provider: ProviderID, home: URL, codexHome: URL?, now: Date) throws -> Credentials {
        let data: Data
        switch provider {
        case .codex:
            let root = codexHome ?? (home.standardizedFileURL == FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL
                ? ProcessInfo.processInfo.environment["CODEX_HOME"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) } : nil)
                ?? home.appendingPathComponent(".codex", isDirectory: true)
            data = try credentialFile(root.appendingPathComponent("auth.json"))
        case .claude:
            let path = home.appendingPathComponent(".claude/.credentials.json")
            if FileManager.default.fileExists(atPath: path.path) {
                data = try credentialFile(path)
            } else if home.standardizedFileURL == FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL {
                data = try claudeKeychain()
            } else { throw ReadError.missing }
        case .grokBot: throw ReadError.missing
        }
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { throw ReadError.invalidCredential }
        let token: String
        var account: String?
        var plan: String?
        if provider == .codex {
            guard let tokens = object["tokens"] as? [String: Any], let access = tokens["access_token"] as? String else { throw ReadError.missing }
            token = access
            account = tokens["account_id"] as? String
            if let expiry = jwtExpiry(access), expiry <= now { throw ReadError.expired }
        } else {
            guard let oauth = object["claudeAiOauth"] as? [String: Any], let access = oauth["accessToken"] as? String else { throw ReadError.missing }
            token = access
            if let raw = oauth["expiresAt"] {
                guard let millis = number(raw), millis > 0 && millis < 253_402_300_800_000 else { throw ReadError.invalidCredential }
                if Date(timeIntervalSince1970: millis / 1000) <= now { throw ReadError.expired }
            }
            if let scopes = oauth["scopes"] as? [String], !scopes.contains("user:profile") { throw ReadError.scope }
            plan = safeLabel(oauth["subscriptionType"])
            account = (object["oauthAccount"] as? [String: Any])?["accountUuid"] as? String
        }
        guard validHeader(token, maximum: 32_768), account.map({ validHeader($0, maximum: 512) }) ?? true else { throw ReadError.invalidCredential }
        let identitySource = provider.rawValue + "|" + (account ?? token)
        let identity = SHA256.hash(data: Data(identitySource.utf8)).map { String(format: "%02x", $0) }.joined()
        return .init(accessToken: token, accountID: provider == .codex ? account : nil, identity: identity, plan: plan)
    }

    private static func credentialFile(_ file: URL) throws -> Data {
        guard FileManager.default.fileExists(atPath: file.path) else { throw ReadError.missing }
        do {
            let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true,
                  let size = values.fileSize, size > 0 && size <= 1_048_576 else { throw ReadError.invalidCredential }
            let data = try Data(contentsOf: file)
            guard data.count <= 1_048_576 else { throw ReadError.invalidCredential }
            return data
        } catch { throw ReadError.invalidCredential }
    }

    private static let keychainInteractionLock = NSLock()

    private static func claudeKeychain(allowInteraction: Bool = false) throws -> Data {
        // Claude Code still uses the legacy login keychain. LAContext alone does not
        // suppress that keychain's access dialog; preserve its process-wide policy.
        // Serialize the short policy scope so background reads cannot enable dialogs.
        keychainInteractionLock.lock()
        defer { keychainInteractionLock.unlock() }
        var previous: DarwinBoolean = true
        guard SecKeychainGetUserInteractionAllowed(&previous) == errSecSuccess,
              SecKeychainSetUserInteractionAllowed(allowInteraction) == errSecSuccess else {
            throw ReadError.keychainAccess
        }
        defer { SecKeychainSetUserInteractionAllowed(previous.boolValue) }

        let context = LAContext()
        context.interactionNotAllowed = !allowInteraction
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "Claude Code-credentials",
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true,
            kSecUseAuthenticationContext as String: context
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { throw ReadError.missing }
        guard status == errSecSuccess else { throw ReadError.keychainAccess }
        guard let data = result as? Data, data.count <= 1_048_576 else { throw ReadError.invalidCredential }
        return data
    }

    private static func jwtExpiry(_ token: String) -> Date? {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        var raw = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        raw += String(repeating: "=", count: (4 - raw.count % 4) % 4)
        guard let data = Data(base64Encoded: raw), let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let stamp = number(object["exp"]), stamp > 0, stamp < 253_402_300_800 else { return nil }
        return Date(timeIntervalSince1970: stamp)
    }

    private static func validHeader(_ value: String, maximum: Int) -> Bool {
        !value.isEmpty && value.utf8.count <= maximum && value.unicodeScalars.allSatisfy { $0.value >= 33 && $0.value <= 126 }
    }
    private static func safeLabel(_ value: Any?) -> String? {
        guard let text = value as? String else { return nil }
        let value = String(text.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }.prefix(80)).trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
    private static func number(_ value: Any?) -> Double? {
        guard let value = value as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(), value.doubleValue.isFinite else { return nil }
        return value.doubleValue
    }
    private static func percent(_ value: Any?) -> Double? {
        guard let value = number(value), value >= 0 && value <= 100 else { return nil }
        return value
    }
    private static func isoReset(_ raw: Any?) throws -> Date? {
        guard let raw, !(raw is NSNull) else { return nil }
        guard let text = raw as? String, let date = MeterDate.parse(text) else { throw ReadError.invalidResponse }
        return date
    }
}

/// A private session never follows redirects or persists tokens/cookies. The size limit applies while streaming.
private final class QuotaFetch: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    struct Response { var data: Data; var status: Int }
    private let lock = NSLock()
    private let done = DispatchSemaphore(value: 0)
    private var result: Result<Response, OAuthQuotaSource.ReadError>?
    private var body = Data()
    private var status = 0

    static func fetch(_ request: URLRequest) throws -> Response {
        let reader = QuotaFetch()
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.urlCache = nil
        config.urlCredentialStorage = nil
        config.timeoutIntervalForRequest = 8
        config.timeoutIntervalForResource = 8
        let session = URLSession(configuration: config, delegate: reader, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        session.dataTask(with: request).resume()
        guard reader.done.wait(timeout: .now() + 8) == .success else { throw OAuthQuotaSource.ReadError.timedOut }
        reader.lock.lock(); defer { reader.lock.unlock() }
        guard let result = reader.result else { throw OAuthQuotaSource.ReadError.unavailable }
        return try result.get()
    }

    private func finish(_ result: Result<Response, OAuthQuotaSource.ReadError>) {
        lock.lock()
        guard self.result == nil else { lock.unlock(); return }
        self.result = result
        body.removeAll(keepingCapacity: false)
        lock.unlock()
        done.signal()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
        finish(.failure(.redirect))
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let response = response as? HTTPURLResponse, response.expectedContentLength <= 2 * 1024 * 1024 else {
            completionHandler(.cancel); finish(.failure(.invalidResponse)); return
        }
        do { try OAuthQuotaSource.validateStatus(response.statusCode) }
        catch let error as OAuthQuotaSource.ReadError { completionHandler(.cancel); finish(.failure(error)); return }
        catch { completionHandler(.cancel); finish(.failure(.unavailable)); return }
        status = response.statusCode
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard body.count + data.count <= 2 * 1024 * 1024 else {
            dataTask.cancel(); finish(.failure(.invalidResponse)); return
        }
        body.append(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error = error as? URLError {
            finish(.failure(error.code == .timedOut ? .timedOut : .unavailable))
        } else if error != nil {
            finish(.failure(.unavailable))
        } else {
            finish(.success(.init(data: body, status: status)))
        }
    }
}
