import Foundation

public struct KnownHostsStore: Sendable {
    public let url: URL
    public init(url: URL) { self.url = url }
    public func records() async throws -> [KnownHostRecord] { try await KnownHostsRecords.shared.records(at: url) }
    public func forget(_ record: KnownHostRecord) async throws { try await KnownHostsRecords.shared.forget(record, at: url) }
    public func key(for host: SSHHost) throws -> String {
        try host.validate()
        return host.port == 22 ? host.address : "[\(host.address)]:\(host.port)"
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
