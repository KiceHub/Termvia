import AppKit
import SwiftUI
import SwiftTerm
import TermviaCore

struct WorkspaceView: View {
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
                            terminalRowHeight: model.activeSplitTree == nil ? model.active.map { TerminalHostView.rowHeight(of: $0.terminal) } : nil) {
                Group {
                    if let tree = model.activeSplitTree {
                        SplitTerminalWorkspace(model: model, tree: tree)
                    } else if let session = model.focusedTerminal, !session.isStartPage {
                        SessionTerminalPane(session: session, focusRevision: model.focusRevision, canFocus: !model.hostManagerPresented && model.tabRenameTarget == nil && model.focusTarget == .terminal, terminalInsets: model.settings.terminalInsets)
                    } else { StartPage(model: model) }
                }.frame(minHeight: 260).background(AppTheme.terminal)
            } second: {
                HStack(spacing: 0) {
                    VStack(spacing: 4) {
                        ForEach([("文件", "folder"), ("传输", "arrow.up.arrow.down"), ("日志", "text.alignleft")], id: \.0) { name, icon in
                            Toggle(isOn: Binding(get: { model.layout.panel == name }, set: { _ in model.layout.panel = name })) {
                                Image(systemName: icon).font(.system(size: 11)).frame(width: 14, height: 22)
                            }.toggleStyle(.button).buttonStyle(.borderless).controlSize(.mini)
                                .tint(model.layout.panel == name ? .accentColor : .secondary).help(T(name)).accessibilityLabel(T(name))
                                .accessibilityIdentifier("Termvia.Panel." + name)
                        }
                        Spacer(minLength: 0)
                        if model.activeTransfers.contains(where: { ["排队中", "传输中", "正在取消"].contains($0.state) }) { ProgressView().controlSize(.mini) }
                    }.frame(width: 24).background(.bar)
#if TERMVIA_DIAGNOSTICS
                    .background(AppearanceCheckProbe(role: "panel"))
#endif

                    Divider()
                    Group {
                        if model.layout.panel == "文件" { files }
                        else if model.layout.panel == "传输" { transferList }
                        else { logList }
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                }.frame(minHeight: 190, idealHeight: 290)
            }
        }
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

        .sheet(item: $model.splitRequest) { SplitHostPicker(model: model, request: $0) }
        .sheet(item: $model.hostTrustToInspect, onDismiss: { model.hostTrustWarning = nil; model.focusTerminal() }) { HostTrustView(model: model, host: $0) }
        .sheet(item: $model.groupEditor) { GroupEditor(model: model, group: $0.group) }
        .sheet(isPresented: $model.hostManagerPresented, onDismiss: { model.hostCopyDraft = nil; model.focusTerminal() }) { HostManager(model: model, host: model.hostToEdit, defaultGroup: model.newHostGroup, draft: model.hostCopyDraft).id(model.hostToEdit?.id ?? model.hostCopyDraft?.host.id) }
        .compactAlert(T("重命名标签页"), isPresented: Binding(get: { model.tabRenameTarget != nil }, set: { if !$0 { model.tabRenameTarget = nil } }),
                      message: T("留空恢复默认名称"), input: .init(placeholder: T("名称"), text: $model.tabNameDraft), actions: [
            .init(T("保存")) { model.confirmTabRename() },
            .init(T("取消"), role: .cancel) { model.tabRenameTarget = nil; model.focusTerminal() }
        ])
        .compactAlert(T("操作失败"), isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } }), message: model.error ?? "", actions: [
            .init(T("确定")) { model.error = nil }
        ])
        .onChange(of: model.hostManagerPresented) { _, showing in if !showing { model.focusTerminal() } }
        .workspaceEnvironment(model: model)
    }
    @ViewBuilder private var files: some View {
        if model.active?.isLocalTerminal == true {
            LocalFiles(model: model, path: $model.localPath, showHidden: $model.layout.showHiddenFiles).id(model.workspaceKey)
        } else {
        PersistentSplit(vertical: true, fraction: model.paneBinding(\.remoteFraction, workspace: model.workspaceKey), firstMinimum: 260, secondMinimum: 260) {
            if model.settings.remoteFilesOnLeft { remoteFiles } else { localFiles }
        } second: {
            if model.settings.remoteFilesOnLeft { localFiles } else { remoteFiles }
        }
        }
    }
    @ViewBuilder private var remoteFiles: some View {
        if let session = model.active, session.host != nil {
            RemoteFileBrowser(model: model, session: session, upload: {
                WorkspaceFileActions.upload(model.localSelection, model: model, session: session, directory: session.remoteDirectory?.path ?? "")
            }, drop: { providers in
                let directory = session.remoteDirectory?.path ?? ""
                return FileDragPayload.receive(providers) { payload in WorkspaceFileActions.drop(payload, ontoRemote: session, directory: directory, model: model) }
            }) { entries in
                WorkspaceFileActions.download(entries, model: model, session: session, directory: URL(fileURLWithPath: model.localPath))
            }.id(session.id)
        } else { EmptyPane(symbol: "externaldrive.badge.wifi", title: "未连接", detail: "") }
    }
    private var localFiles: some View {
        LocalFiles(model: model, path: $model.localPath, showHidden: $model.layout.showHiddenFiles, canUpload: model.active?.connected == true && model.active?.remoteDirectory != nil) { files in
            guard let session = model.active else { return }
            WorkspaceFileActions.upload(files, model: model, session: session, directory: session.remoteDirectory?.path ?? "")
        }.id(model.workspaceKey)
    }
    private var transferList: some View { TransferRows(model: model) }
    private var logList: some View {
        Group { if let activity = model.focusedTerminal?.activity { TabLogList(activity: activity) } }
            .frame(maxWidth: .infinity, maxHeight: .infinity).background(AppTheme.surface)
    }
}
