import Foundation

public struct SSHConnectionSecurity: Sendable, Equatable {
    public let authentication: String?
    public let keyExchange: String?
    public var usesPostQuantum: Bool? {
        keyExchange.map { $0.hasPrefix("mlkem") || $0.hasPrefix("sntrup") }
    }
}
public struct ConnectionVerification: Sendable {
    public let status: Int32
    public let output: String
    public let security: SSHConnectionSecurity
}

/// Parse bounded OpenSSH diagnostics in memory. Only method/algorithm names
/// escape this buffer; debug output is never persisted as an activity log.
final class SSHConnectionDiagnostics: @unchecked Sendable {
    private let lock = NSLock()
    private var pending = Data()
    private var authentication: String?
    private var keyExchange: String?
    func feed(_ bytes: Data) {
        lock.lock(); defer { lock.unlock() }
        pending.append(bytes)
        while let end = pending.firstIndex(of: 10) {
            let line = String(decoding: pending.prefix(upTo: end), as: UTF8.self)
            pending.removeSubrange(...end)
            if let range = line.range(of: "kex: algorithm: ") { keyExchange = token(String(line[range.upperBound...])) }
            if line.contains("Authenticated to "), let range = line.range(of: " using \"") {
                authentication = token(String(line[range.upperBound...].prefix(while: { $0 != "\"" })))
            }
        }
        if pending.count > 8192 { pending.removeFirst(pending.count - 8192) }
    }
    private func token(_ value: String) -> String? {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789@._+-")
        guard !value.isEmpty, value.utf8.count <= 128, value.unicodeScalars.allSatisfy(allowed.contains) else { return nil }
        return value
    }
    var security: SSHConnectionSecurity {
        lock.lock(); defer { lock.unlock() }
        return SSHConnectionSecurity(authentication: authentication, keyExchange: keyExchange)
    }
    static func failureOutput(_ output: String, suppressWarnings: Bool = false) -> String {
        var weakWarning = false
        return output.components(separatedBy: .newlines).filter { line in
            if line.hasPrefix("debug1:") || line.hasPrefix("debug2:") || line.hasPrefix("debug3:") { return false }
            if suppressWarnings {
                if line.hasPrefix("** WARNING:") { weakWarning = true; return false }
                if weakWarning && line.hasPrefix("** ") { return false }
                weakWarning = false
                if line.lowercased().hasPrefix("warning:") { return false }
            }
            return true
        }.joined(separator: "\n")
    }
}
