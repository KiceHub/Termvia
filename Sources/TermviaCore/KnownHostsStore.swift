import Foundation

public struct KnownHostsStore: Sendable {
    public let url: URL
    public init(url: URL) { self.url = url }
    public func records() async throws -> [KnownHostRecord] { try await KnownHostsRecords.shared.records(at: url) }
    public func forget(_ record: KnownHostRecord) async throws { try await KnownHostsRecords.shared.forget(record, at: url) }
    public func forget(_ record: KnownHostRecord, migrating hosts: [SSHHost]) async throws -> [String: String] {
        try await KnownHostsRecords.shared.forget(record, migrating: hosts, at: url)
    }
    public func key(for host: SSHHost) throws -> String {
        try host.validate()
        return SSHHost.knownHostsKey(address: host.address, port: host.port)
    }

    /// Preserve scoped trust while letting OpenSSH validate the unscoped certificate principal.
    public func scopedCertificateView(for host: SSHHost) throws -> (principal: String, records: String)? {
        guard host.address.contains(":"), let scope = host.address.firstIndex(of: "%") else { return nil }
        let scopedKey = try key(for: host)
        let principal = SSHHost.knownHostsKey(address: String(host.address[..<scope]), port: 22)
        var authority = false, projected = ""
        for line in try Self.read(url).utf8.split(separator: 10) {
            // Match OpenSSH's LF lines and space/tab separators. Leave the key
            // text intact so OpenSSH decides which key formats are valid.
            let bytes = line.prefix { $0 != 0 }
            let fields = bytes.split(maxSplits: 3) { $0 == 32 || $0 == 9 }
            guard let first = fields.first, first.first != 35 else { continue }
            let offset = first.first == 64 ? 1 : 0
            let marker = offset == 1 ? String(decoding: first, as: UTF8.self) : ""
            guard ["", "@cert-authority", "@revoked"].contains(marker), fields.count > offset + 1 else { continue }
            let hostField = fields[offset]
            guard hostField.first != 64, KnownHostRecord.matchesHostPattern(String(decoding: hostField, as: UTF8.self), name: scopedKey) else { continue }
            if marker == "@cert-authority" { authority = true }
            let prefix = String(decoding: bytes[..<hostField.startIndex], as: UTF8.self)
            let suffix = String(decoding: bytes[hostField.endIndex...], as: UTF8.self)
            projected += prefix + principal + suffix + "\n"
        }
        return authority ? (principal, projected) : nil
    }

    /// Run at startup before OpenSSH can write trust records. Return ambiguous
    /// entries keyed by current host identity so only those connections fail closed.
    public func migrateLegacyIPv6(for hosts: [SSHHost]) throws -> [String: String] {
        guard hosts.contains(where: { $0.address.contains(":") }) else { return [:] }
        let current = try Self.read(url)
        let result = Self.migration(of: current, for: hosts)
        if result.text != current { try Self.write(result.text, to: url) }
        return result.ambiguous
    }

    static func read(_ url: URL) throws -> String {
        do { return try String(contentsOf: url, encoding: .utf8) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile { return "" }
    }

    static func write(_ text: String, to url: URL) throws {
        try Data(text.utf8).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    static func migration(of current: String, for hosts: [SSHHost]) -> (text: String, ambiguous: [String: String]) {
        var legacyNames: [String: String] = [:]
        for host in hosts where host.address.contains(":") {
            let address = host.address
            let canonical = SSHHost.knownHostsKey(address: address, port: host.port)
            let legacy = host.port == 22 ? "[\(address)]" : "[[\(address)]]:\(host.port)"
            legacyNames[legacy] = canonical
        }
        guard !legacyNames.isEmpty else { return (current, [:]) }
        let literalNames = Dictionary(grouping: legacyNames.keys, by: { $0.lowercased() })

        let lines = current.components(separatedBy: "\n")
        let records = lines.map { line -> KnownHostRecord? in
            guard let record = KnownHostRecord(line: line),
                  ["", "@cert-authority", "@revoked"].contains(record.marker) else { return nil }
            return record
        }
        func targets(for alias: Substring, record: KnownHostRecord) -> Set<String> {
            let names = record.isHashed ? legacyNames.keys.filter { record.matches(name: $0) } : literalNames[alias.lowercased()] ?? []
            return Set(names.compactMap { legacyNames[$0] })
        }
        func isPatternList(_ record: KnownHostRecord) -> Bool {
            !record.isHashed && record.hosts.contains(where: { "!*?".contains($0) })
        }
        var ambiguous: [String: String] = [:]
        for record in records.compactMap({ $0 }) {
            if isPatternList(record) {
                // A past trust or revocation pattern must keep applying to
                // the same identity. Retain any rule whose meaning is ambiguous.
                for (legacy, canonical) in legacyNames where record.matchesHostPattern(legacy) != record.matchesHostPattern(canonical) {
                    ambiguous[canonical] = record.hosts
                }
            } else {
                for alias in record.hosts.split(separator: ",") {
                    let possible = targets(for: alias, record: record)
                    if possible.count > 1 {
                        for name in possible { ambiguous[name] = record.hosts }
                    }
                }
            }
        }
        // Prefer records already stored under the current name. Always retain
        // legacy revocations so migration cannot revive a revoked key.
        let canonicalNames = Set(legacyNames.values)
        let established = canonicalNames.filter { name in
            records.contains { record in
                guard let record, record.marker.isEmpty || record.marker == "@cert-authority" else { return false }
                return record.matchesHostPattern(name)
            }
        }
        let migrated = zip(lines, records).compactMap { line, record -> String? in
            guard let record, !isPatternList(record) else { return line }
            func targetName(for alias: Substring) -> String? {
                let possible = targets(for: alias, record: record)
                guard possible.count == 1, let name = possible.first, ambiguous[name] == nil else { return nil }
                return name
            }
            let field: String
            if record.isHashed {
                guard let canonical = targetName(for: record.hosts[...]) else { return line }
                if established.contains(canonical), record.marker != "@revoked" { return nil }
                guard let hashed = record.rehashName(canonical) else { return line }
                field = hashed
            } else {
                let aliases = record.hosts.split(separator: ",", omittingEmptySubsequences: false)
                guard aliases.contains(where: { targetName(for: $0) != nil }) else { return line }
                let updated = aliases.compactMap { alias -> String? in
                    guard let canonical = targetName(for: alias) else { return String(alias) }
                    return record.marker == "@revoked" || !established.contains(canonical) ? canonical : nil
                }
                guard !updated.isEmpty else { return nil }
                field = updated.joined(separator: ",")
            }
            guard field != record.hosts else { return line }
            let source = line.split(maxSplits: 3, whereSeparator: \.isWhitespace)[record.marker.isEmpty ? 0 : 1]
            var updated = line
            updated.replaceSubrange(source.startIndex..<source.endIndex, with: field)
            return updated
        }.joined(separator: "\n")
        return (migrated, ambiguous)
    }
    public func fingerprints(for host: SSHHost) async throws -> String {
        guard FileManager.default.fileExists(atPath: url.path) else { return "" }
        let result = try await ProcessRunner().run(Invocation(executable: "/usr/bin/ssh-keygen", arguments: ["-F", try key(for: host), "-f", url.path]))
        if result.status == 1 && result.output.isEmpty { return "" }
        guard result.status == 0 else { throw SSHError.failed(result.status, result.output) }
        let keys = result.output.split(separator: "\n").filter { !$0.hasPrefix("#") }.joined(separator: "\n")
        guard !keys.isEmpty else { return "" }
        let fingerprints = try await ProcessRunner().run(Invocation(executable: "/usr/bin/ssh-keygen", arguments: ["-l", "-E", "sha256", "-f", "-"], input: Data((keys + "\n").utf8)))
        guard fingerprints.status == 0 else { throw SSHError.failed(fingerprints.status, fingerprints.output) }
        return fingerprints.output
    }
    public func forget(_ host: SSHHost) async throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let result = try await ProcessRunner().run(Invocation(executable: "/usr/bin/ssh-keygen", arguments: ["-R", try key(for: host), "-f", url.path]))
        guard result.status == 0 else { throw SSHError.failed(result.status, result.output) }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
