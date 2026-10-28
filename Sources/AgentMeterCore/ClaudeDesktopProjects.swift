import Foundation

/// Finds real Code/Cowork usage logs without scanning downloaded tools or chat caches.
public enum ClaudeDesktopProjects {
    public static func roots(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [URL] {
        let manager = FileManager.default
        let desktop = home.appendingPathComponent("Library/Application Support/Claude", isDirectory: true)
        let containers = ["claude-code-sessions", "local-agent-mode-sessions"].map {
            desktop.appendingPathComponent($0, isDirectory: true)
        }
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey]
        let skipped: Set<String> = ["node_modules", ".git", "outputs", "build", "dist", "plugins", "skills", "cache", "Caches"]
        var queue = containers.map { ($0, 0) }
        var index = 0
        var results: [URL] = []
        // A malformed or unexpectedly large session tree cannot trigger an unbounded walk.
        while index < queue.count, index < 4096 {
            let (directory, depth) = queue[index]
            index += 1
            guard let metadata = try? directory.resourceValues(forKeys: keys),
                  metadata.isDirectory == true, metadata.isSymbolicLink != true else { continue }
            if directory.lastPathComponent == ".claude" {
                let projects = directory.appendingPathComponent("projects", isDirectory: true)
                if let metadata = try? projects.resourceValues(forKeys: keys),
                   metadata.isDirectory == true, metadata.isSymbolicLink != true {
                    results.append(projects.standardizedFileURL)
                }
                continue
            }
            guard depth < 8,
                  let children = try? manager.contentsOfDirectory(at: directory,
                    includingPropertiesForKeys: Array(keys), options: []) else { continue }
            for child in children.sorted(by: { $0.path < $1.path }) {
                let name = child.lastPathComponent
                guard !skipped.contains(name), !name.hasPrefix(".") || name == ".claude",
                      let metadata = try? child.resourceValues(forKeys: keys),
                      metadata.isDirectory == true, metadata.isSymbolicLink != true else { continue }
                queue.append((child, depth + 1))
            }
        }
        return Array(Set(results)).sorted { $0.path < $1.path }
    }
}
