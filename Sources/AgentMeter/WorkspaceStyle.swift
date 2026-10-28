import SwiftUI

/// Shared visual language for the resizable workspace; the menu panel keeps its compact layout.
enum WorkspaceStyle {
    static let contentWidth: CGFloat = 960
    static let settingsWidth: CGFloat = 780
    static let cardRadius: CGFloat = 12
    static let cardBackground = Color(nsColor: NSColor(name: NSColor.Name("NowBarWorkspaceCard")) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0.155, green: 0.155, blue: 0.16, alpha: 1)
            : NSColor.white
    })
    static var border: Color { Color.primary.opacity(0.065) }
}

struct WorkspaceCard<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(18)
            .background(WorkspaceStyle.cardBackground, in: RoundedRectangle(cornerRadius: WorkspaceStyle.cardRadius))
            .overlay(RoundedRectangle(cornerRadius: WorkspaceStyle.cardRadius).stroke(WorkspaceStyle.border, lineWidth: 1))
    }
}

struct WorkspaceSettingRow<Content: View>: View {
    var title: String
    var subtitle: String?
    @ViewBuilder var content: Content

    init(_ title: String, subtitle: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.content = content()
    }

    var body: some View {
        HStack(alignment: .center, spacing: 20) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 13))
                if let subtitle {
                    Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }.layoutPriority(1)
            Spacer(minLength: 8)
            content.frame(maxWidth: 240, alignment: .trailing)
        }.padding(.vertical, 5)
    }
}

struct WorkspacePageHeader<Actions: View>: View {
    var title: String
    var subtitle: String
    @ViewBuilder var actions: Actions

    var body: some View {
        HStack(alignment: .top, spacing: 20) {
            VStack(alignment: .leading, spacing: 7) {
                Text(title).font(.system(size: 23, weight: .semibold))
                Text(subtitle).font(.system(size: 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }.layoutPriority(1)
            Spacer(minLength: 0)
            actions.controlSize(.regular)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}
