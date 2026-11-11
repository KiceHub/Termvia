import AppKit

@MainActor enum WorkspaceWindowGeometry {
    static let minimumContentSize = NSSize(width: 960, height: 640)
    static let autosaveName = NSWindow.FrameAutosaveName("Termvia.MainWindow")

    static func configure(_ window: NSWindow, autosaveName: NSWindow.FrameAutosaveName?) {
        window.contentMinSize = minimumContentSize
        // Setting the name restores its saved frame as well as enabling saving.
        // SwiftUI scene restoration is disabled so this is the only owner.
        if let autosaveName { window.setFrameAutosaveName(autosaveName) }
        // SwiftUI uses fullSizeContentView: frameRect(forContentRect:) includes
        // the titlebar in "content", while the workspace needs the usable area.
        let layout = window.contentLayoutRect
        let minimumFrame = NSSize(width: minimumContentSize.width + max(0, window.frame.width - layout.width),
                                  height: minimumContentSize.height + max(0, window.frame.height - layout.height))
        var frame = window.frame
        frame.size.width = max(frame.width, minimumFrame.width)
        frame.size.height = max(frame.height, minimumFrame.height)
        let enlarged = frame.size != window.frame.size
        frame = window.constrainFrameRect(frame, to: window.screen)
        if enlarged, let visible = window.screen?.visibleFrame {
            frame.origin.x = max(visible.minX, min(frame.minX, visible.maxX - frame.width))
            frame.origin.y = min(visible.maxY - frame.height, max(visible.minY, frame.minY))
        }
        if frame != window.frame { window.setFrame(frame, display: false) }
    }
}
