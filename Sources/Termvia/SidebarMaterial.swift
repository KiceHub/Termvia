import AppKit
import SwiftUI

/// One native sidebar material spans the whole window. Opaque document/terminal
/// panes cover its body; the titlebar and sidebar reveal the same backing view.
@MainActor final class SidebarSurfaceController: NSSplitViewController {
    let content: NSViewController
    init(content: NSViewController) {
        self.content = content
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override func viewDidLoad() {
        super.viewDidLoad()
        view.identifier = .init("Termvia.Chrome.Surface")
        splitView.isVertical = true
        let item = NSSplitViewItem(sidebarWithViewController: content)
        item.minimumThickness = 0
        item.maximumThickness = NSSplitViewItem.unspecifiedDimension
        item.automaticMaximumThickness = NSSplitViewItem.unspecifiedDimension
        item.preferredThicknessFraction = 1
        item.canCollapse = false
        item.allowsFullHeightLayout = true
        addSplitViewItem(item)
    }
}

struct WorkspaceSurface: NSViewControllerRepresentable {
    @ObservedObject var model: AppModel
    func makeNSViewController(context: Context) -> SidebarSurfaceController {
        let openSettings = context.environment.openSettings
        model.openSettings = { openSettings() }
        let host = NSHostingController(rootView: WorkspaceView(model: model))
        host.sizingOptions = []
        return SidebarSurfaceController(content: host)
    }
    func updateNSViewController(_ controller: SidebarSurfaceController, context: Context) {
        let openSettings = context.environment.openSettings
        model.openSettings = { openSettings() }
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsViewController: SidebarSurfaceController, context: Context) -> NSSize? {
        NSSize(width: proposal.width ?? 0, height: proposal.height ?? 0)
    }
}
