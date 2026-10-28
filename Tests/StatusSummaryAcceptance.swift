import AppKit

@main
enum StatusSummaryAcceptance {
    @MainActor static func main() {
        let view = MeterStatusSummary(frame: .zero)
        let entries = ["codex", "claude", "grokBot"].enumerated().map { index, id in
            MeterStatusEntry(id: id, image: NSImage(size: NSSize(width: 14, height: 14)),
                             value: ["74%", "76%", "100%"][index], toolTip: id)
        }
        let width = view.update(entries: entries, fallback: nil)
        precondition(view.entries.count == 3 && view.itemFrames.count == 3)
        precondition(width <= 225 && view.frame.height == 22, "Three services must fit a compact native menu row")
        precondition(Set(view.itemFrames.map { $0.value.minY }).count == 1, "Every percentage uses the same baseline")
        for (index, frame) in view.itemFrames.enumerated() {
            precondition(frame.icon.width == 14 && frame.icon.minY >= 0 && frame.icon.maxY <= 22)
            precondition(frame.value.minY >= 0 && frame.value.maxY <= 22 && frame.value.maxX <= width)
            precondition(frame.value.minX > frame.icon.maxX)
            precondition(view.entry(at: NSPoint(x: frame.icon.midX, y: frame.icon.midY))?.id == entries[index].id)
            if index > 0 { precondition(frame.icon.minX > view.itemFrames[index - 1].value.maxX) }
        }
        for value in ["0%", "9%", "99%", "100%", "—"] {
            let changed = entries.map { MeterStatusEntry(id: $0.id, image: $0.image, value: value, toolTip: $0.toolTip) }
            precondition(view.update(entries: changed, fallback: nil) == width, "Quota updates must not move neighboring menu items")
        }
        _ = view.update(entries: [], fallback: NSImage(size: NSSize(width: 14, height: 14)))
        precondition(view.itemFrames.isEmpty && view.frame.width == 28)
        precondition(view.entry(at: .zero) == nil)
        _ = view.update(entries: [entries[0]], fallback: nil)
        precondition(view.itemFrames.count == 1 && view.frame.width < width)
        let iconOnly = MeterStatusEntry(id: "codex", image: entries[0].image, value: "74%", toolTip: "Codex", parts: [.icon])
        let iconWidth = view.update(entries: [iconOnly], fallback: nil)
        precondition(view.itemFrames[0].value == .zero && iconWidth < width / 3, "Icon-only style must remove the numeric slot")
        let custom = MeterStatusEntry(id: "claude", image: entries[1].image, value: "76%", toolTip: "Claude",
                                      parts: [.icon, .text("5h 76%", widthSample: "5h 100%"), .lineBreak, .meter(76), .text("7d —", widthSample: "7d 100%")])
        for offset: CGFloat in [-3, 0, 3] {
            let appearance = MeterStatusAppearance(fontSize: 13, iconSize: 15, spacing: 18, verticalOffset: offset, monospacedDigits: false)
            _ = view.update(entries: [custom], fallback: nil, appearance: appearance)
            let frame = view.itemFrames[0]
            precondition(frame.icon.minY >= 0 && frame.icon.maxY <= 22 && frame.value.maxY <= 22,
                         "Two-line custom layouts and vertical offsets must stay within the native bar")
            precondition(view.contentFrames.allSatisfy { $0.maxY <= 11 || $0.minY >= 11 },
                         "Vertical adjustment must not make two custom rows overlap")
        }
        let long = MeterStatusEntry(id: "codex", image: entries[0].image, value: "74%", toolTip: "Codex",
                                   parts: [.text(String(repeating: "long content ", count: 40)), .icon])
        precondition(view.update(entries: [long, long, long], fallback: nil) <= 720,
                     "Long custom content cannot consume the whole screen")
        print("Status summary: single-line marks, aligned values, stable widths and correct hit targets passed")
    }
}
