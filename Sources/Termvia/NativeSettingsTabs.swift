import AppKit
import SwiftUI
import TermviaCore

extension SettingsPage {
    var title: String {
        switch self {
        case .general: return T("通用")
        case .terminal: return T("终端")
        case .connection: return T("连接设置")
        case .proxies: return T("代理")
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
        case .proxies: return "point.3.connected.trianglepath.dotted"
        case .shortcuts: return "keyboard"
        case .credentials: return "key"
        case .about: return "info.circle"
        }
    }
}

/// Keep one native toolbar and one controller per settings page. Switching the
/// page only selects its cached child; it never replaces the window's toolbar.
struct NativeSettingsTabs: NSViewControllerRepresentable {
    struct Inputs: Equatable {
        let settings: AppSettings
        let layout: WorkspaceLayout
        let hosts: [SSHHost]
        let credentials: [LoginCredential]
        @MainActor init(model: AppModel) {
            settings = model.settings; layout = model.layout; hosts = model.hosts; credentials = model.credentials
        }
    }
    struct Page { let page: SettingsPage; let content: AnyView }
    @Binding var selection: SettingsPage
    let pages: [Page]
    let inputs: Inputs
    func makeNSViewController(context: Context) -> Controller { Controller(pages: pages) }
    func updateNSViewController(_ controller: Controller, context: Context) {
        controller.configure(pages: pages, inputs: inputs, selected: selection, environment: context.environment) { page in
            if selection != page { selection = page }
        }
    }
    final class Controller: NSTabViewController {
        private let pageOrder: [SettingsPage]
        #if TERMVIA_DIAGNOSTICS
        private(set) var rootAssignments = 0
        #endif
        private var applying = false
        private var onSelection: ((SettingsPage) -> Void)?
        private var latestPages: [Page] = []
        private var inputs: Inputs?
        private var dirtyPages = Set<Int>()
        private var locale = Locale.current
        private var scheme = ColorScheme.light
        init(pages: [Page]) {
            pageOrder = pages.map(\.page)
            super.init(nibName: nil, bundle: nil)
            tabStyle = .toolbar
            transitionOptions = []
            canPropagateSelectedChildViewControllerTitle = false
            for page in pages {
                let host = PageController(rootView: AnyView(EmptyView()))
                host.sizingOptions = []
                let item = NSTabViewItem(viewController: host)
                item.identifier = "Termvia.Settings.Tab." + page.page.rawValue
                item.label = page.page.title
                item.image = NSImage(systemSymbolName: page.page.symbol, accessibilityDescription: page.page.title)
                addTabViewItem(item)
            }
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
        func configure(pages: [Page], inputs: Inputs, selected: SettingsPage, environment: EnvironmentValues, onSelection: @escaping (SettingsPage) -> Void) {
            self.onSelection = onSelection
            latestPages = pages
            let environmentChanged = locale != environment.locale || scheme != environment.colorScheme
            if self.inputs == nil || self.inputs != inputs || environmentChanged { dirtyPages = Set(pages.indices) }
            let titlesChanged = self.inputs == nil || locale != environment.locale
            self.inputs = inputs; locale = environment.locale; scheme = environment.colorScheme
            applying = true; defer { applying = false }
            if titlesChanged {
                for (index, page) in pages.enumerated() where tabViewItems.indices.contains(index) {
                    if tabViewItems[index].label != page.page.title { tabViewItems[index].label = page.page.title }
                }
            }
            if let index = pageOrder.firstIndex(of: selected), selectedTabViewItemIndex != index { selectedTabViewItemIndex = index }
            updatePage(at: selectedTabViewItemIndex)
        }
        private func updatePage(at index: Int) {
            guard latestPages.indices.contains(index), tabViewItems.indices.contains(index), dirtyPages.remove(index) != nil,
                  let host = tabViewItems[index].viewController as? NSHostingController<AnyView> else { return }
            #if TERMVIA_DIAGNOSTICS
            rootAssignments += 1
            #endif
            host.rootView = AnyView(latestPages[index].content.environment(\.locale, locale).environment(\.colorScheme, scheme))
        }
        override func tabView(_ tabView: NSTabView, willSelect tabViewItem: NSTabViewItem?) {
            if let item = tabViewItem, let index = tabViewItems.firstIndex(where: { $0 === item }) { updatePage(at: index) }
            super.tabView(tabView, willSelect: tabViewItem)
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
