import Foundation
import Darwin

/// Capture the selected directory's identity at enqueue time without holding
/// a descriptor for every queued file.
public struct DownloadTarget: Sendable {
    public let destination: URL
    fileprivate let device: dev_t
    fileprivate let inode: ino_t
    init(destination: URL, verifiedParent fd: Int32) throws {
        _ = try FilePaths.child(destination.lastPathComponent, in: destination.deletingLastPathComponent().path)
        var info = stat()
        guard fstat(fd, &info) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        self.destination = destination; device = info.st_dev; inode = info.st_ino
    }
    func verifyParent(_ fd: Int32) throws {
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_dev == device, info.st_ino == inode else { throw SSHError.invalid("下载目录已改变，请重新选择") }
    }
    public init(destination: URL) throws {
        guard destination.isFileURL, destination.path.hasPrefix("/"), !destination.path.contains("\0") else { throw SSHError.invalid("本地和远程路径必须是绝对路径") }
        let parent = destination.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath()
        let name = destination.lastPathComponent
        _ = try FilePaths.child(name, in: parent.path)
        let fd = open(parent.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { Darwin.close(fd) }
        var metadata = stat()
        guard fstat(fd, &metadata) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        self.destination = parent.appendingPathComponent(name); device = metadata.st_dev; inode = metadata.st_ino
    }
}

/// Download into a private sibling directory. Commit the complete file with a
/// directory-relative rename; never open the user's destination for writing.
public final class DownloadStaging {
    public let fileURL: URL
    private let parentURL: URL
    private let targetName: String
    private let directoryName: String
    private let overwrite: Bool
    private let isDirectory: Bool
    private var parentFD: Int32 = -1
    private var directoryFD: Int32 = -1
    private var directoryCreated = false
    public convenience init(destination: URL, overwrite: Bool = false) throws {
        try self.init(target: DownloadTarget(destination: destination), overwrite: overwrite)
    }
    public init(target: DownloadTarget, overwrite: Bool = false, directory: Bool = false) throws {
        let destination = target.destination
        parentURL = destination.deletingLastPathComponent()
        targetName = destination.lastPathComponent
        _ = try FilePaths.child(targetName, in: parentURL.path)
        directoryName = ".termvia-download-" + UUID().uuidString
        fileURL = parentURL.appendingPathComponent(directoryName, isDirectory: true).appendingPathComponent("payload")
        self.overwrite = overwrite
        isDirectory = directory
        do {
            parentFD = open(parentURL.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard parentFD >= 0 else { throw Self.systemError() }
            var metadata = stat()
            guard fstat(parentFD, &metadata) == 0 else { throw Self.systemError() }
            guard metadata.st_dev == target.device, metadata.st_ino == target.inode else { throw SSHError.invalid("下载目录已改变，请重新选择") }
            try checkTarget()
            guard mkdirat(parentFD, directoryName, 0o700) == 0 else { throw Self.systemError() }
            directoryCreated = true
            directoryFD = openat(parentFD, directoryName, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard directoryFD >= 0 else { throw Self.systemError() }
            if directory {
                guard mkdirat(directoryFD, "payload", 0o700) == 0 else { throw Self.systemError() }
            } else {
                let payloadFD = openat(directoryFD, "payload", O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
                guard payloadFD >= 0 else { throw Self.systemError() }
                Darwin.close(payloadFD)
            }
        } catch { close(); throw error }
    }
    private static func systemError() -> POSIXError { POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    private func checkTarget(overwrite confirmed: Bool? = nil) throws {
        var metadata = stat()
        if fstatat(parentFD, targetName, &metadata, AT_SYMLINK_NOFOLLOW) == 0 {
            guard !isDirectory else { throw SSHError.invalid(T("目标文件夹已存在：%@", targetName)) }
            guard metadata.st_mode & S_IFMT == S_IFREG else { throw SSHError.invalid("下载目标必须是普通文件或尚不存在") }
            guard confirmed ?? overwrite else { throw SSHError.invalid(T("文件已存在：%@", targetName)) }
        } else if errno != ENOENT { throw Self.systemError() }
    }
    public func commit(overwrite confirmed: Bool? = nil) throws {
        guard parentFD >= 0, directoryFD >= 0 else { throw SSHError.invalid("下载暂存文件已关闭") }
        var original = stat(), current = stat(), payload = stat()
        guard fstat(parentFD, &original) == 0, lstat(parentURL.path, &current) == 0,
              original.st_dev == current.st_dev, original.st_ino == current.st_ino else { throw SSHError.invalid("下载目录已改变，请重新选择") }
        guard fstatat(directoryFD, "payload", &payload, AT_SYMLINK_NOFOLLOW) == 0 else { throw Self.systemError() }
        guard payload.st_mode & S_IFMT == (isDirectory ? S_IFDIR : S_IFREG) else { throw SSHError.invalid("下载暂存结果类型不匹配") }
        try checkTarget(overwrite: confirmed)
        let result = (confirmed ?? overwrite) && !isDirectory ? renameat(directoryFD, "payload", parentFD, targetName) : renameatx_np(directoryFD, "payload", parentFD, targetName, UInt32(RENAME_EXCL))
        guard result == 0 else { throw Self.systemError() }
        close()
    }
    public func close() {
        if isDirectory && directoryFD >= 0 { try? FileManager.default.removeItem(at: fileURL) }
        if directoryFD >= 0 { _ = unlinkat(directoryFD, "payload", 0); Darwin.close(directoryFD); directoryFD = -1 }
        if parentFD >= 0 {
            if directoryCreated { _ = unlinkat(parentFD, directoryName, AT_REMOVEDIR); directoryCreated = false }
            Darwin.close(parentFD); parentFD = -1
        }
    }
    deinit { close() }
}
