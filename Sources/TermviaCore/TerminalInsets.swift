import Foundation

public struct TerminalInsets: Codable, Equatable, Sendable {
    public var top = 3.0
    public var bottom = 6.0
    public var left = 6.0
    public var right = 6.0
    public init() {}
    public var vertical: Double { top + bottom }
    public func validated() -> Self {
        let defaults = Self()
        func edge(_ value: Double, _ fallback: Double) -> Double { value.isFinite ? min(48, max(0, value)) : fallback }
        var result = self
        result.top = edge(top, defaults.top); result.bottom = edge(bottom, defaults.bottom)
        result.left = edge(left, defaults.left); result.right = edge(right, defaults.right)
        return result
    }
}
