import AppKit
import TermviaCore

/// AppKit's standard menus are outside the SwiftUI locale environment.
@MainActor enum AppMenuLocalization {
    private static var observer: NSObjectProtocol?
    private static let closeCommand = WorkspaceCloseCommand()
    static func start(model: AppModel? = nil, window: NSWindow? = nil) {
        if let model, let window { closeCommand.model = model; closeCommand.workspaceWindow = window }
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { apply() }
        }
        apply()
    }
    static func apply() {
        let actions = [
            "orderFrontStandardAboutPanel:": "关于 Termvia", "hide:": "隐藏 Termvia",
            "hideOtherApplications:": "隐藏其他", "unhideAllApplications:": "全部显示", "terminate:": "退出 Termvia",
            "performClose:": "关闭窗口", "performMiniaturize:": "最小化", "performZoom:": "缩放",
            "undo:": "撤销", "redo:": "重做", "cut:": "剪切", "copy:": "复制", "paste:": "粘贴", "selectAll:": "全选",
            "arrangeInFront:": "全部置前"
        ]
        func visit(_ menu: NSMenu) {
            for item in menu.items {
                if let action = item.action, let key = actions[NSStringFromSelector(action)] { item.title = T(key) }
                if item.action == #selector(NSWindow.performClose(_:)) || item.target === closeCommand {
                    item.action = #selector(WorkspaceCloseCommand.closeContext(_:)); item.target = closeCommand
                    item.title = T(NSApp.keyWindow === closeCommand.workspaceWindow ? "关闭当前会话" : "关闭窗口")
                }
                if item.action == #selector(NSWindow.toggleFullScreen(_:)) {
                    item.title = T(NSApp.mainWindow?.styleMask.contains(.fullScreen) == true ? "退出全屏" : "进入全屏")
                }
                if let submenu = item.submenu {
                    if submenu === NSApp.servicesMenu { item.title = T("服务") }
                    visit(submenu)
                }
            }
        }
        guard let main = NSApp.mainMenu else { return }
        visit(main)
        for (menu, key) in [(NSApp.windowsMenu, "窗口"), (NSApp.helpMenu, "帮助"), (NSApp.servicesMenu, "服务")] {
            if let menu, let item = main.items.first(where: { $0.submenu === menu }) { item.title = T(key) }
        }
        // Identify standard Edit and File menus by actions, preserving custom menus.
        if let item = main.items.first(where: { $0.submenu?.items.contains { $0.action == NSSelectorFromString("copy:") } == true }) { item.title = T("编辑") }
        if let item = main.items.first(where: { $0.submenu?.items.contains { $0.target === closeCommand } == true }) { item.title = T("menu.file") }
    }
}

@MainActor private final class WorkspaceCloseCommand: NSObject, NSMenuItemValidation {
    weak var model: AppModel?
    weak var workspaceWindow: NSWindow?
    @objc func closeContext(_ sender: Any?) {
        if let window = workspaceWindow, NSApp.keyWindow === window, window.attachedSheet == nil {
            model?.performShortcut(.closeTab)
        } else { NSApp.keyWindow?.performClose(sender) }
    }
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool { NSApp.keyWindow != nil }
}
