import AppKit
import SwiftUI
import TermviaCore

enum MetricStroke {
    static let width: CGFloat = 1.8
}

/// Geometry is built once per sample. Appending a point never changes any
/// previously drawn segment; animation translates the viewport, not the data.
struct MetricCurve: Equatable {
    struct Segment { let points: [CGPoint]; let line: Path; let area: Path }
    let origin: TimeInterval
    let segments: [Segment]
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.origin == rhs.origin && lhs.segments.elementsEqual(rhs.segments, by: { $0.points == $1.points })
    }
    init(points: [MetricPoint], maximumGap: TimeInterval) {
        let ordered = points.filter { $0.value.isFinite && $0.value >= 0 }.sorted { $0.time < $1.time }
        origin = ordered.first?.time.timeIntervalSinceReferenceDate ?? 0
        var groups: [[CGPoint]] = []
        var previousInterval: TimeInterval?
        for point in ordered {
            let value = CGPoint(x: point.time.timeIntervalSinceReferenceDate - origin, y: point.value)
            if let last = groups.last?.last {
                guard value.x > last.x else { continue }
                let allowedGap = point.samplingInterval.map { max(3, max(previousInterval ?? $0, $0) * 2.5) } ?? maximumGap
                if value.x - last.x > allowedGap { groups.append([]) }
            } else if groups.isEmpty { groups.append([]) }
            groups[groups.count - 1].append(value)
            previousInterval = point.samplingInterval
        }
        segments = groups.map { nodes in
            var line = Path()
            if let first = nodes.first { line.move(to: first) }
            for index in 1..<nodes.count {
                let a = nodes[index - 1], b = nodes[index], width = b.x - a.x
                // Matching horizontal endpoint tangents give smooth joins at
                // peaks as well as troughs, without a future sample rewriting
                // the segment that is already visible. Controls stay bounded.
                line.addCurve(to: b, control1: CGPoint(x: a.x + width / 3, y: a.y),
                              control2: CGPoint(x: b.x - width / 3, y: b.y))
            }
            var area = line
            if let first = nodes.first, let last = nodes.last {
                area.addLine(to: CGPoint(x: last.x, y: 0)); area.addLine(to: CGPoint(x: first.x, y: 0)); area.closeSubpath()
            }
            return Segment(points: nodes, line: line, area: area)
        }
    }
}

/// Draw 62 seconds: the newest and oldest second are outside the full-width
/// 60-second viewport. Buffer duration never depends on the sidebar width.
struct MetricPlotViewport {
    static let edgeDuration: TimeInterval = 1
    static let drawingDuration = MonitorTimeWindow.duration + edgeDuration * 2
    let visible: CGRect
    let scaleX: CGFloat
    let end: TimeInterval
    var visibleRange: ClosedRange<TimeInterval> { (end - Self.edgeDuration - MonitorTimeWindow.duration)...(end - Self.edgeDuration) }
    var drawingRange: ClosedRange<TimeInterval> { (end - Self.drawingDuration)...end }
    init(size: CGSize, end: TimeInterval) {
        visible = CGRect(origin: .zero, size: size).insetBy(dx: 3, dy: 3)
        scaleX = max(0, visible.width) / MonitorTimeWindow.duration
        self.end = end
    }
    func x(at time: TimeInterval) -> CGFloat {
        visible.minX + (time - visibleRange.lowerBound) * scaleX
    }
}

/// Only sample changes cross into AppKit. Core Animation scrolls the cached
/// shape layers between samples without rebuilding a SwiftUI display list.
struct ScrollingMetricCanvas: NSViewRepresentable {
    let end: TimeInterval
    let upperBound: Double
    let curves: [MetricCurve]
    let duration: Double
    var animateScale = true
    var animateScroll = true
    func makeNSView(context: Context) -> MetricLayerView { MetricLayerView() }
    func updateNSView(_ view: MetricLayerView, context: Context) {
        view.update(curves: curves, end: end, upperBound: upperBound,
                    scrollDuration: animateScroll ? duration : 0, scaleDuration: animateScale ? duration : 0)
    }
}
