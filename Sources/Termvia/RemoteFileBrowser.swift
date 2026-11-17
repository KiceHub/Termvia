import AppKit
import SwiftUI
import TermviaCore

private struct RemoteFilePrompt: Identifiable {
    enum Kind { case folder, file, rename, copy, move }
    let id = UUID()
    let kind: Kind
    let entries: [RemoteEntry]
    let directory: String
    var title: String { switch kind { case .folder: return T("新建文件夹"); case .file: return T("新建文件"); case .rename: return T("重命名"); case .copy: return T("复制到远程目录"); case .move: return T("移动到远程目录") } }
}

struct RemoteFileBrowser: View {
    @Environment(\.locale) private var locale
    @ObservedObject var model: AppModel
    @ObservedObject var session: Session
    var upload: (() -> Void)? = nil
    var drop: ([NSItemProvider]) -> Bool = { _ in false }
    let download: ([RemoteEntry]) -> Void
    @State private var sortOrder = [KeyPathComparator(\RemoteEntry.name)]
    @State private var prompt: RemoteFilePrompt?
    @State private var deleting: [RemoteEntry] = []
    @State private var newName = ""
    @State private var sortedEntries: [RemoteEntry] = []
    private var ready: Bool { model.layout.panelVisible && model.layout.panel == "文件" && session.connected && !session.listingBusy && session.remoteDirectory != nil }
    @State private var displayedEntries: [RemoteEntry] = []
    @State private var tableRows: [NativeFileRow] = []
    private var entries: [RemoteEntry] { session.connected ? displayedEntries : [] }
    private func updateDisplayed() {
        displayedEntries = sortedEntries.filter { model.layout.showHiddenFiles || !$0.name.hasPrefix(".") }
        tableRows = displayedEntries.map { NativeFileRow(id: $0.id, entry: $0, sessionID: session.id) }
    }
    private func updateEntries() {
        let sorted = (session.remoteDirectory?.entries ?? []).sorted(using: sortOrder)
        sortedEntries = sorted.filter { $0.displayKind == .directory } + sorted.filter { $0.displayKind != .directory }
        updateDisplayed()
    }
    private func selected(_ ids: Set<String>) -> [RemoteEntry] { entries.filter { ids.contains($0.id) } }
    private func canMove(_ items: [RemoteEntry]) -> Bool {
        !items.isEmpty && items.allSatisfy { $0.kind == .file || ($0.kind == .directory && model.fileProtocol(for: session) == .sftp) }
    }
    var body: some View {
        let _ = locale.identifier
        let rows = entries
        VStack(alignment: .leading, spacing: 8) {
            fileHeader
            fileTable
            if let error = session.listingError { Text(error).font(.caption).foregroundStyle(.red).lineLimit(3).textSelection(.enabled) }
            FileStatusBar(count: rows.count, selectedCount: session.remoteSelection.count, role: "remote") { AnyView(directoryActions) }.frame(height: 20)
        }.controlSize(.small)
            .onDrop(of: FileDragPayload.contentTypes, isTargeted: nil) { providers in ready && drop(providers) }

#if TERMVIA_DIAGNOSTICS
            .background {
                if ProcessInfo.processInfo.arguments.contains("--launch-check") {
                    let items = selected(session.remoteSelection)
                    FileTransferCheckProbe(canDownload: ready && !items.isEmpty && items.allSatisfy { $0.kind == .file || $0.kind == .directory }).frame(width: 0, height: 0).allowsHitTesting(false).accessibilityHidden(true)
                }
            }
#endif

            .onAppear { model.resumeDirectoryIfNeeded(session) }
            .onChange(of: session.remoteDirectory, initial: true) { _, _ in updateEntries() }
            .onChange(of: sortOrder) { _, _ in updateEntries() }
            .onChange(of: model.layout.showHiddenFiles) { _, _ in updateDisplayed(); session.remoteSelection.formIntersection(Set(entries.map(\.id))) }
            .compactAlert(prompt?.title ?? "", isPresented: Binding(get: { prompt != nil }, set: { if !$0 { prompt = nil } }),
                          message: prompt?.directory ?? "", input: .init(placeholder: T(prompt?.kind == .copy || prompt?.kind == .move ? "远程目录绝对路径" : "名称"), text: $newName), actions: [
                .init(T("确定")) { if let item = prompt { apply(item); prompt = nil } },
                .init(T("取消"), role: .cancel) { prompt = nil }
            ])
            .compactAlert(T("删除所选项目？"), isPresented: Binding(get: { !deleting.isEmpty }, set: { if !$0 { deleting = [] } }),
                          message: deleting.prefix(6).map(\.path).joined(separator: "\n") + (deleting.count > 6 ? "\n" + T("另有 %d 项", deleting.count - 6) : "") + "\n" + T("不可恢复。"), actions: [
                .init(T("删除")) { model.mutateRemote(session, operations: deleting.map { $0.kind == .directory ? .removeTree($0.path) : .removeFile($0.path) }); deleting = [] },
                .init(T("取消"), role: .cancel) { deleting = [] }
            ])
    }
    private var fileHeader: some View {
        FileBrowserHeader(title: "远程", symbol: "server.rack", path: $session.remotePath, showHidden: $model.layout.showHiddenFiles,
                          busy: session.listingBusy, enabled: session.connected, parentEnabled: ready && session.remoteDirectory?.path != "/",
                          refresh: { model.refreshDirectory(session) }, parent: { navigate((session.remoteDirectory?.path ?? session.remotePath).parentRemotePath) }, home: { navigate("~/") })
    }
    private var fileTable: some View {
        NativeFileTable(rows: session.connected ? tableRows : [], selection: $session.remoteSelection, ready: ready, drop: { providers in ready && drop(providers) }, open: { open(selected($0)) }, sort: { descriptors in
            sortOrder = descriptors.map { key, ascending -> KeyPathComparator<RemoteEntry> in
                let order: SortOrder = ascending ? .forward : .reverse
                switch key { case "size": return KeyPathComparator(\.sortSize, order: order); case "date": return KeyPathComparator(\.sortDate, order: order); default: return KeyPathComparator(\.name, order: order) }
            }
        }, menu: { AnyView(rowMenu($0)) }, allowExternalDrop: true)
        .overlay {
            if !session.connected {
                EmptyPane(symbol: "externaldrive.badge.wifi", title: "未连接", detail: "").allowsHitTesting(false)
            } else if session.remoteDirectory == nil, !session.listingBusy {
                Button(T("读取目录")) { model.refreshDirectory(session) }.buttonStyle(.bordered).help(T("读取目录"))
            } else if entries.isEmpty, !session.listingBusy { EmptyPane(symbol: "folder", title: "空目录", detail: "").allowsHitTesting(false) }
        }
    }
    @ViewBuilder private func rowMenu(_ ids: Set<String>) -> some View {
        let items = selected(ids)
        if items.isEmpty { directoryActions }
        else {
            Button(T("打开")) { open(items) }.disabled(items.count != 1 || !ready)
            Button(T("拷贝文件路径")) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(items.map(\.path).joined(separator: "\n"), forType: .string) }
            Button(T("下载到本地目录")) { download(items) }.disabled(!ready || items.contains { $0.kind != .file && $0.kind != .directory }).help(model.localPath)
            Button(T("复制到…")) { begin(.copy, items) }.disabled(!ready || items.contains { $0.kind != .file })
            Button(T("移动到…")) { begin(.move, items) }.disabled(!ready || !canMove(items))
            Button(T("重命名…")) { begin(.rename, items) }.disabled(!ready || items.count != 1 || !canMove(items))
            Divider()
            Button(T("删除…"), role: .destructive) { deleting = items }.disabled(!ready)
        }
    }
    private var directoryActions: some View {
        Group {
            Button(T("新建文件夹…")) { begin(.folder) }.disabled(!ready)
            Button(T("新建文件…")) { begin(.file) }.disabled(!ready)
            if let upload { Button(T("上传所选本地文件"), action: upload).disabled(!ready || !model.localSelectionSupportsTransfer) }
            Divider()
            Button(T("刷新目录")) { model.refreshDirectory(session) }.disabled(!session.connected || session.listingBusy)
        }
    }
    private func begin(_ kind: RemoteFilePrompt.Kind, _ items: [RemoteEntry] = []) {
        guard let directory = session.remoteDirectory?.path else { return }
        newName = kind == .rename ? items.first?.name ?? "" : kind == .copy || kind == .move ? directory : ""
        prompt = RemoteFilePrompt(kind: kind, entries: items, directory: directory)
    }
    private func apply(_ item: RemoteFilePrompt) {
        do {
            let operations: [SFTPOperation]
            switch item.kind {
            case .folder: operations = [try .makeDirectory(FilePaths.child(newName, in: item.directory))]
            case .file: operations = [try .makeFile(FilePaths.child(newName, in: item.directory))]
            case .rename:
                guard let entry = item.entries.first else { return }
                operations = [try .rename(entry.path, FilePaths.child(newName, in: item.directory))]
            case .copy, .move:
                operations = try item.entries.compactMap { entry -> SFTPOperation? in
                    let target = try FilePaths.child(entry.name, in: newName)
                    guard !FilePaths.isSelfDestination(source: entry.path, target: target) else { return nil }
                    return item.kind == .copy ? .copyFile(entry.path, target) : .rename(entry.path, target)
                }
            }
            model.mutateRemote(session, operations: operations)
        } catch { model.recordFileFailure(error.localizedDescription, title: item.title, host: session.host, paths: item.directory, activity: session.activity) }
    }
    private func open(_ items: [RemoteEntry]) {
        guard ready, items.count == 1 else { return }
        model.openRemoteEntry(items[0], session: session)
    }
    private func navigate(_ path: String) { guard session.connected, !session.listingBusy else { return }; session.remotePath = path; model.refreshDirectory(session) }
}
extension AppModel {
    func openRemoteEntry(_ entry: RemoteEntry, session: Session) {
        guard session.connected, !session.listingBusy, let host = session.host else { return }
        switch entry.kind {
        case .directory: session.remotePath = entry.path; refreshDirectory(session)
        case .file: fileEditor.openRemote(entry, session: session, model: self)
        case .symbolicLink:
            let transfer = Transfer(host: host, local: "", remote: entry.path, upload: false, method: fileProtocol(for: session), downloadTarget: nil, authentication: session.authentication, activity: session.activity)
            planFileTransfer(activity: session.activity) { _ in
                let target = try await TransferConnection(commands: self.commands, transfer: transfer).resolveEntry(entry.path)
                try Task.checkCancellation()
                guard session.connected, !session.activity.isClosed else { return }
                self.openRemoteEntry(target, session: session)
            }
        case .other: error = T("无法打开文件")
        }
    }
}
private extension String { var parentRemotePath: String { (self as NSString).deletingLastPathComponent.isEmpty ? "/" : (self as NSString).deletingLastPathComponent } }
