import Foundation
import TermviaCore

/// A converted key is private to one live authentication context. It is never
/// put into host metadata, logs or a shared cache directory. Only the temporary
/// filename, never key bytes or the passphrase, is passed to OpenSSH.
final class PPKIdentity: @unchecked Sendable {
    let directory: URL
    let key: URL
    init(directory: URL) { self.directory = directory; key = directory.appendingPathComponent("identity") }
    deinit { try? FileManager.default.removeItem(at: directory) }
}

enum PPKConverter {
    struct Info { let source: URL; let encrypted: Bool; let bytes: Data }
    static func inspect(_ path: String) throws -> Info? {
        guard !path.isEmpty else { return nil }
        let source = URL(fileURLWithPath: NSString(string: path).expandingTildeInPath)
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: source.resolvingSymlinksInPath().path),
              attributes[.type] as? FileAttributeType == .typeRegular else {
            if source.pathExtension.lowercased() == "ppk" { throw SSHError.invalid(T("无法读取 PPK 私钥")) }
            return nil
        }
        let handle = try FileHandle(forReadingFrom: source); defer { try? handle.close() }
        let prefix = try handle.read(upToCount: 256) ?? Data()
        guard String(decoding: prefix, as: UTF8.self).hasPrefix("PuTTY-User-Key-File-") else { return nil }
        guard (attributes[.size] as? NSNumber)?.intValue ?? Int.max <= 1_048_576 else { throw SSHError.invalid(T("PPK 私钥文件过大")) }
        try handle.seek(toOffset: 0)
        let data = try handle.read(upToCount: 1_048_577) ?? Data()
        guard data.count <= 1_048_576 else { throw SSHError.invalid(T("PPK 私钥文件过大")) }
        let text = String(decoding: data, as: UTF8.self)
        guard text.hasPrefix("PuTTY-User-Key-File-2:" ) || text.hasPrefix("PuTTY-User-Key-File-3:") else { throw SSHError.invalid(T("不支持的 PPK 私钥版本")) }
        let lines = text.components(separatedBy: .newlines)
        let encryption = lines.first(where: { $0.hasPrefix("Encryption: ") })?.dropFirst(12).trimmingCharacters(in: .whitespacesAndNewlines)
        guard encryption == "none" || encryption == "aes256-cbc" else { throw SSHError.invalid(T("不支持的 PPK 加密方式")) }
        for (name, maximum) in [("Argon2-Memory", 262144), ("Argon2-Passes", 128), ("Argon2-Parallelism", 16)] {
            if let value = lines.first(where: { $0.hasPrefix(name + ":") })?.split(separator: ":", maxSplits: 1).last {
                guard let number = Int(value.trimmingCharacters(in: .whitespacesAndNewlines)), number > 0, number <= maximum else { throw SSHError.invalid(T("PPK 密钥派生参数超出支持范围")) }
            }
        }
        return Info(source: source, encrypted: encryption != "none", bytes: data)
    }
    static func convert(_ info: Info, passphrase: String, helper: URL? = nil) async throws -> PPKIdentity {
        guard !passphrase.contains("\n"), !passphrase.contains("\r"), !passphrase.contains("\0") else { throw SSHError.invalid(T("PPK 口令不能包含换行或空字符")) }
        let helper = helper ?? Bundle.main.executableURL!.deletingLastPathComponent().appendingPathComponent("termvia-ppk")
        guard FileManager.default.isExecutableFile(atPath: helper.path) else { throw SSHError.invalid(T("PPK 辅助程序缺失，请重新构建应用")) }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("termvia-ppk-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let identity = PPKIdentity(directory: directory)
        let old = directory.appendingPathComponent("old-passphrase"), empty = directory.appendingPathComponent("new-passphrase")
        let source = directory.appendingPathComponent("source.ppk")
        try info.bytes.write(to: source)
        try Data((passphrase + "\n").utf8).write(to: old); try Data("\n".utf8).write(to: empty)
        for file in [source, old, empty] { try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path) }
        defer { for file in [source, old, empty] { try? FileManager.default.removeItem(at: file) } }
        var invocation = Invocation(executable: helper.path, arguments: [source.path, "-O", "private-openssh-new", "-o", identity.key.path, "--old-passphrase", old.path, "--new-passphrase", empty.path])
        invocation.environment["PUTTYSEED"] = directory.appendingPathComponent("seed").path
        let result = try await ProcessRunner().run(invocation)
        try Task.checkCancellation()
        guard result.status == 0 else { throw SSHError.invalid(T("PPK 私钥或口令无效")) }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: identity.key.path)
        return identity
    }
}
