import Foundation
import Combine
import Darwin
import AgentMeterCore

enum AccountLoginFailure: Error, Equatable {
    case missingCLI, unsuccessful, timedOut, cancelled, credentialAccess, signInRequired

    var message: String {
        switch self {
        case .missingCLI: "未找到登录工具，请先安装对应的官方命令行工具。"
        case .unsuccessful: "登录未完成，请重试。"
        case .timedOut: "登录已超时，请重试。"
        case .cancelled: "登录已取消。"
        case .credentialAccess: "无法读取登录凭证，请允许本机钥匙串访问后重试。"
        case .signInRequired: "未找到有效登录，请先点击浏览器登录。"
        }
    }
}

enum AccountAuthorizationState: Equatable {
    case disconnected, enabled, waiting, preparing, checking, failed(AccountLoginFailure)

    var isBusy: Bool { self == .waiting || self == .preparing }
    var message: String {
        switch self {
        case .disconnected: "尚未授权"
        case .enabled: "已启用授权读取"
        case .waiting: "请在浏览器完成登录…"
        case .preparing: "正在连接账户…"
        case .checking: "登录完成，正在验证额度…"
        case .failed(let error): error.message
        }
    }
}

typealias AccountLoginRunner = (
    _ executable: String, _ arguments: [String], _ timeout: TimeInterval,
    _ completion: @escaping (Result<Void, AccountLoginFailure>) -> Void
) throws -> (() -> Void)

/// Owns permission to read an existing account, not the account's credentials.
/// Login is performed by each provider's CLI, which retains ownership of its tokens.
@MainActor
final class AccountAuthorizationController: ObservableObject {
    @Published private(set) var states: [ProviderID: AccountAuthorizationState] = [:]
    var onChange: ((ProviderID) -> Void)?

    private let active: Bool
    private let defaults: UserDefaults
    private let resolveExecutable: (ProviderID) -> String?
    private let runLogin: AccountLoginRunner
    private let loginTimeout: TimeInterval
    private let prepareConnection: (ProviderID) throws -> Void
    private var loginIDs: [ProviderID: UUID] = [:]
    private var cancellations: [ProviderID: () -> Void] = [:]

    init(active: Bool = true, defaults: UserDefaults = .standard, loginTimeout: TimeInterval = 300,
         prepareConnection: @escaping (ProviderID) throws -> Void = OAuthQuotaSource.prepareConnection,
         resolveExecutable: @escaping (ProviderID) -> String? = { provider in
             guard provider == .codex || provider == .claude else { return nil }
             return ProviderInstallation.executable(named: provider.rawValue)
         },
         runLogin: @escaping AccountLoginRunner = AccountLoginProcess.start) {
        self.active = active
        self.defaults = defaults
        self.resolveExecutable = resolveExecutable
        self.runLogin = runLogin
        self.loginTimeout = min(300, max(0.01, loginTimeout))
        self.prepareConnection = prepareConnection
    }

    static func consentKey(_ provider: ProviderID) -> String { "nowbar.oauth.\(provider.rawValue).enabled" }

    func isEnabled(_ provider: ProviderID) -> Bool {
        active && Self.supports(provider) && defaults.bool(forKey: Self.consentKey(provider))
    }

    func state(for provider: ProviderID) -> AccountAuthorizationState {
        states[provider] ?? (isEnabled(provider) ? .enabled : .disconnected)
    }

    func connectExisting(_ provider: ProviderID) {
        guard active, Self.supports(provider), !state(for: provider).isBusy else { return }
        let identifier = UUID()
        loginIDs[provider] = identifier
        prepare(provider, identifier: identifier, afterLogin: false)
    }

    private func prepare(_ provider: ProviderID, identifier: UUID, afterLogin: Bool) {
        states[provider] = .preparing
        let preparation = prepareConnection
        Task { @MainActor [weak self] in
            let failure: AccountLoginFailure? = await Task.detached(priority: .userInitiated) {
                do { try preparation(provider); return nil }
                catch OAuthQuotaSource.ReadError.missing { return .signInRequired }
                catch OAuthQuotaSource.ReadError.expired { return .signInRequired }
                catch { return .credentialAccess }
            }.value
            guard let self, self.loginIDs[provider] == identifier else { return }
            self.loginIDs.removeValue(forKey: provider)
            if let failure {
                self.states[provider] = .failed(failure)
                return
            }
            self.defaults.set(true, forKey: Self.consentKey(provider))
            self.states[provider] = afterLogin ? .checking : .enabled
            self.onChange?(provider)
        }
    }

    func signIn(_ provider: ProviderID) {
        guard active, Self.supports(provider), !state(for: provider).isBusy else { return }
        guard let executable = resolveExecutable(provider) else {
            states[provider] = .failed(.missingCLI)
            return
        }
        let identifier = UUID()
        loginIDs[provider] = identifier
        states[provider] = .waiting
        do {
            let cancel = try runLogin(executable, Self.loginArguments(for: provider), loginTimeout) { [weak self] result in
                Task { @MainActor [weak self] in
                    guard let self, self.loginIDs[provider] == identifier else { return }
                    self.cancellations.removeValue(forKey: provider)
                    switch result {
                    case .success: self.prepare(provider, identifier: identifier, afterLogin: true)
                    case .failure(let failure):
                        self.loginIDs.removeValue(forKey: provider)
                        self.states[provider] = .failed(failure)
                    }
                }
            }
            cancellations[provider] = cancel
        } catch {
            loginIDs.removeValue(forKey: provider)
            states[provider] = .failed(.unsuccessful)
        }
    }

    func cancel(_ provider: ProviderID) {
        guard active else { return }
        loginIDs.removeValue(forKey: provider)
        cancellations.removeValue(forKey: provider)?()
        states[provider] = isEnabled(provider) ? .enabled : .disconnected
    }

    /// Disconnecting NowBar does not log out or erase the provider's shared account.
    func disconnect(_ provider: ProviderID) {
        guard active, Self.supports(provider) else { return }
        cancel(provider)
        defaults.set(false, forKey: Self.consentKey(provider))
        states[provider] = .disconnected
        onChange?(provider)
    }

    static func loginArguments(for provider: ProviderID) -> [String] {
        switch provider {
        case .codex: ["login"]
        case .claude: ["auth", "login", "--claudeai"]
        case .grokBot: []
        }
    }

    private static func supports(_ provider: ProviderID) -> Bool { provider == .codex || provider == .claude }

    deinit { for cancel in cancellations.values { cancel() } }
}

/// Launches without a shell and drains both pipes without storing or parsing their contents.
/// Process lifecycle work is serialized off the main actor; a timed-out/cancelled child is reaped.
private final class AccountLoginProcess: @unchecked Sendable {
    private let queue = DispatchQueue(label: "NowBar.AccountLogin", qos: .userInitiated)
    private let process = Process()
    private let output = Pipe()
    private let errors = Pipe()
    private var finished = false
    private var timeoutWork: DispatchWorkItem?
    private let completion: (Result<Void, AccountLoginFailure>) -> Void

    private init(completion: @escaping (Result<Void, AccountLoginFailure>) -> Void) {
        self.completion = completion
    }

    static func start(executable: String, arguments: [String], timeout: TimeInterval,
                      completion: @escaping (Result<Void, AccountLoginFailure>) -> Void) throws -> (() -> Void) {
        let operation = AccountLoginProcess(completion: completion)
        operation.queue.async {
            operation.launch(executable: executable, arguments: arguments, timeout: timeout)
        }
        return { operation.queue.async { operation.stop(with: .cancelled) } }
    }

    private func launch(executable: String, arguments: [String], timeout: TimeInterval) {
        guard !finished else { return }
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = errors
        // GUI launches may omit the selected Node/Homebrew directory from PATH.
        var environment = ProcessInfo.processInfo.environment
        let directory = URL(fileURLWithPath: executable).deletingLastPathComponent().path
        environment["PATH"] = directory + ":" + (environment["PATH"] ?? "/usr/bin:/bin")
        process.environment = environment
        for pipe in [output, errors] {
            pipe.fileHandleForReading.readabilityHandler = { handle in
                if handle.availableData.isEmpty { handle.readabilityHandler = nil }
            }
        }
        process.terminationHandler = { [weak self] child in
            guard let self else { return }
            self.queue.async {
                self.finish(child.terminationReason == .exit && child.terminationStatus == 0
                            ? .success(()) : .failure(.unsuccessful))
            }
        }
        do {
            try process.run()
            let work = DispatchWorkItem { [weak self] in self?.stop(with: .timedOut) }
            timeoutWork = work
            queue.asyncAfter(deadline: .now() + max(0.01, min(300, timeout)), execute: work)
        } catch {
            finish(.failure(.unsuccessful))
        }
    }

    private func stop(with reason: AccountLoginFailure) {
        guard !finished else { return }
        if process.isRunning {
            process.terminate()
            let child = process
            // Do not wait for the child on the main actor or block cancellation delivery.
            queue.asyncAfter(deadline: .now() + 0.4) {
                if child.isRunning { Darwin.kill(child.processIdentifier, SIGKILL) }
            }
        }
        finish(.failure(reason))
    }

    private func finish(_ result: Result<Void, AccountLoginFailure>) {
        guard !finished else { return }
        finished = true
        timeoutWork?.cancel()
        timeoutWork = nil
        for pipe in [output, errors] {
            pipe.fileHandleForReading.readabilityHandler = nil
            try? pipe.fileHandleForReading.close()
            try? pipe.fileHandleForWriting.close()
        }
        completion(result)
    }
}
