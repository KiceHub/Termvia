import AppKit
import SwiftUI

/// Let AppKit own the sidebar material, edge treatment and collapse behavior.
struct NativeSidebarSplit<Sidebar: View, Content: View>: NSViewControllerRepresentable {
    @Binding var fraction: Double
    @Binding var visible: Bool
    @ViewBuilder var sidebar: () -> Sidebar
    @ViewBuilder var second: () -> Content

    func makeNSViewController(context: Context) -> NativeSidebarController {
        NativeSidebarController(sidebar: AnyView(sidebar().environment(\.locale, context.environment.locale).environment(\.colorScheme, context.environment.colorScheme)),
                                content: AnyView(second().environment(\.locale, context.environment.locale).environment(\.colorScheme, context.environment.colorScheme)))
    }
    func updateNSViewController(_ controller: NativeSidebarController, context: Context) {
        controller.sidebarHost.rootView = AnyView(sidebar().environment(\.locale, context.environment.locale).environment(\.colorScheme, context.environment.colorScheme))
        controller.contentHost.rootView = AnyView(second().environment(\.locale, context.environment.locale).environment(\.colorScheme, context.environment.colorScheme))
        controller.configure(fraction: fraction, visible: visible) { newFraction, newVisible in
            if abs(fraction - newFraction) > 0.002 { fraction = newFraction }
            if visible != newVisible { visible = newVisible }
        }
    }
}

@MainActor final class NativeSidebarController: NSSplitViewController {
    let sidebarHost: NSHostingController<AnyView>
    let contentHost: NSHostingController<AnyView>
    private(set) var sidebarItem: NSSplitViewItem!
    private var fraction = 0.18
    private var lastWidth: CGFloat = 0
    private var applying = false
    private var needsFraction = true
    private var configured = false
    private var collapseObservation: NSKeyValueObservation?
    private var onChange: ((Double, Bool) -> Void)?

    init(sidebar: AnyView, content: AnyView) {
        sidebarHost = NSHostingController(rootView: sidebar)
        contentHost = NSHostingController(rootView: content)
        sidebarHost.sizingOptions = []; contentHost.sizingOptions = []
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override func viewDidLoad() {
        super.viewDidLoad()
        sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebarHost)
        sidebarItem.minimumThickness = 190
        sidebarItem.maximumThickness = 480
        sidebarItem.canCollapseFromWindowResize = false
        // Keep the single session strip across the entire titlebar.
        sidebarItem.allowsFullHeightLayout = false
        sidebarItem.collapseBehavior = .preferResizingSiblingsWithFixedSplitView
        let content = NSSplitViewItem(viewController: contentHost)
        content.minimumThickness = 720
        addSplitViewItem(sidebarItem); addSplitViewItem(content)
        NotificationCenter.default.addObserver(self, selector: #selector(didResize), name: NSSplitView.didResizeSubviewsNotification, object: splitView)
        collapseObservation = sidebarItem.observe(\.isCollapsed) { [weak self] _, _ in
            Task { @MainActor [weak self] in self?.publishState() }
        }
    }
    func configure(fraction: Double, visible: Bool, onChange: @escaping (Double, Bool) -> Void) {
        loadViewIfNeeded()
        self.onChange = onChange
        applying = true
        if abs(self.fraction - fraction) > 0.002 { self.fraction = fraction; needsFraction = true }
        if sidebarItem.isCollapsed == visible { sidebarItem.isCollapsed = !visible; needsFraction = true }
        configured = true
        applying = false
        view.needsLayout = true
    }
    override func viewDidLayout() {
        super.viewDidLayout()
        let width = splitView.bounds.width
        guard width > 0 else { return }
        if abs(lastWidth - width) > 0.5 { lastWidth = width; needsFraction = true }
        guard needsFraction, !sidebarItem.isCollapsed else { return }
        needsFraction = false
        applying = true
        let length = max(0, width - splitView.dividerThickness)
        let position = min(min(480, length - 720), max(190, length * fraction))
        splitView.setPosition(max(0, position), ofDividerAt: 0)
        applying = false
    }
    @objc private func didResize(_ notification: Notification) {
        guard configured, !applying, !sidebarItem.isCollapsed,
              abs(lastWidth - splitView.bounds.width) < 0.5 else { return }
        let length = splitView.bounds.width - splitView.dividerThickness
        guard length > 0 else { return }
        fraction = Double(sidebarHost.view.frame.width / length)
        publishState()
    }
    private func publishState() {
        guard configured, !applying else { return }
        // Defer model writes out of AppKit/SwiftUI's layout pass.
        let callback = onChange, value = fraction, visible = !sidebarItem.isCollapsed
        DispatchQueue.main.async { callback?(value, visible) }
    }
}
