import AppKit

/// SwiftUI retains ownership of its window delegate callbacks. Forward every
/// callback except close approval, which must go through workspace shutdown.
@MainActor final class WorkspaceWindowDelegate: NSObject, NSWindowDelegate {
    weak var original: NSWindowDelegate?
    var onClose: (() -> Void)?
    init(original: NSWindowDelegate?, onClose: @escaping () -> Void) {
        self.original = original; self.onClose = onClose
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { onClose?(); return false }
    override func responds(to selector: Selector!) -> Bool { super.responds(to: selector) || original?.responds(to: selector) == true }
    override func forwardingTarget(for selector: Selector!) -> Any? {
        if original?.responds(to: selector) == true { return original }
        return super.forwardingTarget(for: selector)
    }
}
