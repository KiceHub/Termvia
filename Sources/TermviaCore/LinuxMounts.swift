import Foundation

/// A small mountinfo projection, with paths decoded only after field splitting.
/// Overlay capacity follows its writable upper filesystem, never its lower image.
struct LinuxMount {
    let identity: String
    let path: String
    let kind: String
    let readOnly: Bool
    let upper: String?
    var overlay: Bool { kind == "overlay" || kind == "overlayfs" }
    static func decode(_ rows: [String]) -> [Self] {
        rows.prefix(2048).compactMap { row in
            let p = row.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard p.count == 5, p[0].range(of: #"^[0-9]+:[0-9]+$"#, options: .regularExpression) != nil,
                  let path = unescape(p[1]), path.hasPrefix("/"), path.utf8.count <= 4096,
                  p[2].utf8.count <= 64 else { return nil }
            return Self(identity: p[0], path: path == "/" ? path : "/" + path.trimmingCharacters(in: CharacterSet(charactersIn: "/")),
                        kind: p[2], readOnly: p[3].split(separator: ",").contains("ro"), upper: p[4].isEmpty ? nil : unescape(p[4]))
        }
    }
    private static func unescape(_ value: String) -> String? {
        let bytes = Array(value.utf8); var result: [UInt8] = [], i = 0
        while i < bytes.count {
            if bytes[i] == 92 {
                if i + 3 < bytes.count, bytes[(i + 1)...(i + 3)].allSatisfy({ (48...55).contains($0) }) {
                    let number = Int(bytes[i + 1] - 48) * 64 + Int(bytes[i + 2] - 48) * 8 + Int(bytes[i + 3] - 48)
                    guard number > 0, number < 256 else { return nil }; result.append(UInt8(number)); i += 4; continue
                }
                if i + 1 < bytes.count, [44, 58, 92].contains(bytes[i + 1]) { result.append(bytes[i + 1]); i += 2; continue }
                return nil
            }
            guard bytes[i] != 0 else { return nil }; result.append(bytes[i]); i += 1
        }
        return String(bytes: result, encoding: .utf8)
    }
    func backing(in mounts: [Self], physical: [String: Set<String>], visited: Set<String> = []) -> (identity: String, devices: Set<String>)? {
        guard overlay, !visited.contains(path), visited.count < 16,
              let upper, upper.hasPrefix("/"),
              let mount = mounts.filter({ upper == $0.path || upper.hasPrefix($0.path == "/" ? "/" : $0.path + "/") }).max(by: { $0.path.count < $1.path.count }) else { return nil }
        if mount.overlay { return mount.backing(in: mounts, physical: physical, visited: visited.union([path])) }
        if let devices = physical[mount.identity], !devices.isEmpty { return (mount.identity, devices) }
        // OpenWrt flash filesystems need not expose a conventional block device.
        if ["ubifs", "jffs2"].contains(mount.kind) { return (mount.identity, []) }
        return nil
    }
}

