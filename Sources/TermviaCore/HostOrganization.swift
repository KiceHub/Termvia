import Foundation

/// Separate from connections so empty groups and manual order survive edits.
public struct HostOrganization: Codable, Equatable, Sendable {
    public var groups: [String] = []
    public var hosts: [UUID] = []
    public var appearances: [String: HostGroupAppearance] = [:]
    public var defaultGroupName: String?
    public init() {}
    private enum CodingKeys: String, CodingKey { case groups, hosts, appearances, defaultGroupName }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        groups = try values.decodeIfPresent([String].self, forKey: .groups) ?? []
        hosts = try values.decodeIfPresent([UUID].self, forKey: .hosts) ?? []
        defaultGroupName = try values.decodeIfPresent(String.self, forKey: .defaultGroupName)
        appearances = try (values.decodeIfPresent([String: HostGroupAppearance].self, forKey: .appearances) ?? [:]).mapValues { $0.validated() }
    }
    public func sections(_ connections: [SSHHost], search: String) -> [HostGroup] {
        let original = HostGroup.sections(connections, search: search, defaultGroupName: defaultGroupName)
        var names: [String] = [""]
        for name in groups + original.map({ $0.name ?? "" }) + [""] where !names.contains(name) { names.append(name) }
        let ranks = Dictionary(hosts.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        return names.compactMap { name -> HostGroup? in
            let groupName: String? = name.isEmpty ? nil : name
            if let group = original.first(where: { $0.name == groupName }) {
                // Natural name order is the deterministic tie breaker for newly added hosts.
                let members = group.hosts.enumerated().sorted {
                    let lhs = ranks[$0.element.id, default: Int.max], rhs = ranks[$1.element.id, default: Int.max]
                    return lhs == rhs ? $0.offset < $1.offset : lhs < rhs
                }.map(\.element)
                return HostGroup(name: groupName, hosts: members, displayName: groupName == nil ? defaultGroupName : nil)
            }
            return search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? HostGroup(name: groupName, hosts: [], displayName: groupName == nil ? defaultGroupName : nil) : nil
        }
    }
}
