import Foundation

@main
enum ProviderInstallationSmoke {
    static var checks = 0

    static func main() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: root) }
        let home = root.appendingPathComponent("home")
        let apps = root.appendingPathComponent("Applications")
        let bins = root.appendingPathComponent("bin")
        for directory in [home, apps, bins] { try fm.createDirectory(at: directory, withIntermediateDirectories: true) }
        func detect() -> Set<ProviderID> {
            ProviderInstallation.detect(home: home, applicationDirectories: [apps, home.appendingPathComponent("Applications")], path: "", executableDirectories: [bins])
        }
        func executable(_ name: String) -> String? {
            ProviderInstallation.executable(named: name, home: home, applicationDirectories: [apps], path: "", executableDirectories: [bins])
        }
        func writeExecutable(_ file: URL) throws {
            try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("#!/bin/sh\nexit 0\n".utf8).write(to: file)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        }
        func application(_ url: URL, id: String, validExecutable: Bool = true, bundledCodex: Bool = false) throws {
            let contents = url.appendingPathComponent("Contents")
            try fm.createDirectory(at: contents, withIntermediateDirectories: true)
            let info: [String: Any] = ["CFBundleIdentifier": id, "CFBundleExecutable": "Main"]
            try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: contents.appendingPathComponent("Info.plist"))
            if validExecutable { try writeExecutable(contents.appendingPathComponent("MacOS/Main")) }
            if bundledCodex { try writeExecutable(contents.appendingPathComponent("Resources/codex")) }
        }

        expect(detect().isEmpty, "A clean home does not inherit this computer's installations")
        for leftover in [".codex/sessions/old.jsonl", ".claude/projects/old.jsonl", "Library/Application Support/Grok Bot/state.json"] {
            let file = home.appendingPathComponent(leftover)
            try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("{}".utf8).write(to: file)
        }
        expect(detect().isEmpty, "Leftover logs and account storage are not installation evidence")
        try writeExecutable(bins.appendingPathComponent("codex"))
        expect(detect() == [.codex], "A standalone executable Codex CLI enables Codex")
        expect(executable("codex") == bins.appendingPathComponent("codex").path, "The read path uses the same executable discovery")
        try fm.removeItem(at: bins.appendingPathComponent("codex"))
        expect(detect().isEmpty, "Removing the executable removes its provider")
        try Data("not executable".utf8).write(to: bins.appendingPathComponent("claude"))
        expect(detect().isEmpty, "A non-executable CLI file does not count")
        try fm.removeItem(at: bins.appendingPathComponent("claude"))
        try fm.createSymbolicLink(atPath: bins.appendingPathComponent("claude").path, withDestinationPath: root.appendingPathComponent("missing").path)
        expect(detect().isEmpty, "A dangling CLI symlink does not count")
        try fm.removeItem(at: bins.appendingPathComponent("claude"))
        try fm.createDirectory(at: bins.appendingPathComponent("claude"), withIntermediateDirectories: true)
        expect(detect().isEmpty, "An executable directory is not a CLI")
        try fm.removeItem(at: bins.appendingPathComponent("claude"))
        let realCLI = root.appendingPathComponent("cli-target")
        try writeExecutable(realCLI)
        try fm.createSymbolicLink(atPath: bins.appendingPathComponent("claude").path, withDestinationPath: realCLI.path)
        expect(detect() == [.claude], "A symlink to a usable CLI supports package-manager installations")
        try fm.removeItem(at: bins.appendingPathComponent("claude"))
        try writeExecutable(bins.appendingPathComponent("claude"))
        expect(detect() == [.claude], "A standalone Claude Code CLI enables Claude")
        try fm.removeItem(at: bins.appendingPathComponent("claude"))
        let renamed = apps.appendingPathComponent("Extra/Renamed Desktop.app")
        try application(renamed, id: "com.openai.codex", bundledCodex: true)
        expect(detect() == [.codex], "A renamed Codex bundle in one application subfolder is recognized by identifier")
        expect(executable("codex").map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path } == renamed.appendingPathComponent("Contents/Resources/codex").resolvingSymlinksInPath().path, "Codex reads its bundled CLI even when the app is renamed")
        let claude = home.appendingPathComponent("Applications/Renamed Assistant.app")
        try application(claude, id: "com.anthropic.claudefordesktop")
        expect(detect() == [.codex, .claude], "Claude in the user's Applications directory is recognized")
        let grok = apps.appendingPathComponent("Grok Bot.app")
        try application(grok, id: "com.anysphere.sand", validExecutable: false)
        expect(!detect().contains(.grokBot), "An incomplete application bundle is not installed")
        try writeExecutable(grok.appendingPathComponent("Contents/MacOS/Main"))
        expect(detect() == Set(ProviderID.allCases), "All three complete app bundles are recognized")
        try fm.removeItem(at: grok)
        expect(!detect().contains(.grokBot), "Uninstalling an app removes it without reading leftover state")
        try application(apps.appendingPathComponent("Grok Bot.app"), id: "example.unrelated")
        expect(!detect().contains(.grokBot), "An unrelated app with a matching display name does not count")
        let invalid = apps.appendingPathComponent("Invalid.app/Contents")
        try fm.createDirectory(at: invalid, withIntermediateDirectories: true)
        try Data("broken property list".utf8).write(to: invalid.appendingPathComponent("Info.plist"))
        expect(!detect().contains(.grokBot), "Malformed application metadata is ignored")
        let unsafeInfo: [String: Any] = ["CFBundleIdentifier": "com.anysphere.sand", "CFBundleExecutable": "../outside"]
        try PropertyListSerialization.data(fromPropertyList: unsafeInfo, format: .xml, options: 0).write(to: invalid.appendingPathComponent("Info.plist"))
        try writeExecutable(invalid.appendingPathComponent("outside"))
        expect(!detect().contains(.grokBot), "An application executable cannot escape its MacOS directory")
        let deep = apps.appendingPathComponent("Folder/Nested/Grok Bot.app")
        try application(deep, id: "com.anysphere.sand")
        expect(!detect().contains(.grokBot), "Application scanning stays bounded to one subfolder")
        let pathBin = root.appendingPathComponent("custom-bin")
        try writeExecutable(pathBin.appendingPathComponent("claude"))
        expect(ProviderInstallation.executable(named: "claude", home: home, applicationDirectories: [], path: pathBin.path, executableDirectories: []) == pathBin.appendingPathComponent("claude").path, "An explicit absolute PATH directory is supported")
        expect(ProviderInstallation.executable(named: "claude", home: home, applicationDirectories: [], path: ".", executableDirectories: []) == nil, "Relative PATH entries never probe the working directory")
        try writeExecutable(home.appendingPathComponent(".local/bin/codex"))
        expect(ProviderInstallation.executable(named: "codex", home: home, applicationDirectories: [], path: "", executableDirectories: [home.appendingPathComponent(".local/bin")]) != nil, "User-local CLI installs are supported")
        expect(ProviderInstallation.bundleIdentifiers[.grokBot] == "com.anysphere.sand", "Grok Bot uses its actual desktop bundle identifier")
        print("Provider installation: \(checks) isolated detection and executable-discovery checks passed")
    }

    static func expect(_ value: @autoclosure () -> Bool, _ message: String) {
        guard value() else { fatalError(message) }
        checks += 1
    }
}
