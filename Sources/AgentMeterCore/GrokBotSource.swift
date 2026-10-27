import Foundation
import CommonCrypto
import Darwin

public enum GrokBotSource {
    private static let note = "Grok Bot 官方用量；暂未提供每日 Token 和费用。"

    /// Reads the existing desktop login and quota only. Never refreshes or changes its credentials.
    public static func load(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> ProviderSnapshot {
        do {
            let credentials = try GrokBotCredentials.read(home: home)
            let data = try fetchQuota(credentials)
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw GrokBotReadError.invalidResponse
            }
            return parse(object)
        } catch let error as GrokBotReadError {
            return failure(error.message)
        } catch {
            // Never surface keychain, token, URLSession, or backend response details.
            return failure(GrokBotReadError.invalidResponse.message)
        }
    }

    public static func parse(_ object: [String: Any], now: Date = Date()) -> ProviderSnapshot {
        let unified = object["isUnified"] as? Bool == true
        let sourceNote = note + (unified ? " 此额度为 Cursor、Grok Bot 与 Grok 共享的每周额度。" : "")
        guard object["usesPooledEnterpriseAllowance"] as? Bool != true else {
            return unavailable("团队共享额度暂不支持按个人显示。", sourceNote: sourceNote, now: now)
        }
        // Official screens show percent used and separately explain trial/no-allowance states.
        // A remaining-quota meter must not imply a usable weekly grant in those states.
        if object["hasNonZeroIncludedLimit"] as? Bool == false {
            return unavailable("当前账号未提供每周订阅额度，请在 Grok Bot 中查看试用或计划状态。", sourceNote: sourceNote, now: now)
        }
        guard let value = object["usagePercent"] as? NSNumber,
              CFGetTypeID(value) != CFBooleanGetTypeID(),
              value.doubleValue.isFinite, value.doubleValue >= 0 else {
            return failure("当前账号未提供可读取的每周额度。", sourceNote: sourceNote)
        }
        if object["hasAvailableUsage"] as? Bool == false, value.doubleValue < 100 {
            return unavailable("当前账号没有可用额度，请在 Grok Bot 中查看计划状态。", sourceNote: sourceNote, now: now)
        }
        let plan = unified ? label(object["cursorPlanName"]) ?? label(object["grokPlanLabel"])
                           : label(object["grokPlanLabel"])
        let reset = (object["nextResetTimestampUtc"] as? String).flatMap(MeterDate.parse)
        return .init(provider: .grokBot, plan: plan,
                     windows: [.init(id: "grokBot.weekly", title: "每周", usedPercent: value.doubleValue, resetsAt: reset)],
                     updatedAt: now, days: [], sourceNote: sourceNote,
                     message: reset.map { $0 <= now } == true ? "额度窗口已到重置时间，请刷新确认。" : nil)
    }

    private static func label(_ value: Any?) -> String? {
        guard let text = value as? String else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : String(trimmed.prefix(80))
    }

    private static func failure(_ message: String, sourceNote: String = note) -> ProviderSnapshot {
        var snapshot = ProviderSnapshot(provider: .grokBot, days: [], sourceNote: sourceNote, message: message)
        snapshot.quotaReadFailed = true
        return snapshot
    }

    private static func unavailable(_ message: String, sourceNote: String, now: Date) -> ProviderSnapshot {
        // This is a successful account-state read: an old quota must not be restored by SnapshotMerge.
        .init(provider: .grokBot, updatedAt: now, days: [], sourceNote: sourceNote, message: message)
    }

    private static func fetchQuota(_ credentials: GrokBotCredentials) throws -> Data {
        // This private RPC is also used by the installed official Grok Bot client.
        // Keep the destination fixed so an alternate URL can never receive its login token.
        let url = URL(string: "https://api2.cursor.sh/aiserver.v1.DashboardService/GetSandUsageStatus")!
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 12)
        request.httpMethod = "POST"
        request.httpBody = Data("{}".utf8)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")
        request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("true", forHTTPHeaderField: "x-ghost-mode")
        if let team = credentials.teamID { request.setValue(team, forHTTPHeaderField: "x-cursor-team-id") }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 12
        configuration.timeoutIntervalForResource = 12
        let session = URLSession(configuration: configuration, delegate: GrokBotNoRedirect(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let result = GrokBotHTTPResult()
        let finished = DispatchSemaphore(value: 0)
        let task = session.dataTask(with: request) { data, response, error in
            defer { finished.signal() }
            if let error = error as? URLError, error.code == .timedOut {
                result.store(.failure(.timedOut))
            } else if error != nil {
                result.store(.failure(.requestFailed))
            } else if let response = response as? HTTPURLResponse, response.statusCode == 401 {
                result.store(.failure(.expiredLogin))
            } else if let response = response as? HTTPURLResponse, response.statusCode == 200,
                      let data, data.count <= 1024 * 1024 {
                result.store(.success(data))
            } else {
                result.store(.failure(.requestFailed))
            }
        }
        task.resume()
        guard finished.wait(timeout: .now() + 12) == .success else {
            task.cancel()
            throw GrokBotReadError.timedOut
        }
        return try result.read().get()
    }
}

private enum GrokBotReadError: Error {
    case notLoggedIn, loginUnavailable, expiredLogin, timedOut, requestFailed, invalidResponse

    var message: String {
        switch self {
        case .notLoggedIn: return "请先在 Grok Bot 中登录，再刷新用量。"
        case .loginUnavailable: return "未获授权读取 Grok Bot 登录信息，请在应用中确认登录状态后重试。"
        case .expiredLogin: return "Grok Bot 登录已过期，请打开应用刷新登录后重试。"
        case .timedOut: return "Grok Bot 用量请求超时，请稍后刷新。"
        case .requestFailed: return "暂时无法读取 Grok Bot 用量，请确认登录和网络后重试。"
        case .invalidResponse: return "Grok Bot 用量数据暂时无法识别，请稍后刷新。"
        }
    }
}

private struct GrokBotCredentials {
    var accessToken: String
    var teamID: String?

    static func read(home: URL) throws -> Self {
        let url = home.appendingPathComponent("Library/Application Support/Grok Bot/sand-secrets.json")
        guard FileManager.default.fileExists(atPath: url.path) else { throw GrokBotReadError.notLoggedIn }
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size <= 1024 * 1024,
              let data = try? Data(contentsOf: url), data.count <= 1024 * 1024,
              let store = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw GrokBotReadError.loginUnavailable
        }
        let selected: [String: String]
        if let rawAccounts = store["cursor-accounts"] as? String {
            guard let accountsData = rawAccounts.data(using: .utf8),
                  let record = (try? JSONSerialization.jsonObject(with: accountsData)) as? [String: Any] else {
                throw GrokBotReadError.loginUnavailable
            }
            guard let active = record["active"] as? String,
                  let accounts = record["accounts"] as? [String: [String: String]],
                  let account = accounts[active] else { throw GrokBotReadError.notLoggedIn }
            selected = account
        } else {
            // Older official clients kept the active token in the top-level record.
            selected = store.compactMapValues { $0 as? String }
        }
        guard let rawToken = selected["cursor-access-token"] else { throw GrokBotReadError.notLoggedIn }
        var password = try keychainPassword()
        defer { password.resetBytes(in: 0..<password.count) }
        let token = try decrypt(rawToken, password: password)
        guard !token.isEmpty, !token.contains("\r"), !token.contains("\n") else { throw GrokBotReadError.loginUnavailable }
        var teamID: String?
        if let rawTeam = selected["cursor-selected-team-id"] {
            let team = try decrypt(rawTeam, password: password)
            guard let number = Int64(team), number > 0, number <= 9_007_199_254_740_991 else {
                throw GrokBotReadError.loginUnavailable
            }
            teamID = String(number)
        }
        return .init(accessToken: token, teamID: teamID)
    }

    private static func keychainPassword() throws -> Data {
        // The legacy macOS keychain can block SecItemCopyMatching despite interactionNotAllowed.
        // The trusted system reader already has access; never modify that item's ACL or run a shell.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", "Grok Bot Safe Storage", "-w"]
        var password = try GrokBotBoundedProcess.read(process, timeout: 5)
        if password.last == 10 { password.removeLast() } // security appends one output newline.
        guard !password.isEmpty else { throw GrokBotReadError.loginUnavailable }
        return password
    }

    private static func decrypt(_ stored: String, password: Data) throws -> String {
        var encoded = stored
        if encoded.hasPrefix("scoped:v1:") {
            let parts = encoded.split(separator: ":", maxSplits: 3, omittingEmptySubsequences: false)
            guard parts.count == 4 else { throw GrokBotReadError.loginUnavailable }
            encoded = String(parts[3])
        }
        guard let encrypted = Data(base64Encoded: encoded), encrypted.starts(with: Data("v10".utf8)),
              encrypted.count > 3 else { throw GrokBotReadError.loginUnavailable }
        let salt = Data("saltysalt".utf8)
        var key = Data(repeating: 0, count: kCCKeySizeAES128)
        defer { key.resetBytes(in: 0..<key.count) }
        let derived = password.withUnsafeBytes { passwordBytes in
            salt.withUnsafeBytes { saltBytes in
                key.withUnsafeMutableBytes { keyBytes in
                    CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2),
                                        passwordBytes.baseAddress?.assumingMemoryBound(to: Int8.self), password.count,
                                        saltBytes.baseAddress?.assumingMemoryBound(to: UInt8.self), salt.count,
                                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1), 1003,
                                        keyBytes.baseAddress?.assumingMemoryBound(to: UInt8.self), kCCKeySizeAES128)
                }
            }
        }
        guard derived == kCCSuccess else { throw GrokBotReadError.loginUnavailable }
        let ciphertext = encrypted.dropFirst(3)
        let iv = Data(repeating: 32, count: kCCBlockSizeAES128)
        var output = Data(repeating: 0, count: ciphertext.count + kCCBlockSizeAES128)
        let capacity = output.count
        var written = 0
        let status = key.withUnsafeBytes { keyBytes in
            iv.withUnsafeBytes { ivBytes in
                ciphertext.withUnsafeBytes { cipherBytes in
                    output.withUnsafeMutableBytes { outputBytes in
                        CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                                keyBytes.baseAddress, kCCKeySizeAES128, ivBytes.baseAddress,
                                cipherBytes.baseAddress, ciphertext.count, outputBytes.baseAddress, capacity, &written)
                    }
                }
            }
        }
        defer { output.resetBytes(in: 0..<output.count) }
        guard status == kCCSuccess, let plaintext = String(data: output.prefix(written), encoding: .utf8) else {
            throw GrokBotReadError.loginUnavailable
        }
        return plaintext
    }
}

private final class GrokBotNoRedirect: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

private final class GrokBotHTTPResult: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Result<Data, GrokBotReadError> = .failure(.requestFailed)
    func store(_ result: Result<Data, GrokBotReadError>) {
        lock.lock(); defer { lock.unlock() }
        value = result
    }
    func read() -> Result<Data, GrokBotReadError> {
        lock.lock(); defer { lock.unlock() }
        return value
    }
}

// Internal so the bounded subprocess lifecycle can be checked without a real keychain.
// The sole production caller above fixes both executable and arguments.
enum GrokBotBoundedProcess {
    static func read(_ process: Process, timeout: TimeInterval) throws -> Data {
        let output = Pipe()
        let errors = Pipe()
        let state = GrokBotSecretOutput()
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = errors
        output.fileHandleForReading.readabilityHandler = { handle in
            let data = (try? handle.read(upToCount: 4096)) ?? Data()
            state.receive(data)
            if data.isEmpty { handle.readabilityHandler = nil }
        }
        errors.fileHandleForReading.readabilityHandler = { handle in
            // Discard private diagnostics while draining the pipe so it cannot block the child.
            if ((try? handle.read(upToCount: 65536)) ?? Data()).isEmpty { handle.readabilityHandler = nil }
        }
        process.terminationHandler = { child in state.finish(child.terminationStatus) }
        defer {
            if process.isRunning {
                process.terminate()
                let deadline = Date().addingTimeInterval(0.2)
                while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
                if process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) }
                let killDeadline = Date().addingTimeInterval(0.2)
                while process.isRunning && Date() < killDeadline { Thread.sleep(forTimeInterval: 0.01) }
            }
            output.fileHandleForReading.readabilityHandler = nil
            errors.fileHandleForReading.readabilityHandler = nil
            try? output.fileHandleForReading.close()
            try? errors.fileHandleForReading.close()
            state.clear()
        }
        do { try process.run() }
        catch { throw GrokBotReadError.loginUnavailable }
        return try state.wait(until: Date().addingTimeInterval(timeout))
    }
}

private final class GrokBotSecretOutput: @unchecked Sendable {
    private let condition = NSCondition()
    private var data = Data()
    private var ended = false
    private var exitStatus: Int32?
    private var oversized = false

    func receive(_ chunk: Data) {
        condition.lock(); defer { condition.broadcast(); condition.unlock() }
        if chunk.isEmpty { ended = true; return }
        guard !oversized, data.count + chunk.count <= 4096 else {
            oversized = true
            data.resetBytes(in: 0..<data.count)
            data.removeAll()
            return
        }
        data.append(chunk)
    }

    func finish(_ status: Int32) {
        condition.lock(); defer { condition.broadcast(); condition.unlock() }
        exitStatus = status
    }

    func wait(until deadline: Date) throws -> Data {
        condition.lock(); defer { condition.unlock() }
        while (!ended || exitStatus == nil) && !oversized {
            guard condition.wait(until: deadline) else { throw GrokBotReadError.loginUnavailable }
        }
        guard !oversized, exitStatus == 0, !data.isEmpty else { throw GrokBotReadError.loginUnavailable }
        return data
    }

    func clear() {
        condition.lock(); defer { condition.unlock() }
        data.resetBytes(in: 0..<data.count)
        data.removeAll()
    }
}
