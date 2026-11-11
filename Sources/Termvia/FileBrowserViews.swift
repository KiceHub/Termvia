import TermviaCore
import AppKit
import SwiftUI

struct FilePathBar: View {
    @Environment(\.locale) private var uiLocale
    @Binding var path: String
    let refresh: () -> Void
    var busy = false
    @State private var draft = ""
    var body: some View {
        let _ = uiLocale.identifier
        NativePathField(text: $draft, busy: busy, submit: { path = draft; refresh() }, refresh: { draft = path; refresh() })
            .frame(height: 24)
            .onAppear { draft = path }.onChange(of: path) { _, value in draft = value }
    }
}

struct FileBrowserHeader: View {
    let title: String
    let symbol: String
    @Binding var path: String
    @Binding var showHidden: Bool
    var busy = false
    var enabled = true
    var parentEnabled = true
    let refresh: () -> Void
    let parent: () -> Void
    let home: () -> Void
    var body: some View {
        HStack(spacing: 8) {
            FilePaneLabel(title: title, symbol: symbol, showHidden: $showHidden)
            FilePathBar(path: $path, refresh: refresh, busy: busy).disabled(!enabled)
            Button(action: parent) { Image(systemName: "arrow.up") }.disabled(!enabled || !parentEnabled)
                .help(T("上一级目录")).accessibilityLabel(T("上一级目录"))
            Button(action: home) { Image(systemName: "house") }.disabled(!enabled || busy)
                .help(T(title == "远程" ? "远程家目录" : "本地家目录")).accessibilityLabel(T(title == "远程" ? "远程家目录" : "本地家目录"))
        }.controlSize(.small).font(.system(size: 12)).buttonStyle(.borderless).padding(.horizontal, 8).padding(.top, 6).frame(height: 30)

#if TERMVIA_DIAGNOSTICS
        .background { if ProcessInfo.processInfo.arguments.contains("--launch-check") { FileHeaderGeometryProbe(role: title == "远程" ? "remote" : "local") } }
#endif

    }
}

private struct LocalEntry: Identifiable, Sendable {
    let url: URL
    let directory: Bool
    let link: Bool
    let size: Int64
    let modified: Date
    let name: String
    let id: String
    init(url: URL, directory: Bool, link: Bool, size: Int64, modified: Date) {
        self.url = url; self.directory = directory; self.link = link; self.size = size; self.modified = modified
        name = url.lastPathComponent; id = url.path
    }
}

struct LocalFiles: View {
    @ObservedObject var model: AppModel
    @Environment(\.locale) private var uiLocale
    @Binding var path: String
    @Binding var showHidden: Bool
    var canUpload = false
    var upload: ([URL]) -> Void = { _ in }
    @State private var entries: [LocalEntry] = []
    @State private var error: String?
    @State private var revision = 0
    @State private var busy = false
    @State private var mutating = false
    @State private var loadedPath: String?
    @State private var mutationError: String?
    @State private var selected = Set<String>()
    @State private var sortOrder = [KeyPathComparator(\LocalEntry.name)]
    @State private var creating = false
    @State private var creatingFile = false
    @State private var renaming: LocalEntry?
    @State private var deleting: [LocalEntry] = []
    @State private var newName = ""
    @State private var sortedEntries: [LocalEntry] = []
    private var visible: [LocalEntry] { sortedEntries.filter { showHidden || !$0.name.hasPrefix(".") } }
    private func updateVisible() {
        let sorted = entries.sorted(using: sortOrder)
        sortedEntries = sorted.filter(\.directory) + sorted.filter { !$0.directory }
    }
    private var ready: Bool { !busy && !mutating && loadedPath == path }
    private func items(_ ids: Set<String>) -> [LocalEntry] { visible.filter { ids.contains($0.id) } }
    var body: some View {
        let _ = uiLocale.identifier
        let rows = visible
        VStack(spacing: 8) {
            fileHeader
            fileTable
            if let message = mutationError ?? (entries.isEmpty ? nil : error) { Text(message).font(.caption).foregroundStyle(.red).lineLimit(3) }
            FileStatusBar(count: rows.count, selectedCount: selected.count, role: "local") { AnyView(directoryActions) }.frame(height: 20)
        }.disabled(mutating).controlSize(.small)
#if TERMVIA_DIAGNOSTICS
        .background(AppearanceCheckProbe(role: "local"))
#endif

            .onDrop(of: FileDragPayload.contentTypes, isTargeted: nil, perform: receive)
            .task(id: "\(path)\u{0}\(revision)\u{0}\(model.localFilesRevision)") { await load() }
            .onChange(of: path) { _, _ in mutationError = nil }
            .onChange(of: selected) { _, _ in
                let chosen = items(selected)
                model.localSelection = chosen.map(\.url)
                model.localSelectionSupportsTransfer = !chosen.isEmpty && chosen.allSatisfy { !$0.link }
            }
            .onChange(of: sortOrder) { _, _ in updateVisible() }
            .onChange(of: showHidden) { _, _ in selected.formIntersection(Set(visible.map(\.id))) }
            .alert(T(creatingFile ? "新建文件" : "新建文件夹"), isPresented: $creating) {
                TextField(T("名称"), text: $newName)
                Button(T("创建")) {
                    do {
                        let target = try FilePaths.child(newName, in: path)
                        let file = creatingFile
                        mutate {
                            if file { try Data().write(to: URL(fileURLWithPath: target), options: .withoutOverwriting) }
                            else { try FileManager.default.createDirectory(atPath: target, withIntermediateDirectories: false) }
                        }
                    } catch { self.error = error.localizedDescription }
                }
                Button(T("取消"), role: .cancel) {}
            } message: { Text(path) }
            .alert(T("重命名"), isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } }), presenting: renaming) { entry in
                TextField(T("名称"), text: $newName)
                Button(T("保存")) {
                    do {
                        let destination = try FilePaths.child(newName, in: entry.url.deletingLastPathComponent().path)
                        mutate { try FileManager.default.moveItem(at: entry.url, to: URL(fileURLWithPath: destination)) }
                    } catch { self.error = error.localizedDescription }
                    renaming = nil
                }
                Button(T("取消"), role: .cancel) { renaming = nil }
            } message: { Text($0.url.path) }
            .alert(T("移到废纸篓？"), isPresented: Binding(get: { !deleting.isEmpty }, set: { if !$0 { deleting = [] } })) {
                Button(T("移到废纸篓"), role: .destructive) {
                    let targets = deleting.map(\.url); deleting = []
                    mutate { for target in targets { try FileManager.default.trashItem(at: target, resultingItemURL: nil) } }
                }
                Button(T("取消"), role: .cancel) { deleting = [] }
            } message: { Text(deleting.prefix(6).map { $0.url.path }.joined(separator: "\n")) }
    }
    private func receive(_ providers: [NSItemProvider]) -> Bool {
        guard ready else { return false }
        let directory = URL(fileURLWithPath: path)
        return FileDragPayload.receive(providers) { payload in WorkspaceFileActions.drop(payload, ontoLocal: directory, model: model) }
    }
    private var fileHeader: some View {
        FileBrowserHeader(title: "本地", symbol: "desktopcomputer", path: $path, showHidden: $showHidden, busy: busy, parentEnabled: path != "/",
                          refresh: { revision += 1 }, parent: { path = (path as NSString).deletingLastPathComponent }, home: { path = FileManager.default.homeDirectoryForCurrentUser.path })
    }
    private var fileTable: some View {
        let rows = visible.map { item in
            NativeFileRow(id: item.id, entry: RemoteEntry(name: item.name, path: item.url.path, kind: item.link ? .symbolicLink : item.directory ? .directory : .file, size: UInt64(max(0, item.size)), modified: item.modified), localURL: item.url)
        }
        return NativeFileTable(rows: rows, selection: $selected, ready: ready, drop: receive, open: openDirectory, sort: { descriptors in
            sortOrder = descriptors.map { key, ascending -> KeyPathComparator<LocalEntry> in
                let order: SortOrder = ascending ? .forward : .reverse
                switch key { case "size": return KeyPathComparator(\.size, order: order); case "date": return KeyPathComparator(\.modified, order: order); default: return KeyPathComparator(\.name, order: order) }
            }
        }, menu: { AnyView(rowMenu($0)) })
        .overlay {
            if let error, entries.isEmpty { EmptyPane(symbol: "exclamationmark.folder", title: "无法读取目录", detail: error).allowsHitTesting(false) }
            else if visible.isEmpty && !busy { EmptyPane(symbol: "folder", title: "空目录", detail: "").allowsHitTesting(false) }
        }
    }
    @ViewBuilder private func rowMenu(_ ids: Set<String>) -> some View {
        let chosen = items(ids)
        if chosen.isEmpty { directoryActions }
        else {
            Button(T("打开")) { openDirectory(ids) }.disabled(chosen.count != 1 || chosen.first?.directory != true || !ready)
            Button(T("上传到远程目录")) { upload(chosen.map(\.url)) }.disabled(!ready || !canUpload || chosen.contains(where: \.link))
            Button(T("复制到…")) { relocate(chosen, copy: true) }.disabled(!ready)
            Button(T("移动到…")) { relocate(chosen, copy: false) }.disabled(!ready)
            Button(T("重命名…")) { renaming = chosen.first; newName = chosen.first?.name ?? "" }.disabled(chosen.count != 1 || !ready)
            Divider()
            Button(T("移到废纸篓…"), role: .destructive) { deleting = chosen }.disabled(chosen.isEmpty || !ready)
        }
    }
    private func load() async {
        guard !Task.isCancelled else { return }
        busy = true; selected = []; model.localSelection = []; model.localSelectionSupportsTransfer = false
        loadedPath = nil; entries = []; sortedEntries = []; error = nil
        do {
            let current = path, workspace = model.workspaceKey
            let task = Task.detached(priority: .utility) {
                try Task.checkCancellation()
                let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey]
                return try FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: current), includingPropertiesForKeys: Array(keys)).map { url in
                    try Task.checkCancellation()
                    let values = try? url.resourceValues(forKeys: keys), link = values?.isSymbolicLink == true
                    return LocalEntry(url: url, directory: values?.isDirectory == true && !link, link: link, size: Int64(values?.fileSize ?? 0), modified: values?.contentModificationDate ?? .distantPast)
                }
            }
            let loaded = try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() })
            try Task.checkCancellation(); entries = loaded; updateVisible(); loadedPath = current; error = nil; busy = false
            model.rememberLocalPath(current, workspace: workspace)
        } catch is CancellationError {} catch { guard !Task.isCancelled else { return }; entries = []; self.error = error.localizedDescription; busy = false }
    }
    private func mutate(_ operation: @escaping @Sendable () throws -> Void) {
        guard ready else { return }
        busy = true; mutating = true; loadedPath = nil; mutationError = nil
        Task {
            do { try await model.performLocalFileOperation(operation) }
            catch { mutationError = error.localizedDescription }
            mutating = false; busy = false; revision += 1
        }
    }
    private func openDirectory(_ identifiers: Set<String>) {
        if ready, identifiers.count == 1, let entry = entries.first(where: { identifiers.contains($0.id) && $0.directory }) { path = entry.url.path }
    }
    private func chooseDirectory() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
        if panel.runModal() == .OK, let url = panel.url { path = url.path }
    }
    private var directoryActions: some View {
        Group {
            Button(T("新建文件夹…")) { newName = ""; creatingFile = false; creating = true }.disabled(!ready)
            Button(T("新建文件…")) { newName = ""; creatingFile = true; creating = true }.disabled(!ready)
            Divider()
            Button(T("刷新目录")) { revision += 1 }.disabled(busy)
            Button(T("选择本地目录")) { chooseDirectory() }
        }
    }
    private func relocate(_ chosen: [LocalEntry], copy: Bool) {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
        panel.directoryURL = URL(fileURLWithPath: path)
        panel.title = T(copy ? "复制到本地目录" : "移动到本地目录")
        guard panel.runModal() == .OK, let directory = panel.url else { return }
        let sources = chosen.map(\.url)
        mutate { try LocalFileOperations.relocate(sources, into: directory, copy: copy) }
    }
}

struct FilePaneLabel: View {
    let title: String
    let symbol: String
    @Binding var showHidden: Bool
    var body: some View {
        HStack(spacing: 5) {
            Button { showHidden.toggle() } label: { Image(systemName: symbol) }
                .font(.system(size: 12)).frame(width: 20, height: 24)

#if TERMVIA_DIAGNOSTICS
                .background(GeometryCheckProbe(role: "file-icon-" + (title == "远程" ? "remote" : "local")))
#endif

                .accessibilityLabel(T("显示隐藏文件"))
                .accessibilityValue(T(showHidden ? "开启" : "关闭"))
            Text(T(title)).font(.callout.weight(.semibold))
        }.fixedSize()
    }
}
