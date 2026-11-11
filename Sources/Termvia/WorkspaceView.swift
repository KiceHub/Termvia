import AppKit
import SwiftUI
import SwiftTerm
import TermviaCore

struct WorkspaceView: View {
    @Environment(\.openSettings) private var openSettings
    @Environment(\.locale) private var uiLocale
    @ObservedObject var model: AppModel
    var body: some View {
        let _ = uiLocale.identifier
        let key = model.workspaceKey
        NativeSidebarSplit(fraction: model.paneBinding(\.monitorFraction, workspace: key), visible: model.paneBinding(\.monitorVisible, workspace: key)) {
            WorkspaceSidebar(model: model)
        } second: {
            PersistentSplit(vertical: false, fraction: model.paneBinding(\.terminalFraction, workspace: key),
                            secondHidden: !model.layout.panelVisible, firstMinimum: 260, secondMinimum: 190,
                            terminalRowHeight: model.active.map { TerminalHostView.rowHeight(of: $0.terminal) }) {
                Group {
                    if let session = model.active, !session.isStartPage {
                        SessionTerminalPane(session: session, focusRevision: model.focusRevision, canFocus: !model.hostManagerPresented && model.tabRenameTarget == nil && model.focusTarget == .terminal, terminalInsets: model.settings.terminalInsets)
                    } else { StartPage(model: model) }
                }.frame(minHeight: 260).background(AppTheme.terminal)
            } second: {
                HStack(spacing: 0) {
                    VStack(spacing: 4) {
                        ForEach(model.active?.isLocalTerminal == true ? [("文件", "folder")] : [("文件", "folder"), ("传输", "arrow.up.arrow.down"), ("日志", "text.alignleft")], id: \.0) { name, icon in
                            Toggle(isOn: Binding(get: { model.layout.panel == name }, set: { _ in model.layout.panel = name })) {
                                Image(systemName: icon).frame(width: 16, height: 24)
                            }.toggleStyle(.button).buttonStyle(.bordered).controlSize(.small)
                                .tint(model.layout.panel == name ? .accentColor : .secondary).help(T(name)).accessibilityLabel(T(name))
                                .accessibilityIdentifier("Termvia.Panel." + name)
                        }
                        Spacer(minLength: 0)
                        if model.activeTransfers.contains(where: { ["排队中", "传输中", "正在取消"].contains($0.state) }) { ProgressView().controlSize(.mini) }
                    }.padding(3).background(.bar)
#if TERMVIA_DIAGNOSTICS
                    .background(AppearanceCheckProbe(role: "panel"))
#endif

                    Divider()
                    Group {
                        if model.active?.isLocalTerminal == true || model.layout.panel == "文件" { files }
                        else if model.layout.panel == "传输" { transferList }
                        else { logList }
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                }.frame(minHeight: 190, idealHeight: 290)
            }
        }
        .background(AppTheme.surface)
        .overlay(alignment: .bottomTrailing) {
            if model.showsTransferButton {
                Button { model.showPendingTransfers() } label: {
                    Label(T("传输"), systemImage: "arrow.up.arrow.down")
                        .padding(.horizontal, 4).padding(.vertical, 3)
                }.buttonStyle(.bordered).controlSize(.large)
                    .help(T("传输")).accessibilityIdentifier("Termvia.Transfers.Reopen")
                    .padding(12)
            }
        }

#if TERMVIA_DIAGNOSTICS
        .background(AppearanceCheckProbe(role: "workspace"))
#endif

        .onAppear { model.openSettings = { openSettings() } }
        .sheet(item: $model.hostTrustToInspect, onDismiss: { model.hostTrustWarning = nil; model.focusTerminal() }) { HostTrustView(model: model, host: $0) }
        .sheet(item: $model.groupEditor) { GroupEditor(model: model, group: $0.group) }
        .sheet(isPresented: $model.hostManagerPresented, onDismiss: { model.focusTerminal() }) { HostManager(model: model, host: model.hostToEdit, defaultGroup: model.newHostGroup).id(model.hostToEdit?.id) }
        .alert(T("重命名标签页"), isPresented: Binding(get: { model.tabRenameTarget != nil }, set: { if !$0 { model.tabRenameTarget = nil } }), presenting: model.tabRenameTarget) { _ in
            TextField(T("名称"), text: $model.tabNameDraft)
            Button(T("保存")) { model.confirmTabRename() }
            Button(T("取消"), role: .cancel) { model.tabRenameTarget = nil; model.focusTerminal() }
        } message: { _ in Text(T("留空恢复默认名称")) }
        .alert(T("操作失败"), isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) { Button(T("确定")) { model.error = nil } } message: { Text(model.error ?? "") }
        .onChange(of: model.hostManagerPresented) { _, showing in if !showing { model.focusTerminal() } }
        .workspaceEnvironment(model: model)
    }
    @ViewBuilder private var files: some View {
        if model.active?.isLocalTerminal == true {
            LocalFiles(model: model, path: $model.localPath, showHidden: $model.layout.showHiddenFiles).id(model.workspaceKey)
        } else {
        PersistentSplit(vertical: true, fraction: model.paneBinding(\.remoteFraction, workspace: model.workspaceKey), firstMinimum: 340, secondMinimum: 280) {
            VStack(alignment: .leading, spacing: 8) {
                if let session = model.active, session.host != nil {
                    RemoteFileBrowser(model: model, session: session, upload: {
                        WorkspaceFileActions.upload(model.localSelection, model: model, session: session, directory: session.remoteDirectory?.path ?? "")
                    }, drop: { providers in
                        let directory = session.remoteDirectory?.path ?? ""
                        return FileDragPayload.receive(providers) { payload in WorkspaceFileActions.drop(payload, ontoRemote: session, directory: directory, model: model) }
                    }) { entries in
                        WorkspaceFileActions.download(entries, model: model, session: session, directory: URL(fileURLWithPath: model.localPath))
                    }.id(session.id)
                }
                else {
                    FileBrowserHeader(title: "远程", symbol: "server.rack", path: .constant(""), showHidden: $model.layout.showHiddenFiles, enabled: false, refresh: {}, parent: {}, home: {})
                    NativeFileTable(rows: [], selection: .constant([]), ready: false, drop: { _ in false }, open: { _ in }, sort: { _ in }, menu: { _ in AnyView(EmptyView()) })
                        .overlay { EmptyPane(symbol: "externaldrive.badge.wifi", title: "未连接", detail: "").allowsHitTesting(false) }
                    FileStatusBar(count: 0, selectedCount: 0, role: "remote") { AnyView(EmptyView()) }.frame(height: 20)
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top).background(AppTheme.surface)
#if TERMVIA_DIAGNOSTICS
            .background(AppearanceCheckProbe(role: "remote"))
#endif

        } second: {
            LocalFiles(model: model, path: $model.localPath, showHidden: $model.layout.showHiddenFiles, canUpload: model.active?.connected == true && model.active?.remoteDirectory != nil) { files in
                guard let session = model.active else { return }
                WorkspaceFileActions.upload(files, model: model, session: session, directory: session.remoteDirectory?.path ?? "")
            }.id(model.workspaceKey)
        }
        }
    }
    private var transferList: some View {
        List(model.activeTransfers) { item in
            HStack {
                Image(systemName: item.upload ? "arrow.up.doc" : "arrow.down.doc").foregroundStyle(.secondary).font(.title3).frame(width: 30)
                VStack(alignment: .leading) {
                    Text("\(item.host.name) · \(item.method.rawValue) · \((item.local as NSString).lastPathComponent)")
                    Text(item.remote).font(.caption).foregroundStyle(.secondary)
                    if !item.detail.isEmpty && (["失败", "已取消"].contains(item.state) || item.directory) { Text(item.detail).font(.caption2).textSelection(.enabled) }
                }
                Spacer(); StatusPill(title: item.state, color: item.state == "失败" ? .red : item.state == "成功" ? AppTheme.accent : .secondary)
                if item.state == "已暂停" { Button(T("继续")) { model.resumeTransfer(item.id) }.disabled(!model.canResumeTransfer(item)) }
                if ["排队中", "传输中", "已暂停"].contains(item.state) { Button(T("取消")) { model.cancel(item.id) } }
            }
        }.listStyle(.plain).scrollContentBackground(.hidden).background(AppTheme.surface)
            .overlay { if model.activeTransfers.isEmpty { EmptyPane(symbol: "arrow.up.arrow.down.circle", title: "无传输", detail: "") } }
    }
    private var logList: some View {
        Group { if let activity = model.active?.activity { TabLogList(activity: activity) } }
            .frame(maxWidth: .infinity, maxHeight: .infinity).background(AppTheme.surface)
    }
}
