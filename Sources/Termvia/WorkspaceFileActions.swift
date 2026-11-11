import AppKit
import TermviaCore

@MainActor enum WorkspaceFileActions {
    static func upload(_ files: [URL], model: AppModel, session: Session, directory: String) {
        guard session.connected, session.host != nil, directory.hasPrefix("/") else { model.error = T("请先读取远程目录"); return }
        model.confirmTransfer(sources: files.map(\.path), destination: (session.host?.name ?? "") + ":" + directory, upload: true) {
            uploadConfirmed(files, model: model, session: session, directory: directory)
        }
    }
    private static func uploadConfirmed(_ files: [URL], model: AppModel, session: Session, directory: String) {
        guard session.connected, let host = session.host, directory.hasPrefix("/") else { model.error = T("请先读取远程目录"); return }
        for file in files {
            do {
                let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey])
                guard values.isRegularFile == true || values.isDirectory == true, values.isSymbolicLink != true else { throw SSHError.invalid("请选择文件或文件夹，不支持符号链接") }
                let folder = values.isDirectory == true
                let remote = try FilePaths.child(file.lastPathComponent, in: directory)
                model.enqueue(local: file.path, remote: remote, upload: true, method: model.fileProtocol(for: session), host: host, authentication: session.authentication, directory: folder, askConflicts: true, activity: session.activity)
            } catch { model.error = error.localizedDescription; return }
        }
    }
    static func download(_ entries: [RemoteEntry], model: AppModel, session: Session, directory: URL) {
        guard session.connected, session.host != nil else { model.error = T("请先打开远程会话"); return }
        guard entries.allSatisfy({ $0.kind == .file || $0.kind == .directory }) else { model.error = T("请选择文件或文件夹，不支持符号链接"); return }
        model.confirmTransfer(sources: entries.map { (session.host?.name ?? "") + ":" + $0.path }, destination: directory.path, upload: false) {
            model.planFileTransfer(activity: session.activity) { scope in try await downloadConfirmed(entries, model: model, session: session, directory: directory, scope: scope) }
        }
    }
    private static func downloadConfirmed(_ entries: [RemoteEntry], model: AppModel, session: Session, directory: URL, scope: UUID) async throws {
        var planned = Set<String>()
        func key(_ url: URL) -> String { "local:" + url.standardizedFileURL.resolvingSymlinksInPath().path.precomposedStringWithCanonicalMapping.lowercased() }
        for entry in entries {
            try Task.checkCancellation()
            guard session.connected else { throw CancellationError() }
            var target = URL(fileURLWithPath: try FilePaths.child(entry.name, in: directory.path))
            var overwrite = false, skip = false
            while true {
                let kind = try LocalDirectoryMerge.kind(at: target)
                if let kind, kind != entry.kind { throw SSHError.invalid(T("目标类型不同或为符号链接：%@", target.path)) }
                let exists = kind != nil || planned.contains(key(target)) || model.transfers.contains { ["排队中", "传输中", "正在取消"].contains($0.state) && $0.destinationKey == key(target) }
                if !exists { break }
                let choice = try await model.fileConflict(path: target.path, directory: entry.kind == .directory, scope: scope, rename: entry.kind == .file ? target : nil)
                switch choice {
                case .replace: overwrite = true
                case .skip: skip = true
                case .cancel: throw CancellationError()
                case .saveAs(let url): target = url; continue
                }
                break
            }
            if skip { continue }
            try Task.checkCancellation()
            planned.insert(key(target))
            model.enqueue(local: target.path, remote: entry.path, upload: false, method: model.fileProtocol(for: session), host: session.host, authentication: session.authentication, overwrite: overwrite, directory: entry.kind == .directory, askConflicts: entry.kind == .directory, activity: session.activity)
        }
    }
    static func drop(_ payload: FileDragPayload, ontoRemote session: Session?, directory: String, model: AppModel) {
        guard let session, session.host != nil else { model.error = T("请先打开远程会话"); return }
        if !payload.localPaths.isEmpty {
            upload(payload.localPaths.map { URL(fileURLWithPath: $0) }, model: model, session: session, directory: directory)
        } else if let sourceID = payload.sessionID, let source = model.sessions.first(where: { $0.id == sourceID }), source.host?.id == session.host?.id {
            do {
                guard payload.entries.allSatisfy({ $0.kind == .file }) else { throw SSHError.invalid("请选择普通文件；目录和符号链接不自动跟随") }
                let operations = try payload.entries.compactMap { entry -> SFTPOperation? in
                    let target = try FilePaths.child(entry.name, in: directory)
                    guard !FilePaths.isSelfDestination(source: entry.path, target: target) else { return nil }
                    return .copyFile(entry.path, target)
                }
                model.mutateRemote(session, operations: operations)
            } catch { model.error = error.localizedDescription }
        } else { model.error = T("请切换到来源主机后再操作") }
    }
    static func drop(_ payload: FileDragPayload, ontoLocal directory: URL, model: AppModel) {
        if let sourceID = payload.sessionID, let source = model.sessions.first(where: { $0.id == sourceID }), source.host != nil {
            download(payload.entries, model: model, session: source, directory: directory)
        } else if !payload.localPaths.isEmpty {
            let urls = payload.localPaths.map { URL(fileURLWithPath: $0) }
            Task {
                do { try await model.performLocalFileOperation { try LocalFileOperations.relocate(urls, into: directory, copy: true) }; model.refreshLocalFiles() }
                catch { model.error = error.localizedDescription }
            }
        } else { model.error = T("请切换到来源主机后再操作") }
    }
}
