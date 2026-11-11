import Foundation

public struct PhysicalDiskUsage: Sendable {
    public let identity: String
    public let devices: Set<String>
    public let total: Double
    public let used: Double
    public let remaining: Double
}

enum DiskUsageDecoder {
    private static func valid(_ identity: String, devices: Set<String>, total: Double, used: Double, remaining: Double? = nil, allowUnmapped: Bool = false) -> PhysicalDiskUsage? {
        let remaining = remaining ?? total - used
        guard !identity.isEmpty, identity.utf8.count <= 256, (!devices.isEmpty || allowUnmapped),
              total.isFinite, used.isFinite, total > 0, used >= 0, used <= total, remaining.isFinite, remaining >= 0, used + remaining <= total * 1.01 else { return nil }
        return PhysicalDiskUsage(identity: identity, devices: devices, total: total, used: used, remaining: remaining)
    }
    static func linux(_ mappings: [String], volumes: [RemoteVolume], physical: Set<String>, mounts rows: [String] = []) -> [PhysicalDiskUsage] {
        var sources: [String: (String, Set<String>)] = [:]
        for row in mappings.prefix(2048) {
            let fields = row.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard fields.count == 3, fields[0].utf8.count <= 1024, fields[1].utf8.count <= 128 else { continue }
            let devices = Set(fields[2].split(separator: ",").map(String.init))
            if !devices.isEmpty, devices.isSubset(of: physical) { sources[fields[0]] = (fields[1], devices) }
        }
        let mounts = LinuxMount.decode(rows)
        var physicalByIdentity: [String: Set<String>] = [:]
        for (_, value) in sources { physicalByIdentity[value.0, default: []].formUnion(value.1) }
        var overlays: [String: (identity: String, devices: Set<String>)] = [:]
        for mount in mounts where mount.overlay {
            if let backing = mount.backing(in: mounts, physical: physicalByIdentity) { overlays[mount.path] = backing }
        }
        let backingIDs = Set(overlays.values.map(\.identity))
        var records: [String: PhysicalDiskUsage] = [:]
        func insert(_ item: PhysicalDiskUsage) {
            if let old = records[item.identity] {
                records[item.identity] = valid(item.identity, devices: item.devices.union(old.devices), total: max(old.total, item.total), used: max(old.used, item.used), remaining: min(old.remaining, item.remaining), allowUnmapped: true)
            } else { records[item.identity] = item }
        }
        var rootFallback: PhysicalDiskUsage?
        for volume in volumes {
            let mount = mounts.first { $0.path == volume.mount }
            let backing: (String, Set<String>)?
            if let overlay = overlays[volume.mount] { backing = (overlay.identity, overlay.devices) }
            else if let mount, !mount.overlay, backingIDs.contains(mount.identity) { backing = (mount.identity, physicalByIdentity[mount.identity] ?? []) }
            else { backing = sources[volume.source] }
            let remaining = mount?.overlay == true && mount?.readOnly == true ? 0 : volume.available
            if let (identity, devices) = backing,
               let item = valid(identity, devices: devices, total: volume.total, used: volume.used, remaining: remaining, allowUnmapped: true) { insert(item) }
            else if let mount, mount.overlay, mount.path == "/" {
                rootFallback = valid("overlay:" + mount.identity, devices: [], total: volume.total, used: volume.used, remaining: remaining, allowUnmapped: true)
            }
        }
        // Container namespaces may hide upperdir and all its backing mounts.
        // Use root statfs/df only when no mapped data is available, avoiding a
        // second copy of storage already exposed by bind mounts in that namespace.
        if records.isEmpty, let rootFallback { insert(rootFallback) }
        return Array(records.values)
    }
    private static func plist(_ rows: [String]) -> [String: Any] {
        guard let data = rows.joined(separator: "\n").data(using: .utf8), data.count <= 196608 else { return [:] }
        return (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)) as? [String: Any] ?? [:]
    }
    static func mac(layout: [String], apfs: [String], volumes: [RemoteVolume], physical: Set<String>) -> [PhysicalDiskUsage] {
        var parents: [String: String] = [:]
        for disk in (plist(layout)["AllDisksAndPartitions"] as? [[String: Any]] ?? []).prefix(512) {
            guard let name = disk["DeviceIdentifier"] as? String, physical.contains(name) else { continue }
            parents[name] = name
            for partition in (disk["Partitions"] as? [[String: Any]] ?? []).prefix(256) {
                if let child = partition["DeviceIdentifier"] as? String { parents[child] = name }
            }
        }
        var result: [PhysicalDiskUsage] = [], containers = Set<String>(), stores = Set<String>()
        for container in (plist(apfs)["Containers"] as? [[String: Any]] ?? []).prefix(512) {
            let physicalStores = (container["PhysicalStores"] as? [[String: Any]] ?? []).compactMap { $0["DeviceIdentifier"] as? String }
            let devices = Set(physicalStores.compactMap { parents[$0] })
            guard let reference = container["ContainerReference"] as? String, !devices.isEmpty,
                  physicalStores.allSatisfy({ parents[$0] != nil }),
                  let total = container["CapacityCeiling"] as? NSNumber, let free = container["CapacityFree"] as? NSNumber,
                  free.doubleValue >= 0, free.doubleValue <= total.doubleValue,
                  let record = valid("apfs:" + reference, devices: devices, total: total.doubleValue, used: total.doubleValue - free.doubleValue) else { continue }
            containers.insert(reference); stores.formUnion(physicalStores); result.append(record)
        }
        var seen = Set<String>()
        for volume in volumes {
            let name = volume.source.hasPrefix("/dev/") ? String(volume.source.dropFirst(5)) : volume.source
            // APFS volumes/snapshots share container allocation; count its
            // native allocated capacity once, never sum their df rows.
            if stores.contains(name) || containers.contains(where: { name == $0 || name.hasPrefix($0 + "s") }) { continue }
            guard let parent = parents[name], seen.insert(name).inserted,
                  let record = valid("fs:" + name, devices: [parent], total: volume.total, used: volume.used, remaining: volume.available) else { continue }
            result.append(record)
        }
        return result
    }
}

/// Readable filesystem/container space. Unknown devices are excluded from both
/// sides of the sum; remaining uses df Available (excluding reserved blocks).
public struct DiskSpace: Sendable, Equatable {
    public let used: Double
    public let remaining: Double
    public var total: Double { used + remaining }
}

extension RemoteSnapshot {
    public func diskSpace(device: String?) -> DiskSpace? {
        var used = 0.0, remaining = 0.0, count = 0
        for item in diskUsage {
            if let device, !item.devices.contains(device) || item.devices.count != 1 { continue }
            let backing = item.devices.compactMap { capacities[$0] }
            // A failed raw-size read does not invalidate readable filesystem
            // data. Reject inconsistent overprovisioning only when sizes exist.
            if !item.devices.isEmpty, backing.count == item.devices.count, item.total > backing.reduce(0, +) * 1.01 { continue }
            used += item.used; remaining += item.remaining; count += 1
        }
        guard count > 0, used.isFinite, remaining.isFinite else { return nil }
        return DiskSpace(used: used, remaining: remaining)
    }
    public func diskUsedCapacity(device: String?) -> Double? { diskSpace(device: device)?.used }
}
