import Foundation

/// A bounded, relative-path manifest. Links and special files are rejected,
/// rather than following them outside the selected folder or omitting them.
public struct TransferTree: Sendable {
    public var directories: [String] = []
    public var files: [String] = []
    public init() {}
    private mutating func append(_ path: String, directory: Bool, depth: Int) throws {
        guard depth <= 64, directories.count + files.count < 100000 else { throw SSHError.invalid("文件夹过大或层级过深") }
        if directory { directories.append(path) } else { files.append(path) }
    }
    public static func local(_ root: URL) throws -> Self {
        var result = Self(), pending: [(URL, String, Int)] = [(root, "", 0)]
        while let (directory, relative, depth) = pending.popLast() {
            try Task.checkCancellation()
            let metadata = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard metadata.isDirectory == true, metadata.isSymbolicLink != true else { throw SSHError.invalid("文件夹传输不跟随符号链接或特殊文件") }
            for child in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]) {
                try Task.checkCancellation()
                _ = try FilePaths.child(child.lastPathComponent, in: directory.path)
                let values = try child.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey])
                guard values.isSymbolicLink != true, values.isDirectory == true || values.isRegularFile == true else { throw SSHError.invalid("文件夹传输不跟随符号链接或特殊文件") }
                let path = relative.isEmpty ? child.lastPathComponent : relative + "/" + child.lastPathComponent
                try result.append(path, directory: values.isDirectory == true, depth: depth + 1)
                if values.isDirectory == true { pending.append((child, path, depth + 1)) }
            }
        }
        return result
    }
    public static func remote(_ root: String, list: @Sendable (String) async throws -> RemoteDirectory) async throws -> Self {
        var result = Self(), pending: [(String, String, Int)] = [(root, "", 0)]
        while let (path, relative, depth) = pending.popLast() {
            try Task.checkCancellation()
            let directory = try await list(path)
            guard directory.path == path else { throw SSHError.invalid("传输源目录已改变，请重新选择") }
            for entry in directory.entries {
                try Task.checkCancellation()
                guard entry.path == (try FilePaths.child(entry.name, in: path)), entry.kind == .file || entry.kind == .directory else { throw SSHError.invalid("文件夹传输不跟随符号链接或特殊文件") }
                let child = relative.isEmpty ? entry.name : relative + "/" + entry.name
                try result.append(child, directory: entry.kind == .directory, depth: depth + 1)
                if entry.kind == .directory { pending.append((entry.path, child, depth + 1)) }
            }
        }
        return result
    }
}
