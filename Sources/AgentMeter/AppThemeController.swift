import AppKit
import AgentMeterCore

@MainActor
enum AppThemeController {
    static func apply(_ theme: AppTheme) {
        switch theme {
        case .system: NSApplication.shared.appearance = nil
        case .light: NSApplication.shared.appearance = NSAppearance(named: .aqua)
        case .dark: NSApplication.shared.appearance = NSAppearance(named: .darkAqua)
        }
    }
}
