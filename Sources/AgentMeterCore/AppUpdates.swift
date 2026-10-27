import Foundation

public struct AppRelease: Decodable, Sendable, Equatable {
    public let version: String
    public let notes: String
    public let url: URL

    public init(version: String, notes: String, url: URL) {
        self.version = version
        self.notes = notes
        self.url = url
    }

    private enum CodingKeys: String, CodingKey {
        case tag = "tag_name", notes = "body", url = "html_url", draft, prerelease
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let tag = try values.decode(String.self, forKey: .tag)
        guard !(try values.decode(Bool.self, forKey: .draft)),
              !(try values.decode(Bool.self, forKey: .prerelease)),
              let parsed = StableVersion(tag),
              let components = URLComponents(string: try values.decode(String.self, forKey: .url)),
              components.scheme == "https", components.host == "github.com",
              components.user == nil, components.password == nil, components.port == nil,
              components.query == nil, components.fragment == nil,
              components.percentEncodedPath == "/itskylon/NowBar/releases/tag/\(tag)",
              let url = components.url else { throw AppUpdateError.invalidResponse }
        version = parsed.description
        notes = try values.decodeIfPresent(String.self, forKey: .notes) ?? ""
        self.url = url
    }
}

public enum AppUpdateError: Error {
    case invalidResponse
    case rateLimited
    case unavailable
}

public enum AppUpdates {
    public static func newerRelease(data: Data, currentVersion: String) throws -> AppRelease? {
        guard let current = StableVersion(currentVersion) else { throw AppUpdateError.invalidResponse }
        let release: AppRelease
        do { release = try JSONDecoder().decode(AppRelease.self, from: data) }
        catch { throw AppUpdateError.invalidResponse }
        guard let latest = StableVersion(release.version) else { throw AppUpdateError.invalidResponse }
        return current < latest ? release : nil
    }

    public static func fetch(currentVersion: String) async throws -> AppRelease? {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.urlCache = nil
        config.timeoutIntervalForResource = 20
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        return try await fetch(currentVersion: currentVersion, session: session)
    }

    static func fetch(currentVersion: String, session: URLSession) async throws -> AppRelease? {
        let url = URL(string: "https://api.github.com/repos/itskylon/NowBar/releases/latest")!
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("NowBar", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw AppUpdateError.invalidResponse }
        if http.statusCode == 403 || http.statusCode == 429 { throw AppUpdateError.rateLimited }
        guard http.statusCode == 200 else { throw AppUpdateError.unavailable }
        return try newerRelease(data: data, currentVersion: currentVersion)
    }
}

private struct StableVersion: Comparable, CustomStringConvertible {
    let components: [Int]
    var description: String { components.map(String.init).joined(separator: ".") }

    init?(_ source: String) {
        let version = source.hasPrefix("v") ? String(source.dropFirst()) : source
        let parts = version.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        var numbers: [Int] = []
        for part in parts {
            guard !part.isEmpty, part.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }),
                  (part.count == 1 || part.first != "0"), let value = Int(part) else { return nil }
            numbers.append(value)
        }
        components = numbers
    }

    static func < (lhs: StableVersion, rhs: StableVersion) -> Bool {
        lhs.components.lexicographicallyPrecedes(rhs.components)
    }
}
