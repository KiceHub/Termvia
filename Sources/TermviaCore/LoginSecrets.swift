import Foundation

/// Both values live only in the existing permission-restricted secret store.
/// Connection/credential JSON continues to contain metadata and references only.
public struct LoginSecrets: Codable, Equatable, Sendable {
    public var password: String
    public var passphrase: String
    private static let prefix = "termvia-login-v2:"
    public init(password: String = "", passphrase: String = "") { self.password = password; self.passphrase = passphrase }
    public init(stored: String?, method: SSHAuthentication) {
        if let stored, stored.hasPrefix(Self.prefix), let data = Data(base64Encoded: String(stored.dropFirst(Self.prefix.count))),
           let decoded = try? JSONDecoder().decode(Self.self, from: data) { self = decoded }
        else { self.init(password: method == .privateKey ? "" : stored ?? "", passphrase: method == .privateKey ? stored ?? "" : "") }
    }
    public func stored(method: SSHAuthentication) throws -> String {
        try validateLoginSecret(password); try validateLoginSecret(passphrase)
        switch method {
        case .privateKey: return passphrase
        case .keyAndPassword: return Self.prefix + (try JSONEncoder().encode(self)).base64EncodedString()
        default: return password
        }
    }
}
