import Foundation
import AgentMeterCore

@main
struct AuthorizationAcceptance {
    @MainActor static func main() async {
        let suite = "NowBar.AuthorizationTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var count = 0
        func expect(_ result: Bool, _ reason: String) {
            precondition(result, reason); count += 1
        }
        var completions: [(Result<Void, AccountLoginFailure>) -> Void] = []
        var commands: [[String]] = []
        var cancelled = 0
        var changes: [ProviderID] = []
        let auth = AccountAuthorizationController(defaults: defaults, prepareConnection: { _ in }, resolveExecutable: { _ in "/fixture/cli" },
            runLogin: { executable, arguments, timeout, completion in
                expect(executable == "/fixture/cli" && timeout == 300, "Resolved executable and bounded login time")
                commands.append(arguments); completions.append(completion)
                return { cancelled += 1 }
            })
        auth.onChange = { changes.append($0) }
        expect(!auth.isEnabled(.codex) && auth.state(for: .codex) == .disconnected, "First launch never discovers or reads credentials")
        expect(commands.isEmpty, "Initializing does not launch CLI or browser")
        auth.connectExisting(.codex)
        await settle(auth, .codex)
        expect(auth.isEnabled(.codex) && changes == [.codex], "Explicit existing-account connection enables only that provider")
        expect(commands.isEmpty && auth.state(for: .codex) == .enabled, "Existing-account connection launches no login")
        let restarted = AccountAuthorizationController(defaults: defaults, prepareConnection: { _ in }, resolveExecutable: { _ in nil })
        expect(restarted.isEnabled(.codex) && !restarted.isEnabled(.claude), "Only consent survives restart, not guessed quota state")
        auth.signIn(.claude)
        expect(commands.last == ["auth", "login", "--claudeai"] && auth.state(for: .claude).isBusy, "Claude launches the official Claude-account browser flow")
        expect(!auth.isEnabled(.claude), "A login attempt alone is not a completed connection")
        auth.signIn(.claude)
        expect(commands.count == 1, "Repeated presses cannot create concurrent login processes")
        completions[0](.success(()))
        await settle(auth, .claude)
        expect(auth.isEnabled(.claude) && auth.state(for: .claude) == .checking, "Successful CLI login requests quota verification without claiming quota success")
        expect(changes == [.codex, .claude], "Completed login requests a refresh")
        auth.signIn(.codex)
        expect(commands.last == ["login"], "Codex uses its browser login command")
        auth.disconnect(.codex)
        expect(!auth.isEnabled(.codex) && cancelled == 1 && auth.state(for: .codex) == .disconnected, "Disconnect only revokes NowBar access and cancels its pending login")
        completions[1](.success(()))
        await drain()
        expect(!auth.isEnabled(.codex) && auth.state(for: .codex) == .disconnected, "A stale login completion cannot reconnect after disconnect")
        auth.signIn(.codex)
        completions[2](.failure(.timedOut))
        await drain()
        expect(!auth.isEnabled(.codex) && auth.state(for: .codex) == .failed(.timedOut), "Timeout is distinct from successful authorization")
        auth.signIn(.codex)
        completions[3](.failure(.unsuccessful))
        await drain()
        expect(auth.state(for: .codex).message == "登录未完成，请重试。", "Failure feedback is fixed and never includes CLI output")
        auth.connectExisting(.grokBot)
        auth.signIn(.grokBot)
        expect(!auth.isEnabled(.grokBot) && commands.count == 4, "Unsupported services never invoke a fabricated authorization flow")
        let missing = AccountAuthorizationController(defaults: defaults, prepareConnection: { _ in }, resolveExecutable: { _ in nil })
        missing.signIn(.codex)
        expect(missing.state(for: .codex) == .failed(.missingCLI), "Missing CLI explains the required installation")
        let before = defaults.dictionaryRepresentation()
        let inactive = AccountAuthorizationController(active: false, defaults: defaults, prepareConnection: { _ in fatalError("Preview must never prompt") },
            resolveExecutable: { _ in fatalError("Preview must never resolve a real CLI") },
            runLogin: { _, _, _, _ in fatalError("Preview must never run login") })
        inactive.connectExisting(.codex); inactive.signIn(.claude); inactive.disconnect(.claude)
        expect(defaults.dictionaryRepresentation() as NSDictionary == before as NSDictionary, "Preview performs no consent or credential writes")
        expect(!inactive.isEnabled(.claude), "Preview does not inherit live consent")
        let path = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("nowbar-auth-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: path) }
        let script = path.appendingPathComponent("fixture")
        try! Data("#!/bin/sh\nprintf 'access_token=must-never-be-exposed\\n'\nprintf 'private session key\\n' >&2\nexit 7\n".utf8).write(to: script)
        try! FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        let actual = AccountAuthorizationController(defaults: defaults, prepareConnection: { _ in }, resolveExecutable: { _ in script.path })
        actual.signIn(.codex)
        for _ in 0..<200 where actual.state(for: .codex).isBusy { try? await Task.sleep(nanoseconds: 10_000_000) }
        expect(actual.state(for: .codex) == .failed(.unsuccessful), "Real failing child process discards both output streams")
        expect(!actual.state(for: .codex).message.contains("must-never"), "Secret-like process output cannot reach UI")
        let sleeper = path.appendingPathComponent("sleeper")
        try! Data("#!/bin/sh\ntrap '' TERM\nwhile :; do sleep 0.05; done\n".utf8).write(to: sleeper)
        try! FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: sleeper.path)
        let timeout = AccountAuthorizationController(defaults: defaults, loginTimeout: 0.04, prepareConnection: { _ in },
            resolveExecutable: { _ in sleeper.path })
        timeout.signIn(.codex)
        let started = Date()
        for _ in 0..<150 where timeout.state(for: .codex).isBusy { try? await Task.sleep(nanoseconds: 10_000_000) }
        expect(timeout.state(for: .codex) == .failed(.timedOut), "A real unresponsive login reaches its timeout")
        expect(Date().timeIntervalSince(started) < 1, "An unresponsive login never blocks the main actor")
        let cancellation = AccountAuthorizationController(defaults: defaults, prepareConnection: { _ in }, resolveExecutable: { _ in sleeper.path })
        cancellation.signIn(.codex)
        try? await Task.sleep(nanoseconds: 40_000_000)
        cancellation.cancel(.codex)
        expect(!cancellation.state(for: .codex).isBusy, "Cancelling an unresponsive process returns immediately")
        try? await Task.sleep(nanoseconds: 550_000_000)
        expect(cancellation.state(for: .codex) == .disconnected, "Terminated process completion cannot restore cancelled state")
        let denied = AccountAuthorizationController(defaults: defaults,
            prepareConnection: { _ in throw URLError(.userAuthenticationRequired) })
        denied.connectExisting(.codex)
        await settle(denied, .codex)
        expect(!denied.isEnabled(.codex) && denied.state(for: .codex) == .failed(.credentialAccess), "Denied Keychain access does not grant OAuth consent")
        let signedOut = AccountAuthorizationController(defaults: defaults,
            prepareConnection: { _ in throw OAuthQuotaSource.ReadError.missing })
        signedOut.connectExisting(.codex)
        await settle(signedOut, .codex)
        expect(!signedOut.isEnabled(.codex) && signedOut.state(for: .codex) == .failed(.signInRequired), "Missing credentials request login instead of reporting a Keychain failure")
        let semaphore = DispatchSemaphore(value: 0)
        let suspended = AccountAuthorizationController(defaults: defaults,
            prepareConnection: { _ in semaphore.wait() })
        suspended.connectExisting(.codex)
        expect(suspended.state(for: .codex) == .preparing, "Explicit connection exposes preparation state")
        suspended.disconnect(.codex)
        semaphore.signal()
        try? await Task.sleep(nanoseconds: 20_000_000)
        expect(!suspended.isEnabled(.codex) && suspended.state(for: .codex) == .disconnected, "A late credential prompt result cannot reconnect a disconnected provider")
        print("Authorization acceptance: \(count) checks passed")
    }

    @MainActor static func settle(_ auth: AccountAuthorizationController, _ provider: ProviderID) async {
        for _ in 0..<200 where auth.state(for: provider).isBusy {
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
    }

    @MainActor static func drain() async {
        for _ in 0..<10 { await Task.yield() }
    }
}
