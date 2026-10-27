import AppKit

/// A menu-sized window without NSPopover's arrow or extra chrome.
final class MeterPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) { orderOut(sender) }
}

/// Keeps the status button's native hit target while drawing the compact quota rows.
final class MeterStatusSummary: NSView {
    private let markView = NSImageView(frame: NSRect(x: 6, y: 3, width: 16, height: 16))
    var rows: [(title: String, value: String)] = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        markView.imageScaling = .scaleProportionallyUpOrDown
        markView.contentTintColor = .labelColor
        addSubview(markView)
    }

    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func update(mark: NSImage?, rows: [(title: String, value: String)]) -> CGFloat {
        markView.image = mark
        self.rows = rows
        let font = NSFont.monospacedDigitSystemFont(ofSize: rows.count > 1 ? 9 : 11, weight: .medium)
        let titleWidth = rows.map { ($0.title as NSString).size(withAttributes: [.font: font]).width }.max() ?? 0
        let valueWidth = rows.map { ($0.value as NSString).size(withAttributes: [.font: font]).width }.max() ?? 0
        let width = ceil(12 + 16 + (rows.isEmpty ? 0 : 5 + titleWidth + 7 + valueWidth))
        frame.size = NSSize(width: width, height: 22)
        needsDisplay = true
        return width
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard !rows.isEmpty else { return }
        let font = NSFont.monospacedDigitSystemFont(ofSize: rows.count > 1 ? 9 : 11, weight: .medium)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.labelColor]
        let titleWidth = rows.map { ($0.title as NSString).size(withAttributes: attributes).width }.max() ?? 0
        let lineHeight: CGFloat = rows.count > 1 ? 10 : 14
        let top = (bounds.height - lineHeight * CGFloat(rows.count)) / 2 - 1
        for (index, row) in rows.enumerated() {
            let point = NSPoint(x: 27, y: top + lineHeight * CGFloat(index))
            (row.title as NSString).draw(at: point, withAttributes: attributes)
            (row.value as NSString).draw(at: NSPoint(x: point.x + titleWidth + 7, y: point.y), withAttributes: attributes)
        }
    }
}
