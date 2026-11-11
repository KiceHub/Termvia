import AppKit
import SwiftUI

/// Resolve the owning window from the attached view, rather than assuming that
/// SwiftUI's onAppear runs after NSApplication.windows has been populated.
struct WorkspaceWindowAttachment: NSViewRepresentable {
    let attach: (NSWindow) -> Void
    func makeNSView(context: Context) -> AttachmentView {
        let view = AttachmentView(); view.attach = attach; return view
    }
    func updateNSView(_ view: AttachmentView, context: Context) {
        view.attach = attach; view.notifyAttachment()
    }
    final class AttachmentView: NSView {
        var attach: ((NSWindow) -> Void)?
        private weak var deliveredWindow: NSWindow?
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); notifyAttachment() }
        func notifyAttachment() {
            guard let window, window !== deliveredWindow, let attach else { return }
#if TERMVIA_DIAGNOSTICS
            WindowStartupLaunchCheck.begin(window)
#endif
            // This callback must finish before the hosting view's first draw.
            // Defer activation/focus, but not toolbar or frame configuration.
            deliveredWindow = window; attach(window)
        }
    }
}
