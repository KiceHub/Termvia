import AppKit
import SwiftUI
import TermviaCore

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    var model: AppModel?
    var windowCloseDelegate: WorkspaceWindowDelegate?
    var mainWindow: NSWindow?
    var titlebarController: TitlebarController?
    private var terminationPending = false
    private var windowObserver: NSObjectProtocol?
    private var closeConfirmation: CompactAlert?
    private var closeObserver: NSObjectProtocol?
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Activation must not depend on the attachment view's first layout:
        // a background launch can defer that layout until the app is active.
        NSApp.activate()
        windowObserver = NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { note in
            MainActor.assumeIsolated { (note.object as? NSWindow)?.preventsApplicationTerminationWhenModal = false }
        }
        closeObserver = NotificationCenter.default.addObserver(forName: NSWindow.willBeginSheetNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                for window in NSApp.windows { window.preventsApplicationTerminationWhenModal = false }
            }
        }
    }
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        let main = menu.addItem(withTitle: T("主界面"), action: #selector(showWorkspace), keyEquivalent: ""); main.target = self
        if model?.fileEditor.openDocuments.isEmpty == false { let editor = menu.addItem(withTitle: T("文件编辑器"), action: #selector(showEditor), keyEquivalent: ""); editor.target = self }
        return menu
    }
    @objc private func showWorkspace() { mainWindow?.deminiaturize(nil); mainWindow?.makeKeyAndOrderFront(nil); NSApp.activate() }
    @objc private func showEditor() { model?.fileEditor.bringToFront() }
    func requestTermination() {
        for window in NSApp.windows { window.preventsApplicationTerminationWhenModal = false }
        if NSApp.modalWindow != nil { NSApp.stopModal(withCode: .cancel) }
        NSApp.terminate(nil)
    }
    @objc func closeWorkspace(_ sender: Any?) { requestWindowClose() }
    func requestWindowClose() {
        guard let model, let window = mainWindow, !terminationPending, closeConfirmation == nil else { return }
        guard model.busy || model.sessions.count > 1 else { requestTermination(); return }
        let alert = CompactAlert(); closeConfirmation = alert
        alert.messageText = T("退出 Termvia？")
        alert.informativeText = T("未保存更改将丢失，传输将取消。")
        alert.addButton(withTitle: T("退出")); alert.addButton(withTitle: T("取消"))
        alert.buttons[0].keyEquivalent = ""; alert.buttons[1].keyEquivalent = "\u{1b}"
        alert.beginSheetModal(for: window) { [weak self] result in
            self?.closeConfirmation = nil
            if result == .alertFirstButtonReturn { self?.requestTermination() }
        }
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model else { return .terminateNow }
        guard !terminationPending else { return .terminateLater }
        terminationPending = true
        // Hide immediately while process cleanup completes in the background.
        for window in NSApp.windows {
            if let sheet = window.attachedSheet { window.endSheet(sheet, returnCode: .cancel) }
            if window.isVisible { window.orderOut(nil) }
        }
        model.quitShortcut.uninstall(); model.shutdown()
        Task {
            await model.finishShutdown()
            if ProcessInfo.processInfo.arguments.contains("--launch-check"), ProcessInfo.processInfo.environment["TERMVIA_QUIT_ONLY"] == "1" {
                guard model.sessions.allSatisfy({ $0.isStartPage || !$0.terminal.process.running }) else { fputs("Quit check: live process after shutdown\n", stderr); exit(1) }
                if ProcessInfo.processInfo.environment["TERMVIA_QUIT_DIALOG"]?.hasPrefix("file-close") == true {
                    guard model.fileEditor.openDocuments.isEmpty, model.fileEditor.openPrompts.alert == nil,
                          (0..<2).allSatisfy({ (try? String(contentsOf: model.root.appendingPathComponent("quit-editor-\($0).txt"), encoding: .utf8)) == "quit original\n" }) else { fputs("Quit check: editor saved or remained open\n", stderr); exit(1) }
                    print("PASS quit overrides editor close/save sheets and discards all unsaved buffers")
                }
                try? FileManager.default.removeItem(at: model.root)
                print("Termvia termination check passed")
            }
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
    func applicationDidResignActive(_ notification: Notification) { model?.quitShortcut.cancel() }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main struct TermviaApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var model: AppModel
    init() {
        do {
            let root: URL
            if ProcessInfo.processInfo.arguments.contains("--launch-check") || ProcessInfo.processInfo.arguments.contains("--export-ui-previews") {
                root = FileManager.default.temporaryDirectory.appendingPathComponent("termvia-launch-\(UUID())")
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            } else { root = try AppPaths.prepare() }
#if TERMVIA_DIAGNOSTICS
            if ProcessInfo.processInfo.arguments.contains("--launch-check") { try AppearanceStartupLaunchCheck.prepare(root: root) }
#endif
            let model = AppModel(root: root)
            model.startApplicationAppearance()
            model.newStartPage()
            _model = StateObject(wrappedValue: model)
        }
        catch { fatalError(T("无法创建 Termvia 数据目录：%@", error.localizedDescription)) }
        NSApplication.shared.setActivationPolicy(.regular)
    }
#if !TERMVIA_DIAGNOSTICS
    @MainActor private func checkStartup() async {
        do {
            try await Task.sleep(for: .milliseconds(500))
            guard let window = delegate.mainWindow, window.isVisible, window.titlebarAppearsTransparent,
                  window.titleVisibility == .hidden, window.styleMask.contains(.fullSizeContentView),
                  model.active?.isStartPage == true else { throw MetricsError.invalid }
            guard let executableDirectory = Bundle.main.executableURL?.deletingLastPathComponent(), ["termvia-askpass", "termvia-proxy", "termvia-wireguard", "termvia-ppk"].allSatisfy({ FileManager.default.isExecutableFile(atPath: executableDirectory.appendingPathComponent($0).path) }) else { throw MetricsError.invalid }
            model.connect(nil)
            for _ in 0..<140 where model.active?.monitor.latest == nil { try await Task.sleep(for: .milliseconds(50)) }
            guard let session = model.active, session.terminal.process.running, session.monitor.latest != nil else { throw MetricsError.invalid }
            model.shutdown(); await model.finishShutdown()
            try FileManager.default.removeItem(at: model.root)
            print("Termvia startup check passed"); exit(0)
        } catch {
            model.shutdown(); await model.finishShutdown()
            try? FileManager.default.removeItem(at: model.root)
            fputs("Termvia startup check failed: \(error)\n", stderr); exit(1)
        }
    }
#endif
    var body: some Scene {
        Window("Termvia", id: "workspace") {
            WorkspaceSurface(model: model).ignoresSafeArea()

#if TERMVIA_DIAGNOSTICS
            .background(WindowStartupDrawProbe())
#endif

                .frame(minWidth: WorkspaceWindowGeometry.minimumContentSize.width, minHeight: WorkspaceWindowGeometry.minimumContentSize.height)
                // SwiftUI owns this scene's titlebar and otherwise restores its
                // automatic backdrop after the AppKit toolbar is configured.
                .toolbar(removing: .title)
                .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
                .background(WorkspaceWindowAttachment { window in
                    guard delegate.mainWindow !== window else { return }
#if TERMVIA_DIAGNOSTICS
                    WindowStartupLaunchCheck.record("configure", window)
#endif
#if TERMVIA_DIAGNOSTICS
                    if ProcessInfo.processInfo.arguments.contains("--launch-check") { AppearanceStartupLaunchCheck.recordBeforeWindowSetup(window) }
#endif
                    delegate.model = model
                    model.quitShortcut.install {
                        // terminateLater may spin an AppKit run loop. Enter it
                        // from the native run loop after the current Swift task
                        // returns, so MainActor cleanup can still make progress.
                        RunLoop.main.perform(inModes: [.common, .modalPanel, .eventTracking]) { MainActor.assumeIsolated { delegate.requestTermination() } }
                    }
                    delegate.mainWindow = window
                    delegate.mainWindow?.isReleasedWhenClosed = false
                    if let window = delegate.mainWindow, delegate.windowCloseDelegate == nil {
                        let bridge = WorkspaceWindowDelegate(original: window.delegate) { [weak appDelegate = delegate] in appDelegate?.requestWindowClose() }
                        delegate.windowCloseDelegate = bridge; window.delegate = bridge
                    }
                    AppMenuLocalization.start()
                    if let window = delegate.mainWindow, delegate.titlebarController == nil {
                        delegate.titlebarController = TitlebarController(model: model, window: window)
#if TERMVIA_DIAGNOSTICS
                        WindowStartupLaunchCheck.record("toolbar", window)
#endif
                    }
                    let arguments = ProcessInfo.processInfo.arguments
                    let isolated = arguments.contains("--launch-check") || arguments.contains("--export-ui-previews")
                    let name: NSWindow.FrameAutosaveName?
#if TERMVIA_DIAGNOSTICS
                    if WindowStartupLaunchCheck.enabled { name = WindowStartupLaunchCheck.prepareFrame(window) }
                    else { name = isolated ? nil : WorkspaceWindowGeometry.autosaveName }
#else
                    name = isolated ? nil : WorkspaceWindowGeometry.autosaveName
#endif
                    WorkspaceWindowGeometry.configure(window, autosaveName: name)
#if TERMVIA_DIAGNOSTICS
                    WindowStartupLaunchCheck.record("configured", window)
#endif
                    DispatchQueue.main.async {
                        NSApplication.shared.activate(ignoringOtherApps: true)
                        window.makeKeyAndOrderFront(nil)
#if TERMVIA_DIAGNOSTICS
                        WindowStartupLaunchCheck.record("presented", window)
#endif
#if TERMVIA_DIAGNOSTICS
                        if let index = arguments.firstIndex(of: "--export-ui-previews"), index + 1 < arguments.count {
                            UIPreviewExporter.run(model: model, directory: URL(fileURLWithPath: arguments[index + 1]))
                        } else if arguments.contains("--launch-check") {
                            Task { await LaunchCheck.run(model: model) }
                        }
#else
                        if arguments.contains("--launch-check") {
                            Task { await checkStartup() }
                        }
#endif
                    }
                }.frame(width: 0, height: 0))
        }
        .defaultSize(width: 1280, height: 820)
        .restorationBehavior(.disabled)
        .defaultLaunchBehavior(.presented)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button(T("关于 Termvia")) { model.settingsPage = .about; model.openSettings?() }
            }
            CommandGroup(replacing: .appSettings) {
                SettingsLink { Text(T("设置…")) }.keyboardShortcut(",")
            }
            CommandGroup(replacing: .newItem) {
                Button(T("新建标签页")) { model.newStartPage() }.appShortcut(.newTab, settings: model.settings)
                Button(T("新建本地终端")) { model.connect(nil) }.appShortcut(.localTerminal, settings: model.settings)
                Button(T("主机管理…")) { model.showHosts() }.appShortcut(.showHosts, settings: model.settings)
                Button(T("新增主机")) { model.showHosts(); model.presentHostEditor() }.appShortcut(.newHost, settings: model.settings)
            }
            CommandMenu(T("会话")) {
                Button(T("重命名标签页…")) { model.performShortcut(.renameTab) }.appShortcut(.renameTab, settings: model.settings).disabled(model.active == nil)
                Divider()
                Button(T("关闭当前会话")) { model.performShortcut(.closeTab) }
                    .disabled(model.active == nil)
                Button(T("重新连接")) { model.performShortcut(.reconnect) }
                    .appShortcut(.reconnect, settings: model.settings).disabled(model.active == nil || model.active?.isStartPage == true)
                Divider()
                Button(T("上一个会话")) { model.selectNext(-1) }.appShortcut(.previousTab, settings: model.settings)
                Button(T("下一个会话")) { model.selectNext(1) }.appShortcut(.nextTab, settings: model.settings)
                Button(T("聚焦终端")) { model.focusTerminal() }.appShortcut(.focusTerminal, settings: model.settings)
            }
            CommandMenu(T("工作区")) {
                Picker(T("语言"), selection: $model.layout.language) {
                    ForEach(AppLanguage.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Divider()
                Toggle(T("显示侧栏"), isOn: $model.layout.monitorVisible).appShortcut(.sidebar, settings: model.settings)
                Toggle(T("显示底部面板"), isOn: $model.layout.panelVisible).appShortcut(.panel, settings: model.settings)
                Divider()
                Button(T("增大终端字体")) { model.changeFont(1) }.appShortcut(.largerFont, settings: model.settings)
                Button(T("减小终端字体")) { model.changeFont(-1) }.appShortcut(.smallerFont, settings: model.settings)
                Button(T("默认终端字体")) { model.layout.fontSize = 13 }.appShortcut(.defaultFont, settings: model.settings)
            }
        }
        Settings {
            SettingsView(model: model)
                .workspaceEnvironment(model: model)
        }
    }
}
