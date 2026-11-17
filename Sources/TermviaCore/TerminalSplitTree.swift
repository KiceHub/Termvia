import Foundation

public indirect enum TerminalSplitTree: Equatable, Sendable {
    case leaf(UUID)
    case split(UUID, sideBySide: Bool, TerminalSplitTree, TerminalSplitTree)
    public var leaves: [UUID] {
        switch self { case .leaf(let id): return [id]; case .split(_, _, let a, let b): return a.leaves + b.leaves }
    }
    public func adding(_ id: UUID, beside target: UUID, sideBySide: Bool) -> Self {
        switch self {
        case .leaf(let leaf): return leaf == target ? .split(UUID(), sideBySide: sideBySide, self, .leaf(id)) : self
        case .split(let key, let axis, let a, let b): return .split(key, sideBySide: axis, a.adding(id, beside: target, sideBySide: sideBySide), b.adding(id, beside: target, sideBySide: sideBySide))
        }
    }
    public func swapping(_ first: UUID, _ second: UUID) -> Self {
        switch self {
        case .leaf(let id): return .leaf(id == first ? second : id == second ? first : id)
        case .split(let id, let axis, let a, let b): return .split(id, sideBySide: axis, a.swapping(first, second), b.swapping(first, second))
        }
    }
    public func removing(_ id: UUID) -> Self? {
        switch self {
        case .leaf(let leaf): return leaf == id ? nil : self
        case .split(let key, let axis, let a, let b):
            let a = a.removing(id), b = b.removing(id)
            if let a, let b { return .split(key, sideBySide: axis, a, b) }
            return a ?? b
        }
    }
}
