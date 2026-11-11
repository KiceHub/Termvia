import AppKit
import QuartzCore
import SwiftUI
import TermviaCore

/// Keeps the presentation position when a new sample interrupts an animation.
/// No display timer is needed: the compositor evaluates the same linear phase.
struct MetricTransition {
    var from: Double
    var to: Double
    var began: Double
    var duration: Double
    func value(at now: Double) -> Double {
        let fraction = duration > 0 ? min(1, max(0, (now - began) / duration)) : 1
        return from + (to - from) * fraction
    }
    func remaining(at now: Double) -> Double { max(0, duration - max(0, now - began)) }
}

/// Cached paths are submitted once per sample/resize. Core Animation handles
/// scrolling and occasional scale growth without per-frame SwiftUI/CPU drawing.
@MainActor final class MetricLayerView: NSView {
    private let grid = CAShapeLayer(), clip = CALayer(), content = CALayer()
    private var fills: [CAShapeLayer] = [], strokes: [CAShapeLayer] = [], markers: [CAShapeLayer] = []
    private var curves: [MetricCurve] = []
    private var end = 0.0, upperBound = 1.0, scrollDuration = 0.0, scaleDuration = 0.0
    private var scroll: MetricTransition?, scale: MetricTransition?
    private var renderedSize = CGSize.zero
    private var dirty = false
    private(set) var geometryUpdates = 0
    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }
    // Layers are configured in layout; no empty backing bitmap is necessary.
    override func updateLayer() {}

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.isGeometryFlipped = true
        layer?.addSublayer(grid); layer?.addSublayer(clip)
        clip.masksToBounds = true; clip.addSublayer(content)
        grid.fillColor = nil; grid.lineWidth = 0.5
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func update(curves: [MetricCurve], end: Double, upperBound: Double, scrollDuration: Double, scaleDuration: Double) {
        let bound = max(1, upperBound)
        guard self.curves != curves || self.end != end || self.upperBound != bound
                || self.scrollDuration != scrollDuration || self.scaleDuration != scaleDuration else { return }
        self.curves = curves; self.end = end; self.upperBound = bound
        self.scrollDuration = scrollDuration; self.scaleDuration = scaleDuration
        invalidateGeometry()
    }
    override func layout() {
        super.layout()
        if dirty || renderedSize != bounds.size { render() }
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        invalidateGeometry()
    }
    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        invalidateGeometry()
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        invalidateGeometry()
    }
    private func invalidateGeometry() {
        dirty = true; needsLayout = true
    }

    private func phase(_ previous: MetricTransition?, target: Double, duration: Double, now: Double) -> MetricTransition {
        guard let previous, duration > 0, target >= previous.to else { return MetricTransition(from: target, to: target, began: now, duration: 0) }
        guard previous.to != target else { return previous }
        return MetricTransition(from: previous.value(at: now), to: target, began: now, duration: duration)
    }
    private func animate(_ layer: CALayer, key: String, from: Any, to: Any, duration: Double) {
        layer.removeAnimation(forKey: key)
        guard duration > 0 else { return }
        let animation = CABasicAnimation(keyPath: key)
        animation.fromValue = from; animation.toValue = to; animation.duration = duration
        // Slow, small monitor plots do not need the display's maximum rate.
        animation.preferredFrameRateRange = CAFrameRateRange(minimum: 15, maximum: 30, preferred: 30)
        animation.timingFunction = CAMediaTimingFunction(name: .linear)
        layer.add(animation, forKey: key)
    }
    private func render() {
        guard bounds.width > 6, bounds.height > 6, let root = layer else { return }
        dirty = false; renderedSize = bounds.size; geometryUpdates += 1
        let rect = bounds.insetBy(dx: 3, dy: 3)
        let viewport = MetricPlotViewport(size: bounds.size, end: end)
        let now = CACurrentMediaTime()
        scroll = phase(scroll, target: viewport.end, duration: scrollDuration, now: now)
        scale = phase(scale, target: upperBound, duration: scaleDuration, now: now)
        guard let scroll, let scale else { return }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        let density = window?.backingScaleFactor ?? 2
        root.contentsScale = density; grid.contentsScale = density
        grid.frame = bounds
        let gridPath = CGMutablePath()
        for fraction in [0.0, 0.5, 1] {
            let y = rect.minY + rect.height * fraction
            gridPath.move(to: CGPoint(x: rect.minX, y: y)); gridPath.addLine(to: CGPoint(x: rect.maxX, y: y))
        }
        grid.path = gridPath
        effectiveAppearance.performAsCurrentDrawingAppearance { grid.strokeColor = NSColor.separatorColor.withAlphaComponent(0.45).cgColor }
        clip.frame = viewport.visible
        content.anchorPoint = .zero; content.bounds = bounds
        content.position = CGPoint(x: -viewport.visible.minX, y: -viewport.visible.minY)
        if fills.count != curves.count {
            content.sublayers?.forEach { $0.removeFromSuperlayer() }
            fills = curves.map { _ in CAShapeLayer() }; strokes = curves.map { _ in CAShapeLayer() }; markers = curves.map { _ in CAShapeLayer() }
            for index in curves.indices.reversed() { content.addSublayer(fills[index]) }
            for index in curves.indices.reversed() { content.addSublayer(strokes[index]); content.addSublayer(markers[index]) }
        }
        let colors: [NSColor] = [.systemBlue, .systemOrange, .systemPurple]
        for index in curves.indices {
            let curve = curves[index]
            func paths(bound: Double) -> (line: CGPath, area: CGPath, marker: CGPath) {
                let line = CGMutablePath(), area = CGMutablePath(), marker = CGMutablePath()
                var matrix = CGAffineTransform(a: viewport.scaleX, b: 0, c: 0, d: -rect.height / max(1, bound), tx: viewport.x(at: curve.origin), ty: rect.maxY)
                for segment in curve.segments {
                    if segment.points.count == 1, let node = segment.points.first {
                        guard viewport.drawingRange.contains(curve.origin + node.x) else { continue }
                        let point = node.applying(matrix), radius = MetricStroke.width / 2
                        marker.addEllipse(in: CGRect(x: point.x - radius, y: point.y - radius, width: MetricStroke.width, height: MetricStroke.width))
                    } else {
                        if let path = segment.line.cgPath.copy(using: &matrix) { line.addPath(path) }
                        if let path = segment.area.cgPath.copy(using: &matrix) { area.addPath(path) }
                    }
                }
                return (line, area, marker)
            }
            let target = paths(bound: upperBound), remaining = scale.remaining(at: now)
            let current = remaining > 0 ? paths(bound: scale.value(at: now)) : target
            let layers = [strokes[index], fills[index], markers[index]]
            effectiveAppearance.performAsCurrentDrawingAppearance {
                let color = colors[min(2, index)]
                strokes[index].strokeColor = color.cgColor; strokes[index].fillColor = nil
                fills[index].fillColor = color.withAlphaComponent(0.12).cgColor; fills[index].strokeColor = nil
                markers[index].fillColor = color.cgColor; markers[index].strokeColor = nil
            }
            strokes[index].lineWidth = MetricStroke.width; strokes[index].lineCap = .round; strokes[index].lineJoin = .round
            let before = [current.line, current.area, current.marker], after = [target.line, target.area, target.marker]
            for index in layers.indices {
                let shape = layers[index]
                shape.frame = bounds; shape.contentsScale = density; shape.path = after[index]
                animate(shape, key: "path", from: before[index], to: after[index], duration: remaining)
            }
        }
        content.transform = CATransform3DIdentity
        animate(content, key: "transform.translation.x", from: (viewport.end - scroll.value(at: now)) * viewport.scaleX, to: 0.0, duration: scroll.remaining(at: now))
    }
}
