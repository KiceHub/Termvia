import Foundation
import Darwin

/// Local, unencrypted secrets. Only the current user can access the directory
/// (0700) and files (0600); no Keychain or additional password is involved.
public struct FileSecretStore: CredentialSecretStore {
    public let directory: URL
    public init(directory: URL) { self.directory = directory }

    private func systemError() -> POSIXError { POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    private func makePrivate(_ fd: Int32, mode: mode_t) throws {
        // A macOS ACL can grant access beyond the POSIX mode bits.
        guard let acl = acl_init(0) else { throw systemError() }
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        guard acl_set_fd_np(fd, acl, ACL_TYPE_EXTENDED) == 0, fchmod(fd, mode) == 0 else { throw systemError() }
    }
    private func openDirectory(create: Bool) throws -> Int32? {
        if create {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        let fd = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        if fd < 0 {
            if !create && errno == ENOENT { return nil }
            throw systemError()
        }
        do {
            var info = stat()
            guard fstat(fd, &info) == 0 else { throw systemError() }
            guard info.st_uid == geteuid() else { throw POSIXError(.EACCES) }
            try makePrivate(fd, mode: 0o700)
            return fd
        } catch { Darwin.close(fd); throw error }
    }
    public func read(_ id: UUID) throws -> String? {
        guard let parent = try openDirectory(create: false) else { return nil }
        defer { Darwin.close(parent) }
        let fd = openat(parent, id.uuidString, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        if fd < 0 { if errno == ENOENT { return nil }; throw systemError() }
        defer { Darwin.close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0 else { throw systemError() }
        guard info.st_mode & S_IFMT == S_IFREG, info.st_uid == geteuid(), info.st_size <= 8192 else { throw POSIXError(.EACCES) }
        try makePrivate(fd, mode: 0o600)
        var data = Data(), buffer = [UInt8](repeating: 0, count: 8193)
        while true {
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count < 0 && errno == EINTR { continue }
            guard count >= 0 else { throw systemError() }
            if count == 0 { break }
            data.append(contentsOf: buffer.prefix(count))
            guard data.count <= 8192 else { throw POSIXError(.EFBIG) }
        }
        guard let value = String(data: data, encoding: .utf8) else { throw SSHError.invalid("无法读取本地登录信息") }
        try validateLoginSecret(value)
        return value
    }
    public func write(_ value: String, id: UUID) throws {
        try validateLoginSecret(value)
        guard let parent = try openDirectory(create: true) else { throw POSIXError(.ENOENT) }
        defer { Darwin.close(parent) }
        let temporary = "." + UUID().uuidString
        let fd = openat(parent, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw systemError() }
        defer { Darwin.close(fd); _ = unlinkat(parent, temporary, 0) }
        try makePrivate(fd, mode: 0o600)
        // Use a new private inode, then rename within the opened directory.
        // Readers see either complete version and never a truncated secret.
        try Data(value.utf8).withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { if count == 0 { throw POSIXError(.EIO) }; throw systemError() }
                offset += count
            }
        }
        guard renameat(parent, temporary, parent, id.uuidString) == 0 else { throw systemError() }
    }
    public func delete(_ id: UUID) throws {
        guard let parent = try openDirectory(create: false) else { return }
        defer { Darwin.close(parent) }
        if unlinkat(parent, id.uuidString, 0) != 0 && errno != ENOENT { throw systemError() }
    }
}
