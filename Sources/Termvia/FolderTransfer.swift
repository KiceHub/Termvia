import Foundation
import TermviaCore

extension AppModel {
    private func approveConflict(_ transfer: Transfer, path: String, directory: Bool) async throws -> Bool {
        guard transfer.askConflicts else { throw SSHError.invalid(T("文件已存在：%@", (path as NSString).lastPathComponent)) }
        switch try await fileConflict(path: path, directory: directory, scope: transfer.id) {
        case .replace: return true
        case .skip: return false
        case .cancel, .saveAs: throw CancellationError()
        }
    }
    func transferUploadFile(_ transfer: Transfer) async throws -> Int {
        let connection = TransferConnection(commands: commands, transfer: transfer)
        let parent = (transfer.remote as NSString).deletingLastPathComponent
        if let entry = try await connection.directory(parent).entries.first(where: { $0.path == transfer.remote }) {
            guard entry.kind == .file else { throw SSHError.invalid(T("目标类型不同或为符号链接：%@", transfer.remote)) }
            guard try await approveConflict(transfer, path: transfer.host.name + ":" + transfer.remote, directory: false) else { throw TransferSkipped() }
        }
        try await connection.run(commands.transfer(connection.host, local: transfer.local, remote: transfer.remote, upload: true, method: transfer.method))
        return 0
    }
    func transferFolder(_ transfer: Transfer) async throws -> Int {
        let connection = TransferConnection(commands: commands, transfer: transfer)
        let local = URL(fileURLWithPath: transfer.local)
        if transfer.upload {
            let scan = Task.detached(priority: .utility) { try TransferTree.local(local) }
            let tree = try await withTaskCancellationHandler(operation: { try await scan.value }, onCancel: { scan.cancel() })
            for path in tree.files { _ = try commands.transfer(connection.host, local: local.appendingPathComponent(path).path, remote: transfer.remote + "/" + path, upload: true, method: transfer.method) }
            return try await uploadFolder(transfer, tree: tree, connection: connection, local: local)
        }
        let tree = try await TransferTree.remote(transfer.remote) { path in try await connection.directory(path) }
        if let kind = try LocalDirectoryMerge.kind(at: local) {
            guard kind == .directory else { throw SSHError.invalid(T("目标类型不同或为符号链接：%@", local.path)) }
            if !transfer.overwrite {
                guard try await approveConflict(transfer, path: local.path, directory: true) else { throw TransferSkipped() }
            }
            return try await mergeDownload(transfer, tree: tree, connection: connection)
        }
        guard let target = transfer.downloadTarget else { throw SSHError.invalid("无法读取目录") }
        let staging = try DownloadStaging(target: target, directory: true)
        defer { staging.close() }
        let stageURL = staging.fileURL
        do {
            let create = Task.detached(priority: .utility) {
                for path in tree.directories { try Task.checkCancellation(); try FileManager.default.createDirectory(at: stageURL.appendingPathComponent(path), withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]) }
            }
            try await withTaskCancellationHandler(operation: { try await create.value }, onCancel: { create.cancel() })
            try await connection.files(tree.files, localRoot: stageURL)
            try Task.checkCancellation(); try staging.commit()
        } catch {
            await Task.detached(priority: .utility) { try? FileManager.default.removeItem(at: stageURL) }.value
            throw error
        }
        return 0
    }
    private func uploadFolder(_ transfer: Transfer, tree: TransferTree, connection: TransferConnection, local: URL) async throws -> Int {
        let parent = (transfer.remote as NSString).deletingLastPathComponent
        let rootEntry = try await connection.directory(parent).entries.first { $0.path == transfer.remote }
        if let rootEntry {
            guard rootEntry.kind == .directory else { throw SSHError.invalid(T("目标类型不同或为符号链接：%@", transfer.remote)) }
            guard try await approveConflict(transfer, path: transfer.host.name + ":" + transfer.remote, directory: true) else { throw TransferSkipped() }
        }
        func index(_ relative: String) async throws -> [String: RemoteEntry] {
            let path = relative.isEmpty ? transfer.remote : transfer.remote + "/" + relative
            let directory = try await connection.directory(path)
            guard directory.path == path else { throw SSHError.invalid("传输源目录已改变，请重新选择") }
            return Dictionary(directory.entries.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        }
        var contents: [String: [String: RemoteEntry]] = ["": rootEntry == nil ? [:] : try await index("")]
        var existingDirs = Set<String>(), skippedDirs = Set<String>(), createDirs: [String] = [], files: [String] = [], approvedFiles = Set<String>(), skipped = 0
        if rootEntry != nil { existingDirs.insert("") }
        func excluded(_ path: String) -> Bool { skippedDirs.contains { path == $0 || path.hasPrefix($0 + "/") } }
        for path in tree.directories {
            try Task.checkCancellation()
            if excluded(path) { continue }
            let parent = (path as NSString).deletingLastPathComponent, name = (path as NSString).lastPathComponent
            if let entry = contents[parent]?[name] {
                guard entry.kind == .directory else { throw SSHError.invalid(T("目标类型不同或为符号链接：%@", entry.path)) }
                guard try await approveConflict(transfer, path: transfer.host.name + ":" + entry.path, directory: true) else { skippedDirs.insert(path); skipped += 1; continue }
                existingDirs.insert(path); contents[path] = try await index(path)
            } else { createDirs.append(path); contents[path] = [:] }
        }
        for path in tree.files.sorted() where !excluded(path) {
            try Task.checkCancellation()
            if let entry = contents[(path as NSString).deletingLastPathComponent]?[(path as NSString).lastPathComponent] {
                guard entry.kind == .file else { throw SSHError.invalid(T("目标类型不同或为符号链接：%@", entry.path)) }
                guard try await approveConflict(transfer, path: transfer.host.name + ":" + entry.path, directory: false) else { skipped += 1; continue }
                approvedFiles.insert(path)
            }
            files.append(path)
        }
        // No directory or file writes until all initial conflict decisions finish.
        if rootEntry == nil { _ = try await connection.directory(parent, operations: [.makeDirectory(transfer.remote)]) }
        for start in stride(from: 0, to: createDirs.count, by: 64) {
            _ = try await connection.directory(transfer.remote, operations: createDirs[start..<min(start + 64, createDirs.count)].map { .makeDirectory(transfer.remote + "/" + $0) })
        }
        // Refresh existing parents after the dialogs; never rely on a browser cache.
        var finalFiles: [String] = []
        let groupedFiles = Dictionary(grouping: files) { ($0 as NSString).deletingLastPathComponent }
        for directory in groupedFiles.keys.sorted() {
            let current = existingDirs.contains(directory) ? try await index(directory) : [:]
            for path in groupedFiles[directory, default: []] {
                if let entry = current[(path as NSString).lastPathComponent] {
                    guard entry.kind == .file else { throw SSHError.invalid(T("目标类型不同或为符号链接：%@", entry.path)) }
                    if !approvedFiles.contains(path) {
                        guard try await approveConflict(transfer, path: transfer.host.name + ":" + entry.path, directory: false) else { skipped += 1; continue }
                    }
                }
                finalFiles.append(path)
            }
        }
        try await connection.files(finalFiles, localRoot: local)
        return skipped
    }
    private func mergeDownload(_ transfer: Transfer, tree: TransferTree, connection: TransferConnection) async throws -> Int {
        let merge = try LocalDirectoryMerge(root: URL(fileURLWithPath: transfer.local))
        var allowedDirs = Set<String>(), skippedDirs = Set<String>(), approvedFiles = Set<String>(), directories: [String] = [], files: [String] = [], skipped = 0
        func excluded(_ path: String) -> Bool { skippedDirs.contains { path == $0 || path.hasPrefix($0 + "/") } }
        for path in tree.directories {
            try Task.checkCancellation()
            if excluded(path) { continue }
            if let kind = try merge.kind(path) {
                guard kind == .directory else { throw SSHError.invalid(T("目标类型不同或为符号链接：%@", merge.root.appendingPathComponent(path).path)) }
                guard try await approveConflict(transfer, path: merge.root.appendingPathComponent(path).path, directory: true) else { skippedDirs.insert(path); skipped += 1; continue }
                allowedDirs.insert(path)
            }
            directories.append(path)
        }
        for path in tree.files.sorted() where !excluded(path) {
            try Task.checkCancellation()
            if let kind = try merge.kind(path) {
                guard kind == .file else { throw SSHError.invalid(T("目标类型不同或为符号链接：%@", merge.root.appendingPathComponent(path).path)) }
                guard try await approveConflict(transfer, path: merge.root.appendingPathComponent(path).path, directory: false) else { skipped += 1; continue }
                approvedFiles.insert(path)
            }
            files.append(path)
        }
        for path in directories { try Task.checkCancellation(); try merge.prepareDirectory(path, allowExisting: allowedDirs.contains(path)) }
        for start in stride(from: 0, to: files.count, by: 16) {
            var stages: [(String, DownloadTarget, DownloadStaging, Bool)] = []
            defer { for (_, _, stage, _) in stages { stage.close() } }
            for path in files[start..<min(start + 16, files.count)] {
                try Task.checkCancellation()
                var overwrite = approvedFiles.contains(path)
                if let kind = try merge.kind(path) {
                    guard kind == .file else { throw SSHError.invalid(T("目标类型不同或为符号链接：%@", merge.root.appendingPathComponent(path).path)) }
                    if !overwrite {
                        guard try await approveConflict(transfer, path: merge.root.appendingPathComponent(path).path, directory: false) else { skipped += 1; continue }
                        overwrite = true
                    }
                }
                let target = try merge.downloadTarget(path)
                stages.append((path, target, try DownloadStaging(target: target, overwrite: overwrite), overwrite))
            }
            let invocations = try stages.map { path, _, stage, _ in try commands.transfer(connection.host, local: stage.fileURL.path, remote: transfer.remote + "/" + path, upload: false, method: transfer.method) }
            if transfer.method == .sftp, var batch = invocations.first {
                batch.input = invocations.reduce(into: Data()) { $0.append($1.input ?? Data()) }; try await connection.run(batch)
            } else { for invocation in invocations { try await connection.run(invocation) } }
            for (path, target, stage, previous) in stages {
                try Task.checkCancellation(); try merge.validate(path, target: target)
                var overwrite = previous
                if !overwrite, try merge.kind(path) != nil {
                    guard try await approveConflict(transfer, path: merge.root.appendingPathComponent(path).path, directory: false) else { skipped += 1; continue }
                    overwrite = true
                }
                try stage.commit(overwrite: overwrite)
            }
        }
        return skipped
    }
}
