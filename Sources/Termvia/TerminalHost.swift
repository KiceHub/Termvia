import TermviaCore
import AppKit
import SwiftUI

/// Only the selected terminal is attached. Sessions retain the other views and
/// processes, so their scrollback and connections survive a tab switch.
struct TerminalSurface: NSViewRepresentable {
    let session: Session?
    let focusRevision: Int
    let canFocus: Bool
    var insets = TerminalInsets()
    func makeNSView(context: Context) -> TerminalHostView { TerminalHostView() }
    func updateNSView(_ view: TerminalHostView, context: Context) {
        view.present(session, revision: focusRevision, canFocus: canFocus, insets: insets)
    }
}

@MainActor final class TerminalHostView: NSView {
    private(set) var insets = TerminalInsets()
    private(set) var session: Session?
    private var focusRevision = -1
    private var focusPending = false
    private var canFocus = true
    private var activationPending = false
    private var contentFrame: NSRect {
        NSRect(x: insets.left, y: insets.bottom, width: max(0, bounds.width - insets.left - insets.right), height: max(0, bounds.height - insets.top - insets.bottom))
    }
    static func rowHeight(of terminal: ThemedTerminalView) -> CGFloat {
        terminal.getOptimalFrameSize().height / CGFloat(max(1, terminal.terminalDimensions.rows))
    }
    override var isOpaque: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        (session?.terminal.nativeBackgroundColor ?? NSColor.textBackgroundColor).setFill()
        dirtyRect.fill()
    }
    func present(_ next: Session?, revision: Int, canFocus: Bool, insets: TerminalInsets = TerminalInsets()) {
        self.canFocus = canFocus
        self.insets = insets.validated()
        if session?.id != next?.id {
            if window?.firstResponder === session?.terminal { window?.makeFirstResponder(nil) }
            session?.terminal.removeFromSuperview()
            session = next
            if let terminal = next?.terminal {
                terminal.frame = contentFrame
                terminal.autoresizingMask = [] // The host centers a whole-cell grid.
                addSubview(terminal)
                terminal.refreshNativeColors()
            }
        }
        needsLayout = true
        if revision != focusRevision { focusRevision = revision; focusPending = true }
        if window != nil { activateSession() }
    }
    override func layout() {
        super.layout()
        guard let terminal = session?.terminal else { return }
        let dimensions = terminal.terminalDimensions
        let optimal = terminal.getOptimalFrameSize().size
        let scroller = terminal.scrollerStyle == .legacy ? NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy) : 0
        let cell = NSSize(width: (optimal.width - scroller) / CGFloat(max(1, dimensions.cols)), height: optimal.height / CGFloat(max(1, dimensions.rows)))
        guard cell.width > 0, cell.height > 0 else { return }
        // Calculate from cell metrics, not the previous frame's row count:
        // SwiftTerm intentionally coalesces grid updates during live resizing.
        let fittedHeight = min(contentFrame.height, floor(contentFrame.height / cell.height + 1e-6) * cell.height + 1e-6)
        // Center both cell remainders instead of accumulating unused height at
        // one edge. In a split workspace the file pane absorbs the row remainder.
        let vertical = insets.bottom + (contentFrame.height - fittedHeight) / 2
        let availableWidth = contentFrame.width
        let width = min(availableWidth, max(0, floor((availableWidth - scroller) / cell.width + 1e-6)) * cell.width + scroller + 1e-6)
        terminal.frame = NSRect(x: insets.left + (availableWidth - width) / 2, y: vertical, width: width, height: fittedHeight)
        var ancestor = superview
        while let view = ancestor {
            if let split = view as? WorkspaceSplitView, !split.isVertical {
                split.reflowTerminalGrid(); break
            }
            ancestor = view.superview
        }
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { activateSession() }
    }
    private func activateSession() {
        guard !activationPending else { return }
        activationPending = true
        // Starting publishes phase changes. Leave the representable update /
        // native layout pass before notifying the observing SwiftUI views.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.activationPending = false
            guard self.window != nil else { return }
            self.session?.start(); self.requestFocus()
        }
    }
    private func requestFocus() {
        guard focusPending, canFocus, let session, session.phase != .connecting, let window, window.attachedSheet == nil else { return }
        let expected = session.id
        DispatchQueue.main.async { [weak self, weak window] in
            guard let self, let window, self.canFocus, self.session?.id == expected, window.attachedSheet == nil else { return }
            if window.makeFirstResponder(session.terminal) { self.focusPending = false }
        }
    }
}
