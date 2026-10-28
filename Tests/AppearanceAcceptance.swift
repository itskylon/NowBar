import AppKit
import AgentMeterCore

@main
struct AppearanceAcceptance {
    @MainActor static func main() {
        let app = NSApplication.shared
        let original = app.appearance
        defer { app.appearance = original }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
        var checks = 0
        func expect(_ value: Bool, _ reason: String) { precondition(value, reason); checks += 1 }
        AppThemeController.apply(.light)
        expect(app.appearance?.name == .aqua, "Light explicitly selects Aqua")
        expect(window.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .aqua, "An existing window follows light")
        AppThemeController.apply(.dark)
        expect(app.appearance?.name == .darkAqua, "Dark explicitly selects Dark Aqua")
        expect(window.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua, "An existing window changes to dark")
        AppThemeController.apply(.system)
        expect(app.appearance == nil, "System mode clears the app override")
        expect(AppTheme.allCases.count == 3, "All supported themes are selectable")
        print("Appearance: \(checks) native checks passed without changing system settings")
    }
}
