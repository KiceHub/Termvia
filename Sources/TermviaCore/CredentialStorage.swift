import Foundation
import Darwin

public protocol EnumerableCredentialSecretStore: CredentialSecretStore {
    func identifiers() throws -> [UUID]
}

/// Routes saved secrets through the selected backend and keeps interrupted
/// migrations recoverable without recording secret values in the journal.
public struct CredentialStorage: Sendable {
    public enum Category: String, CaseIterable, Codable, Sendable {
        case hosts = "host-secrets"
        case profiles = "credential-secrets"
        case proxies = "proxy-secrets"
    }

    private struct Entry: Codable { let category: Category; let id: UUID }
    private struct Cleanup: Codable { let keychain: Bool; let entries: [Entry] }
    private struct Preference: Codable { var keychain: Bool?; var cleanup: Cleanup? }

    private let root: URL
    private let keychain: @Sendable (Category) -> any EnumerableCredentialSecretStore

    public init(root: URL, keychain: @escaping @Sendable (Category) -> any EnumerableCredentialSecretStore = {
        KeychainSecretStore(service: "app.termvia.client." + $0.rawValue)
    }) {
        self.root = root
        self.keychain = keychain
    }

    private var journal: URL { root.appendingPathComponent("credential-storage.json") }

    public func preference() throws -> Bool? { try load().keychain }

    public func store(for category: Category) -> any CredentialSecretStore {
        RoutedStore(storage: self, category: category)
    }

    /// Returns a cleanup warning if the selected backend was committed, but
    /// the old copies could not all be removed. They are retried next launch.
    public func selectKeychain(_ enabled: Bool) throws -> String? {
        try withLock {
            let current = try load()
            try finishCleanup(current)
            let wasEnabled = current.keychain == true
            if wasEnabled == enabled {
                try persist(Preference(keychain: enabled, cleanup: nil))
                return nil
            }

            var originals: [Entry] = []
            var copies: [(entry: Entry, value: String)] = []
            for category in Category.allCases {
                let source = backend(keychain: wasEnabled, category: category)
                let destination = backend(keychain: enabled, category: category)
                for id in Set(try source.identifiers()) {
                    guard let value = try source.read(id) else { continue }
                    let entry = Entry(category: category, id: id)
                    originals.append(entry)
                    if let existing = try destination.read(id) {
                        guard existing == value else { throw SSHError.invalid(T("无法验证迁移后的登录信息")) }
                    } else {
                        copies.append((entry, value))
                    }
                }
            }

            // Before the commit, only remove copies created on this attempt.
            let rollback = Preference(keychain: current.keychain, cleanup: Cleanup(keychain: enabled, entries: copies.map(\.entry)))
            try persist(rollback)
            let committed = Preference(keychain: enabled, cleanup: Cleanup(keychain: wasEnabled, entries: originals))
            do {
                for copy in copies {
                    let store = backend(keychain: enabled, category: copy.entry.category)
                    try store.write(copy.value, id: copy.entry.id)
                    guard try store.read(copy.entry.id) == copy.value else {
                        throw SSHError.invalid(T("无法验证迁移后的登录信息"))
                    }
                }
                try persist(committed)
            } catch {
                // Keep the rollback journal if a locked Keychain prevents
                // cleanup now. The source still owns the saved secrets.
                try? finishCleanup(rollback)
                throw error
            }

            do { try finishCleanup(committed); return nil }
            catch { return T("已切换凭据保存方式，但部分旧副本暂时无法删除：%@", error.localizedDescription) }
        }
    }

    public func retryCleanup() throws {
        try withLock { try finishCleanup(load()) }
    }

    private func finishCleanup(_ preference: Preference) throws {
        guard let cleanup = preference.cleanup else { return }
        for entry in cleanup.entries {
            try backend(keychain: cleanup.keychain, category: entry.category).delete(entry.id)
        }
        try persist(Preference(keychain: preference.keychain, cleanup: nil))
    }

    private func load() throws -> Preference {
        do { return try JSONDecoder().decode(Preference.self, from: Data(contentsOf: journal)) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return Preference(keychain: nil, cleanup: nil)
        } catch {
            throw SSHError.invalid(T("无法读取凭据存储设置：%@", error.localizedDescription))
        }
    }

    private func persist(_ value: Preference) throws {
        try JSONEncoder().encode(value).write(to: journal, options: .atomic)
    }

    private func backend(keychain enabled: Bool, category: Category) -> any EnumerableCredentialSecretStore {
        if enabled { return keychain(category) }
        return FileSecretStore(directory: root.appendingPathComponent(category.rawValue, isDirectory: true))
    }

    private func withLock<Result>(_ operation: () throws -> Result) throws -> Result {
        // Flock the stable Application Support directory across launches. A
        // busy migration can wait on system authorization off the main thread.
        let fd = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(fd) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            if errno == EWOULDBLOCK { throw SSHError.invalid(T("凭据正在迁移，请稍后重试。")) }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return try operation()
    }

    private struct RoutedStore: CredentialSecretStore {
        let storage: CredentialStorage
        let category: Category

        private func use<Result>(_ action: (any CredentialSecretStore) throws -> Result) throws -> Result {
            try storage.withLock {
                let enabled = try storage.load().keychain == true
                return try action(storage.backend(keychain: enabled, category: category))
            }
        }

        func read(_ id: UUID) throws -> String? { try use { try $0.read(id) } }
        func write(_ value: String, id: UUID) throws { try use { try $0.write(value, id: id) } }
        func delete(_ id: UUID) throws { try use { try $0.delete(id) } }
    }
}
