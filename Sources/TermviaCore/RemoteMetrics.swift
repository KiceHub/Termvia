import Foundation

public struct IOCounters: Sendable, Equatable { public let read: UInt64; public let write: UInt64 }
public struct IORate: Sendable, Equatable { public let read: Double; public let write: Double }
public struct RemoteVolume: Identifiable, Sendable {
    public let source: String
    public let mount: String
    public let total: Double
    public let used: Double
    public let available: Double
    public var id: String { Data((source + "\0" + mount).utf8).base64EncodedString() }
    public init(source: String, mount: String, total: Double, used: Double, available: Double? = nil) {
        self.source = source; self.mount = mount; self.total = total; self.used = used
        self.available = available ?? total - used
    }
}
public enum RemotePlatform: String, Sendable { case linux = "Linux", macOS = "Darwin" }
public struct RemoteSnapshot: Sendable {
    public let platform: RemotePlatform
    public private(set) var time: Date
    public let hostClock: RemoteHostClock?
    public let uptime: Double?
    public let boot: String
    public let counterTime: Double
    public let physicalNetworkInterfaces: Set<String>
    public let physicalDisks: Set<String>
    public let hostname: String
    public let kernel: String
    public let system: String
    public let architecture: String
    public let processor: String
    public let cores: Int
    public let threads: Int
    public let cpu: [UInt64]
    public let cpuPercent: Double?
    public let memoryTotal: Double?
    public let memoryAvailable: Double?
    public let load: [Double]
    public let network: [String: IOCounters]
    public let preferredNetworkInterface: String?
    public let disks: [String: IOCounters]
    public let capacities: [String: Double]
    public let volumes: [RemoteVolume]
    public let diskUsage: [PhysicalDiskUsage]
    public var memoryUsed: Double? {
        guard let memoryTotal, let memoryAvailable else { return nil }
        return max(0, memoryTotal - memoryAvailable)
    }
    public var memoryPercent: Double? {
        guard let memoryTotal, memoryTotal > 0, let memoryUsed else { return nil }
        return min(100, memoryUsed / memoryTotal * 100)
    }
    fileprivate func sampled(at date: Date) -> Self { var copy = self; copy.time = date; return copy }

    private static let readableSections: Set<String> = ["platform", "uptime", "cpu", "cpu-percent", "cpu-baseline", "memory", "load", "hostname", "os", "network-compact", "disk-sectors", "network", "disks"]
    public static func parse(_ text: String, time: Date = Date(), inheriting previous: Self? = nil) throws -> Self {
        guard text.utf8.count <= 262144 else { throw MetricsError.invalid }
        var fields: [String: [String]] = [:], section = ""
        for line in text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            if line.hasPrefix("["), line.hasSuffix("]") {
                section = String(line.dropFirst().dropLast())
                if fields[section] == nil { fields[section] = [] }
            }
            else { fields[section, default: []].append(line) }
        }
        func words(_ value: String) -> [String] { value.split(whereSeparator: \.isWhitespace).map(String.init) }
        func short(_ value: String) -> String { String(decoding: value.utf8.prefix(512), as: UTF8.self) }
        func line(_ key: String, _ fallback: String = "") -> String { fields[key] == nil ? fallback : short(fields[key]?.first ?? "") }
        let physicalNetwork = fields["physical-network"] == nil ? previous?.physicalNetworkInterfaces ?? [] : PhysicalDevices.names(fields["physical-network"], limit: 256)
        let physicalDisks = fields["physical-disks"] == nil ? previous?.physicalDisks ?? [] : PhysicalDevices.names(fields["physical-disks"], limit: 512)
        guard let platform = RemotePlatform(rawValue: line("platform", previous?.platform.rawValue ?? "Linux")) else { throw MetricsError.invalid }
        // A missing or malformed sensor invalidates only that metric. Never
        // reuse a previous numeric sample as if it were a fresh measurement.
        func bounded(_ value: String, maximum: Double) -> Double? {
            guard let value = Double(value), value.isFinite, value >= 0, value <= maximum else { return nil }
            return value
        }
        let uptime = bounded(words(line("uptime")).first ?? "", maximum: 1e12)
        let cpuParts = words(line("cpu"))
        let ticks = cpuParts.dropFirst().prefix(8).compactMap(UInt64.init)
        let cpu = cpuParts.first == "cpu" && ticks.count >= 4 && ticks.count == min(8, cpuParts.count - 1) ? ticks : []
        let cpuPercent = platform == .macOS && fields["cpu-baseline"] == nil ? bounded(line("cpu-percent"), maximum: 100) : nil
        var memory: [String: Double] = [:]
        for row in fields["memory"] ?? [] {
            let parts = words(row)
            if parts.count >= 2, let value = UInt64(parts[1]), value <= UInt64.max / 1024 { memory[parts[0]] = Double(value) * 1024 }
        }
        let total = memory["MemTotal:"].flatMap { $0 > 0 ? $0 : nil }
        let estimated = memory["MemFree:"].map { $0 + (memory["Buffers:"] ?? 0) + (memory["Cached:"] ?? 0) }
        let available = total.flatMap { total in (memory["MemAvailable:"] ?? estimated).map { min(total, $0) } }
        let parsedLoads = words(line("load")).prefix(3).compactMap { bounded($0, maximum: 1e6) }
        let loads = parsedLoads.count == 3 ? parsedLoads : []
        var network: [String: IOCounters] = [:], disks: [String: IOCounters] = [:]
        var capacities = previous?.capacities.filter { physicalDisks.contains($0.key) } ?? [:]
        if fields["partitions"] != nil || fields["capacities"] != nil { capacities = [:] }
        for row in (fields["network"] ?? []).prefix(4096) {
            let parts = row.split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            let name = parts[0].trimmingCharacters(in: .whitespaces), values = words(parts[1])
            if physicalNetwork.contains(name), name.utf8.count <= 64, values.count >= 16, let rx = UInt64(values[0]), let tx = UInt64(values[8]) { network[name] = IOCounters(read: rx, write: tx) }
        }
        for row in (fields["disks"] ?? []).prefix(4096) {
            let p = words(row)
            if p.count >= 14, physicalDisks.contains(p[2]), let read = UInt64(p[5]), let write = UInt64(p[9]), read <= UInt64.max / 512, write <= UInt64.max / 512 { disks[p[2]] = IOCounters(read: read * 512, write: write * 512) }
        }
        for row in (fields["partitions"] ?? []).prefix(514) {
            let p = words(row)
            if p.count == 4, physicalDisks.contains(p[3]), let blocks = UInt64(p[2]), blocks <= UInt64.max / 1024 { capacities[p[3]] = Double(blocks) * 1024 }
        }
        var volumes: [RemoteVolume] = fields["volumes"] == nil ? previous?.volumes ?? [] : []; var volumeIDs = Set<String>()
        if platform == .macOS, fields["network-darwin"] != nil || fields["disks-darwin"] != nil {
            network = DarwinMetrics.network(fields["network-darwin"] ?? [], physical: physicalNetwork)
            let storage = DarwinMetrics.storage(fields["disks-darwin"] ?? [], physical: physicalDisks)
            disks = storage.counters; capacities = storage.capacities
        }
        func compactCounters(_ section: String, allowed: Set<String>, multiplier: UInt64 = 1) -> [String: IOCounters] {
            var result: [String: IOCounters] = [:]
            for row in (fields[section] ?? []).prefix(512) {
                let p = words(row)
                guard p.count == 3, allowed.contains(p[0]), let read = UInt64(p[1]), let write = UInt64(p[2]), read <= UInt64.max / multiplier, write <= UInt64.max / multiplier else { continue }
                result[p[0]] = IOCounters(read: read * multiplier, write: write * multiplier)
            }
            return result
        }
        if fields["network-compact"] != nil { network = compactCounters("network-compact", allowed: physicalNetwork) }
        if fields["disks-compact"] != nil { disks = compactCounters("disks-compact", allowed: physicalDisks) }
        if fields["disk-sectors"] != nil { disks = compactCounters("disk-sectors", allowed: physicalDisks, multiplier: 512) }
        for row in (fields["capacities"] ?? []).prefix(512) {
            let p = words(row)
            if p.count == 2, physicalDisks.contains(p[0]), let bytes = UInt64(p[1]) { capacities[p[0]] = Double(bytes) }
        }
        for row in (fields["volumes"] ?? []).prefix(129) {
            let p = words(row)
            if p.count >= 6, let size = UInt64(p[1]), let used = UInt64(p[2]), let available = Int64(p[3]), size <= UInt64.max / 1024, size > 0, used <= size, available <= Int64(size) { let volume = RemoteVolume(source: p[0], mount: p.dropFirst(5).joined(separator: " "), total: Double(size) * 1024, used: Double(used) * 1024, available: Double(max(0, available)) * 1024); if volumeIDs.insert(volume.id).inserted { volumes.append(volume) } }
        }
        let metadataChanged = ["physical-disks", "volumes", "volume-physical-map", "mounts-linux", "disk-layout-darwin", "apfs-darwin"].contains { fields[$0] != nil }
        let diskUsage = !metadataChanged && previous != nil ? previous!.diskUsage : platform == .linux
            ? DiskUsageDecoder.linux(fields["volume-physical-map"] ?? [], volumes: volumes, physical: physicalDisks, mounts: fields["mounts-linux"] ?? [])
            : DiskUsageDecoder.mac(layout: fields["disk-layout-darwin"] ?? [], apfs: fields["apfs-darwin"] ?? [], volumes: volumes, physical: physicalDisks)
        let os = (fields["os"] ?? []).first { $0.hasPrefix("PRETTY_NAME=") }.map { String($0.dropFirst(12)).trimmingCharacters(in: CharacterSet(charactersIn: "\"'")) } ?? (fields["os"] == nil ? previous?.system : nil) ?? (platform == .macOS ? "macOS" : "Linux")
        guard fields.keys.contains(where: readableSections.contains) else { throw MetricsError.invalid }
        let hostClock = RemoteHostClock.parse(line("clock"))
        let counterTime = bounded(line("counter-time"), maximum: 1e12) ?? uptime ?? hostClock?.date.timeIntervalSince1970 ?? time.timeIntervalSince1970
        guard counterTime.isFinite else { throw MetricsError.invalid }
        func count(_ key: String, previous: Int) -> Int {
            guard fields[key] != nil else { return previous }
            guard let value = Int(line(key)), (1...65536).contains(value) else { return 0 }
            return value
        }
        let threads = count("threads", previous: previous?.threads ?? 0)
        let cores = count("cores", previous: previous?.cores ?? 0)
        return Self(platform: platform, time: time, hostClock: hostClock, uptime: uptime, boot: line("boot", previous?.boot ?? ""), counterTime: counterTime, physicalNetworkInterfaces: physicalNetwork, physicalDisks: physicalDisks, hostname: line("hostname", previous?.hostname ?? ""), kernel: line("kernel", previous?.kernel ?? ""), system: short(os), architecture: line("architecture", previous?.architecture ?? ""), processor: line("processor", previous?.processor ?? ""), cores: threads > 0 && cores > threads ? 0 : cores, threads: threads, cpu: cpu, cpuPercent: cpuPercent, memoryTotal: total, memoryAvailable: available, load: loads, network: network, preferredNetworkInterface: network[line("primary-interface", previous?.preferredNetworkInterface ?? "")] == nil ? nil : line("primary-interface", previous?.preferredNetworkInterface ?? ""), disks: disks, capacities: capacities, volumes: volumes, diskUsage: diskUsage)
    }
}
public enum MetricsError: LocalizedError {
    case invalid
    public var errorDescription: String? { T("监控数据无效或超出限制") }
}
public struct MetricsSample: Identifiable, Sendable {
    public let id = UUID()
    public let snapshot: RemoteSnapshot
    public let samplingInterval: TimeInterval
    public let cpuPercent: Double?
    public let network: [String: IORate]
    public let disks: [String: IORate]
    public func networkRate(device: String?) -> IORate? { Self.rate(network, device: device) }
    public func diskRate(device: String?) -> IORate? { Self.rate(disks, device: device) }
    private static func rate(_ values: [String: IORate], device: String?) -> IORate? {
        if let device { return values[device] }
        guard !values.isEmpty else { return nil }
        return values.values.reduce(IORate(read: 0, write: 0)) { IORate(read: $0.read + $1.read, write: $0.write + $1.write) }
    }
    public func diskCapacity(device: String?) -> Double? {
        if let device { return snapshot.capacities[device] }
        guard !snapshot.capacities.isEmpty else { return nil }
        return snapshot.capacities.values.reduce(0, +)
    }
}
public struct MetricsHistory {
    public private(set) var samples: [MetricsSample] = []
    private var previous: RemoteSnapshot?
    public init() {}
    public mutating func pause() { previous = nil }
    public mutating func append(_ current: RemoteSnapshot, interval: TimeInterval = 1) {
        if let last = samples.last?.snapshot, current.platform != last.platform || (current.uptime.flatMap { now in last.uptime.map { now < $0 } } ?? false) || (!current.boot.isEmpty && !last.boot.isEmpty && current.boot != last.boot) { samples = []; self.previous = nil }
        let elapsed = previous.map { current.counterTime - $0.counterTime } ?? 0
        func rates(_ now: [String: IOCounters], _ before: [String: IOCounters]?) -> [String: IORate] {
            guard elapsed >= 0.001, let before else { return [:] }
            return now.reduce(into: [:]) { result, item in
                guard let old = before[item.key], item.value.read >= old.read, item.value.write >= old.write else { return }
                result[item.key] = IORate(read: Double(item.value.read - old.read) / elapsed, write: Double(item.value.write - old.write) / elapsed)
            }
        }
        var percentage = current.cpuPercent
        if percentage == nil, current.cpu.count >= 4, let old = previous, old.cpu.count == current.cpu.count, zip(current.cpu, old.cpu).allSatisfy({ $0 >= $1 }) {
            let delta = zip(current.cpu, old.cpu).map { Double($0 - $1) }, total = zip(current.cpu, old.cpu).reduce(0.0) { $0 + Double($1.0 - $1.1) }
            if total > 0 { percentage = max(0, min(100, (1 - (delta[3] + (delta.count > 4 ? delta[4] : 0)) / total) * 100)) }
        }
        samples.append(MetricsSample(snapshot: current, samplingInterval: interval.isFinite ? min(30, max(1, interval)) : 1, cpuPercent: percentage, network: rates(current.network, previous?.network), disks: rates(current.disks, previous?.disks)))
        if samples.count > 120 { samples.removeFirst(samples.count - 120) }
        previous = current
    }
}
/// Incremental, bounded frames. Non-frame text is retained only as a bounded
/// diagnostic, never interpreted as metrics. Feed serially; read diagnostics
/// after the producing stream has finished.
public final class MetricsDecoder: @unchecked Sendable {
    private var pending = Data(), frame: [String]?, frameSize = 0
    private var diagnostics = Data()
    private static let diagnosticLimit = 2048
    /// Read after the stream finishes. Only text outside telemetry frames is
    /// suitable for a diagnostic; a truncated frame is never an error message.
    public var diagnosticOutput: String {
        var tail = diagnostics
        if frame == nil, !pending.isEmpty {
            let text = String(decoding: pending, as: UTF8.self)
            let markers = ["@termvia-begin", "@termvia-begin-v2", "@termvia-end"]
            if !text.hasPrefix("@termvia-"), !markers.contains(where: { $0.hasPrefix(text) }) { tail.append(pending) }
        }
        return String(decoding: tail.suffix(Self.diagnosticLimit), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    private var compact = false
    private var previous: RemoteSnapshot?
    private var clockAnchor: (counter: Double, date: Date)?
    private var lastClockCounter: Double?
    public init() {}
    public func feed(_ data: Data) throws -> [RemoteSnapshot] {
        pending.append(data); var result: [RemoteSnapshot] = []
        while let end = pending.firstIndex(of: 10) {
            guard end <= 262144, let line = String(data: pending.prefix(upTo: end), encoding: .utf8) else { throw MetricsError.invalid }
            pending.removeSubrange(...end)
            if line == "@termvia-begin" || line == "@termvia-begin-v2" {
                if line == "@termvia-begin" { previous = nil; clockAnchor = nil; lastClockCounter = nil }
                compact = line == "@termvia-begin-v2"; frame = []; frameSize = 0
            }
            else if line == "@termvia-end", let completed = frame {
                frame = nil
                if compact && previous == nil && !completed.contains("[platform]") { throw MetricsError.invalid }
                let snapshot = try RemoteSnapshot.parse(completed.joined(separator: "\n"), inheriting: compact ? previous : nil)
                previous = compact ? snapshot : nil; result.append(snapshot)
            }
            else if frame != nil { frameSize += line.utf8.count + 1; guard frameSize <= 262144 else { throw MetricsError.invalid }; frame!.append(line) }
            else if !line.isEmpty, !line.hasPrefix("@termvia-") {
                diagnostics.append(contentsOf: (line + "\n").utf8)
                if diagnostics.count > Self.diagnosticLimit { diagnostics.removeFirst(diagnostics.count - Self.diagnosticLimit) }
            }
        }
        guard pending.count <= 262144 else { throw MetricsError.invalid }
        if compact, let last = result.last {
            let now = Date()
            let skew = clockAnchor.map { abs($0.date.addingTimeInterval(last.counterTime - $0.counter).timeIntervalSince(now)) } ?? .infinity
            if clockAnchor == nil || last.counterTime < (lastClockCounter ?? last.counterTime) || skew > 5 { clockAnchor = (last.counterTime, now) }
            if let anchor = clockAnchor {
                // SSH can batch several frames in one read. Their placement
                // follows the sampler's clock, never sub-millisecond receipts.
                result = result.map { $0.sampled(at: anchor.date.addingTimeInterval($0.counterTime - anchor.counter)) }
                previous = result.last
                lastClockCounter = last.counterTime
            }
        }
        return result
    }
}
public enum RemoteSampler {
    public static let linuxScript = LinuxSampler.script
    public static let script: String = "LC_ALL=C; export LC_ALL\ncase \"$(uname -s)\" in\nLinux)\n" + linuxScript + "\n;;\nDarwin)\n" + DarwinMetrics.script + "\n;;\n*) exit 42;;\nesac"
    public static func localInvocation(samples: Int? = nil, interval: Int = 1) -> Invocation {
        Invocation(executable: "/bin/sh", arguments: ["-c", script, "termvia-local", samples.map { String(max(1, min(120, $0))) } ?? "0", String(min(30, max(1, interval)))])
    }
    private static let scriptInput = Data((script + "\n").utf8)
    /// Dropbear limits the SSH exec request to 9000 bytes. Keep that request
    /// short and stream the complete program through the channel's stdin.
    public static func remoteInvocation(_ host: SSHHost, commands: SSHCommands, samples: Int? = nil, interval: Int = 1) throws -> Invocation {
        let limit = samples.map { String(max(1, min(120, $0))) } ?? "0"
        var invocation = try commands.execute(host, command: "LC_ALL=C sh -s -- " + limit + " " + String(min(30, max(1, interval))))
        invocation.input = scriptInput
        return invocation
    }
}
