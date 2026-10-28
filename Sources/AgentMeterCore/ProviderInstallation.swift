import Foundation

/// Installation evidence is a complete application bundle or a usable CLI, never account storage.
public enum ProviderInstallation {
    public static let bundleIdentifiers: [ProviderID: String] = [
        .codex: "com.openai.codex",
        .claude: "com.anthropic.claudefordesktop",
        .grokBot: "com.anysphere.sand"
    ]

    public static func detect(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        applicationDirectories: [URL]? = nil,
        path: String? = nil,
        executableDirectories: [URL]? = nil
    ) -> Set<ProviderID> {
        var installed = Set(applications(home: home, directories: applicationDirectories).map(\.provider))
        for (provider, name) in [(ProviderID.codex, "codex"), (.claude, "claude")] {
            if command(named: name, home: home, path: path, directories: executableDirectories) != nil {
                installed.insert(provider)
            }
        }
        return installed
    }

    public static func executable(
        named name: String,
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        applicationDirectories: [URL]? = nil,
        path: String? = nil,
        executableDirectories: [URL]? = nil
    ) -> String? {
        guard validComponent(name) else { return nil }
        if let command = command(named: name, home: home, path: path, directories: executableDirectories) {
            return command
        }
        guard name == "codex" else { return nil }
        for application in applications(home: home, directories: applicationDirectories) where application.provider == .codex {
            let bundled = application.url.appendingPathComponent("Contents/Resources/codex")
            if isExecutable(bundled) { return bundled.path }
        }
        return nil
    }

    private static func command(named name: String, home: URL, path: String?, directories: [URL]?) -> String? {
        let defaults = [".local/bin", ".npm-global/bin", ".volta/bin"].map { home.appendingPathComponent($0) }
            + [URL(fileURLWithPath: "/opt/homebrew/bin"), URL(fileURLWithPath: "/usr/local/bin")]
        var search = directories ?? (defaults + nodeDirectories(home: home))
        search += (path ?? ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":")
            .filter { $0.hasPrefix("/") }
            .map { URL(fileURLWithPath: String($0), isDirectory: true) }
        var visited = Set<String>()
        for directory in search where visited.insert(directory.standardizedFileURL.path).inserted {
            let file = directory.appendingPathComponent(name)
            if isExecutable(file) { return file.path }
        }
        return nil
    }

    private static func nodeDirectories(home: URL) -> [URL] {
        let versions = home.appendingPathComponent(".nvm/versions/node")
        return children(of: versions).filter { $0.lastPathComponent.hasPrefix("v") }
            .prefix(64).map { $0.appendingPathComponent("bin") }
    }

    private static func applications(home: URL, directories: [URL]?) -> [(provider: ProviderID, url: URL)] {
        let roots = directories ?? [URL(fileURLWithPath: "/Applications"), home.appendingPathComponent("Applications")]
        var bundles: [URL] = []
        for root in roots {
            for child in children(of: root) {
                if child.pathExtension.lowercased() == "app" {
                    bundles.append(child)
                } else if (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                    bundles += children(of: child).filter { $0.pathExtension.lowercased() == "app" }
                }
            }
        }
        return bundles.compactMap { url in
            let infoURL = url.appendingPathComponent("Contents/Info.plist")
            guard let data = try? Data(contentsOf: infoURL),
                  let info = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any],
                  let identifier = info["CFBundleIdentifier"] as? String,
                  let provider = bundleIdentifiers.first(where: { $0.value == identifier })?.key,
                  let executable = info["CFBundleExecutable"] as? String,
                  validComponent(executable),
                  isExecutable(url.appendingPathComponent("Contents/MacOS").appendingPathComponent(executable)) else {
                return nil
            }
            return (provider, url)
        }
    }

    private static func children(of directory: URL) -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
        )) ?? []).sorted { $0.path < $1.path }
    }

    private static func validComponent(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("/") && !name.contains("\\")
    }

    private static func isExecutable(_ file: URL) -> Bool {
        let resolved = file.resolvingSymlinksInPath()
        return (try? resolved.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
            && FileManager.default.isExecutableFile(atPath: resolved.path)
    }
}
