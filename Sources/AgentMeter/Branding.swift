import SwiftUI
import AgentMeterCore

enum AppBrand {
    static let name = "NowBar"
    static let icon = Bundle.main.url(forResource: "AppIcon", withExtension: "icns")
        .flatMap { NSImage(contentsOf: $0) }
}

struct AppBrandMark: View {
    var size: CGFloat

    var body: some View {
        Group {
            if let icon = AppBrand.icon {
                Image(nsImage: icon).resizable().scaledToFit()
            } else {
                Image(systemName: "sparkle").resizable().scaledToFit().foregroundStyle(.teal)
            }
        }.frame(width: size, height: size).accessibilityHidden(true)
    }
}
