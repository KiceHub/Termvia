import Foundation
import Darwin

/// An existing merge root, bound to its inode. All descendants are opened
/// relative to this descriptor without following symbolic links.
public final class LocalDirectoryMerge: @unchecked Sendable {
    public let root: URL
    private let descriptor: Int32
    private let device: dev_t
    private let inode: ino_t
    public init(root: URL) throws {
        guard root.isFileURL, root.path.hasPrefix("/"), !root.path.contains("\0") else { throw SSHError.invalid("本地和远程路径必须是绝对路径") }
        self.root = root.standardizedFileURL
        let fd = open(self.root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw Self.systemError() }
        var info = stat()
        guard fstat(fd, &info) == 0 else { let error = Self.systemError(); Darwin.close(fd); throw error }
        descriptor = fd; device = info.st_dev; inode = info.st_ino
    }
    deinit { Darwin.close(descriptor) }
    private static func systemError() -> POSIXError { POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    public static func kind(at url: URL) throws -> RemoteFileKind? {
        var info = stat()
        if lstat(url.path, &info) != 0 { if errno == ENOENT { return nil }; throw systemError() }
        return kind(info.st_mode)
    }
    private static func kind(_ mode: mode_t) -> RemoteFileKind {
        switch mode & S_IFMT { case S_IFREG: return .file; case S_IFDIR: return .directory; case S_IFLNK: return .symbolicLink; default: return .other }
    }
    private func components(_ relative: String) throws -> [String] {
        let result = relative.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !result.isEmpty else { throw SSHError.invalid("请输入有效的单个文件名") }
        for component in result { _ = try FilePaths.child(component, in: root.path) }
        return result
    }
    private func validateRoot() throws {
        var info = stat()
        guard lstat(root.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR, info.st_dev == device, info.st_ino == inode else { throw SSHError.invalid("下载目录已改变，请重新选择") }
    }
    private func parent(_ relative: String) throws -> (Int32, String) {
        try validateRoot()
        let parts = try components(relative)
        var fd = fcntl(descriptor, F_DUPFD_CLOEXEC, 0)
        guard fd >= 0 else { throw Self.systemError() }
        do {
            for part in parts.dropLast() {
                let next = openat(fd, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard next >= 0 else { throw Self.systemError() }
                Darwin.close(fd); fd = next
            }
            return (fd, parts.last!)
        } catch { Darwin.close(fd); throw error }
    }
    public func kind(_ relative: String) throws -> RemoteFileKind? {
        do {
            let (fd, name) = try parent(relative); defer { Darwin.close(fd) }
            var info = stat()
            if fstatat(fd, name, &info, AT_SYMLINK_NOFOLLOW) != 0 { if errno == ENOENT { return nil }; throw Self.systemError() }
            return Self.kind(info.st_mode)
        } catch let error as POSIXError where error.code == .ENOENT { return nil }
    }
    public func prepareDirectory(_ relative: String, allowExisting: Bool) throws {
        let (fd, name) = try parent(relative); defer { Darwin.close(fd) }
        if mkdirat(fd, name, 0o700) == 0 { return }
        guard errno == EEXIST, allowExisting else { throw Self.systemError() }
        var info = stat()
        guard fstatat(fd, name, &info, AT_SYMLINK_NOFOLLOW) == 0, info.st_mode & S_IFMT == S_IFDIR else { throw SSHError.invalid(T("目标类型不同或为符号链接：%@", relative)) }
    }
    public func downloadTarget(_ relative: String) throws -> DownloadTarget {
        let (fd, _) = try parent(relative); defer { Darwin.close(fd) }
        return try DownloadTarget(destination: root.appendingPathComponent(relative), verifiedParent: fd)
    }
    public func validate(_ relative: String, target: DownloadTarget) throws {
        let (fd, _) = try parent(relative); defer { Darwin.close(fd) }
        try target.verifyParent(fd)
    }
}
