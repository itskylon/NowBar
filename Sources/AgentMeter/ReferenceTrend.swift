import SwiftUI
import AgentMeterCore

struct TrendDatum: Identifiable {
    let index: Int
    let date: String
    let amount: Double
    let series: Int
    var id: Int { index }
}

/// The approved reference uses a 324×110 drawing, with the peak below generous headroom.
struct ReferenceTrend: View {
    let points: [TrendDatum]
    let cost: Bool
    var exactReference = false

    var body: some View {
        Canvas { context, size in
            let sx = size.width / 324
            let sy = size.height / 110
            let peak = max(1, points.map(\.amount).max() ?? 1)
            let baseline = 90 * sy
            let plotLeft: CGFloat = exactReference ? 24 : 40
            let plotWidth = 318 - plotLeft
            let position: (TrendDatum) -> CGPoint = { point in
                CGPoint(x: (plotLeft + CGFloat(point.index) * plotWidth / 6) * sx, y: (90 - point.amount / peak * 57.6) * sy)
            }
            let step = exactReference && cost ? 10 : peak / 3
            for index in 0..<4 {
                let value = Double(index) * step
                let y = (90 - value / peak * 57.6) * sy
                var grid = Path()
                grid.move(to: CGPoint(x: plotLeft * sx, y: y))
                grid.addLine(to: CGPoint(x: 318 * sx, y: y))
                context.stroke(grid, with: .color(ReferenceStyle.divider), lineWidth: 0.6)
                let label = cost ? String(Int(value)) : MeterFormat.tokens(Int64(value))
                context.draw(Text(label).font(.system(size: 9)).foregroundColor(ReferenceStyle.caption), at: CGPoint(x: (plotLeft - 6) * sx, y: y), anchor: .trailing)
            }
            for series in Set(points.map(\.series)).sorted() {
                let run = points.filter { $0.series == series }.sorted { $0.index < $1.index }
                let locations = run.map(position)
                guard let first = locations.first, let last = locations.last else { continue }
                let line = monotonePath(locations)
                if locations.count > 1 {
                    var area = line
                    area.addLine(to: CGPoint(x: last.x, y: baseline))
                    area.addLine(to: CGPoint(x: first.x, y: baseline))
                    area.closeSubpath()
                    context.fill(area, with: .linearGradient(Gradient(colors: [ReferenceStyle.green.opacity(0.24), ReferenceStyle.green.opacity(0.01)]), startPoint: CGPoint(x: 0, y: 32.4 * sy), endPoint: CGPoint(x: 0, y: baseline)))
                    context.stroke(line, with: .color(ReferenceStyle.green), style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
                }
                for point in run {
                    let location = position(point)
                    let radius: CGFloat = point.amount == peak ? 3.1 : 1.6
                    context.fill(Path(ellipseIn: CGRect(x: location.x - radius, y: location.y - radius, width: radius * 2, height: radius * 2)), with: .color(ReferenceStyle.green))
                }
            }
            for index in [0, 2, 4, 6] {
                // Labels identify the calendar even when that date has no sample.
                let date = points.first { $0.index == index }?.date ?? dateLabel(index)
                let anchor: UnitPoint = index == 0 ? .leading : index == 6 ? .trailing : .center
                context.draw(Text(date).font(.system(size: 9)).foregroundColor(ReferenceStyle.caption), at: CGPoint(x: (plotLeft + CGFloat(index) * plotWidth / 6) * sx, y: 103 * sy), anchor: anchor)
            }
            if let highest = points.max(by: { $0.amount < $1.amount }) {
                let location = position(highest)
                let label = cost ? MeterFormat.cost(highest.amount) : MeterFormat.tokens(Int64(highest.amount))
                context.draw(Text(label).font(.system(size: 11, weight: .medium)).foregroundColor(ReferenceStyle.statistic), at: CGPoint(x: max(48, min(size.width - 32, location.x)), y: location.y - 5 * sy), anchor: .bottom)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L10n.format("最近七天%@趋势，%@天有记录；缺失日期留空", L10n.text(cost ? "参考费用" : "Token"), String(points.count)))
    }

    private func dateLabel(_ index: Int) -> String {
        // The last recorded date may precede today; infer labels from its calendar index.
        guard let point = points.first else { return "" }
        let parts = point.date.split(whereSeparator: { $0 == "月" || $0 == "日" || $0 == "/" })
        guard parts.count == 2, let month = Int(parts[0]), let day = Int(parts[1]),
              let date = Calendar.current.date(from: DateComponents(year: Calendar.current.component(.year, from: Date()), month: month, day: day)),
              let shifted = Calendar.current.date(byAdding: .day, value: index - point.index, to: date) else { return "" }
        let fields = Calendar.current.dateComponents([.month, .day], from: shifted)
        return L10n.isEnglish ? "\(fields.month!)/\(fields.day!)" : "\(fields.month!)月\(fields.day!)日"
    }

    private func monotonePath(_ points: [CGPoint]) -> Path {
        var path = Path()
        guard let first = points.first else { return path }
        path.move(to: first)
        guard points.count > 1 else { return path }
        let slopes = zip(points, points.dropFirst()).map { ($1.y - $0.y) / ($1.x - $0.x) }
        var tangents = [CGFloat](repeating: 0, count: points.count)
        tangents[0] = slopes[0]
        tangents[points.count - 1] = slopes[slopes.count - 1]
        if points.count > 2 {
            for index in 1..<(points.count - 1) {
                let before = slopes[index - 1], after = slopes[index]
                if before * after > 0 {
                    let average = (before + after) / 2
                    tangents[index] = (average > 0 ? 1 : -1) * min(abs(average), 2 * min(abs(before), abs(after)))
                }
            }
            tangents[0] = (3 * slopes[0] - tangents[1]) / 2
            tangents[points.count - 1] = (3 * slopes[slopes.count - 1] - tangents[points.count - 2]) / 2
        }
        for index in 1..<points.count {
            let previous = points[index - 1], next = points[index]
            let dx = (next.x - previous.x) / 3
            path.addCurve(to: next, control1: CGPoint(x: previous.x + dx, y: previous.y + tangents[index - 1] * dx), control2: CGPoint(x: next.x - dx, y: next.y - tangents[index] * dx))
        }
        return path
    }
}
