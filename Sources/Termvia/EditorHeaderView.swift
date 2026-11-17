import AppKit
import SwiftUI
import TermviaCore

/// Match the workspace's native, single-row titlebar and toolbar controls.
@MainActor final class EditorTitlebarController: NSObject, NSToolbarDelegate {
    static let tabsID = NSToolbarItem.Identifier("Termvia.Editor.Tabs")
    static let zoomOutID = NSToolbarItem.Identifier("Termvia.Editor.ZoomOut")
    static let zoomInID = NSToolbarItem.Identifier("Termvia.Editor.ZoomIn")
    static let refreshID = NSToolbarItem.Identifier("Termvia.Editor.Refresh")
    static let saveID = NSToolbarItem.Identifier("Termvia.Editor.Save")
    private weak var controller: FileEditorController?
    private weak var window: NSWindow?
    private var header: NSHostingView<EditorHeaderContent>?
    private var appearanceRefresh: ToolbarAppearanceRefresh?
    private var tabMonitor: Any?
    let toolbar = NSToolbar(identifier: "Termvia.Editor.Titlebar")

    init(controller: FileEditorController, window: NSWindow) {
        self.controller = controller; self.window = window
        super.init()
        toolbar.delegate = self; toolbar.displayMode = .iconOnly; toolbar.allowsUserCustomization = false
        window.titleVisibility = .hidden; window.toolbarStyle = .unifiedCompact; window.toolbar = toolbar
        WorkspaceChrome.apply(to: window)
        appearanceRefresh = ToolbarAppearanceRefresh(toolbar: toolbar, preserving: [Self.tabsID])
        // NSToolbar intercepts context clicks before embedded SwiftUI controls.
        // Route them to the same native tab host used by the main window.
        tabMonitor = NSEvent.addLocalMonitorForEvents(matching: [.rightMouseDown, .leftMouseDown]) { [weak self] event in
            guard let self, self.routeTabEvent(event) else { return event }
            return nil
        }
    }
    func reload() {
        guard let controller else { return }
        for item in toolbar.items where item.itemIdentifier != Self.tabsID {
            item.isEnabled = enabled(item.itemIdentifier, controller: controller)
            guard let button = item.view as? NSButton else { continue }
            let label = label(for: item.itemIdentifier)
            item.label = label; item.toolTip = label; button.toolTip = label
            button.setAccessibilityLabel(label); button.isEnabled = item.isEnabled
        }
    }
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { [Self.tabsID, Self.zoomOutID, Self.zoomInID, .space, Self.refreshID, .space, Self.saveID] }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { toolbarDefaultItemIdentifiers(toolbar) }
    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        guard let controller else { return nil }
        let item = NSToolbarItem(itemIdentifier: identifier)
        if identifier == Self.tabsID {
            let view = NSHostingView(rootView: EditorHeaderContent(controller: controller))
            view.identifier = .init("Termvia.Editor.TabStrip"); view.sizingOptions = []; view.clipsToBounds = true
            view.setContentHuggingPriority(.init(1), for: .horizontal)
            view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            view.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([view.widthAnchor.constraint(greaterThanOrEqualToConstant: 160), view.heightAnchor.constraint(equalToConstant: 34)])
            item.view = view; item.label = T("文件编辑器"); item.visibilityPriority = .high; item.isBordered = false
            header = view
            return item
        }
        let symbol: String, action: Selector
        switch identifier {
        case Self.zoomOutID: symbol = "textformat.size.smaller"; action = #selector(zoomOut)
        case Self.zoomInID: symbol = "textformat.size.larger"; action = #selector(zoomIn)
        case Self.refreshID: symbol = "arrow.clockwise"; action = #selector(refresh)
        case Self.saveID: symbol = "checkmark"; action = #selector(save)
        default: return nil
        }
        let label = label(for: identifier)
        item.label = label; item.toolTip = label; item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        item.target = self; item.action = action; item.isBordered = true; item.autovalidates = false
        let button = ToolbarLayoutButton(image: item.image, label: label, tip: label, target: self, action: action)
        button.setAccessibilityIdentifier(identifier.rawValue)
        if identifier == Self.saveID { button.keyEquivalent = "s"; button.keyEquivalentModifierMask = .command }
        item.isEnabled = enabled(identifier, controller: controller); button.isEnabled = item.isEnabled; item.view = button
        return item
    }
    private func label(for identifier: NSToolbarItem.Identifier) -> String {
        switch identifier { case Self.zoomOutID: T("缩小文本"); case Self.zoomInID: T("放大文本"); case Self.refreshID: T("刷新"); default: T("保存并同步") }
    }
    private func enabled(_ identifier: NSToolbarItem.Identifier, controller: FileEditorController) -> Bool {
        guard let document = controller.currentDocument, !document.closing else { return false }
        if identifier == Self.refreshID { return !document.refreshing }
        if identifier == Self.saveID { return !document.refreshing }
        return true
    }
    @objc private func refresh() { controller?.refreshCurrent() }
    @objc private func zoomOut() { controller?.zoom(-1) }
    @objc private func zoomIn() { controller?.zoom(1) }
    @objc private func save() { controller?.saveCurrent() }
    private func routeTabEvent(_ event: NSEvent) -> Bool {
        let contextClick = event.type == .rightMouseDown || (event.type == .leftMouseDown && event.modifierFlags.contains(.control))
        guard contextClick || (event.type == .leftMouseDown && event.clickCount == 2),
              let window, event.window === window, window.attachedSheet == nil, NSApp.modalWindow == nil,
              let header, header.bounds.contains(header.convert(event.locationInWindow, from: nil)), let parent = header.superview else { return false }
        var hit = header.hitTest(parent.convert(event.locationInWindow, from: nil))
        while let view = hit, view !== header {
            if let tab = view as? NativeSessionTab.Hosting {
                if contextClick { tab.rightMouseDown(with: event); return true }
                return tab.handleDoubleClick(event)
            }
            hit = view.superview
        }
        return false
    }
    deinit { if let tabMonitor { NSEvent.removeMonitor(tabMonitor) } }
}

struct EditorHeaderContent: View {
    @ObservedObject var controller: FileEditorController
    var body: some View {
        CompactTabStrip(items: controller.openDocuments, id: \.key, selected: controller.currentDocument?.key, move: controller.reorderDocuments) { document in
            EditorTab(controller: controller, document: document)
        } trailing: {
            WindowDragSpace().frame(minWidth: 20, maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct EditorTab: View {
    @ObservedObject var controller: FileEditorController
    let document: FileEditorController.Document
    @Environment(\.colorScheme) private var scheme
    @Environment(\.appearsActive) private var active
    @State private var hovered = false
    var body: some View {
        NativeSessionTab(content: AnyView(content.environment(\.colorScheme, scheme).environment(\.appearsActive, active)), actions: [
            .init(T("保存")) { controller.select(document); controller.saveCurrent() },
            .init(T("关闭文件")) { controller.close(document) },
            .init(T("关闭其他文件")) { controller.closeOthers(document) },
            .init(T("关闭全部文件")) { controller.closeAll() }
        ], onDoubleClick: { controller.close(document) }, identifier: "Termvia.Editor.TabContainer." + document.key)
            .frame(height: 30).onHover { hovered = $0 }
    }
    private var content: some View {
        let selected = controller.currentDocument === document
        return CompactTabContent(title: document.url.lastPathComponent + (document.dirty ? " •" : ""), selected: selected, hovered: hovered,
                                 select: { controller.select(document) }, close: { controller.close(document) }, closeLabel: T("关闭文件"),
                                 identifier: "Termvia.Editor.Tab." + document.key, closeIdentifier: "Termvia.Editor.Close." + document.key,
                                 help: document.title + "\n" + (document.remotePath ?? document.url.path)) {
            EditorFileIcon(url: document.url)
        }
    }
}
