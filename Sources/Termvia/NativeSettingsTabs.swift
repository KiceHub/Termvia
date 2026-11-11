import AppKit
import SwiftUI
import TermviaCore

extension SettingsPage {
    var title: String {
        switch self {
        case .general: return T("通用")
        case .terminal: return T("终端")
        case .connection: return T("连接设置")
        case .shortcuts: return T("快捷键")
        case .credentials: return T("登录信息")
        case .about: return T("关于")
        }
    }
    var symbol: String {
        switch self {
        case .general: return "gearshape"
        case .terminal: return "terminal"
        case .connection: return "network"
        case .shortcuts: return "keyboard"
        case .credentials: return "key"
        case .about: return "info.circle"
        }
    }
}

/// Keep one native toolbar and one controller per settings page. Switching the
/// page only selects its cached child; it never replaces the window's toolbar.
struct NativeSettingsTabs: NSViewControllerRepresentable {
    struct Page { let page: SettingsPage; let content: AnyView }
    @Binding var selection: SettingsPage
    let pages: [Page]
    func makeNSViewController(context: Context) -> Controller { Controller(pages: pages) }
    func updateNSViewController(_ controller: Controller, context: Context) {
        controller.configure(pages: pages, selected: selection, environment: context.environment) { page in
            if selection != page { selection = page }
        }
    }
    final class Controller: NSTabViewController {
        private let pageOrder: [SettingsPage]
        private var applying = false
        private var onSelection: ((SettingsPage) -> Void)?
        init(pages: [Page]) {
            pageOrder = pages.map(\.page)
            super.init(nibName: nil, bundle: nil)
            tabStyle = .toolbar
            transitionOptions = []
            canPropagateSelectedChildViewControllerTitle = false
            for page in pages {
                let host = PageController(rootView: page.content)
                host.sizingOptions = []
                let item = NSTabViewItem(viewController: host)
                item.identifier = "Termvia.Settings.Tab." + page.page.rawValue
                item.label = page.page.title
                item.image = NSImage(systemSymbolName: page.page.symbol, accessibilityDescription: page.page.title)
                addTabViewItem(item)
            }
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
        func configure(pages: [Page], selected: SettingsPage, environment: EnvironmentValues, onSelection: @escaping (SettingsPage) -> Void) {
            self.onSelection = onSelection
            applying = true; defer { applying = false }
            for (index, page) in pages.enumerated() {
                guard tabViewItems.indices.contains(index), let host = tabViewItems[index].viewController as? NSHostingController<AnyView> else { continue }
                host.rootView = AnyView(page.content.environment(\.locale, environment.locale).environment(\.colorScheme, environment.colorScheme))
                let title = page.page.title
                if tabViewItems[index].label != title { tabViewItems[index].label = title }
            }
            if let index = pageOrder.firstIndex(of: selected), selectedTabViewItemIndex != index { selectedTabViewItemIndex = index }
        }
        override func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
            super.tabView(tabView, didSelect: tabViewItem)
            guard !applying, pageOrder.indices.contains(selectedTabViewItemIndex) else { return }
            let selected = pageOrder[selectedTabViewItemIndex]
            onSelection?(selected)
        }
    }

    private final class PageController: NSHostingController<AnyView> {
        override func viewDidAppear() {
            super.viewDidAppear()
            // AppKit otherwise selects the first editable field when opening
            // a page. Leave focus with the window until the user navigates.
            view.window?.makeFirstResponder(nil)
        }
    }
}
