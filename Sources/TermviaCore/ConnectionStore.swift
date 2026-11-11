import Foundation

public struct ConnectionStore {
    public let url: URL
    public init(url: URL) { self.url = url }
    private struct Document: Codable { var version: Int; var hosts: [SSHHost] }
    public func load() throws -> [SSHHost] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        if let legacy = try? decoder.decode([SSHHost].self, from: data) { try validate(legacy); return legacy }
        let document = try decoder.decode(Document.self, from: data)
        guard document.version == 1 else { throw SSHError.invalid(T("不支持的主机配置版本：%d", document.version)) }
        try validate(document.hosts)
        return document.hosts
    }
    private func validate(_ hosts: [SSHHost]) throws {
        for host in hosts { try host.validate() }
        guard Set(hosts.map(\.id)).count == hosts.count else { throw SSHError.invalid("主机标识重复") }
    }
    public func save(_ hosts: [SSHHost]) throws {
        try validate(hosts)
        let names = hosts.map { $0.name.trimmingCharacters(in: .whitespacesAndNewlines).folding(options: .caseInsensitive, locale: nil) }
        guard Set(names).count == hosts.count else { throw SSHError.invalid("主机名称已存在") }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(Document(version: 1, hosts: hosts)).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
