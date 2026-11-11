import CryptoKit
import Foundation

/// One trust record, independent of saved host configurations. Its identity
/// includes the address, marker and key, so a stale selection cannot delete a
/// replacement key or another address that happens to use the same key.
public struct KnownHostRecord: Identifiable, Equatable, Sendable {
    public let hosts: String
    public let keyType: String
    public let marker: String
    public let fingerprint: String
    public let id: String
    public var isHashed: Bool { hosts.hasPrefix("|1|") }

    init?(line: String, fingerprint: String = "") {
        let fields = line.split(whereSeparator: \.isWhitespace)
        guard let first = fields.first, !first.hasPrefix("#") else { return nil }
        let offset = first.hasPrefix("@") ? 1 : 0
        guard fields.count >= offset + 3,
              let blob = Data(base64Encoded: String(fields[offset + 2])), blob.count >= 4 else { return nil }
        let length = blob.prefix(4).reduce(0) { ($0 << 8) | Int($1) }
        guard length > 0, length <= blob.count - 4,
              String(data: blob[4..<(4 + length)], encoding: .utf8) == String(fields[offset + 1]) else { return nil }
        hosts = String(fields[offset]); keyType = String(fields[offset + 1])
        marker = offset == 1 ? String(first) : ""
        self.fingerprint = fingerprint
        id = [marker, hosts, keyType, String(fields[offset + 2])].joined(separator: " ")
    }

    /// Resolve hashed entries only against addresses the user has saved. The
    /// original name of an orphaned hash cannot be recovered.
    public func matches(address: String, port: Int) -> Bool {
        let name = port == 22 ? address : "[\(address)]:\(port)"
        if !isHashed { return hosts.split(separator: ",").contains { $0.caseInsensitiveCompare(name) == .orderedSame } }
        let parts = hosts.split(separator: "|", omittingEmptySubsequences: false)
        guard parts.count == 4, let salt = Data(base64Encoded: String(parts[2])),
              let expected = Data(base64Encoded: String(parts[3])), salt.count == 20, expected.count == 20 else { return false }
        return [name, name.lowercased()].contains {
            HMAC<Insecure.SHA1>.isValidAuthenticationCode(expected, authenticating: Data($0.utf8), using: SymmetricKey(data: salt))
        }
    }
}

/// Keep file I/O and hashing off the main actor, with serialized management
/// updates. Every deletion rereads the latest file rather than writing a UI
/// snapshot, retaining unrelated records accepted since the list was loaded.
actor KnownHostsRecords {
    static let shared = KnownHostsRecords()
    func records(at url: URL) async throws -> [KnownHostRecord] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let text = try String(contentsOf: url, encoding: .utf8)
        var seen = Set<String>()
        let records = text.components(separatedBy: "\n").compactMap { KnownHostRecord(line: $0) }.filter { seen.insert($0.id).inserted }
        guard !records.isEmpty else { return [] }
        // One OpenSSH call validates all keys and computes the canonical
        // fingerprints, including certificates (whose fingerprint is of the
        // underlying public key, not the complete certificate blob).
        let keys = records.enumerated().map { index, record in
            let fields = record.id.split(whereSeparator: \.isWhitespace)
            return "\(record.keyType) \(fields.last!) termvia-record-\(index)"
        }.joined(separator: "\n") + "\n"
        let result = try await ProcessRunner().run(Invocation(executable: "/usr/bin/ssh-keygen", arguments: ["-l", "-E", "sha256", "-f", "-"], input: Data(keys.utf8)), outputLimit: 1048576)
        guard result.status == 0 else { throw SSHError.failed(result.status, result.output) }
        var fingerprints: [Int: String] = [:]
        for line in result.output.split(separator: "\n") {
            let fields = line.split(whereSeparator: \.isWhitespace)
            guard fields.count >= 3, Int(fields[0]) != nil, fields[1].hasPrefix("SHA256:"),
                  fields[2].hasPrefix("termvia-record-"), let index = Int(fields[2].dropFirst("termvia-record-".count)) else { continue }
            fingerprints[index] = String(fields[1])
        }
        return records.enumerated().compactMap { index, record in
            fingerprints[index].flatMap { KnownHostRecord(line: record.id, fingerprint: $0) }
        }
    }
    func forget(_ record: KnownHostRecord, at url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let text = try String(contentsOf: url, encoding: .utf8)
        let lines = text.components(separatedBy: "\n")
        let remaining = lines.filter { KnownHostRecord(line: $0)?.id != record.id }
        guard remaining.count != lines.count else { return }
        try Data(remaining.joined(separator: "\n").utf8).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
