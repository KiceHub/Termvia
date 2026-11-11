import TermviaCore
import AppKit
import SwiftUI
import Combine

/// A single native titlebar: traffic lights, flexible session strip, icon controls.
@MainActor final class TitlebarController: NSObject, NSToolbarDelegate, NSMenuDelegate {
    static let sessionsID = NSToolbarItem.Identifier("Termvia.Sessions")
    static let sidebarID = NSToolbarItem.Identifier("Termvia.Sidebar")
    static let panelID = NSToolbarItem.Identifier("Termvia.Panel")
    static let settingsID = NSToolbarItem.Identifier("Termvia.Settings")
    static let controlIDs = [sidebarID, panelID, settingsID]
    let model: AppModel
    private weak var window: NSWindow?
    let toolbar = NSToolbar(identifier: "Termvia.Titlebar")
    private var layoutObservers = Set<AnyCancellable>()
    private var appearanceObserver: NSKeyValueObservation?
    private var tabContextMonitor: Any?
    private var shortcutRouter: WorkspaceShortcutRouter?
    init(model: AppModel, window: NSWindow) {
        self.model = model
        self.window = window
        model.authenticationPrompts.window = window
        super.init()
        shortcutRouter = WorkspaceShortcutRouter(model: model, window: window)
        AppMenuLocalization.start(model: model, window: window)
        // NSToolbar otherwise handles right-clicks as toolbar customization,
        // before they reach the embedded session controls.
        tabContextMonitor = NSEvent.addLocalMonitorForEvents(matching: [.rightMouseDown, .leftMouseDown]) { [weak self] event in
            guard let self, self.routeTabContextEvent(event) else { return event }
            return nil
        }
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        window.titleVisibility = .hidden
        window.toolbarStyle = .unifiedCompact
        window.toolbar = toolbar
        applyAppearance()
        appearanceObserver = window.observe(\.effectiveAppearance) { [weak self] _, _ in
            DispatchQueue.main.async { [weak self] in
                guard let self, let window = self.window else { return }
                self.model.updateResolvedAppearance(window.effectiveAppearance)
            }
        }
        model.$layout.map(\.language).removeDuplicates().sink { [weak self] _ in
            DispatchQueue.main.async { [weak self] in self?.localizeItems() }
        }.store(in: &layoutObservers)
        model.$layout.map(\.appearance).removeDuplicates().sink { [weak self] _ in
            DispatchQueue.main.async { [weak self] in self?.applyAppearance() }
        }.store(in: &layoutObservers)
    }
    deinit { if let tabContextMonitor { NSEvent.removeMonitor(tabContextMonitor) } }
    private func routeTabContextEvent(_ event: NSEvent) -> Bool {
        let contextClick = event.type == .rightMouseDown || (event.type == .leftMouseDown && event.modifierFlags.contains(.control))
        guard contextClick || (event.type == .leftMouseDown && event.clickCount == 2),
              let window, event.window === window, window.attachedSheet == nil, NSApp.modalWindow == nil,
              let strip = toolbar.items.first(where: { $0.itemIdentifier == Self.sessionsID })?.view,
              strip.bounds.contains(strip.convert(event.locationInWindow, from: nil)), let parent = strip.superview else { return false }
        var hit = strip.hitTest(parent.convert(event.locationInWindow, from: nil))
        while let view = hit, view !== strip {
            if let tab = view as? NativeSessionTab.Hosting {
                if contextClick { tab.rightMouseDown(with: event); return true }
                return tab.handleDoubleClick(event)
            }
            hit = view.superview
        }
        return false
    }
    private func applyAppearance() {
        let appearance = AppAppearance.override(for: model.layout.appearance)
        guard let window else { return }
        if window.appearance?.name != appearance?.name { window.appearance = appearance }
        model.updateResolvedAppearance(window.effectiveAppearance)
    }
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { [Self.sessionsID] + Self.controlIDs }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { toolbarDefaultItemIdentifiers(toolbar) }
    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        if identifier == Self.sessionsID {
            let item = NSToolbarItem(itemIdentifier: identifier)
            let view = NSHostingView(rootView: LocalizedTitlebar(model: model))
            view.identifier = NSUserInterfaceItemIdentifier("Termvia.SessionStrip")
            view.sizingOptions = []
            view.setContentHuggingPriority(.init(1), for: .horizontal)
            view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            view.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([view.widthAnchor.constraint(greaterThanOrEqualToConstant: 160), view.heightAnchor.constraint(equalToConstant: 32)])
            item.view = view; item.label = T("会话"); item.visibilityPriority = .high
            // Each selected tab has its own system glass; avoid nesting it in a glass strip.
            item.isBordered = false
            return item
        }
        if identifier == Self.settingsID {
            let item = NSMenuToolbarItem(itemIdentifier: identifier)
            item.label = T("更多"); item.toolTip = T("更多")
            item.image = NSImage(systemSymbolName: "ellipsis", accessibilityDescription: T("更多"))
            item.isBordered = true
            item.showsIndicator = false
            let menu = NSMenu(); menu.delegate = self
            menuNeedsUpdate(menu) // Populate before AppKit snapshots the toolbar menu.
            item.menu = menu
            let image = item.image
            let button = ToolbarMenuButton(menu: menu, label: item.label, tip: item.toolTip)
            item.view = button
            button.setDisplayImage(image)
            return item
        }
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.isBordered = true
        switch identifier {
        case Self.sidebarID:
            item.label = T("侧栏"); item.toolTip = T("侧栏 · ⌥⌘M")
            item.image = NSImage(systemSymbolName: "sidebar.left", accessibilityDescription: T("显示或隐藏侧栏"))
            item.action = #selector(toggleSidebar)
        case Self.panelID:
            item.label = T("文件面板"); item.toolTip = T("文件面板 · ⌥⌘B")
            item.image = NSImage(systemSymbolName: "rectangle.bottomthird.inset.filled", accessibilityDescription: T("显示或隐藏底部面板"))
            item.action = #selector(togglePanel)
        default: return nil
        }
        item.target = self
        // Keep the compact 40 pt titlebar. A native button with a 28 pt height
        // lets AppKit size the shared glass slightly taller than its 24 pt default.
        item.view = ToolbarLayoutButton(image: item.image, label: item.label, tip: item.toolTip, target: self, action: item.action)
        return item
    }
    @objc private func toggleSidebar() { model.layout.monitorVisible.toggle() }
    @objc private func togglePanel() { model.layout.panelVisible.toggle() }
    @objc private func showSettings() { model.openSettings?() }
    @objc private func setAppearance(_ sender: NSMenuItem) { if let mode = sender.representedObject as? String { model.layout.appearance = mode } }
    @objc private func resetLayout() {
        var reset = model.layout
        let defaults = TermviaCore.WorkspaceLayout()
        reset.monitorFraction = defaults.monitorFraction; reset.terminalFraction = defaults.terminalFraction; reset.remoteFraction = defaults.remoteFraction
        reset.monitorVisible = true; reset.panelVisible = true
        model.layout = reset
    }
    @objc private func setLanguage(_ sender: NSMenuItem) {
        if let raw = sender.representedObject as? String, let language = AppLanguage(rawValue: raw) { model.layout.language = language }
    }
    private func localizeItems() {
        let labels = [Self.sessionsID: "会话", Self.sidebarID: "侧栏", Self.panelID: "文件面板", Self.settingsID: "更多"]
        let tips = [Self.sidebarID: "侧栏 · ⌥⌘M", Self.panelID: "文件面板 · ⌥⌘B", Self.settingsID: "更多"]
        for item in toolbar.items {
            if let key = labels[item.itemIdentifier] { item.label = T(key) }
            if let key = tips[item.itemIdentifier] { item.toolTip = T(key) }
            if let button = item.view as? NSButton { button.setAccessibilityLabel(item.label) }
            if let menu = (item as? NSMenuToolbarItem)?.menu { menuNeedsUpdate(menu) }
        }
        AppMenuLocalization.apply()
    }
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let settings = NSMenuItem(title: T("设置…"), action: #selector(showSettings), keyEquivalent: ",")
        settings.target = self; menu.addItem(settings); menu.addItem(.separator())
        let languageItem = NSMenuItem(title: T("语言"), action: nil, keyEquivalent: "")
        let languages = NSMenu()
        for language in AppLanguage.allCases {
            let item = NSMenuItem(title: language.title, action: #selector(setLanguage(_:)), keyEquivalent: "")
            item.target = self; item.representedObject = language.rawValue
            item.state = model.layout.language == language ? .on : .off
            languages.addItem(item)
        }
        languageItem.submenu = languages; menu.addItem(languageItem)
        let themeItem = NSMenuItem(title: T("主题"), action: nil, keyEquivalent: "")
        let themes = NSMenu()
        for mode in ["系统", "浅色", "深色"] {
            let item = NSMenuItem(title: T(mode), action: #selector(setAppearance(_:)), keyEquivalent: "")
            item.target = self; item.representedObject = mode; item.state = model.layout.appearance == mode ? .on : .off
            themes.addItem(item)
        }
        themeItem.submenu = themes; menu.addItem(themeItem)
        menu.addItem(.separator())
        let reset = NSMenuItem(title: T("重置布局"), action: #selector(resetLayout), keyEquivalent: "")
        reset.target = self; menu.addItem(reset)
        // Rebuilding an attached native pull-down can hide its new first item
        // as a title, even when usesItemFromMenu is false. Restore the action
        // after insertion, both on initial localization and before tracking.
        settings.isHidden = false
    }
}

private struct LocalizedTitlebar: View {
    @ObservedObject var model: AppModel
    var body: some View { TitlebarSessions(model: model).workspaceEnvironment(model: model) }
}

struct TitlebarSessions: View {
    @Environment(\.locale) private var uiLocale
    @ObservedObject var model: AppModel
    var body: some View {
        let _ = uiLocale.identifier
        GeometryReader { geometry in
            ScrollViewReader { reader in
                ScrollView(.horizontal) {
                    HStack(spacing: 2) {
                        ForEach(model.sessions) { session in
                            SessionTab(session: session, selected: model.selected == session.id,
                                       select: { model.selected = session.id; model.focusTerminal() },
                                       close: { model.close(session) },
                                       reconnect: { model.reconnect(session) },
                                       rename: { model.presentTabRename(session) },
                                       hostIcon: model.tabIcon(for: session),
                                       doubleClickCloses: model.settings.doubleClickClosesTab).id(session.id)
                        }
                        NewSessionButton { model.newStartPage() }
                        WindowDragSpace().frame(minWidth: 20, maxWidth: .infinity, maxHeight: .infinity)
                    }.frame(minWidth: geometry.size.width, alignment: .leading)
                }.scrollIndicators(.hidden)
                    .onChange(of: model.selected) { _, id in if let id { reader.scrollTo(id) } }
            }
        }.frame(height: 32).environment(\.locale, model.locale)
#if TERMVIA_DIAGNOSTICS
        .background(AppearanceCheckProbe(role: "tabs"))
#endif

    }
}

private struct NewSessionButton: View {
    let action: () -> Void
    @State private var hovered = false
    var body: some View {
        Button(action: action) { Image(systemName: "plus").frame(width: 38, height: 30).contentShape(Capsule()) }
            .buttonStyle(.plain).help(T("新建标签页")).accessibilityLabel(T("新建标签页")).accessibilityIdentifier("Termvia.NewTab")
            .modifier(SessionCapsule(hovered: hovered)).onHover { hovered = $0 }
    }
}

private struct WindowDragSpace: NSViewRepresentable {
    final class DragView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }
        override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
    }
    func makeNSView(context: Context) -> DragView { DragView() }
    func updateNSView(_ view: DragView, context: Context) {}
}
