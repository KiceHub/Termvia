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

/// Parse bounded OpenSSH diagnostics and capture visible login text in memory.
final class SSHConnectionDiagnostics: @unchecked Sendable {
    private static let loginOutputLimit = 16_384
    private let lock = NSLock()
    private var pending = Data()
    private var loginOutput: Data?
    private var authentication: String?
    private var keyExchange: String?

    init(captureLoginOutput: Bool = false) {
        loginOutput = captureLoginOutput ? Data() : nil
    }

    func feed(_ bytes: Data) {
        lock.lock(); defer { lock.unlock() }
        pending.append(bytes)
        while let end = pending.firstIndex(of: 10) {
            let line = String(decoding: pending.prefix(upTo: end), as: UTF8.self)
            pending.removeSubrange(...end)
            if let range = line.range(of: "kex: algorithm: ") { keyExchange = token(String(line[range.upperBound...])) }
            let isAuthenticationDiagnostic = line.hasPrefix("Authenticated to ") || line.hasPrefix("debug1: Authenticated to ")
            if isAuthenticationDiagnostic, let range = line.range(of: " using \"") {
                authentication = token(String(line[range.upperBound...].prefix(while: { $0 != "\"" })))
            }
            if let count = loginOutput?.count, count < Self.loginOutputLimit,
               !isAuthenticationDiagnostic, !Self.isDebugLine(line), !line.hasPrefix("OpenSSH_") {
                // OpenSSH writes a banner verbatim, so the next debug record
                // can follow directly on a banner without a trailing newline.
                let end = line.firstMatch(of: #/debug[123]: /#)?.range.lowerBound ?? line.endIndex
                let visible = String(line[..<end]) + "\n"
                loginOutput?.append(contentsOf: visible.utf8.prefix(Self.loginOutputLimit - count))
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
    func takeLoginOutput(suppressWarnings: Bool) -> String {
        lock.lock()
        let output = loginOutput ?? Data()
        loginOutput = nil
        lock.unlock()
        let text = String(decoding: output, as: UTF8.self).replacingOccurrences(of: "\r\n", with: "\n")
        // A server's login notice can start with "Warning:". Filter only
        // recognizable OpenSSH warnings from this mixed output.
        let visible = suppressWarnings ? text.components(separatedBy: "\n").filter {
            !$0.hasPrefix("Warning: Permanently added ")
                && !$0.hasPrefix("Warning: Identity file ")
                && !$0.hasPrefix("** WARNING: connection is not using a post-quantum")
                && !$0.hasPrefix("** This session may be vulnerable to ")
                && !$0.hasPrefix("** The server may need to be upgraded.")
        }.joined(separator: "\n") : text
        // Banners are remote text. Only the terminal view supplies line positioning.
        return String(visible.unicodeScalars.filter {
            $0 == "\n" || $0 == "\t" || !CharacterSet.controlCharacters.contains($0)
        }).trimmingCharacters(in: .newlines)
    }

    private static func isDebugLine(_ line: String) -> Bool {
        line.hasPrefix("debug1:") || line.hasPrefix("debug2:") || line.hasPrefix("debug3:")
    }

    static func failureOutput(_ output: String, suppressWarnings: Bool = false) -> String {
        var weakWarning = false
        return output.components(separatedBy: .newlines).filter { line in
            if isDebugLine(line) { return false }
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
