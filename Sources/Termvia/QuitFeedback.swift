import AppKit
import Combine
import SwiftUI
import TermviaCore

@MainActor final class QuitFeedbackController {
    private let panel: NSPanel
    private var visibility: AnyCancellable?
    private var fadedWindows: [FadedWindow] = []
    @MainActor private final class FadedWindow {
        weak var window: NSWindow?
        let alpha: CGFloat
        init(_ window: NSWindow) { self.window = window; alpha = window.alphaValue }
    }
    private final class HintPanel: NSPanel {
        override var canBecomeKey: Bool { false }
        override var canBecomeMain: Bool { false }
    }
    init(shortcut: HoldToQuit) {
        panel = HintPanel(contentRect: NSRect(x: 0, y: 0, width: 320, height: 100), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.identifier = NSUserInterfaceItemIdentifier("Termvia.QuitHint")
        panel.isReleasedWhenClosed = false; panel.isOpaque = false; panel.backgroundColor = .clear
        panel.hasShadow = false; panel.ignoresMouseEvents = true; panel.hidesOnDeactivate = true; panel.worksWhenModal = true
        panel.level = .modalPanel
        panel.collectionBehavior = [.fullScreenAuxiliary, .transient]
        panel.contentView = NSHostingView(rootView: QuitShortcutHint())
        // @Published sends before storing. Use its new value directly on the
        // owning actor; default-mode delivery would stall inside runModal().
        visibility = shortcut.$showingHint.removeDuplicates().sink { [weak self] showing in self?.update(showing: showing) }
    }
    private func update(showing: Bool) {
        guard showing else { hide(); return }
        guard !panel.isVisible else { return }
        guard let parent = NSApp.keyWindow?.sheetParent ?? NSApp.keyWindow ?? NSApp.mainWindow else { return }
        panel.appearance = parent.effectiveAppearance
        panel.animationBehavior = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? .none : .utilityWindow
        let available = parent.screen?.visibleFrame ?? parent.frame
        let size = panel.frame.size
        let x = min(max(parent.frame.midX - size.width / 2, available.minX + 12), available.maxX - size.width - 12)
        let y = min(max(parent.frame.midY - size.height / 2, available.minY + 12), available.maxY - size.height - 12)
        panel.setFrameOrigin(NSPoint(x: x, y: y))
        parent.addChildWindow(panel, ordered: .above)
        panel.orderFront(nil)
        NSAccessibility.post(element: NSApp!, notification: .announcementRequested, userInfo: [
            .announcement: T("按住 ⌘Q 退出"), .priority: NSAccessibilityPriorityLevel.high.rawValue
        ])
    }
    func confirm() {
        guard fadedWindows.isEmpty else { return }
        // Alpha, not orderOut/hide: keep the key application alive until Q is
        // released so a held shortcut cannot reach the next application.
        fadedWindows = NSApp.windows.filter { $0 !== panel && $0.isVisible }.map(FadedWindow.init)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.12
            for item in fadedWindows { item.window?.animator().alphaValue = 0 }
        }
    }
    func restoreWindows() {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            for item in fadedWindows { item.window?.animator().alphaValue = item.alpha }
        }
        fadedWindows.removeAll()
    }
    private func hide() {
        panel.parent?.removeChildWindow(panel); panel.orderOut(nil)
    }
    func stop() {
        visibility?.cancel(); visibility = nil
        restoreWindows(); hide(); panel.contentView = nil
    }
}

struct QuitShortcutHint: View {
    var body: some View {
        Text(T("按住 ⌘Q 退出")).font(.system(size: 21, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.85)
            .padding(.horizontal, 20).frame(width: 296, height: 76)
            .glassEffect(.regular, in: .rect(cornerRadius: 22)).padding(12)
            .allowsHitTesting(false).accessibilityElement(children: .ignore)
            .accessibilityLabel(T("按住 ⌘Q 退出"))
    }
}
