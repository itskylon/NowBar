import Foundation
import CommonCrypto
import SQLite3

/// Read-only subscription data from the account signed in to the Claude desktop app.
public enum ClaudeDesktopSource {
    static let note = "Claude 桌面版账户共享额度；普通聊天未提供每日 Token。"
    static let cacheNote = "Claude 桌面缓存中的 5 小时额度；随聊天更新，普通聊天未提供每日 Token。"

    public static func isPresent(home: URL) -> Bool {
        cookieStores(home: home).contains { FileManager.default.fileExists(atPath: $0.path) }
    }

    public static func load(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> ProviderSnapshot {
        var accountID: String?
        do {
            let credentials = try readCredentials(home: home)
            let orgData = try fetch(request(path: "/api/organizations", sessionKey: credentials.sessionKey))
            guard let orgs = try JSONSerialization.jsonObject(with: orgData) as? [[String: Any]] else {
                throw ReadError.invalidResponse
            }
            let org = try selectOrganization(orgs, preferredID: credentials.organization)
            guard let id = org["uuid"] as? String, UUID(uuidString: id) != nil else { throw ReadError.invalidResponse }
            accountID = quotaIdentity(sessionKey: credentials.sessionKey, organizationID: id)
            let data = try fetch(request(path: "/api/organizations/\(id)/usage", sessionKey: credentials.sessionKey))
            guard let usage = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw ReadError.invalidResponse
            }
            let plan = planName(org)
            let value = parseUsage(usage, plan: plan, accountID: accountID)
            // Free accounts can return null aggregate API limits while the desktop has real observations.
            guard plan?.caseInsensitiveCompare("Free") == .orderedSame, value.quotaReadFailed != true,
                  !value.windows.contains(where: { $0.id == "claude.five_hour" }),
                  let cached = ClaudeDesktopQuotaCache.load(home: home, organizationID: id) else { return value }
            return applyingCache(cached, to: value)
        } catch let error as ReadError {
            return failure(error, accountID: accountID)
        } catch {
            // Never expose HTTP bodies, cookie contents, keychain diagnostics or account metadata.
            return failure(.unavailable, accountID: accountID)
        }
    }

    public static func parseUsage(_ usage: [String: Any], plan: String? = nil,
                                  accountID: String? = nil, now: Date = Date()) -> ProviderSnapshot {
        let fields = [("five_hour", "5 小时"), ("seven_day", "每周"),
                      ("seven_day_opus", "Opus 每周"), ("seven_day_sonnet", "Sonnet 每周"),
                      ("seven_day_cowork", "Cowork 每周")]
        var windows: [LimitWindow] = []
        var malformed = false
        for (key, title) in fields {
            guard let raw = usage[key], !(raw is NSNull) else { continue }
            guard let item = raw as? [String: Any], let n = item["utilization"] as? NSNumber,
                  CFGetTypeID(n) != CFBooleanGetTypeID(), n.doubleValue.isFinite, n.doubleValue >= 0 else {
                malformed = true; continue
            }
            windows.append(.init(id: "claude.\(key)", title: title, usedPercent: n.doubleValue,
                                 resetsAt: (item["resets_at"] as? String).flatMap(MeterDate.parse)))
        }
        // New responses expose model-specific weekly budgets separately from the aggregate windows.
        var scopedIDs = Set<String>()
        for raw in usage["limits"] as? [Any] ?? [] {
            guard let item = raw as? [String: Any], item["kind"] as? String == "weekly_scoped",
                  item["group"] as? String == "weekly" else { continue }
            guard let n = item["percent"] as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(),
                  n.doubleValue.isFinite, n.doubleValue >= 0,
                  let scope = item["scope"] as? [String: Any], let model = scope["model"] as? [String: Any],
                  let rawName = model["display_name"] as? String else { malformed = true; continue }
            let name = String(rawName.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))
            let identity = (model["id"] as? String ?? name).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, !identity.isEmpty else { malformed = true; continue }
            let normalized = identity.lowercased().replacingOccurrences(of: "_", with: "-")
            guard name.lowercased() != "all models", normalized != "all-models",
                  !normalized.hasSuffix("-all-models"), scopedIDs.insert(identity).inserted else { continue }
            windows.append(.init(id: "claude.scoped." + identity, title: name + " 每周", usedPercent: n.doubleValue,
                                 resetsAt: (item["resets_at"] as? String).flatMap(MeterDate.parse)))
        }
        let recognized = fields.contains { usage.keys.contains($0.0) } || usage["limits"] is [Any]
        if !recognized || (windows.isEmpty && malformed) { return failure(.invalidResponse, accountID: accountID) }
        let message: String? = windows.isEmpty ? "Claude 已连接；在桌面版正常聊天后，会自动读取 5 小时额度。" : nil
        var value = ProviderSnapshot(provider: .claude, plan: plan.map { String($0.prefix(80)) },
                                     windows: windows, updatedAt: now, sourceNote: note, message: message)
        value.quotaSource = .claudeDesktop
        value.quotaAccountID = accountID
        value.quotaMessage = message
        return value
    }

    static func applyingCache(_ sample: ClaudeDesktopQuotaCache.Sample, to value: ProviderSnapshot) -> ProviderSnapshot {
        guard !value.windows.contains(where: { $0.id == sample.window.id }) else { return value }
        var value = value
        value.windows.insert(sample.window, at: 0)
        value.updatedAt = sample.observedAt
        value.quotaFromCache = true
        value.sourceNote = cacheNote
        value.message = nil; value.quotaMessage = nil
        return value
    }

    static func planName(_ org: [String: Any]) -> String? {
        for key in ["plan_display_label", "plan_display_name"] {
            if let name = org[key] as? String, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return String(name.prefix(80))
            }
        }
        // These are the explicit Free billing/tier values, not an inference from a missing limit.
        if org["billing_type"] as? String == "none", org["rate_limit_tier"] as? String == "default_claude_ai" {
            return "Free"
        }
        return nil
    }

    // Organizations can contain multiple users; never reuse one user's quota after a desktop login switch.
    static func quotaIdentity(sessionKey: String, organizationID: String) -> String {
        SHA256Digest(organizationID + "|" + sessionKey).map { String(format: "%02x", $0) }.joined()
    }

    static func selectOrganization(_ orgs: [[String: Any]], preferredID: String?) throws -> [String: Any] {
        let chat = orgs.filter { ($0["capabilities"] as? [String])?.contains("chat") == true }
        if let preferredID {
            guard let active = chat.first(where: { $0["uuid"] as? String == preferredID }) else { throw ReadError.organization }
            return active
        }
        guard chat.count == 1, let only = chat.first else { throw ReadError.organization }
        return only
    }

    static func request(path: String, sessionKey: String) throws -> URLRequest {
        // Validate both route and value before placing a secret in a request. No caller-supplied host.
        let prefix = "/api/organizations/"
        let suffix = "/usage"
        let organizationRoute = path.hasPrefix(prefix) && path.hasSuffix(suffix)
            && UUID(uuidString: String(path.dropFirst(prefix.count).dropLast(suffix.count))) != nil
        guard path == "/api/organizations" || organizationRoute,
              !sessionKey.isEmpty, sessionKey.utf8.count <= 4096,
              sessionKey.unicodeScalars.allSatisfy({ $0.value >= 33 && $0.value <= 126 && $0 != ";" }) else {
            throw ReadError.login
        }
        var request = URLRequest(url: URL(string: "https://claude.ai" + path)!,
                                 cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 12)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("sessionKey=\(sessionKey)", forHTTPHeaderField: "Cookie")
        return request
    }

    private static func cookieStores(home: URL) -> [URL] {
        let root = home.appendingPathComponent("Library/Application Support/Claude", isDirectory: true)
        return [root.appendingPathComponent("Cookies"), root.appendingPathComponent("Network/Cookies")]
    }

    private struct Credentials { var sessionKey: String; var organization: String? }

    private static func readCredentials(home: URL) throws -> Credentials {
        guard let file = cookieStores(home: home).first(where: { FileManager.default.fileExists(atPath: $0.path) }) else {
            throw ReadError.login
        }
        let metadata = try file.resourceValues(forKeys: [.fileSizeKey, .isSymbolicLinkKey])
        guard metadata.isSymbolicLink != true, let size = metadata.fileSize, size <= 16 * 1024 * 1024 else { throw ReadError.login }
        var database: OpaquePointer?
        guard sqlite3_open_v2(file.path, &database, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK else {
            if let database { sqlite3_close(database) }; throw ReadError.login
        }
        defer { sqlite3_close(database) }
        sqlite3_busy_timeout(database, 500)
        var statement: OpaquePointer?
        let sql = "SELECT host_key,name,value,encrypted_value,expires_utc FROM cookies WHERE host_key IN ('claude.ai','.claude.ai') AND name IN ('sessionKey','lastActiveOrg') ORDER BY last_access_utc DESC"
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { throw ReadError.login }
        defer { sqlite3_finalize(statement) }
        var rows: [(host: String, name: String, plain: String, encrypted: Data)] = []
        var step = sqlite3_step(statement)
        while step == SQLITE_ROW {
            defer { step = sqlite3_step(statement) }
            guard rows.count < 20, let host = sqlite3_column_text(statement, 0), let name = sqlite3_column_text(statement, 1) else { throw ReadError.login }
            let expires = sqlite3_column_int64(statement, 4)
            if expires > 0, Double(expires) / 1_000_000 - 11_644_473_600 <= Date().timeIntervalSince1970 { continue }
            let count = Int(sqlite3_column_bytes(statement, 3))
            guard count <= 8192 else { throw ReadError.login }
            let encrypted = sqlite3_column_blob(statement, 3).map { Data(bytes: $0, count: count) } ?? Data()
            let plain = sqlite3_column_text(statement, 2).map { String(cString: $0) } ?? ""
            rows.append((String(cString: host), String(cString: name), plain, encrypted))
        }
        guard step == SQLITE_DONE, rows.contains(where: { $0.name == "sessionKey" }) else { throw ReadError.login }
        var password = Data()
        if rows.contains(where: { !$0.encrypted.isEmpty }) { password = try keychainPassword() }
        defer { password.resetBytes(in: 0..<password.count) }
        var values: [String: String] = [:]
        for row in rows where values[row.name] == nil {
            let value = row.encrypted.isEmpty ? row.plain : try decodeCookie(row.encrypted, host: row.host, password: password)
            if !value.isEmpty { values[row.name] = value }
        }
        guard let sessionKey = values["sessionKey"] else { throw ReadError.login }
        return .init(sessionKey: sessionKey, organization: values["lastActiveOrg"].flatMap { UUID(uuidString: $0) != nil ? $0 : nil })
    }

    private static func keychainPassword() throws -> Data {
        // Reuse the bounded system-keychain reader; never change ACLs or invoke a shell.
        for service in ["Claude Safe Storage", "Claude Key"] {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
            process.arguments = ["find-generic-password", "-s", service, "-w"]
            if var data = try? GrokBotBoundedProcess.read(process, timeout: 5) {
                if data.last == 10 { data.removeLast() }
                if !data.isEmpty { return data }
            }
        }
        throw ReadError.keychain
    }

    static func decodeCookie(_ encrypted: Data, host: String, password: Data) throws -> String {
        guard ["claude.ai", ".claude.ai"].contains(host), encrypted.starts(with: Data("v10".utf8)), encrypted.count > 3 else { throw ReadError.login }
        let salt = Data("saltysalt".utf8)
        var key = Data(repeating: 0, count: kCCKeySizeAES128)
        defer { key.resetBytes(in: 0..<key.count) }
        let status = password.withUnsafeBytes { p in salt.withUnsafeBytes { s in key.withUnsafeMutableBytes { k in
            CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), p.baseAddress?.assumingMemoryBound(to: Int8.self), password.count,
                                s.baseAddress?.assumingMemoryBound(to: UInt8.self), salt.count,
                                CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1), 1003,
                                k.baseAddress?.assumingMemoryBound(to: UInt8.self), kCCKeySizeAES128)
        } } }
        guard status == kCCSuccess else { throw ReadError.login }
        let cipher = encrypted.dropFirst(3), iv = Data(repeating: 32, count: kCCBlockSizeAES128)
        var output = Data(repeating: 0, count: cipher.count + kCCBlockSizeAES128)
        let capacity = output.count
        var written = 0
        let decrypted = key.withUnsafeBytes { k in iv.withUnsafeBytes { v in cipher.withUnsafeBytes { c in output.withUnsafeMutableBytes { o in
            CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                    k.baseAddress, kCCKeySizeAES128, v.baseAddress, c.baseAddress, cipher.count, o.baseAddress, capacity, &written)
        } } } }
        defer { output.resetBytes(in: 0..<output.count) }
        guard decrypted == kCCSuccess else { throw ReadError.login }
        let plaintext = Data(output.prefix(written)), domain = Data(SHA256Digest(host))
        // Modern Chromium binds every encrypted cookie to its domain (database v24+).
        guard plaintext.count > 32, plaintext.starts(with: domain),
              let value = String(data: plaintext.dropFirst(32), encoding: .utf8) else { throw ReadError.login }
        return value
    }

    private static func SHA256Digest(_ value: String) -> [UInt8] {
        let bytes = Data(value.utf8)
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        bytes.withUnsafeBytes { _ = CC_SHA256($0.baseAddress, CC_LONG(bytes.count), &digest) }
        return digest
    }

    private static func fetch(_ request: URLRequest) throws -> Data {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.timeoutIntervalForResource = 12
        let session = URLSession(configuration: configuration, delegate: NoRedirect(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let result = HTTPResult(), finished = DispatchSemaphore(value: 0)
        let task = session.dataTask(with: request) { data, response, error in
            defer { finished.signal() }
            let code = (response as? HTTPURLResponse)?.statusCode
            if error != nil { result.store(.failure(.unavailable)) }
            else if code == 401 { result.store(.failure(.login)) }
            else if code == 403 { result.store(.failure(.forbidden)) }
            else if code == 429 { result.store(.failure(.rateLimited)) }
            else if code == 200, let data, data.count <= 2 * 1024 * 1024 { result.store(.success(data)) }
            else { result.store(.failure(.unavailable)) }
        }
        task.resume()
        guard finished.wait(timeout: .now() + 13) == .success else { task.cancel(); throw ReadError.unavailable }
        return try result.read().get()
    }

    private enum ReadError: Error {
        case login, keychain, organization, unavailable, invalidResponse, forbidden, rateLimited
        var message: String {
            switch self {
            case .login: "请先在 Claude 桌面版登录，再刷新用量。"
            case .keychain: "无法读取 Claude 桌面版登录信息，请确认钥匙串访问后重试。"
            case .organization: "无法确定 Claude 当前账户，请在桌面版选择账户后重试。"
            case .unavailable: "暂时无法读取 Claude 桌面版用量，请检查网络后刷新。"
            case .invalidResponse: "Claude 桌面版用量格式暂时无法识别，请稍后刷新。"
            case .forbidden: "Claude 暂未允许读取用量，请打开桌面版确认登录后重试。"
            case .rateLimited: "Claude 用量查询暂时限流，请稍后刷新。"
            }
        }
    }

    private static func failure(_ error: ReadError, accountID: String?) -> ProviderSnapshot {
        var value = ProviderSnapshot(provider: .claude, sourceNote: note, message: error.message)
        value.quotaSource = .claudeDesktop; value.quotaAccountID = accountID
        value.quotaReadFailed = true; value.quotaMessage = value.message
        return value
    }

    private final class NoRedirect: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
    }
    private final class HTTPResult: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Result<Data, ReadError> = .failure(.unavailable)
        func store(_ value: Result<Data, ReadError>) { lock.lock(); defer { lock.unlock() }; self.value = value }
        func read() -> Result<Data, ReadError> { lock.lock(); defer { lock.unlock() }; return value }
    }
}
