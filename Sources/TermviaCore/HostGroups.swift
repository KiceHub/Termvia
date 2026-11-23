import Foundation

public struct HostGroup: Identifiable, Equatable, Sendable {
    public let name: String?
    public let hosts: [SSHHost]
    public var displayName: String? = nil
    public var id: String { name.map { "group:" + $0 } ?? "ungrouped" }
    public var title: String { displayName ?? name ?? T("默认分组") }

    public static func sections(_ hosts: [SSHHost], search: String, defaultGroupName: String? = nil) -> [HostGroup] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        let defaultTitle = defaultGroupName ?? T("默认分组")
        let filtered = hosts.filter { host in
            let group = host.group?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return query.isEmpty || [host.name, host.address, host.user, group.isEmpty ? defaultTitle : group, String(host.port)].contains {
                matches($0, query: query)
            }
        }
        let groups = Dictionary(grouping: filtered) { host -> String in
            let group = host.group?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return group
        }
        return groups.map { name, members in
            HostGroup(name: name.isEmpty ? nil : name, hosts: members.sorted {
                let order = $0.name.localizedStandardCompare($1.name)
                return order == .orderedSame ? $0.id.uuidString < $1.id.uuidString : order == .orderedAscending
            }, displayName: name.isEmpty ? defaultGroupName : nil)
        }.sorted {
            if $0.name == nil { return $1.name != nil }
            if $1.name == nil { return false }
            return $0.name!.localizedStandardCompare($1.name!) == .orderedAscending
        }
    }

    static func matches(_ text: String, query: String) -> Bool {
        text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }
}
