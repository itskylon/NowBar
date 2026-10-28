import AppKit

/// A menu-sized window without NSPopover's arrow or extra chrome.
final class MeterPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) { orderOut(sender) }

    func containsWindow(_ window: NSWindow) -> Bool {
        var candidate: NSWindow? = window
        while let current = candidate {
            if current === self { return true }
            candidate = current.parent
        }
        return false
    }

    var containsKeyWindow: Bool {
        func hasKeyWindow(_ window: NSWindow) -> Bool {
            window.isKeyWindow || (window.childWindows ?? []).contains(where: hasKeyWindow)
        }
        return hasKeyWindow(self)
    }
}

enum StatusItemScreenRegions {
    /// Window bounds and layers are available without recording screen contents.
    static func menuBarIsVisible(at point: NSPoint) -> Bool {
        guard let primary = NSScreen.screens.first,
              let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return false }
        let screenPoint = CGPoint(x: point.x, y: primary.frame.maxY - point.y)
        for window in windows {
            guard (window[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                  let bounds = window[kCGWindowBounds as String] as? [String: Any],
                  let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary), rect.contains(screenPoint) else { continue }
            return (window[kCGWindowLayer as String] as? Int) == Int(CGWindowLevelForKey(.mainMenuWindow))
        }
        return false
    }

    /// AppKit moves the native status window between display mirrors when it
    /// forwards a click. Preserve the button's distance from the top-right edge.
    static func rectangles(button: NSRect, screens: [NSRect]) -> [NSRect] {
        guard !button.isEmpty,
              let source = screens.first(where: { $0.contains(NSPoint(x: button.midX, y: button.midY)) }) else { return [] }
        let trailing = source.maxX - button.maxX
        let top = source.maxY - button.maxY
        return screens.map { screen in
            NSRect(x: screen.maxX - trailing - button.width,
                   y: screen.maxY - top - button.height,
                   width: button.width, height: button.height).intersection(screen)
        }.filter { !$0.isEmpty }
    }
}

enum MeterStatusPart {
    case icon
    case text(String, widthSample: String? = nil)
    case meter(Double?)
    case space, lineBreak
}

struct MeterStatusEntry {
    let id: String
    let image: NSImage?
    let value: String
    let toolTip: String
    var parts: [MeterStatusPart] = []
    var color: NSColor? = nil
}

struct MeterStatusAppearance {
    var fontSize: CGFloat = 12
    var iconSize: CGFloat = 14
    var spacing: CGFloat = 12
    var verticalOffset: CGFloat = 0
    var monospacedDigits = true
    var maximumWidth: CGFloat = 720
}

/// Shared by the native menu and settings preview; it never draws outside the 22pt bar.
final class MeterStatusSummary: NSView {
    private var imageViews: [NSImageView] = []
    private var drawItems: [(part: MeterStatusPart, frame: NSRect, font: NSFont, color: NSColor)] = []
    private var entryFrames: [NSRect] = []
    private(set) var entries: [MeterStatusEntry] = []
    private(set) var itemFrames: [(icon: NSRect, value: NSRect)] = []
    private(set) var contentFrames: [NSRect] = []

    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { frame.size }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func update(entries: [MeterStatusEntry], fallback: NSImage?, appearance: MeterStatusAppearance = .init()) -> CGFloat {
        self.entries = entries
        itemFrames = []; entryFrames = []; drawItems = []
        imageViews.forEach { $0.isHidden = true }
        var imageIndex = 0
        func placeImage(_ image: NSImage?, rect: NSRect, color: NSColor) {
            if imageIndex == imageViews.count {
                let view = NSImageView()
                view.imageScaling = .scaleProportionallyUpOrDown
                addSubview(view)
                imageViews.append(view)
            }
            let view = imageViews[imageIndex]
            view.frame = rect; view.image = image; view.contentTintColor = color; view.isHidden = false
            imageIndex += 1
        }
        let spacing = min(24, max(6, appearance.spacing))
        let budget = max(40, floor((appearance.maximumWidth - 12 - spacing * CGFloat(max(0, entries.count - 1))) / CGFloat(max(1, entries.count))))
        var x: CGFloat = 6
        for entry in entries {
            let parts: [MeterStatusPart] = entry.parts.isEmpty ? [.icon, .text(entry.value, widthSample: "100%")] : entry.parts
            var lines: [[MeterStatusPart]] = [[]]
            for part in parts {
                if case .lineBreak = part { if lines.count == 1 { lines.append([]) }; continue }
                lines[lines.count - 1].append(part)
            }
            let twoLines = lines.count == 2
            let fontSize = twoLines ? min(9, appearance.fontSize) : min(14, max(10, appearance.fontSize))
            let font = appearance.monospacedDigits ? NSFont.monospacedDigitSystemFont(ofSize: fontSize, weight: .medium) : NSFont.systemFont(ofSize: fontSize, weight: .medium)
            let textHeight = ceil(font.ascender - font.descender)
            let iconSize = twoLines ? 9 : min(16, max(12, appearance.iconSize))
            let tint = entry.color ?? .labelColor
            let start = x
            var end = x
            var firstIcon = NSRect.zero
            var firstValue = NSRect.zero
            for (lineIndex, line) in lines.enumerated() {
                var cursor = start
                let center: CGFloat = twoLines ? (lineIndex == 0 ? 5.5 : 16.5) : 11
                let offset = twoLines ? 0 : min(3, max(-3, appearance.verticalOffset))
                for part in line {
                    let available = start + budget - cursor
                    guard available > 4 else { break }
                    let rect: NSRect
                    switch part {
                    case .icon:
                        guard available >= iconSize else { continue }
                        rect = NSRect(x: cursor, y: min(22 - iconSize, max(0, floor(center - iconSize / 2 + offset))), width: iconSize, height: iconSize)
                        placeImage(entry.image, rect: rect, color: tint)
                        if firstIcon == .zero { firstIcon = rect }
                    case .text(let text, let sample):
                        let width = ceil(((sample ?? text) as NSString).size(withAttributes: [.font: font]).width)
                        rect = NSRect(x: cursor, y: min(22 - textHeight, max(0, floor(center - textHeight / 2 + offset))), width: min(available, width), height: textHeight)
                        drawItems.append((part, rect, font, tint))
                        if firstValue == .zero { firstValue = rect }
                    case .meter:
                        rect = NSRect(x: cursor, y: min(12, max(0, floor(center - 5 + offset))), width: min(28, available), height: 10)
                        drawItems.append((part, rect, font, tint))
                    case .space:
                        cursor += 5
                        continue
                    case .lineBreak: continue
                    }
                    cursor = rect.maxX + 5
                }
                end = max(end, cursor - 5)
            }
            end = max(start + 14, end)
            itemFrames.append((firstIcon, firstValue))
            entryFrames.append(NSRect(x: start - spacing / 2, y: 0, width: end - start + spacing, height: 22))
            x = end + spacing
        }
        if entries.isEmpty { placeImage(fallback, rect: NSRect(x: 7, y: 4, width: 14, height: 14), color: .labelColor) }
        contentFrames = drawItems.map(\.frame) + imageViews.filter { !$0.isHidden }.map(\.frame)
        frame.size = NSSize(width: entries.isEmpty ? 28 : ceil(x - spacing + 6), height: 22)
        invalidateIntrinsicContentSize()
        needsDisplay = true
        return frame.width
    }

    func entry(at point: NSPoint) -> MeterStatusEntry? {
        entryFrames.enumerated().first { $0.element.contains(point) }.map { entries[$0.offset] }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        for item in drawItems {
            switch item.part {
            case .text(let text, let sample):
                let paragraph = NSMutableParagraphStyle()
                paragraph.alignment = sample == nil ? .left : .right
                paragraph.lineBreakMode = .byTruncatingTail
                (text as NSString).draw(in: item.frame, withAttributes: [.font: item.font, .foregroundColor: item.color, .paragraphStyle: paragraph])
            case .meter(let amount):
                for index in 0..<8 {
                    let lit = amount.map { Double(index) < max(0, min(100, $0)) / 100 * 8 } ?? false
                    (lit ? item.color : item.color.withAlphaComponent(0.22)).setFill()
                    NSBezierPath(roundedRect: NSRect(x: item.frame.minX + CGFloat(index) * item.frame.width / 8, y: item.frame.minY, width: item.frame.width / 8 - 1.5, height: item.frame.height), xRadius: 1, yRadius: 1).fill()
                }
            default: break
            }
        }
    }
}
