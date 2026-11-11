import Foundation

public enum SSHAuthentication: String, Codable, CaseIterable, Sendable {
    case automatic, password, privateKey, keyAndPassword
    public var title: String {
        switch self { case .automatic: return T("自动"); case .password: return T("密码"); case .privateKey: return T("私钥"); case .keyAndPassword: return T("密钥和密码") }
    }
}

/// This document contains references and login metadata, never secrets.
public struct LoginCredential: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var user: String
    public var authentication: SSHAuthentication
    public var identity: String
    public init(id: UUID = UUID(), name: String, user: String, authentication: SSHAuthentication, identity: String = "") {
        self.id = id; self.name = name; self.user = user; self.authentication = authentication; self.identity = identity
    }
    public func validate() throws {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, authentication != .automatic else { throw SSHError.invalid("请输入凭据名称并选择认证方式") }
        var host = SSHHost(name: name, address: "localhost", user: user, identity: identity)
        host.authentication = authentication
        try host.validate()
    }
    public func applying(to host: SSHHost) -> SSHHost {
        var result = host
        result.user = user; result.identity = identity; result.authentication = authentication; result.credentialID = id
        return result
    }
}

public protocol CredentialSecretStore: Sendable {
    func read(_ id: UUID) throws -> String?
    func write(_ value: String, id: UUID) throws
    func delete(_ id: UUID) throws
}
public func validateLoginSecret(_ value: String) throws {
    guard value.utf8.count <= 8192 else { throw SSHError.invalid("密码或口令过长") }
    guard !value.contains("\n"), !value.contains("\r"), !value.contains("\0") else { throw SSHError.invalid("密码或口令不能包含换行或空字符") }
}

public enum CredentialSecretUpdate { case keep, replace(String), remove }
public struct CredentialStore {
    public let url: URL
    public let secrets: any CredentialSecretStore
    public init(url: URL, secrets: (any CredentialSecretStore)? = nil) {
        self.url = url
        self.secrets = secrets ?? FileSecretStore(directory: url.deletingLastPathComponent().appendingPathComponent("credential-secrets", isDirectory: true))
    }
    private struct Document: Codable { let version: Int; let credentials: [LoginCredential] }
    public func load() throws -> [LoginCredential] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let document = try JSONDecoder().decode(Document.self, from: Data(contentsOf: url))
        guard document.version == 1 else { throw SSHError.invalid("不支持的凭据配置版本") }
        try validate(document.credentials)
        return document.credentials
    }
    private func validate(_ credentials: [LoginCredential]) throws {
        for value in credentials { try value.validate() }
        guard Set(credentials.map(\.id)).count == credentials.count,
              Set(credentials.map { $0.name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil) }).count == credentials.count else { throw SSHError.invalid("凭据名称或标识重复") }
    }
    private func write(_ credentials: [LoginCredential]) throws {
        try validate(credentials)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(Document(version: 1, credentials: credentials)).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    public func save(_ credential: LoginCredential, secret update: CredentialSecretUpdate) throws -> [LoginCredential] {
        let original = try load()
        var update = update
        if case .keep = update, let previous = original.first(where: { $0.id == credential.id }), (previous.authentication != credential.authentication || (credential.authentication == .privateKey && previous.identity != credential.identity)) { update = .remove }
        var updated = original.filter { $0.id != credential.id }; updated.append(credential)
        try validate(updated)
        let previous: String?
        switch update { case .keep: previous = nil; default: previous = try secrets.read(credential.id) }
        switch update {
        case .keep: break
        case .replace(let value): try secrets.write(value, id: credential.id)
        case .remove: try secrets.delete(credential.id)
        }
        do { try write(updated) }
        catch {
            switch update {
            case .keep: break
            default:
                if let previous { try secrets.write(previous, id: credential.id) } else { try secrets.delete(credential.id) }
            }
            throw error
        }
        return updated
    }
    public func delete(_ id: UUID) throws -> [LoginCredential] {
        let original = try load(), previous = try secrets.read(id)
        try secrets.delete(id)
        let updated = original.filter { $0.id != id }
        do { try write(updated) }
        catch { if let previous { try secrets.write(previous, id: id) }; throw error }
        return updated
    }
}

extension SSHHost {
    public func acceptsSecretPrompt(_ request: AskpassRequest) -> Bool {
        guard request.hint.isEmpty else { return false }
        let prompt = request.prompt.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        switch authentication ?? .automatic {
        case .password:
            // Keyboard-interactive may prepend its name/instructions. Match the
            // actual final challenge, never a suffix such as "one-time password".
            let challenge = prompt.split(separator: "\n").last?.trimmingCharacters(in: .whitespaces) ?? ""
            return challenge == "password:" || challenge == "\(user)@\(address)'s password:".lowercased() || challenge == "(\(user)@\(address)) password:".lowercased()
        case .privateKey:
            return request.prompt.trimmingCharacters(in: .whitespacesAndNewlines) == "Enter passphrase for key '\((identity as NSString).expandingTildeInPath)':"
        case .keyAndPassword:
            var passwordHost = self; passwordHost.authentication = .password
            return passwordHost.acceptsSecretPrompt(request)
        case .automatic: return false
        }
    }
}
