import Foundation

@main
enum AppUpdatesSmoke {
    private static var checks = 0

    static func main() async throws {
        let release = try AppUpdates.newerRelease(data: fixture(), currentVersion: "0.6.3")
        try check(release?.version == "0.6.4", "normalizes the release tag for display")
        try check(release?.notes == "Update checks and reminders", "preserves release notes")
        try check(release?.url.absoluteString == "https://github.com/itskylon/NowBar/releases/tag/v0.6.4", "preserves the validated release URL")
        try check(try AppUpdates.newerRelease(data: fixture(), currentVersion: "0.6.4") == nil, "equal versions do not update")
        try check(try AppUpdates.newerRelease(data: fixture(), currentVersion: "0.7.0") == nil, "an older release cannot downgrade the app")
        try check(try AppUpdates.newerRelease(data: fixture(tag: "v0.6.10"), currentVersion: "0.6.9")?.version == "0.6.10", "numeric comparison handles multi-digit components")
        try check(try AppUpdates.newerRelease(data: fixture(tag: "v1.0.0"), currentVersion: "0.99.99") != nil, "major versions take priority")
        try check(try AppUpdates.newerRelease(data: fixture(tag: "v0.7.0"), currentVersion: "0.6.99") != nil, "minor versions take priority")
        try check(try AppUpdates.newerRelease(data: fixture(tag: "0.6.4"), currentVersion: "0.6.3") != nil, "stable tags need not have a v prefix")
        try check(try AppUpdates.newerRelease(data: fixture(notes: NSNull()), currentVersion: "0.6.3")?.notes == "", "a null body has empty release notes")
        try check(try AppUpdates.newerRelease(data: fixture(omitBody: true), currentVersion: "0.6.3")?.notes == "", "missing notes do not hide a valid update")

        for tag in ["", "latest", "v0.6.4-beta", "v0.6.4+build", "v0.6", "0.6.4.1", "v00.6.4", "v0.-1.4", "v0.6.999999999999999999999999999", "v0.6.４", " v0.6.4"] {
            try invalid(fixture(tag: tag), "rejects invalid stable release tag: \(tag)")
        }
        for current in ["", "0.6", "0.6.3-beta", "unknown", "00.6.3"] {
            do {
                _ = try AppUpdates.newerRelease(data: fixture(), currentVersion: current)
                throw Failure(message: "accepted an invalid current version")
            } catch AppUpdateError.invalidResponse { checks += 1 }
        }
        try invalid(fixture(draft: true), "does not offer a draft release")
        try invalid(fixture(prerelease: true), "does not offer a prerelease")
        for url in [
            "http://github.com/itskylon/NowBar/releases/tag/v0.6.4",
            "https://example.com/itskylon/NowBar/releases/tag/v0.6.4",
            "https://github.com.evil.test/itskylon/NowBar/releases/tag/v0.6.4",
            "https://github.com/other/NowBar/releases/tag/v0.6.4",
            "https://github.com/itskylon/Other/releases/tag/v0.6.4",
            "https://github.com/itskylon/NowBar/releases/tag/v0.6.5",
            "https://user@github.com/itskylon/NowBar/releases/tag/v0.6.4",
            "https://github.com:444/itskylon/NowBar/releases/tag/v0.6.4",
            "https://github.com/itskylon/NowBar/releases/tag/v0.6.4?redirect=evil",
            "https://github.com/itskylon/NowBar/releases/tag/v0.6.4#evil",
            "file:///tmp/update.app"
        ] {
            try invalid(fixture(url: url), "rejects an untrusted release URL: \(url)")
        }
        for payload in ["{}", "[]", "null", "not json", #"{"tag_name":"v0.6.4","html_url":"https://github.com/itskylon/NowBar/releases/tag/v0.6.4"}"#] {
            try invalid(Data(payload.utf8), "malformed releases are an error rather than up-to-date")
        }

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ReleaseProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        ReleaseProtocol.status = 200
        ReleaseProtocol.body = try fixture()
        let fetched = try await AppUpdates.fetch(currentVersion: "0.6.3", session: session)
        try check(fetched?.version == "0.6.4", "HTTP success parses the release")
        let request = ReleaseProtocol.lastRequest
        try check(request?.url?.absoluteString == "https://api.github.com/repos/itskylon/NowBar/releases/latest", "the client contacts only the fixed release endpoint")
        try check(request?.value(forHTTPHeaderField: "Authorization") == nil, "no account authorization is sent to GitHub")
        try check(request?.timeoutInterval == 15, "update requests have a bounded timeout")
        for status in [403, 429] {
            ReleaseProtocol.status = status
            do {
                _ = try await AppUpdates.fetch(currentVersion: "0.6.3", session: session)
                throw Failure(message: "rate limiting was treated as a successful check")
            } catch AppUpdateError.rateLimited { checks += 1 }
        }
        for status in [404, 500, 301] {
            ReleaseProtocol.status = status
            do {
                _ = try await AppUpdates.fetch(currentVersion: "0.6.3", session: session)
                throw Failure(message: "HTTP failure was treated as a successful check")
            } catch AppUpdateError.unavailable { checks += 1 }
        }
        print("AppUpdates: \(checks) checks passed")
    }

    private static func fixture(tag: String = "v0.6.4", notes: Any = "Update checks and reminders", draft: Bool = false, prerelease: Bool = false, url: String? = nil, omitBody: Bool = false) throws -> Data {
        var object: [String: Any] = ["tag_name": tag, "html_url": url ?? "https://github.com/itskylon/NowBar/releases/tag/\(tag)", "draft": draft, "prerelease": prerelease]
        if !omitBody { object["body"] = notes }
        return try JSONSerialization.data(withJSONObject: object)
    }

    private static func invalid(_ data: Data, _ message: String) throws {
        do {
            _ = try AppUpdates.newerRelease(data: data, currentVersion: "0.6.3")
            throw Failure(message: message)
        } catch AppUpdateError.invalidResponse { checks += 1 }
    }

    private static func check(_ passed: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try passed() else { throw Failure(message: message) }
        checks += 1
    }

    private struct Failure: Error { let message: String }
}

private final class ReleaseProtocol: URLProtocol {
    static var status = 200
    static var body = Data()
    static var lastRequest: URLRequest?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lastRequest = request
        let response = HTTPURLResponse(url: request.url!, statusCode: Self.status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
